const { createHash } = require('crypto');

class VideoUrlValidationError extends Error {
    constructor(message) {
        super(message);
        this.name = 'VideoUrlValidationError';
    }
}

const VIDEO_EXTENSIONS = new Set([
    '.mp4', '.mov', '.avi', '.mkv', '.webm', '.flv', '.m4v', '.mpeg', '.mpg'
]);

const INPUT_FORMAT_BY_EXTENSION = {
    '.mp4': 'mp4',
    '.m4v': 'mp4',
    '.mov': 'mov',
    '.avi': 'avi',
    '.mkv': 'matroska',
    '.webm': 'webm',
    '.flv': 'flv',
    '.mpeg': 'mpeg',
    '.mpg': 'mpeg',
};

// GCS bucket names are 3-63 chars and cannot start or end with a punctuation mark.
const GCS_BUCKET_NAME = /^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$/;
const GCS_VIRTUAL_HOST_SUFFIX = '.storage.googleapis.com';

function extensionOfPath(pathname) {
    const lastSegment = pathname.toLowerCase().split('/').filter(Boolean).pop() || '';
    return [...VIDEO_EXTENSIONS].find(extension => lastSegment.endsWith(extension)) || null;
}

function configuredBucketAllowlist() {
    const raw = process.env.ALLOWED_VIDEO_BUCKETS;
    if (!raw) return null;
    const buckets = raw.split(',').map(entry => entry.trim()).filter(Boolean);
    return buckets.length > 0 ? new Set(buckets) : null;
}

function gcsBucketFromUrl(parsed) {
    const host = parsed.hostname.toLowerCase();
    if (host === 'storage.googleapis.com') {
        const parts = parsed.pathname.split('/').filter(Boolean);
        return parts[0] || '';
    }
    if (host.endsWith(GCS_VIRTUAL_HOST_SUFFIX)) {
        return host.slice(0, -GCS_VIRTUAL_HOST_SUFFIX.length);
    }
    return '';
}

function assertAllowedGcsHost(host) {
    if (host === 'storage.googleapis.com') return;
    if (!host.endsWith(GCS_VIRTUAL_HOST_SUFFIX)) {
        throw new VideoUrlValidationError('videoUrl host is not allowed');
    }
    const bucket = host.slice(0, -GCS_VIRTUAL_HOST_SUFFIX.length);
    if (!GCS_BUCKET_NAME.test(bucket)) {
        throw new VideoUrlValidationError('videoUrl host is not allowed');
    }
}

function ffmpegInputFormat(videoUrl) {
    const parsed = new URL(videoUrl);
    const extension = extensionOfPath(parsed.pathname);
    const format = extension ? INPUT_FORMAT_BY_EXTENSION[extension] : null;
    if (!format) {
        throw new VideoUrlValidationError('videoUrl path does not identify a supported video');
    }
    return format;
}

function validatedVideoUrl(value) {
    if (typeof value !== 'string' || value.length === 0 || value.length > 8192) {
        throw new VideoUrlValidationError('videoUrl must be a bounded string');
    }

    let parsed;
    try {
        parsed = new URL(value);
    } catch {
        throw new VideoUrlValidationError('videoUrl must be a valid URL');
    }

    const host = parsed.hostname.toLowerCase();
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password) {
        throw new VideoUrlValidationError('videoUrl must be credential-free HTTPS');
    }
    if (parsed.port && parsed.port !== '443') {
        throw new VideoUrlValidationError('videoUrl must use the standard HTTPS port');
    }
    assertAllowedGcsHost(host);

    const pathParts = parsed.pathname.split('/').filter(Boolean);
    if (host === 'storage.googleapis.com' && pathParts.length < 2) {
        throw new VideoUrlValidationError('videoUrl path does not identify a supported video');
    }

    const bucket = gcsBucketFromUrl(parsed);
    if (!GCS_BUCKET_NAME.test(bucket)) {
        throw new VideoUrlValidationError('videoUrl host is not allowed');
    }
    const allowlist = configuredBucketAllowlist();
    if (allowlist && !allowlist.has(bucket)) {
        throw new VideoUrlValidationError('videoUrl host is not allowed');
    }

    if (!extensionOfPath(parsed.pathname)) {
        throw new VideoUrlValidationError('videoUrl path does not identify a supported video');
    }

    // Drop the fragment so it never reaches FFmpeg. Keep origin/path/query as
    // parsed so signed-query encoding is preserved without userinfo or hash.
    return `${parsed.origin}${parsed.pathname}${parsed.search}`;
}

function videoUrlForLog(value) {
    try {
        const parsed = new URL(value);
        const pathDigest = createHash('sha256')
            .update(`${parsed.hostname.toLowerCase()}\n${parsed.pathname}`)
            .digest('hex')
            .slice(0, 16);
        return `gcs-object-sha256-${pathDigest}`;
    } catch {
        return '[invalid video url]';
    }
}

const TIME_POSITION = /^(?:\d{1,2}:)?[0-5]\d:[0-5]\d(?:\.\d{1,3})?$/;
const MIN_DIMENSION = 64;
const MAX_DIMENSION = 1920;

function isBoundedDimension(value) {
    return Number.isInteger(value) && value >= MIN_DIMENSION && value <= MAX_DIMENSION;
}

/**
 * The single bound-enforcement point for every value that reaches the FFmpeg
 * argument vector.
 *
 * `normalizedThumbnailOptions` parses the wire shape (a `WIDTHxHEIGHT` string)
 * into these fields; `buildFfmpegArgs` re-asserts them on the way out. That
 * second assertion is not redundant: `-vf scale=W:H` is filter *syntax*, so a
 * width that never passed a bound lets a caller append filters — for example
 * `640,drawtext=textfile=/etc/passwd` — and render a local file into the JPEG
 * the service returns. Only the HTTP route normalizes today, so re-asserting
 * at the argv boundary means a future caller that bypasses it (a queue worker,
 * a batch job, a second endpoint) inherits the bound rather than silently
 * reopening the hole.
 */
function validatedFfmpegOptions({ timePosition, width, height, quality } = {}) {
    if (typeof timePosition !== 'string' || !TIME_POSITION.test(timePosition)) {
        throw new VideoUrlValidationError('timePosition must be a bounded timestamp');
    }
    if (!isBoundedDimension(width) || (height !== -1 && !isBoundedDimension(height))) {
        throw new VideoUrlValidationError('size is outside the supported bounds');
    }
    if (!Number.isInteger(quality) || quality < 1 || quality > 100) {
        throw new VideoUrlValidationError('quality must be an integer from 1 through 100');
    }

    return { timePosition, width, height, quality };
}

function normalizedThumbnailOptions({ timePosition, size, quality } = {}) {
    const normalizedSize = size ?? '640x-1';
    if (typeof normalizedSize !== 'string') {
        throw new VideoUrlValidationError('size must be a string');
    }
    const sizeMatch = normalizedSize.match(/^(\d{2,4})x(-1|\d{2,4})$/);
    if (!sizeMatch) {
        throw new VideoUrlValidationError('size must be WIDTHxHEIGHT');
    }

    return validatedFfmpegOptions({
        timePosition: timePosition ?? '00:00:01',
        width: Number(sizeMatch[1]),
        height: Number(sizeMatch[2]),
        quality: quality ?? 85,
    });
}

module.exports = {
    VideoUrlValidationError,
    validatedVideoUrl,
    videoUrlForLog,
    normalizedThumbnailOptions,
    validatedFfmpegOptions,
    ffmpegInputFormat,
};
