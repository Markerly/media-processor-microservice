# Rate limiting

**This service has no application-level rate limiting, deliberately.** If you are
here to add some, read this first — it was removed on purpose, and the load it
was meant to handle is the load it actually broke.

## Why there is none

Authorization is Cloud Run IAM: `roles/run.invoker` for the platform App Engine
identity only. The service is private and has exactly one authorized caller. A
per-IP rate limiter cannot protect a single trusted caller from anything — IAM
already decides who may call — so its only possible effect is to drop that
caller's own legitimate traffic.

That is not hypothetical. The previous `express-rate-limit` setup (two limiters,
100 requests / 15 min each, keyed on IP, in-memory per instance) rejected **84%
of thumbnail requests** during a real report generation on 2026-08-14: 10,813×
429 against 1,474× 200. Because `platform-api` retries a 429 with backoff, the
retries spent the very budget they were waiting on — the limiter and the retry
loop defeated each other. See issue #4.

## What bounds cost and blast radius instead

Cloud Run's own admission control, which a per-IP app limiter cannot improve on:

- `--concurrency 2` — at most two in-flight FFmpeg processes per instance
- `--max-instances 10` — a hard ceiling on horizontal fan-out
- the per-request timeout in `thumbnailGenerator.js` — no request pins a slot open

When the service is genuinely saturated, Cloud Run returns 429 itself, and the
platform caller's existing backoff handles it. Those 429s mean "at capacity",
not "you tripped an artificial per-IP counter that fires far below capacity".

## If you think you need it back

You almost certainly need a different lever:

- Runaway cost → lower `--max-instances`, or shorten the request timeout.
- One caller monopolising capacity → that is a scheduling problem in the caller,
  not an edge concern; fix it where the fan-out is issued.
- The service went public → do not paper over it with a limiter. A public
  media-processing endpoint is an SSRF/abuse surface; the release's anonymous-403
  probe exists to keep that from ever shipping.
