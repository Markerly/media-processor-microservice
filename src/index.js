const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const compression = require('compression');
const winston = require('winston');
const chalk = require('chalk');
const { generalLimiter } = require('./middleware/rateLimiter');

const app = express();
const PORT = process.env.PORT || 8082;

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
app.use(cors());
app.use(compression());
app.use(express.json({ limit: '50mb' }));

// Apply general rate limiting to all routes (except health check)
app.use(generalLimiter);

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
app.use((err, req, res, next) => {
  logger.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

app.listen(PORT, () => {
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