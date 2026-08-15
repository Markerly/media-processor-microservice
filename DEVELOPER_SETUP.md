# Developer setup

## Prerequisites

- Node.js 22
- Docker
- Google Cloud SDK only for authorized release operators

## Local loop

```sh
npm ci
npm test -- --runInBand
npm run lint
npm start
curl --fail http://127.0.0.1:8080/health
```

The service accepts remote objects, not multipart file uploads. Keep all new
input fetches behind the exact-host URL policy in `src/lib/videoUrlPolicy.js`.
Optionally set `ALLOWED_VIDEO_BUCKETS` to a comma-separated GCS bucket list to
narrow the host policy further. Never interpolate request values into a shell
command or return/log raw FFmpeg, HTTP-client, or signed-URL errors.

## Deployment

Infrastructure is administrator-managed. A merge to `main` reaches an
approval-gated Cloud Build trigger; developers do not grant IAM from local
scripts. The reviewed identities and immutable image path are declared in
`cloudbuild.yaml` and summarized in `README.md`.

Before approving a build, require the tests, lint, npm audit, container health,
SSRF/lookalike rejects, a real JPEG generation, and a log scan proving that a
sentinel query secret and object path do not appear.
