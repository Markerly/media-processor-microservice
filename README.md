# Media Processor Microservice

FFmpeg processing microservice for Cloud Run deployment on the glassy-tube project.

## Overview

This microservice handles media processing tasks that can't be performed on App Engine due to FFmpeg requirements. It's designed to run on Google Cloud Run with automatic scaling.

## Quick Start

### Prerequisites

- Node.js 18+
- Google Cloud SDK (`gcloud`)
- GitHub CLI (`gh`)
- Docker (for local testing)

### Local Development

```bash
# Install dependencies
npm install

# Start development server
npm run dev

# Test the service
curl http://localhost:8080/health
```

### Google Cloud Setup

1. Run the setup script:
   ```bash
   ./setup-gcp.sh
   ```

2. Connect GitHub repository to Cloud Build:
   - Go to [Cloud Build Triggers](https://console.cloud.google.com/cloud-build/triggers)
   - Click "Connect Repository"
   - Select GitHub and this repository
   - Create a trigger for the `main` branch

3. Push code to deploy:
   ```bash
   git add .
   git commit -m "Initial deployment"
   git push origin main
   ```

## Project Structure

```
├── src/
│   └── index.js          # Main application entry point
├── Dockerfile            # Container configuration
├── cloudbuild.yaml       # Cloud Build deployment config
├── setup-gcp.sh          # Google Cloud setup script
└── package.json          # Node.js dependencies
```

## Development Tasks

### TODO: Implement FFmpeg Processing Routes

The basic service structure is complete. Next steps for development:

1. **Create processing routes** (`src/routes/process.js`):
   - Video conversion endpoints
   - Audio extraction
   - Image processing
   - File format validation

2. **Add file upload handling**:
   - Multipart form data processing
   - Temporary file management
   - Cloud Storage integration

3. **Implement FFmpeg operations**:
   - Video transcoding
   - Audio conversion
   - Thumbnail generation
   - Metadata extraction

4. **Error handling and logging**:
   - Detailed error responses
   - Processing progress tracking
   - Performance monitoring

5. **Security and validation**:
   - File type restrictions
   - Size limits
   - Input sanitization

### Example Usage (After Implementation)

```bash
# Convert video to different format
curl -X POST http://localhost:8080/process/convert \
  -F "file=@input.mp4" \
  -F "format=webm" \
  -F "quality=720p"

# Extract audio from video
curl -X POST http://localhost:8080/process/extract-audio \
  -F "file=@video.mp4" \
  -F "format=mp3"
```

## Deployment

The service automatically deploys to Cloud Run when code is pushed to the `main` branch. The deployment includes:

- 2GB memory allocation
- 2 CPU cores
- 300-second timeout
- Auto-scaling up to 10 instances

## Service Configuration

- **Port**: 8080 (configurable via PORT env var)
- **Health check**: `/health` endpoint
- **Memory**: 2GB
- **CPU**: 2 cores
- **Timeout**: 5 minutes
- **Region**: us-central1

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | Service port | 8080 |
| `NODE_ENV` | Environment | development |

## Contributing

1. Create a feature branch
2. Implement changes with tests
3. Submit a pull request
4. Automatic deployment on merge to main

## License

MIT