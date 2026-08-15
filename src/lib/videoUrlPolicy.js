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

function normalizedThumbnailOptions({ timePosition, size, quality } = {}) {
    const normalizedTime = timePosition ?? '00:00:01';
    if (typeof normalizedTime !== 'string' ||
        !/^(?:\d{1,2}:)?[0-5]\d:[0-5]\d(?:\.\d{1,3})?$/.test(normalizedTime)) {
        throw new VideoUrlValidationError('timePosition must be a bounded timestamp');
    }

    const normalizedSize = size ?? '640x-1';
    if (typeof normalizedSize !== 'string') {
        throw new VideoUrlValidationError('size must be a string');
    }
    const sizeMatch = normalizedSize.match(/^(\d{2,4})x(-1|\d{2,4})$/);
    if (!sizeMatch) {
        throw new VideoUrlValidationError('size must be WIDTHxHEIGHT');
    }
    const width = Number(sizeMatch[1]);
    const height = Number(sizeMatch[2]);
    if (width < 64 || width > 1920 || (height !== -1 && (height < 64 || height > 1920))) {
        throw new VideoUrlValidationError('size is outside the supported bounds');
    }

    const normalizedQuality = quality ?? 85;
    if (!Number.isInteger(normalizedQuality) || normalizedQuality < 1 || normalizedQuality > 100) {
        throw new VideoUrlValidationError('quality must be an integer from 1 through 100');
    }

    return {
        timePosition: normalizedTime,
        width,
        height,
        quality: normalizedQuality,
    };
}

module.exports = {
    VideoUrlValidationError,
    validatedVideoUrl,
    videoUrlForLog,
    normalizedThumbnailOptions,
    ffmpegInputFormat,
};
