# Rate Limiting Documentation

## Overview

The media processor microservice implements rate limiting to protect against abuse and control processing costs. Rate limits are applied per IP address.

## Rate Limits

### General Endpoints
- **Limit**: 100 requests per 15 minutes
- **Applies to**: `/`, `/health`, and other non-processing endpoints
- **Window**: 15 minutes (900 seconds)

### Thumbnail Generation
- **Limit**: 50 requests per 15 minutes
- **Applies to**: `POST /generate-thumbnail`
- **Window**: 15 minutes (900 seconds)
- **Reason**: More restrictive due to resource-intensive FFmpeg processing

## Response Headers

All requests include rate limit information in response headers:

```
ratelimit-policy: 100;w=900
ratelimit-limit: 100
ratelimit-remaining: 95
ratelimit-reset: 654
```

- `ratelimit-policy`: Rate limit policy (limit;window in seconds)
- `ratelimit-limit`: Maximum requests allowed in window
- `ratelimit-remaining`: Requests remaining in current window
- `ratelimit-reset`: Seconds until rate limit window resets

## Rate Limit Exceeded Response

When rate limit is exceeded, the service returns:

**Status Code**: `429 Too Many Requests`

**Response Body**:
```json
{
  "error": "Too many thumbnail requests",
  "message": "You have exceeded the rate limit of 50 requests per 15 minutes. Please try again later.",
  "retryAfter": "15 minutes"
}
```

## Testing Rate Limits

### Using curl
```bash
# Check rate limit headers
curl -v https://media-processor-65la52ndha-uc.a.run.app/ 2>&1 | grep -i ratelimit

# Test thumbnail endpoint
curl -X POST https://media-processor-65la52ndha-uc.a.run.app/generate-thumbnail \
  -H "Content-Type: application/json" \
  -d '{"videoUrl": "https://example.com/video.mp4"}' \
  -v 2>&1 | grep -i ratelimit
```

### Using test scripts
```bash
# Run comprehensive rate limit test
./test-rate-limit.sh
```

## Configuration

Rate limits can be adjusted in `src/middleware/rateLimiter.js`:

```javascript
const thumbnailLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 50, // Adjust this value
    // ... other options
});
```

## Bypassing Rate Limits

Health check endpoint (`/health`) is excluded from rate limiting to allow monitoring systems to check service status without consuming rate limit quota.

## Implementation Details

- **Package**: `express-rate-limit`
- **Storage**: In-memory (resets when service restarts)
- **Identification**: By IP address
- **Headers**: Standard RateLimit headers (RFC draft)

## Cost Considerations

Rate limiting helps control costs by:
1. Preventing excessive FFmpeg processing
2. Limiting concurrent resource usage
3. Protecting against unintentional or malicious abuse
4. Ensuring fair resource allocation across users

## Future Enhancements

Potential improvements:
- Redis-based storage for distributed rate limiting
- API key-based rate limits (higher limits for authenticated requests)
- Dynamic rate limits based on resource availability
- Custom rate limits per client/organization
