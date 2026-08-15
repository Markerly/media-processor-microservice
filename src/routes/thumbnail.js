/**
 * Thumbnail Generation Routes
 */

const express = require('express');
const fs = require('fs');
const path = require('path');
const { generateThumbnail, cleanupThumbnail, CONFIG } = require('../services/thumbnailGenerator');
const { thumbnailLimiter } = require('../middleware/rateLimiter');
const chalk = require('chalk');
const {
    VideoUrlValidationError,
    normalizedThumbnailOptions,
    validatedVideoUrl,
    videoUrlForLog,
} = require('../lib/videoUrlPolicy');

const router = express.Router();

/**
 * A failure this file constructs itself. The distinction matters for logging:
 * these messages are authored here and provably carry no request data, no
 * signed URL, and no third-party exception text, so they are safe to record in
 * full. FFmpeg, fs, and HTTP-client exceptions are not, and stay redacted to
 * their `name`.
 */
class ThumbnailIntegrityError extends Error {
    constructor(message) {
        super(message);
        this.name = 'ThumbnailIntegrityError';
    }
}

// Each branch names its own cause. Collapsing all three into "file is empty"
// made the single log line an operator sees during an incident describe a
// defect that had not occurred.
function assertJpegThumbnail(thumbnailPath) {
    const resolved = path.resolve(thumbnailPath);
    if (path.dirname(resolved) !== CONFIG.tempDir || path.extname(resolved) !== '.jpg') {
        throw new ThumbnailIntegrityError(`generated thumbnail escaped ${CONFIG.tempDir}/*.jpg`);
    }
    const header = Buffer.alloc(3);
    const fd = fs.openSync(resolved, 'r');
    try {
        if (fs.readSync(fd, header, 0, 3, 0) !== 3) {
            throw new ThumbnailIntegrityError('generated thumbnail is shorter than a JPEG header');
        }
    } finally {
        fs.closeSync(fd);
    }
    if (header[0] !== 0xff || header[1] !== 0xd8 || header[2] !== 0xff) {
        throw new ThumbnailIntegrityError('generated thumbnail is not JPEG (missing SOI marker)');
    }
}

/**
 * POST /generate-thumbnail
 *
 * Generates a thumbnail from a video URL
 *
 * Body:
 * {
 *   videoUrl: string (required) - URL of the video
 *   timePosition: string (optional) - Time position (e.g., '00:00:01' or '10%')
 *   size: string (optional) - Thumbnail size (e.g., '640x360')
 *   quality: number (optional) - JPEG quality (1-100)
 * }
 *
 * Returns: Thumbnail image file (image/jpeg)
 * Rate limit: 100 requests per 15 minutes per IP
 */
router.post('/generate-thumbnail', thumbnailLimiter, async (req, res) => {
    const { videoUrl: presentedVideoUrl, timePosition, size, quality } = req.body || {};

    if (!presentedVideoUrl) {
        return res.status(400).json({
            error: 'Bad Request',
            message: 'videoUrl is required'
        });
    }

    let videoUrl;
    let options;
    try {
        videoUrl = validatedVideoUrl(presentedVideoUrl);
        options = normalizedThumbnailOptions({ timePosition, size, quality });
    } catch (error) {
        if (!(error instanceof VideoUrlValidationError)) throw error;
        return res.status(400).json({
            error: 'Bad Request',
            message: 'The video URL or thumbnail options are invalid'
        });
    }

    let thumbnailPath = null;

    try {
        console.log(chalk.cyan('[Thumbnail Route] Request received for video:'), videoUrlForLog(videoUrl));

        thumbnailPath = await generateThumbnail(videoUrl, options);

        const stats = fs.statSync(thumbnailPath);
        if (stats.size === 0) {
            throw new ThumbnailIntegrityError('generated thumbnail file is empty');
        }
        assertJpegThumbnail(thumbnailPath);

        console.log(chalk.green('[Thumbnail Route] ✓ Sending thumbnail file:'), thumbnailPath, chalk.gray(`(${stats.size} bytes)`));

        res.sendFile(path.basename(thumbnailPath), {
            root: CONFIG.tempDir,
            dotfiles: 'deny',
            headers: { 'Content-Type': 'image/jpeg' },
        }, (err) => {
            if (err) {
                console.error(chalk.red('[Thumbnail Route] ✗ Error sending file'), {
                    errorType: err?.name || 'Error'
                });
                if (!res.headersSent) {
                    res.status(500).json({
                        error: 'Failed to send thumbnail',
                        message: 'Unable to return the generated thumbnail'
                    });
                }
            }

            if (thumbnailPath) {
                cleanupThumbnail(thumbnailPath).catch(() => {});
            }
        });

    } catch (error) {
        console.error(chalk.red('[Thumbnail Route] ✗ Processing failed'), {
            errorType: error?.name || 'Error',
            // Only messages this service authored are safe to log verbatim;
            // FFmpeg and HTTP-client exception text can carry the signed URL
            // and object path this service is required never to record.
            ...(error instanceof ThumbnailIntegrityError ? { reason: error.message } : {}),
        });

        if (thumbnailPath) {
            cleanupThumbnail(thumbnailPath).catch(() => {});
        }

        res.status(500).json({
            error: 'Thumbnail generation failed',
            message: 'The thumbnail could not be generated'
        });
    }
});

module.exports = router;
