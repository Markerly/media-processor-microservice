/**
 * Rate Limiting Middleware
 *
 * Protects the media processor from abuse and controls processing costs.
 * Implements different rate limits for different endpoints.
 */

const rateLimit = require('express-rate-limit');
const chalk = require('chalk');

/**
 * Rate limit configuration for thumbnail generation
 * More restrictive since FFmpeg processing is resource-intensive
 */
const thumbnailLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 100, // Limit each IP to 100 requests per window (increased to handle reports with 50+ posts)
    message: {
        error: 'Too many thumbnail requests',
        message: 'You have exceeded the rate limit. Please try again later.',
        retryAfter: '15 minutes'
    },
    standardHeaders: true, // Return rate limit info in the `RateLimit-*` headers
    legacyHeaders: false, // Disable the `X-RateLimit-*` headers
    handler: (req, res) => {
        console.log(chalk.yellow('[Rate Limiter] Thumbnail request blocked from IP:'), req.ip);
        res.status(429).json({
            error: 'Too many thumbnail requests',
            message: 'You have exceeded the rate limit of 100 requests per 15 minutes. Please try again later.',
            retryAfter: '15 minutes'
        });
    },
    skip: (req) => {
        // Skip rate limiting for health checks
        return req.path === '/health';
    }
});

/**
 * General rate limit for all other endpoints
 * More lenient for non-processing endpoints
 */
const generalLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 100, // Limit each IP to 100 requests per window
    message: {
        error: 'Too many requests',
        message: 'You have exceeded the rate limit. Please try again later.',
        retryAfter: '15 minutes'
    },
    standardHeaders: true,
    legacyHeaders: false,
    handler: (req, res) => {
        console.log(chalk.yellow('[Rate Limiter] General request blocked from IP:'), req.ip);
        res.status(429).json({
            error: 'Too many requests',
            message: 'You have exceeded the rate limit of 100 requests per 15 minutes. Please try again later.',
            retryAfter: '15 minutes'
        });
    },
    skip: (req) => {
        // Skip rate limiting for health checks
        return req.path === '/health';
    }
});

/**
 * Strict rate limit for when we want to be very restrictive
 * Can be used for specific high-cost operations
 */
const strictLimiter = rateLimit({
    windowMs: 60 * 60 * 1000, // 1 hour
    max: 20, // Limit each IP to 20 requests per hour
    message: {
        error: 'Rate limit exceeded',
        message: 'This endpoint has a strict rate limit. Please try again later.',
        retryAfter: '1 hour'
    },
    standardHeaders: true,
    legacyHeaders: false,
    handler: (req, res) => {
        console.log(chalk.red('[Rate Limiter] Strict limit blocked from IP:'), req.ip);
        res.status(429).json({
            error: 'Rate limit exceeded',
            message: 'You have exceeded the strict rate limit of 20 requests per hour. Please try again later.',
            retryAfter: '1 hour'
        });
    }
});

module.exports = {
    thumbnailLimiter,
    generalLimiter,
    strictLimiter
};
