/**
 * Thumbnail Generation Routes
 */

const express = require('express');
const fs = require('fs');
const { generateThumbnail, cleanupThumbnail } = require('../services/thumbnailGenerator');
const { thumbnailLimiter } = require('../middleware/rateLimiter');
const chalk = require('chalk');

const router = express.Router();

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
 * Rate limit: 50 requests per 15 minutes per IP
 */
router.post('/generate-thumbnail', thumbnailLimiter, async (req, res) => {
    const { videoUrl, timePosition, size, quality } = req.body;

    // Validation: videoUrl is required
    if (!videoUrl) {
        return res.status(400).json({
            error: 'Bad Request',
            message: 'videoUrl is required'
        });
    }

    // Validation: Must be a Google Cloud Storage URL
    if (!videoUrl.includes('storage.googleapis.com') && !videoUrl.includes('storage.cloud.google.com')) {
        return res.status(400).json({
            error: 'Bad Request',
            message: 'Only Google Cloud Storage URLs are supported'
        });
    }

    // Validation: Must be a video file (check extension)
    const videoExtensions = ['.mp4', '.mov', '.avi', '.mkv', '.webm', '.flv', '.m4v', '.mpeg', '.mpg'];
    const urlLower = videoUrl.toLowerCase();
    const hasVideoExtension = videoExtensions.some(ext => urlLower.includes(ext));

    if (!hasVideoExtension) {
        return res.status(400).json({
            error: 'Bad Request',
            message: 'URL must point to a valid video file (.mp4, .mov, .avi, .mkv, .webm, .flv, .m4v, .mpeg, .mpg)'
        });
    }

    let thumbnailPath = null;

    try {
        console.log(chalk.cyan('[Thumbnail Route] Request received for video:'), videoUrl);

        // Generate thumbnail
        thumbnailPath = await generateThumbnail(videoUrl, {
            timePosition,
            size,
            quality
        });

        // Check if file exists and has content
        const stats = fs.statSync(thumbnailPath);
        if (stats.size === 0) {
            throw new Error('Generated thumbnail file is empty');
        }

        console.log(chalk.green('[Thumbnail Route] ✓ Sending thumbnail file:'), thumbnailPath, chalk.gray(`(${stats.size} bytes)`));

        // Send file as response
        res.sendFile(thumbnailPath, (err) => {
            if (err) {
                console.error(chalk.red('[Thumbnail Route] ✗ Error sending file:'), err);
                if (!res.headersSent) {
                    res.status(500).json({
                        error: 'Failed to send thumbnail',
                        message: err.message
                    });
                }
            }

            // Cleanup after sending (or on error)
            if (thumbnailPath) {
                cleanupThumbnail(thumbnailPath).catch(console.error);
            }
        });

    } catch (error) {
        console.error(chalk.red('[Thumbnail Route] ✗ Error:'), error);

        // Cleanup on error
        if (thumbnailPath) {
            cleanupThumbnail(thumbnailPath).catch(console.error);
        }

        res.status(500).json({
            error: 'Thumbnail generation failed',
            message: error.message
        });
    }
});

module.exports = router;
