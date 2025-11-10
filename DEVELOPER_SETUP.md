# Developer Setup Instructions for Alejandro

## Project: Media Processor Microservice
**Repository:** https://github.com/Markerly/media-processor-microservice  
**Google Cloud Project:** glassy-tube

---

## Quick Setup

### 1. Clone the Repository
```bash
git clone https://github.com/Markerly/media-processor-microservice.git
cd media-processor-microservice
```

### 2. Install Dependencies
```bash
npm install
```

### 3. Google Cloud Authentication
```bash
# Install Google Cloud SDK if not already installed
# https://cloud.google.com/sdk/docs/install

# Authenticate with your Google account
gcloud auth login

# Set the project
gcloud config set project glassy-tube

# Verify access
gcloud projects describe glassy-tube
```

### 4. Test Local Development
```bash
# Start development server
npm run dev

# Test the service (in another terminal)
curl http://localhost:8080/health
```

### 5. Deploy to Cloud Run
```bash
# Set up Google Cloud resources (run once)
./setup-gcp.sh

# Connect GitHub to Cloud Build:
# 1. Go to https://console.cloud.google.com/cloud-build/triggers
# 2. Click "Connect Repository"
# 3. Select GitHub and connect this repository
# 4. Create a trigger for the 'main' branch

# Deploy changes
git add .
git commit -m "Your changes"
git push origin main
```

---

## Development Tasks

### Primary Goal: Implement FFmpeg Processing

The basic service structure is ready. You need to implement:

#### 1. Create Processing Routes (`src/routes/process.js`)
```javascript
// Example structure needed:
const express = require('express');
const multer = require('multer');
const ffmpeg = require('fluent-ffmpeg');
const router = express.Router();

// Video conversion endpoint
router.post('/convert', upload.single('file'), async (req, res) => {
  // TODO: Implement video conversion
});

// Audio extraction endpoint  
router.post('/extract-audio', upload.single('file'), async (req, res) => {
  // TODO: Implement audio extraction
});

module.exports = router;
```

#### 2. Key Features to Implement
- **File upload handling** with size/type validation
- **Video transcoding** (mp4, webm, etc.)
- **Audio conversion** (mp3, wav, etc.) 
- **Thumbnail generation**
- **Progress tracking** for long operations
- **Temporary file cleanup**
- **Error handling** and logging

#### 3. Update Main App (`src/index.js`)
Uncomment and connect the process routes:
```javascript
app.use('/process', require('./routes/process'));
```

---

## Project Structure
```
├── src/
│   ├── index.js          # Main app (basic structure ready)
│   └── routes/           # Create this directory
│       └── process.js    # Main implementation needed here
├── Dockerfile            # Ready for Cloud Run
├── cloudbuild.yaml       # CI/CD configuration
├── setup-gcp.sh          # Google Cloud setup
└── package.json          # Dependencies ready
```

---

## Useful Resources

### FFmpeg Documentation
- [fluent-ffmpeg npm package](https://www.npmjs.com/package/fluent-ffmpeg)
- [FFmpeg official docs](https://ffmpeg.org/documentation.html)

### Google Cloud
- [Cloud Run documentation](https://cloud.google.com/run/docs)
- [Cloud Build documentation](https://cloud.google.com/build/docs)

### Example API Endpoints (After Implementation)
```bash
# Convert video format
curl -X POST https://media-processor-glassy-tube-us-central1.a.run.app/process/convert \
  -F "file=@video.mp4" \
  -F "format=webm" \
  -F "quality=720p"

# Extract audio
curl -X POST https://media-processor-glassy-tube-us-central1.a.run.app/process/extract-audio \
  -F "file=@video.mp4" \
  -F "format=mp3"
```

---

## Support

- **Repository Issues:** https://github.com/Markerly/media-processor-microservice/issues
- **Cloud Console:** https://console.cloud.google.com/run?project=glassy-tube
- **Service Logs:** Available in Google Cloud Console > Cloud Run > media-processor

---

## Current Status
✅ Basic service structure complete  
✅ Cloud Run deployment ready  
✅ CI/CD pipeline configured  
🔄 **Next: Implement FFmpeg processing routes**

The foundation is ready - focus on implementing the core FFmpeg functionality in `src/routes/process.js`.