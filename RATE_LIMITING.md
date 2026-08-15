# Rate limiting

Rate limits are a secondary control. Production authorization is Cloud Run IAM
(`roles/run.invoker` for the platform App Engine identity only). Do not treat
per-IP limits as an authentication boundary.

## Limits

- General endpoints: 100 requests per 15 minutes per IP
- `POST /generate-thumbnail`: 100 requests per 15 minutes per IP
- `GET /health` is excluded so probes do not consume the budget

Limits are in-memory and reset on instance restart. Adjust them in
`src/middleware/rateLimiter.js`.
