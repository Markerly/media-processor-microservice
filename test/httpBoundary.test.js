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

    test('a missing JSON body fails as a bounded client error', async () => {
        await request(app)
            .post('/generate-thumbnail')
            .expect(400, {
                error: 'Bad Request',
                message: 'videoUrl is required',
            });
    });
});
