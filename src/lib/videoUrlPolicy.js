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
    if (host !== 'storage.googleapis.com' && !host.endsWith('.storage.googleapis.com')) {
        throw new VideoUrlValidationError('videoUrl host is not allowed');
    }

    const lowerPath = parsed.pathname.toLowerCase();
    const hasVideoExtension = [...VIDEO_EXTENSIONS].some(extension => lowerPath.endsWith(extension));
    if (!hasVideoExtension) {
        throw new VideoUrlValidationError('videoUrl path does not identify a supported video');
    }

    return parsed.toString();
}

function videoUrlForLog(value) {
    try {
        const parsed = new URL(value);
        const pathDigest = createHash('sha256').update(parsed.pathname).digest('hex').slice(0, 16);
        return `${parsed.origin}/object-sha256-${pathDigest}`;
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
};
