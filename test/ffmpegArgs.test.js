const { buildFfmpegArgs } = require('../src/services/thumbnailGenerator');
const { VideoUrlValidationError } = require('../src/lib/videoUrlPolicy');

describe('FFmpeg argument contract', () => {
    const videoUrl = 'https://storage.googleapis.com/bucket/clip.mp4?X-Goog-Signature=secret';
    const args = buildFfmpegArgs(videoUrl, '/tmp/thumb.jpg', {
        width: 640,
        height: -1,
        timePosition: '00:00:01',
        quality: 85,
    });

    test('keeps FFmpeg on an argv array with a closed HTTPS protocol set', () => {
        expect(args[args.indexOf('-protocol_whitelist') + 1]).toBe('https,tls,tcp');
        expect(args.join(' ')).not.toMatch(/\bfile\b/);
        expect(args[args.indexOf('-max_redirects') + 1]).toBe('0');
        expect(args[args.indexOf('-i') + 1]).toBe(videoUrl);
    });

    test('forces the validated container and bounds the decode/output', () => {
        const inputFormatIndex = args.indexOf('-f');
        expect(args[inputFormatIndex + 1]).toBe('mp4');
        expect(args[args.indexOf('-t') + 1]).toBe('1');
        expect(args).toContain('-an');
        expect(args[args.lastIndexOf('-f') + 1]).toBe('image2');
        expect(args[args.indexOf('-fs') + 1]).toBe(String(5 * 1024 * 1024));
    });

    test('rejects a URL that never passed the host policy', () => {
        expect(() => buildFfmpegArgs(
            'https://.storage.googleapis.com/video.mp4',
            '/tmp/thumb.jpg',
            { width: 640, height: -1, timePosition: '00:00:01', quality: 85 },
        )).toThrow('videoUrl host is not allowed');
    });

    // The HTTP route normalizes options, but it is not the only possible caller
    // and `-vf scale=W:H` is filter syntax: a width carrying `,drawtext=...`
    // would render a local file into the returned JPEG. buildFfmpegArgs must
    // therefore refuse options itself rather than trusting whoever called it.
    test.each([
        ['filter injection through width', { width: '640,drawtext=textfile=/etc/passwd', height: -1, timePosition: '00:00:01', quality: 85 }],
        ['filter injection through height', { width: 640, height: '-1[a];movie=/etc/passwd', timePosition: '00:00:01', quality: 85 }],
        ['argv injection through timePosition', { width: 640, height: -1, timePosition: '00:00:01 -f lavfi', quality: 85 }],
        ['unbounded width', { width: 999999, height: -1, timePosition: '00:00:01', quality: 85 }],
        ['non-integer quality', { width: 640, height: -1, timePosition: '00:00:01', quality: '85' }],
        ['missing options entirely', undefined],
    ])('refuses unvalidated options from a non-route caller: %s', (_label, config) => {
        expect(() => buildFfmpegArgs(
            'https://storage.googleapis.com/bucket/clip.mp4',
            '/tmp/thumb.jpg',
            config,
        )).toThrow(VideoUrlValidationError);
    });

    test('never lets a filter expression reach the -vf argument', () => {
        const injected = { width: '640,drawtext=text=pwned', height: -1, timePosition: '00:00:01', quality: 85 };
        expect(() => buildFfmpegArgs('https://storage.googleapis.com/bucket/clip.mp4', '/tmp/t.jpg', injected))
            .toThrow('size is outside the supported bounds');
    });
});
