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

if [[ "$project" != glassy-tube-622 ]]; then
  echo "release is pinned to production project glassy-tube-622" >&2
  exit 64
fi
if [[ ! "$commit_sha" =~ ^[a-f0-9]{40}$ ]]; then
  echo "release requires an exact 40-character Git commit SHA" >&2
  exit 64
fi
if [[ ! "$build_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
  echo "release requires the exact Cloud Build UUID" >&2
  exit 64
fi
if [[ "$oidc_ready" != true || "$oidc_proof" == UNSET || -z "$oidc_proof" ]]; then
  echo "private cutover blocked: deploy and prove the platform-api OIDC caller first" >&2
  echo "set _PLATFORM_OIDC_READY=true and record _PLATFORM_OIDC_PROOF in the approved build" >&2
  exit 78
fi
if [[ ! "$oidc_proof" =~ ^platform-api@[a-f0-9]{40}$ ]]; then
  echo "OIDC proof must pin the exact serving platform-api Git commit" >&2
  exit 64
fi

service='media-processor'
region='us-central1'
runtime_service_account="media-processor-runtime@$project.iam.gserviceaccount.com"
image="us-central1-docker.pkg.dev/$project/media-processor-repo/media-processor:$commit_sha"
digest="$(gcloud artifacts docker images describe "$image" \
  --project "$project" \
  --format='value(image_summary.digest)')"
if [[ ! "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "Artifact Registry did not return an immutable SHA-256 digest" >&2
  exit 1
fi
deploy_image="${image%:*}@$digest"

active_revision() {
  python3 -c '
import json, sys
traffic = json.load(sys.stdin)["status"]["traffic"]
active = sorted(set(
    item["revisionName"]
    for item in traffic
    if item.get("percent") == 100 and item.get("revisionName")
))
assert len(active) == 1, f"expected exactly one revision at 100%, got {active}"
print(active[0])
'
}

assert_private_iam() {
  local policy_json public_count
  policy_json="$(gcloud run services get-iam-policy "$service" \
    --project "$project" \
    --region "$region" \
    --format=json)"
  public_count="$(python3 -c '
import json, sys
policy = json.load(sys.stdin)
public = {"allUsers", "allAuthenticatedUsers"}
print(sum(
    1
    for binding in policy.get("bindings", [])
    if binding.get("role") == "roles/run.invoker"
    for member in binding.get("members", [])
    if member in public
))
' <<<"$policy_json")"
  if [[ "$public_count" != 0 ]]; then
    echo "media-processor still has $public_count public Run Invoker binding(s)" >&2
    return 1
  fi
}

assert_runtime_revision() {
  local revision_name="$1" revision_json
  revision_json="$(gcloud run revisions describe "$revision_name" \
    --project "$project" \
    --region "$region" \
    --format=json)"
  python3 -c '
import json, sys

revision = json.load(sys.stdin)
expected_image, expected_sa = sys.argv[1:]

def require(condition, message):
    if not condition:
        raise AssertionError(message)

ready = [
    condition.get("status")
    for condition in revision.get("status", {}).get("conditions", [])
    if condition.get("type") == "Ready"
]
require(ready == ["True"], f"revision is not uniquely Ready: {ready}")
require(revision.get("status", {}).get("imageDigest") == expected_image, "image digest drift")

spec = revision.get("spec", {})
containers = spec.get("containers", [])
require(spec.get("serviceAccountName") == expected_sa, "runtime service account drift")
require(spec.get("containerConcurrency") == 2, "concurrency drift")
require(spec.get("timeoutSeconds") == 300, "timeout drift")
require(len(containers) == 1, "media revision must have exactly one container")

container = containers[0]
limits = container.get("resources", {}).get("limits", {})
require(str(limits.get("cpu")) in {"2", "2000m"}, "CPU drift")
require(limits.get("memory") == "2Gi", "memory drift")
ports = container.get("ports", [])
require(len(ports) == 1 and ports[0].get("containerPort") == 8080, "port drift")
require(not container.get("command"), "inherited command override")
require(not container.get("args"), "inherited argument override")
require("livenessProbe" not in container, "inherited liveness probe")
require(not container.get("volumeMounts"), "inherited volume mount")

startup = container.get("startupProbe", {}).get("httpGet", {})
require(startup.get("path") == "/health", "startup probe path drift")
require(startup.get("port") == 8080, "startup probe port drift")

env = container.get("env", [])
require(env == [{"name": "NODE_ENV", "value": "production"}], "environment drift")
require(not spec.get("volumes"), "inherited volume")

annotations = revision.get("metadata", {}).get("annotations", {})
require(annotations.get("autoscaling.knative.dev/maxScale") == "10", "max instances drift")
require(annotations.get("autoscaling.knative.dev/minScale", "0") in {"", "0"}, "min instances drift")
require(annotations.get("run.googleapis.com/execution-environment") == "gen2", "execution environment drift")
require(not annotations.get("run.googleapis.com/cloudsql-instances"), "inherited Cloud SQL attachment")
require(not annotations.get("run.googleapis.com/vpc-access-connector"), "inherited VPC connector")
' "$deploy_image" "$runtime_service_account" <<<"$revision_json"
}

service_json="$(gcloud run services describe "$service" \
  --project "$project" \
  --region "$region" \
  --format=json)"
previous_revision="$(printf '%s' "$service_json" | active_revision)"

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
    else
      rollback_service_json="$(gcloud run services describe "$service" \
        --project "$project" \
        --region "$region" \
        --format=json)" || rollback_service_json=''
      rollback_active="$(printf '%s' "$rollback_service_json" | active_revision)" || rollback_active=''
      if [[ "$rollback_active" != "$previous_revision" ]]; then
        echo "ROLLBACK FAILED: active revision is '$rollback_active', expected '$previous_revision'" >&2
      else
        echo "ROLLBACK VERIFIED: $previous_revision restored at 100%" >&2
      fi
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
  --service-account "$runtime_service_account" \
  --no-allow-unauthenticated \
  --invoker-iam-check \
  --no-traffic \
  --tag "$candidate_tag" \
  --revision-suffix "$candidate_tag" \
  --memory 2Gi \
  --cpu 2 \
  --concurrency 2 \
  --timeout 300 \
  --min-instances 0 \
  --max-instances 10 \
  --port 8080 \
  --execution-environment gen2 \
  --cpu-throttling \
  --no-cpu-boost \
  --no-session-affinity \
  --no-use-http2 \
  --command="" \
  --args="" \
  --liveness-probe="" \
  --clear-secrets \
  --clear-cloudsql-instances \
  --clear-vpc-connector \
  --clear-volumes \
  --clear-volume-mounts \
  --startup-probe="httpGet.path=/health,httpGet.port=8080,timeoutSeconds=5,periodSeconds=5,failureThreshold=3" \
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
assert_runtime_revision "$candidate_revision"
assert_private_iam
id_token="$(gcloud auth print-identity-token --audiences="$service_url")"

printf 'header = "Authorization: Bearer %s"\n' "$id_token" \
  | curl --config - --fail --silent --show-error --max-time 15 \
      "$candidate_url/health" \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "healthy"'
anonymous_code="$(curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}' "$candidate_url/health")"
test "$anonymous_code" = 403

gcloud run services update-traffic "$service" \
  --project "$project" \
  --region "$region" \
  --to-revisions "$candidate_revision=100" \
  --quiet
shifted=true

live_service_json="$(gcloud run services describe "$service" \
  --project "$project" \
  --region "$region" \
  --format=json)"
live_revision="$(printf '%s' "$live_service_json" | active_revision)"
test "$live_revision" = "$candidate_revision"
assert_runtime_revision "$live_revision"
assert_private_iam

printf 'header = "Authorization: Bearer %s"\n' "$id_token" \
  | curl --config - --fail --silent --show-error --max-time 15 \
      "$service_url/health" \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "healthy"'
anonymous_code="$(curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}' "$service_url/health")"
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
