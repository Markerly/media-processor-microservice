const request = require('supertest');
const { app } = require('../src/index');

describe('HTTP request boundary', () => {
    test('health remains available', async () => {
        const response = await request(app).get('/health').expect(200);
        expect(response.body).toEqual(expect.objectContaining({ status: 'healthy' }));
    });

    test('an oversized JSON body returns 413 rather than masquerading as a server failure', async () => {
        await request(app)
            .post('/generate-thumbnail')
            .send({ videoUrl: 'x'.repeat(20_000) })
            .expect(413, { error: 'Request body is too large' });
    });

    test('malformed JSON returns a generic 400', async () => {
        await request(app)
            .post('/generate-thumbnail')
            .set('content-type', 'application/json')
            .send('{')
            .expect(400, { error: 'Request body is invalid JSON' });
    });

    test('an SSRF-shaped video URL is rejected before FFmpeg starts', async () => {
        await request(app)
            .post('/generate-thumbnail')
            .send({ videoUrl: 'http://metadata.google.internal/computeMetadata/v1/video.mp4' })
            .expect(400, {
                error: 'Bad Request',
                message: 'The video URL or thumbnail options are invalid',
            });
    });

    test('a lookalike GCS host is rejected before FFmpeg starts', async () => {
        await request(app)
            .post('/generate-thumbnail')
            .send({ videoUrl: 'https://.storage.googleapis.com/video.mp4' })
            .expect(400, {
                error: 'Bad Request',
                message: 'The video URL or thumbnail options are invalid',
            });
    });

    test('a missing JSON body fails as a bounded client error', async () => {
        await request(app)
            .post('/generate-thumbnail')
            .expect(400, {
                error: 'Bad Request',
                message: 'videoUrl is required',
            });
    });

    // Regression guard for issue #4: two per-IP, per-instance, in-memory limiters
    // (100 req / 15 min each) rejected 84% of thumbnail requests during a real
    // report burst on 2026-08-14, and platform-api's retries spent the same
    // budget they waited on. The service is private (Cloud Run IAM), so the
    // limiter protected nothing IAM does not and only dropped the sole authorized
    // caller. It was removed; this fires well past the old 100-request budget from
    // one source and asserts nothing is throttled. Bad-request bodies keep it off
    // the FFmpeg path so the burst stays fast and deterministic.
    test('a burst past the old rate-limit budget is never throttled', async () => {
        const BURST = 130; // > the old 100/15min ceiling
        const responses = await Promise.all(
            Array.from({ length: BURST }, () =>
                request(app).post('/generate-thumbnail').send({ videoUrl: '' })),
        );
        const throttled = responses.filter(r => r.status === 429);
        expect(throttled).toHaveLength(0);
        // And the requests really were served (not dropped some other way).
        expect(responses.every(r => r.status === 400)).toBe(true);
    });
});
