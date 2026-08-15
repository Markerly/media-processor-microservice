/**
 * DEVELOPER_SETUP.md requires "a log scan proving that a sentinel query secret
 * and object path do not appear" before a build is approved. That was a manual
 * checklist item, which means it was only ever as reliable as the operator
 * running it. This test makes it a release-blocking assertion instead.
 *
 * FFmpeg is stubbed rather than executed so the check is deterministic and
 * offline — and the stub is deliberately hostile: it writes the signed URL onto
 * stderr, which is exactly what real FFmpeg does when a signed GCS URL expires
 * or 403s. The service must drain that stream without ever logging it.
 */
const { EventEmitter } = require('events');

jest.mock('child_process', () => ({ spawn: jest.fn() }));

const { spawn } = require('child_process');
const request = require('supertest');
const { app } = require('../src/index');

const SECRET = 'SENTINELSIGNATUREVALUE123';
const OBJECT = 'sentinel-object-path-xyz';
const BUCKET = 'sentinel-bucket-name';
const SIGNED_URL =
    `https://${BUCKET}.storage.googleapis.com/${OBJECT}/clip.mp4?X-Goog-Signature=${SECRET}`;

function stubFfmpegFailure() {
    const child = new EventEmitter();
    child.stderr = new EventEmitter();
    child.kill = () => {};
    process.nextTick(() => {
        child.stderr.emit(
            'data',
            Buffer.from(`[https @ 0x0] HTTP error 403 Forbidden\n${SIGNED_URL}: Server returned 403\n`),
        );
        child.emit('close', 8);
    });
    return child;
}

describe('signed-URL redaction across the whole request path', () => {
    let written;
    const sinks = [];

    beforeEach(() => {
        written = [];
        spawn.mockImplementation(stubFfmpegFailure);
        for (const method of ['log', 'error', 'warn']) {
            sinks.push([method, console[method]]);
            console[method] = (...args) => {
                written.push(args.map(value =>
                    typeof value === 'string' ? value : JSON.stringify(value)).join(' '));
            };
        }
    });

    afterEach(() => {
        for (const [method, original] of sinks.splice(0)) console[method] = original;
        spawn.mockReset();
    });

    test('no sentinel reaches the logs or the client when FFmpeg fails loudly', async () => {
        const response = await request(app).post('/generate-thumbnail').send({ videoUrl: SIGNED_URL });

        expect(response.status).toBe(500);

        const logs = written.join('\n');
        // The request must have actually been processed, or this proves nothing.
        expect(logs).toContain('gcs-object-sha256-');
        expect(spawn).toHaveBeenCalledTimes(1);

        for (const [label, sentinel] of [
            ['signed query credential', SECRET],
            ['object path', OBJECT],
            ['bucket name', BUCKET],
        ]) {
            expect(`${label}:${logs}`).not.toContain(sentinel);
            expect(`${label}:${JSON.stringify(response.body)}`).not.toContain(sentinel);
        }
    });

    test('the URL handed to FFmpeg is the validated one, fragment stripped', async () => {
        await request(app)
            .post('/generate-thumbnail')
            .send({ videoUrl: `${SIGNED_URL}#fragment` });

        const args = spawn.mock.calls[0][1];
        expect(args[args.indexOf('-i') + 1]).toBe(SIGNED_URL);
        expect(args.join(' ')).not.toContain('#fragment');
    });
});
