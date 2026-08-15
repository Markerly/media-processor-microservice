const { buildFfmpegArgs } = require('../src/services/thumbnailGenerator');

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
});
