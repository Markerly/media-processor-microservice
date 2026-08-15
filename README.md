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

The service never logs signed query credentials, bucket names, or object paths.
FFmpeg runs as the non-root `node` user, receives an argument array rather than
a shell command, has a restricted network protocol allowlist, follows no HTTP
redirects, forces a demuxer from the validated extension, and is killed on a
bounded timeout.

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

Scope of the IAM assertion, stated plainly: the release reads the *service*-level
IAM policy and proves no public binding and no unexpected service-level invoker
exists. `roles/run.invoker` granted at project or folder level is invisible to
it — and the release identity is expected to hold exactly such a grant, because
the service-level policy is asserted to contain the platform caller and nothing
else. Reading the project policy would require `resourcemanager.projects.getIamPolicy`
on the release identity, widening it past the least privilege this release
establishes. What proves the public edge is closed is the anonymous 403 probe
against the live URL, not the policy read. Audit project-level invoker grants
separately.

Optionally set `ALLOWED_VIDEO_BUCKETS` (comma-separated) on the service to
narrow the GCS host policy to specific buckets. It is the only environment
variable the release permits besides `NODE_ENV`; anything else fails the
revision contract as drift.

Do not add `--allow-unauthenticated`, grant project-wide Editor/Owner, restore
the deleted workstation IAM scripts, or deploy with the default Compute Engine
service account.

## Preflight

Before approving a release build, run:

```sh
bash scripts/preflight-release.sh [PROJECT] [ACCOUNT]
```

Pass `ACCOUNT` whenever more than one thing on the machine drives `gcloud`.
`gcloud config set account` is global, so a concurrent shell or agent can move
the active identity between runs and the answers would quietly become about a
different principal. The argument exports `CLOUDSDK_CORE_ACCOUNT` for that
process only, never mutating shared config, and the effective account is echoed
in the output so any result can be attributed. An authenticated identity that
simply lacks access to the project is reported differently from a stale
credential — they need opposite fixes.

It is read-only and answers, in one pass, the rollout checks that were otherwise
prose: both least-privilege identities exist, the Artifact Registry repository
exists, the platform caller holds an unconditional `roles/run.invoker` binding,
the release identity holds the project-level invoker its own health proof needs,
whether the service is still public (i.e. whether this release performs the
cutover), and the exact `_PLATFORM_OIDC_PROOF` value to paste.

A check it could not run reports `UNKNOWN` and exits 2, never `FAIL`. Expired
credentials and a missing binding mean opposite things — "look again" versus "do
not release" — and a preflight that renders them identically would be the same
class of guard-shaped object this release exists to remove.

## Release and rollback

Sequencing caveat, because `--no-traffic` does not isolate it: the
`--no-allow-unauthenticated` flag on the candidate deploy is **service**-scoped
and lands with the deploy, so the public edge closes for the revision currently
serving 100% while the candidate still holds zero traffic. The candidate
isolates new *code*, not the *authorization* change. That is why the release
refuses to deploy at all until the platform caller already holds an
unconditional `roles/run.invoker` binding, and why the OIDC proof gate exists:
once the edge closes, rollback restores the previous revision but deliberately
never restores public access.

The reviewed Cloud Build trigger builds an immutable `$COMMIT_SHA` image and
requires `_PLATFORM_OIDC_PROOF=platform-api@<exact 40-character serving SHA>`.
A prose ticket, mutable label, stale SHA, or invented SHA cannot unlock the
private cutover: before its first gcloud lookup, the release requires the exact
commit in that proof to match production platform-api's `/versionz` attestation.
The release
deploys under the zero-role runtime identity, clears inherited secrets,
database/VPC attachments including Direct VPC, custom audiences, volumes,
command/argument overrides, and probes,
then independently re-describes the candidate and verifies its digest,
identity, one-container shape, environment, resource ceilings, startup probe,
and private IAM before traffic moves.

Runtime concurrency is pinned to two on a two-vCPU instance so a request burst
cannot fan out dozens of simultaneous FFmpeg processes inside one container;
Cloud Run scales across the bounded instance pool instead. The trigger is
approval-gated until this hardening release and the platform OIDC caller are
both deployed and verified. ID tokens are passed to curl over stdin rather
than exposed in process arguments.

If a stable-URL proof fails after traffic moves, the release migrates traffic
back to the exact previous ready revision and re-describes the service to prove
that revision is again at 100%. A failed or unverifiable rollback is loud and
requires manual intervention. Do not make the service public as a rollback
mechanism.
