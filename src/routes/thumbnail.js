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

function assertJpegThumbnail(thumbnailPath) {
    const resolved = path.resolve(thumbnailPath);
    if (path.dirname(resolved) !== CONFIG.tempDir || path.extname(resolved) !== '.jpg') {
        throw new Error('Generated thumbnail file is empty');
    }
    const header = Buffer.alloc(3);
    const fd = fs.openSync(resolved, 'r');
    try {
        if (fs.readSync(fd, header, 0, 3, 0) !== 3) {
            throw new Error('Generated thumbnail file is empty');
        }
    } finally {
        fs.closeSync(fd);
    }
    if (header[0] !== 0xff || header[1] !== 0xd8 || header[2] !== 0xff) {
        throw new Error('Generated thumbnail file is empty');
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
            throw new Error('Generated thumbnail file is empty');
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
            errorType: error?.name || 'Error'
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
