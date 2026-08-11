#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 5 ]]; then
  echo "usage: release-cloud-run.sh PROJECT COMMIT_SHA BUILD_ID OIDC_READY OIDC_PROOF" >&2
  exit 64
fi

project="$1"
commit_sha="$2"
build_id="$3"
oidc_ready="$4"
oidc_proof="$5"

if [[ ! "$commit_sha" =~ ^[a-f0-9]{40}$ ]]; then
  echo "release requires an exact 40-character Git commit SHA" >&2
  exit 64
fi
if [[ "$oidc_ready" != true || "$oidc_proof" == UNSET || -z "$oidc_proof" ]]; then
  echo "private cutover blocked: deploy and prove the platform-api OIDC caller first" >&2
  echo "set _PLATFORM_OIDC_READY=true and record _PLATFORM_OIDC_PROOF in the approved build" >&2
  exit 78
fi
if [[ ! "$oidc_proof" =~ ^[A-Za-z0-9._:@/-]{3,200}$ ]]; then
  echo "OIDC proof identifier contains unsupported characters" >&2
  exit 64
fi

service='media-processor'
region='us-central1'
image="us-central1-docker.pkg.dev/$project/media-processor-repo/media-processor:$commit_sha"
digest="$(gcloud artifacts docker images describe "$image" \
  --project "$project" \
  --format='value(image_summary.digest)')"
if [[ ! "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "Artifact Registry did not return an immutable SHA-256 digest" >&2
  exit 1
fi
deploy_image="${image%:*}@$digest"

service_json="$(gcloud run services describe "$service" \
  --project "$project" \
  --region "$region" \
  --format=json)"
previous_revision="$(python3 -c '
import json, sys
traffic = json.load(sys.stdin)["status"]["traffic"]
active = [item["revisionName"] for item in traffic if item.get("percent") == 100 and not item.get("tag")]
assert len(active) == 1, f"expected exactly one untagged 100% production revision, got {active}"
print(active[0])
' <<<"$service_json")"

commit_short="${commit_sha:0:8}"
build_short="${build_id%%-*}"
build_short="${build_short:0:8}"
candidate_tag="candidate-$commit_short-$build_short"
candidate_attempted=false
shifted=false
succeeded=false

cleanup() {
  status=$?
  trap - EXIT
  set +e

  if [[ "$succeeded" != true && "$shifted" == true ]]; then
    echo "release proof failed; rolling traffic back to $previous_revision" >&2
    if ! gcloud run services update-traffic "$service" \
      --project "$project" \
      --region "$region" \
      --to-revisions "$previous_revision=100" \
      --quiet; then
      echo "ROLLBACK FAILED: manual traffic restoration is required" >&2
    fi
  fi

  if [[ "$candidate_attempted" == true ]]; then
    gcloud run services update-traffic "$service" \
      --project "$project" \
      --region "$region" \
      --remove-tags "$candidate_tag" \
      --quiet || echo "candidate tag cleanup failed" >&2
  fi

  exit "$status"
}
trap cleanup EXIT

candidate_attempted=true
gcloud run deploy "$service" \
  --project "$project" \
  --image "$deploy_image" \
  --region "$region" \
  --platform managed \
  --service-account "media-processor-runtime@$project.iam.gserviceaccount.com" \
  --no-allow-unauthenticated \
  --invoker-iam-check \
  --no-traffic \
  --tag "$candidate_tag" \
  --revision-suffix "$candidate_tag" \
  --memory 2Gi \
  --cpu 2 \
  --timeout 300 \
  --max-instances 10 \
  --set-env-vars NODE_ENV=production \
  --quiet

service_json="$(gcloud run services describe "$service" \
  --project "$project" \
  --region "$region" \
  --format=json)"
service_url="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["url"])' <<<"$service_json")"
candidate_revision="$(python3 -c '
import json, sys
tag = sys.argv[1]
traffic = json.load(sys.stdin)["status"]["traffic"]
matches = [item["revisionName"] for item in traffic if item.get("tag") == tag]
assert len(matches) == 1, f"expected one candidate revision for {tag}, got {matches}"
print(matches[0])
' "$candidate_tag" <<<"$service_json")"
candidate_url="$(python3 -c '
import json, sys
tag = sys.argv[1]
traffic = json.load(sys.stdin)["status"]["traffic"]
matches = [item["url"] for item in traffic if item.get("tag") == tag]
assert len(matches) == 1, f"expected one candidate URL for {tag}, got {matches}"
print(matches[0])
' "$candidate_tag" <<<"$service_json")"
id_token="$(gcloud auth print-identity-token --audiences="$service_url")"

curl --fail --silent --show-error \
  --header "Authorization: Bearer $id_token" \
  "$candidate_url/health" \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "healthy"'
anonymous_code="$(curl --silent --output /dev/null --write-out '%{http_code}' "$candidate_url/health")"
test "$anonymous_code" = 403

gcloud run services update-traffic "$service" \
  --project "$project" \
  --region "$region" \
  --to-revisions "$candidate_revision=100" \
  --quiet
shifted=true

curl --fail --silent --show-error \
  --header "Authorization: Bearer $id_token" \
  "$service_url/health" \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "healthy"'
anonymous_code="$(curl --silent --output /dev/null --write-out '%{http_code}' "$service_url/health")"
test "$anonymous_code" = 403

gcloud run services update-traffic "$service" \
  --project "$project" \
  --region "$region" \
  --remove-tags "$candidate_tag" \
  --quiet
succeeded=true
trap - EXIT

echo "released $candidate_revision from $deploy_image"
echo "platform OIDC proof: $oidc_proof"
