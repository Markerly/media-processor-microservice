# Media processor

Private Cloud Run service that generates a JPEG thumbnail from an HTTPS Google
Cloud Storage video object.

## HTTP contract

- `GET /health`
- `POST /generate-thumbnail`

The thumbnail request body contains `videoUrl` and optional bounded
`timePosition`, `size`, and `quality` fields. Input URLs must use an exact
Google Storage HTTPS hostname and a supported video extension. Redirect-capable
generic URLs, metadata hosts, hostname lookalikes, URL userinfo, and nonstandard
ports are rejected before FFmpeg starts.

The service never logs signed query credentials or object paths. FFmpeg runs as
the non-root `node` user, receives an argument array rather than a shell command,
has a restricted network protocol allowlist, and is killed on a bounded timeout.

## Local verification

```sh
npm ci
npm test -- --runInBand
npm run lint
npm audit --audit-level=moderate
docker build -t media-processor:local .
docker run --rm -p 8080:8080 media-processor:local
```

Example request:

```sh
curl --fail --output thumbnail.jpg \
  -H 'content-type: application/json' \
  --data '{"videoUrl":"https://storage.googleapis.com/bucket/video.mp4"}' \
  http://127.0.0.1:8080/generate-thumbnail
```

## Production identity boundary

Cloud Run is intended to be private. The platform App Engine service account is
the application caller and sends a Google-signed ID token whose audience is the
exact Cloud Run service origin.

Cloud Build uses the service-specific `media-processor-release` identity. It
can write only to the service Artifact Registry repository, update only this
Cloud Run service, act as only `media-processor-runtime`, write build logs, and
invoke this service for its post-deploy health proof. The runtime identity has
zero project roles.

Do not add `--allow-unauthenticated`, grant project-wide Editor/Owner, restore
the deleted workstation IAM scripts, or deploy with the default Compute Engine
service account.

## Release and rollback

The reviewed Cloud Build trigger builds an immutable `$COMMIT_SHA` image,
deploys it under the zero-role runtime identity, and performs an authenticated
health request. The trigger is approval-gated until this hardening release and
the platform OIDC caller are both deployed and verified.

Rollback by migrating Cloud Run traffic to the previous ready revision. Do not
make the service public as a rollback mechanism.
