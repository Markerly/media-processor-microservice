/**
 * Thumbnail Generation Service
 *
 * Handles video thumbnail generation using FFmpeg
 */

const ffmpeg = require('fluent-ffmpeg');
const path = require('path');
const fs = require('fs').promises;
const { v4: uuidv4 } = require('uuid');
const chalk = require('chalk');

/**
 * Configuration for thumbnail generation
 */
const CONFIG = {
    // Default thumbnail size (width x height)
    thumbnailSize: '640x-1',

    // Time position to capture thumbnail
    thumbnailTime: '00:00:01',

    // JPEG quality (1-100)
    jpegQuality: 85,

    // Timeout for processing
    processingTimeout: 25000, // 25 seconds (leave buffer for HTTP timeout)

    // Temp directory
    tempDir: '/tmp'
};

/**
 * Generates a thumbnail from a video URL
 *
 * @param {string} videoUrl - URL of the video
 * @param {Object} options - Generation options
 * @param {string} options.timePosition - Time position (e.g., '00:00:01' or '10%')
 * @param {string} options.size - Thumbnail size (e.g., '640x360')
 * @param {number} options.quality - JPEG quality (1-100)
 * @returns {Promise<string>} Path to generated thumbnail
 * @throws {Error} If thumbnail generation fails
 */
async function generateThumbnail(videoUrl, options = {}) {
    const config = {
        size: options.size || CONFIG.thumbnailSize,
        timePosition: options.timePosition || CONFIG.thumbnailTime,
        quality: options.quality || CONFIG.jpegQuality,
        timeout: options.timeout || CONFIG.processingTimeout,
    };

    // Generate unique output filename
    const outputFilename = `thumb_${uuidv4()}.jpg`;
    const outputPath = path.join(CONFIG.tempDir, outputFilename);

    console.log(chalk.cyan('[Thumbnail Generator] Starting generation'));
    console.log(chalk.cyan('[Thumbnail Generator] Video URL:'), videoUrl);
    console.log(chalk.cyan('[Thumbnail Generator] Output path:'), outputPath);
    console.log(chalk.cyan('[Thumbnail Generator] Config:'), config);

    return new Promise((resolve, reject) => {
        const timeoutId = setTimeout(() => {
            reject(new Error(`Thumbnail generation timed out after ${config.timeout}ms`));
        }, config.timeout);

        try {
            ffmpeg(videoUrl)
                // Seek to specific time
                .seekInput(config.timePosition)
                // Take only 1 frame and set scale filter
                .outputOptions([
                    '-vframes 1',
                    `-q:v ${Math.round((100 - config.quality) / 10)}`,
                    '-vf scale=640:-2' // Width 640, height auto (divisible by 2)
                ])
                // Set output
                .output(outputPath)
                // Handle completion
                .on('end', () => {
                    clearTimeout(timeoutId);
                    console.log(chalk.green('[Thumbnail Generator] ✓ Thumbnail generated successfully:'), outputPath);
                    resolve(outputPath);
                })
                // Handle errors
                .on('error', (err) => {
                    clearTimeout(timeoutId);
                    console.error(chalk.red('[Thumbnail Generator] ✗ Error generating thumbnail:'), err);
                    reject(new Error(`Failed to generate thumbnail: ${err.message}`));
                })
                // Start processing
                .run();
        } catch (error) {
            clearTimeout(timeoutId);
            console.error(chalk.red('[Thumbnail Generator] ✗ Exception during setup:'), error);
            reject(new Error(`Exception during thumbnail generation: ${error.message}`));
        }
    });
}

/**
 * Cleans up temporary thumbnail file
 *
 * @param {string} thumbnailPath - Path to thumbnail file
 * @returns {Promise<void>}
 */
async function cleanupThumbnail(thumbnailPath) {
    try {
        await fs.unlink(thumbnailPath);
        console.log(chalk.gray('[Thumbnail Generator] Cleaned up temp file:'), thumbnailPath);
    } catch (error) {
        console.warn(chalk.yellow('[Thumbnail Generator] ⚠ Failed to cleanup temp file:'), error.message);
    }
}

module.exports = {
    generateThumbnail,
    cleanupThumbnail,
    CONFIG
};
