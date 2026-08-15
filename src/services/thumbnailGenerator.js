/**
 * Thumbnail Generation Service
 *
 * Handles video thumbnail generation using FFmpeg
 */

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs').promises;
const { randomUUID } = require('crypto');
const chalk = require('chalk');
const {
    ffmpegInputFormat,
    validatedVideoUrl,
    videoUrlForLog,
} = require('../lib/videoUrlPolicy');

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
    tempDir: '/tmp',

    // Cap the JPEG so a decoder bomb cannot fill the tmpfs.
    maxOutputBytes: 5 * 1024 * 1024,
};

function buildFfmpegArgs(videoUrl, outputPath, config) {
    const safeUrl = validatedVideoUrl(videoUrl);
    const inputFormat = ffmpegInputFormat(safeUrl);
    const quality = Math.max(1, Math.round((100 - config.quality) / 10));

    return [
        '-nostdin',
        '-hide_banner',
        '-loglevel', 'error',
        '-protocol_whitelist', 'https,tls,tcp',
        '-max_redirects', '0',
        '-rw_timeout', '15000000',
        '-ss', config.timePosition,
        '-t', '1',
        '-f', inputFormat,
        '-i', safeUrl,
        '-an',
        '-frames:v', '1',
        '-q:v', String(quality),
        '-vf', `scale=${config.width}:${config.height}`,
        '-f', 'image2',
        '-fs', String(CONFIG.maxOutputBytes),
        '-y',
        outputPath,
    ];
}

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
        width: options.width || 640,
        height: options.height ?? -1,
        timePosition: options.timePosition || CONFIG.thumbnailTime,
        quality: options.quality || CONFIG.jpegQuality,
        timeout: options.timeout || CONFIG.processingTimeout,
    };

    const outputFilename = `thumb_${randomUUID()}.jpg`;
    const outputPath = path.join(CONFIG.tempDir, outputFilename);
    if (path.dirname(outputPath) !== CONFIG.tempDir) {
        throw new Error('Unable to initialize thumbnail generation');
    }

    console.log(chalk.cyan('[Thumbnail Generator] Starting generation'));
    console.log(chalk.cyan('[Thumbnail Generator] Video URL:'), videoUrlForLog(videoUrl));
    console.log(chalk.cyan('[Thumbnail Generator] Output path:'), outputPath);
    console.log(chalk.cyan('[Thumbnail Generator] Config:'), config);

    return new Promise((resolve, reject) => {
        let settled = false;
        const fail = async (error) => {
            if (settled) return;
            settled = true;
            clearTimeout(timeoutId);
            await fs.unlink(outputPath).catch(() => {});
            reject(error);
        };

        const args = buildFfmpegArgs(videoUrl, outputPath, config);
        const command = spawn('ffmpeg', args, { stdio: ['ignore', 'ignore', 'pipe'] });
        command.stderr.on('data', () => {});

        const timeoutId = setTimeout(() => {
            command.kill('SIGKILL');
            void fail(new Error('Thumbnail generation timed out'));
        }, config.timeout);

        command.once('error', (error) => {
            console.error(chalk.red('[Thumbnail Generator] ✗ FFmpeg launch failed'), {
                errorType: error?.name || 'Error'
            });
            void fail(new Error('Unable to initialize thumbnail generation'));
        });

        command.once('close', (code) => {
            if (settled) return;
            if (code !== 0) {
                console.error(chalk.red('[Thumbnail Generator] ✗ FFmpeg failed'), { exitCode: code });
                void fail(new Error('Failed to generate thumbnail'));
                return;
            }
            settled = true;
            clearTimeout(timeoutId);
            console.log(chalk.green('[Thumbnail Generator] ✓ Thumbnail generated successfully:'), outputPath);
            resolve(outputPath);
        });
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
        console.warn(chalk.yellow('[Thumbnail Generator] ⚠ Failed to cleanup temp file'), {
            errorType: error?.name || 'Error'
        });
    }
}

module.exports = {
    generateThumbnail,
    cleanupThumbnail,
    buildFfmpegArgs,
    CONFIG
};
