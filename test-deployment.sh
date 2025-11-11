#!/bin/bash

echo "========================================="
echo "Media Processor FFmpeg Deployment Test"
echo "========================================="
echo ""

SERVICE_URL="https://media-processor-65la52ndha-uc.a.run.app"

# Test 1: Health check
echo "Test 1: Health Check"
curl -s "$SERVICE_URL/health" | python -m json.tool
echo ""

# Test 2: Service info
echo "Test 2: Service Info"
curl -s "$SERVICE_URL/" | python -m json.tool
echo ""

# Test 3: Generate thumbnail (default settings)
echo "Test 3: Generate Thumbnail (Default)"
curl -X POST "$SERVICE_URL/generate-thumbnail" \
  -H "Content-Type: application/json" \
  -d '{"videoUrl": "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4", "timePosition": "00:00:02"}' \
  --output test-thumb-default.jpg \
  -w "HTTP Status: %{http_code}\n" \
  --silent
file test-thumb-default.jpg
echo ""

# Test 4: Generate thumbnail (high quality)
echo "Test 4: Generate Thumbnail (High Quality)"
curl -X POST "$SERVICE_URL/generate-thumbnail" \
  -H "Content-Type: application/json" \
  -d '{"videoUrl": "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4", "timePosition": "00:00:10", "quality": 95}' \
  --output test-thumb-hq.jpg \
  -w "HTTP Status: %{http_code}\n" \
  --silent
file test-thumb-hq.jpg
echo ""

# Test 5: Error handling
echo "Test 5: Error Handling (Invalid URL)"
curl -X POST "$SERVICE_URL/generate-thumbnail" \
  -H "Content-Type: application/json" \
  -d '{"videoUrl": "https://invalid.com/video.mp4"}' \
  -w "\nHTTP Status: %{http_code}\n"
echo ""

# Test 6: Validation (missing videoUrl)
echo "Test 6: Validation (Missing videoUrl)"
curl -X POST "$SERVICE_URL/generate-thumbnail" \
  -H "Content-Type: application/json" \
  -d '{}' \
  -w "\nHTTP Status: %{http_code}\n"
echo ""

echo "========================================="
echo "Test Results:"
echo "========================================="
ls -lh test-thumb-*.jpg 2>/dev/null
echo ""
echo "All tests completed!"
