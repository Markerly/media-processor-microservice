const express = require('express');
const helmet = require('helmet');
const compression = require('compression');
const winston = require('winston');
const chalk = require('chalk');
const { generalLimiter } = require('./middleware/rateLimiter');

const app = express();
const PORT = process.env.PORT || 8080;

// Trust proxy - required for Cloud Run/App Engine and other proxies
// This allows express-rate-limit to correctly identify users via X-Forwarded-For
app.set('trust proxy', 1);

// Configure logger
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.json()
  ),
  defaultMeta: { service: 'media-processor' },
  transports: [
    new winston.transports.Console()
  ]
});

// Middleware
app.use(helmet());
app.use(compression());
app.use(express.json({ limit: '16kb' }));

// Health check endpoint
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy', timestamp: new Date().toISOString() });
});

// Apply general rate limiting after health so liveness checks cannot consume
// the application request budget.
app.use(generalLimiter);

// Basic info endpoint
app.get('/', (req, res) => {
  res.json({
    service: 'Media Processor Microservice',
    version: '1.0.0',
    description: 'FFmpeg processing service for Cloud Run',
    endpoints: {
      health: 'GET /health',
      generateThumbnail: 'POST /generate-thumbnail'
    }
  });
});

// Thumbnail generation routes
app.use('/', require('./routes/thumbnail'));

// Error handling middleware
app.use((err, req, res, _next) => {
  if (err?.type === 'entity.too.large') {
    return res.status(413).json({ error: 'Request body is too large' });
  }
  if (err instanceof SyntaxError && err?.status === 400 && 'body' in err) {
    return res.status(400).json({ error: 'Request body is invalid JSON' });
  }
  logger.error('Unhandled request failure', { errorType: err?.name || 'Error' });
  return res.status(500).json({ error: 'Internal server error' });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

function start() {
  return app.listen(PORT, () => {
  console.log(chalk.green.bold('\n✓ Media Processor Microservice Started'));
  console.log(chalk.cyan('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'));
  console.log(chalk.white('  Service:'), chalk.yellow('Media Processor'));
  console.log(chalk.white('  Port:'), chalk.yellow(PORT));
  console.log(chalk.white('  Status:'), chalk.green('Running'));
  console.log(chalk.cyan('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'));
  console.log(chalk.gray('  Endpoints:'));
  console.log(chalk.gray('    GET  /health'));
  console.log(chalk.gray('    POST /generate-thumbnail'));
  console.log(chalk.cyan('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'));
  console.log(chalk.gray('  Rate Limits:'));
  console.log(chalk.gray('    General: 100 requests per 15 minutes'));
  console.log(chalk.gray('    Thumbnails: 50 requests per 15 minutes'));
  console.log(chalk.cyan('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'));

  logger.info(`Media processor service listening on port ${PORT}`);
  });
}

if (require.main === module) {
  start();
}

module.exports = { app, start };
