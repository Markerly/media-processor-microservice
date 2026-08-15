const express = require('express');
const helmet = require('helmet');
const compression = require('compression');
const winston = require('winston');
const chalk = require('chalk');

const app = express();
const PORT = process.env.PORT || 8080;

// No application-level rate limiting. This service is private: authorization is
// Cloud Run IAM (roles/run.invoker for the platform App Engine identity only),
// and the single authorized caller retries on 429. A per-IP, per-instance,
// in-memory limiter therefore protected nothing an IAM boundary does not — it
// only dropped that one caller's legitimate burst load. Cost and blast radius
// are bounded by Cloud Run's own admission control (--concurrency 2,
// --max-instances 10) and the per-request timeout, which a limiter cannot
// improve on for a single trusted caller. See RATE_LIMITING.md and issue #4.

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
  console.log(chalk.gray('  Access: Cloud Run IAM (private); cost bounded by concurrency + max-instances'));
  console.log(chalk.cyan('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'));

  logger.info(`Media processor service listening on port ${PORT}`);
  });
}

if (require.main === module) {
  start();
}

module.exports = { app, start };
