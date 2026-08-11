const {
    VideoUrlValidationError,
    validatedVideoUrl,
    videoUrlForLog,
    normalizedThumbnailOptions,
} = require('../src/lib/videoUrlPolicy');

describe('video URL security boundary', () => {
    test.each([
        'https://storage.googleapis.com/bucket/video.mp4?X-Goog-Signature=secret',
        'https://bucket.storage.googleapis.com/path/video.webm',
    ])('accepts a Google Storage HTTPS video object: %s', value => {
        expect(validatedVideoUrl(value)).toBe(value);
    });

    test.each([
        'http://storage.googleapis.com/bucket/video.mp4',
        'https://metadata.google.internal/storage.googleapis.com/video.mp4',
        'https://storage.googleapis.com.attacker.example/video.mp4',
        'https://user:pass@storage.googleapis.com/bucket/video.mp4',
        'https://storage.googleapis.com:444/bucket/video.mp4',
        'https://storage.googleapis.com/bucket/not-video.jpg?filename=video.mp4',
    ])('rejects an SSRF or lookalike URL: %s', value => {
        expect(() => validatedVideoUrl(value)).toThrow(VideoUrlValidationError);
    });

    test('log rendering strips signed query credentials and fragments', () => {
        const rendered = videoUrlForLog('https://storage.googleapis.com/bucket/video.mp4?X-Goog-Signature=secret#fragment');
        expect(rendered).toMatch(/^https:\/\/storage\.googleapis\.com\/object-sha256-[a-f0-9]{16}$/);
        expect(rendered).not.toContain('secret');
        expect(rendered).not.toContain('fragment');
        expect(rendered).not.toContain('bucket');
        expect(rendered).not.toContain('video.mp4');
    });

    test('normalizes bounded ffmpeg options', () => {
        expect(normalizedThumbnailOptions()).toEqual({
            timePosition: '00:00:01',
            width: 640,
            height: -1,
            quality: 85,
        });
        expect(normalizedThumbnailOptions({ timePosition: '12:34', size: '1920x1080', quality: 90 }))
            .toEqual({ timePosition: '12:34', width: 1920, height: 1080, quality: 90 });
    });

    test.each([
        { timePosition: '-i /etc/passwd' },
        { timePosition: '100%' },
        { size: '640x360;touch /tmp/pwned' },
        { size: '9999x9999' },
        { quality: '85' },
        { quality: 0 },
    ])('rejects an unsafe or unbounded ffmpeg option: %j', options => {
        expect(() => normalizedThumbnailOptions(options)).toThrow(VideoUrlValidationError);
    });
});
