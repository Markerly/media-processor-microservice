#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: verify-images.sh TEST_IMAGE RUNTIME_IMAGE" >&2
  exit 64
fi

test_image="$1"
runtime_image="$2"

# Execute tests on every release invocation, even when Docker reuses a cached
# image layer. The sandbox matches the production filesystem/security posture.
docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=128m \
  --tmpfs /test-tools:rw,exec,nosuid,size=4m \
  --env RELEASE_TEST_TMPDIR=/test-tools \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 256 \
  --memory 1g \
  --cpus 1 \
  "$test_image"

# npm audit cannot see Alpine/FFmpeg packages. Scan both OS and Node runtime
# packages with immutable Trivy v0.73.0 and a freshly downloaded advisory DB.
scanner='mirror.gcr.io/aquasec/trivy@sha256:7cced7cae583819fc7806d4cbc0dbbc7cad18b99f7d3e235192e6da8c091045c'
scan_cache="media-processor-trivy-$(date +%s)-$$"
docker volume create "$scan_cache" >/dev/null
cleanup_scan() {
  docker volume rm --force "$scan_cache" >/dev/null 2>&1 || true
}
trap cleanup_scan EXIT

if ! docker run --rm \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume "$scan_cache:/root/.cache/trivy" \
  "$scanner" \
  image \
  --exit-code 1 \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --scanners vuln \
  --no-progress \
  --quiet \
  --format json \
  --output /dev/null \
  "$runtime_image"; then
  echo "fixable high/critical image vulnerability detected" >&2
  docker run --rm \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    --volume "$scan_cache:/root/.cache/trivy" \
    "$scanner" \
    image \
    --skip-db-update \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --scanners vuln \
    --no-progress \
    "$runtime_image" >&2 || true
  exit 1
fi

cleanup_scan
trap - EXIT

container="media-processor-verify-$(date +%s)-$$"
cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

docker run --detach \
  --name "$container" \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=256m \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 256 \
  --memory 2g \
  --cpus 2 \
  "$runtime_image" >/dev/null

ready=false
attempt=1
while [ "$attempt" -le 45 ]; do
  if docker exec "$container" node -e '
    fetch("http://127.0.0.1:8080/health")
      .then(async response => {
        const body = await response.json();
        if (response.status !== 200 || body.status !== "healthy") process.exit(1);
      })
      .catch(() => process.exit(1));
  ' >/dev/null 2>&1; then
    ready=true
    break
  fi

  if [ "$(docker inspect "$container" --format '{{.State.Running}}')" != true ]; then
    docker logs "$container" >&2
    exit 1
  fi
  sleep 2
  attempt=$((attempt + 1))
done

if [ "$ready" != true ]; then
  docker logs "$container" >&2
  echo "production image did not become ready" >&2
  exit 1
fi

docker exec "$container" node -e '
  fetch("http://127.0.0.1:8080/generate-thumbnail", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({videoUrl: "x".repeat(20000)}),
  })
    .then(response => {
      if (response.status !== 413) process.exit(1);
    })
    .catch(() => process.exit(1));
'

# URL policy forbids non-GCS inputs, so prove the runtime FFmpeg binary can
# still decode a frame to JPEG without going through the HTTP route.
docker exec "$container" ffmpeg -nostdin -hide_banner -loglevel error \
  -f lavfi -i 'testsrc=duration=1:size=160x120:rate=1' \
  -frames:v 1 -f image2 -y /tmp/ffmpeg-ok.jpg
docker exec "$container" node -e '
  const fs = require("fs");
  const bytes = fs.readFileSync("/tmp/ffmpeg-ok.jpg");
  if (bytes.length < 32 || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) {
    process.exit(1);
  }
'

test "$(docker inspect "$container" --format '{{.Config.User}}')" = 'node:node'
docker exec "$container" sh -c \
  'test "$(id -u):$(id -g)" = 1000:1000 && ! command -v npm && ! command -v npx'
