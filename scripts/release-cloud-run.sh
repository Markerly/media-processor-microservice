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

service='media-processor'
region='us-central1'
platform_caller='serviceAccount:glassy-tube-622@appspot.gserviceaccount.com'
runtime_service_account="media-processor-runtime@$project.iam.gserviceaccount.com"
release_service_account="media-processor-release@$project.iam.gserviceaccount.com"
# Both Google-generated hostnames for this one service. platform-api mints
# its ID token for the project-number URL (MEDIA_PROCESSOR_URL in the
# production secret). status.url is the hash URL. Cloud Run's implicit
# accepted audience is "the" *.run.app URL — which of the two is not a
# contract. Setting both as custom audiences makes either token valid the
# moment --no-allow-unauthenticated lands. Clearing them would re-open the
# guess. These are also the two origins platform-api allowlists.
platform_audience='https://media-processor-132233585000.us-central1.run.app'
hash_audience='https://media-processor-65la52ndha-uc.a.run.app'
accepted_audiences="${platform_audience},${hash_audience}"

# The platform-api /versionz pin answers "is the ID-token caller deployed?"
# That question only matters while this service is still public and about to
# stop being so. Once the boundary exists, every release already proves the
# caller can invoke (IAM + authenticated 200 + anonymous 403). Leaving the
# pin in place forever couples media hotfixes to platform-api's deploy
# cadence — and the usual outcome of that friction is someone routing
# around the gate. Read the live policy first; require the attestation
# only when this release is the cutover. Restoring allUsers as break-glass
# makes the next release demand the proof again.
service_has_public_invoker() {
  local policy_json
  policy_json="$(gcloud run services get-iam-policy "$service" \
    --project "$project" \
    --region "$region" \
    --format=json)"
  python3 -c '
import json, sys
policy = json.load(sys.stdin)
public = {"allUsers", "allAuthenticatedUsers"}
members = {
    member
    for binding in policy.get("bindings", [])
    if binding.get("role") == "roles/run.invoker"
    for member in binding.get("members", [])
}
raise SystemExit(0 if members & public else 1)
' <<<"$policy_json"
}

require_cutover_oidc_proof() {
  if [[ "$oidc_ready" != true || "$oidc_proof" == UNSET || -z "$oidc_proof" ]]; then
    echo "private cutover blocked: deploy and prove the platform-api OIDC caller first" >&2
    echo "set _PLATFORM_OIDC_READY=true and record _PLATFORM_OIDC_PROOF in the approved build" >&2
    exit 78
  fi
  if [[ ! "$oidc_proof" =~ ^platform-api@[a-f0-9]{40}$ ]]; then
    echo "OIDC proof must pin the exact serving platform-api Git commit" >&2
    exit 64
  fi

  local platform_commit="${oidc_proof#platform-api@}"
  # Bare service host, not a tenant slug. /versionz is mounted ahead of
  # platform-api's tenant resolution, so both spellings answer identically
  # today — but the tenant form additionally depends on App Engine
  # soft-routing an unknown version name to the default one.
  local platform_version_url='https://platform-api-dot-glassy-tube-622.appspot.com/versionz'
  local platform_version_json
  if ! platform_version_json="$(curl --fail --silent --show-error --proto '=https' --max-time 15 --max-filesize 16384 "$platform_version_url")"; then
    echo "private cutover blocked: platform-api /versionz is unreachable" >&2
    exit 78
  fi
  if [[ "${#platform_version_json}" -gt 16384 ]]; then
    echo "private cutover blocked: platform-api /versionz is unreachable" >&2
    exit 78
  fi
  if ! python3 -c '
import json, re, sys
try:
    version = json.load(sys.stdin)
    expected = sys.argv[1]
    assert isinstance(version, dict)
    assert version.get("ok") is True
    assert version.get("gae_service") == "platform-api"
    assert version.get("gae_version") == "production"
    assert re.fullmatch(r"[a-f0-9]{40}", str(version.get("commit", "")))
    assert version.get("commit") == expected
except Exception as error:
    print(f"platform-api serving-commit proof failed: {type(error).__name__}", file=sys.stderr)
    raise SystemExit(1)
' "$platform_commit" <<<"$platform_version_json"; then
    echo "private cutover blocked: reviewed platform-api commit is not serving" >&2
    exit 78
  fi
}

if service_has_public_invoker; then
  echo "service is public; this release performs the cutover and requires the OIDC attestation"
  require_cutover_oidc_proof
else
  echo "service is already private; skipping the one-time platform-api OIDC cutover attestation"
fi

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

# Scope note, deliberately explicit: this reads the SERVICE-level IAM policy
# only. `roles/run.invoker` granted at the project or folder level does not
# appear here and is not checked. So the guarantee this function provides is "no
# public binding, and no service-level invoker beyond the two this design names"
# — not "only these two principals can invoke". Anything stronger needs
# resourcemanager.projects.getIamPolicy, which would widen the release identity
# past the least privilege this release exists to establish. The anonymous 403
# probes are what prove the public edge is closed.
#
# The two named principals are the platform caller (the application) and the
# release identity (which must invoke to run its own post-deploy health proof).
# An earlier revision asserted the caller was the ONLY service-level invoker.
# Live policy on glassy-tube-622 shows the release identity holding exactly such
# a binding, so that assertion would have aborted every release — and aborted it
# AFTER the candidate deploy had already closed the public edge service-wide.
assert_invocation_iam() {
  local policy_json
  local expected_caller="$platform_caller"
  local release_identity="serviceAccount:$release_service_account"
  policy_json="$(gcloud run services get-iam-policy "$service" \
    --project "$project" \
    --region "$region" \
    --format=json)"
  python3 -c '
import json, sys
policy = json.load(sys.stdin)
expected_caller, release_identity = sys.argv[1:3]
public = {"allUsers", "allAuthenticatedUsers"}
invoker_bindings = [
    binding
    for binding in policy.get("bindings", [])
    if binding.get("role") == "roles/run.invoker"
]
invoker_members = [
    member
    for binding in invoker_bindings
    for member in binding.get("members", [])
]
unconditional_members = [
    member
    for binding in invoker_bindings
    if not binding.get("condition")
    for member in binding.get("members", [])
]

public_members = sorted(member for member in invoker_members if member in public)
assert not public_members, f"public Run Invoker binding remains: {public_members}"

# The release identity belongs here, and is permitted rather than merely
# tolerated: the authenticated /health proof further down presents ITS token, so
# a policy that excludes it leaves this release structurally unable to prove the
# boundary it just established. Holding that grant at SERVICE scope is the
# narrow choice -- the alternative, project-level roles/run.invoker, would
# confer invoke on every Cloud Run service in the project.
unexpected = sorted(set(invoker_members) - {expected_caller, release_identity})
assert not unexpected, f"unexpected Run Invoker members: {unexpected}"

assert expected_caller in unconditional_members, (
    f"the platform caller {expected_caller} needs an unconditional service-level "
    f"invoker binding; got {invoker_members}"
)
if release_identity in invoker_members:
    assert release_identity in unconditional_members, (
        f"{release_identity} holds only a conditional invoker binding, so the "
        f"authenticated health proof below would 403"
    )
' "$expected_caller" "$release_identity" <<<"$policy_json"
}

# Pre-flight, and the ordering here is the whole point.
#
# `--no-allow-unauthenticated` on the candidate deploy below is SERVICE-scoped
# and takes effect when the deploy lands — not when traffic shifts. The public
# edge therefore closes for the revision that is *currently serving 100%*, while
# the candidate still holds zero traffic. `--no-traffic` isolates the new code;
# it does not isolate the authorization change.
#
# That makes the platform caller's invoker binding a precondition, not a
# post-condition. If it is missing at deploy time the caller starts receiving 403
# immediately, and this release deliberately has no public-access rollback (see
# README) — so the automated recovery path cannot undo it. Prove the caller can
# get in while the door is still open, and refuse the cutover otherwise.
assert_platform_caller_present() {
  local policy_json
  policy_json="$(gcloud run services get-iam-policy "$service" \
    --project "$project" \
    --region "$region" \
    --format=json)"
  python3 -c '
import json, sys
policy = json.load(sys.stdin)
expected_caller = sys.argv[1]
granted = [
    binding
    for binding in policy.get("bindings", [])
    if binding.get("role") == "roles/run.invoker"
    and expected_caller in binding.get("members", [])
    and not binding.get("condition")
]
assert granted, (
    f"refusing to close the public edge: {expected_caller} holds no unconditional "
    f"roles/run.invoker binding on this service. Closing it now would 403 the "
    f"platform caller immediately, and rollback cannot restore public access."
)
' "$platform_caller" <<<"$policy_json"
}

# Service-level custom audiences apply to every revision, including the one
# still serving 100% when this deploy closes the public edge. Require both
# production origins so a token minted for either hostname is accepted.
assert_accepted_audiences() {
  python3 -c '
import json, sys
service = json.load(sys.stdin)
required = set(sys.argv[1].split(","))
raw = (service.get("metadata") or {}).get("annotations", {}).get(
    "run.googleapis.com/custom-audiences", "[]"
)
if isinstance(raw, list):
    declared = set(raw)
elif isinstance(raw, str):
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as error:
        raise AssertionError(f"custom-audiences annotation is not JSON: {error}") from error
    if not isinstance(parsed, list):
        raise AssertionError(f"custom-audiences annotation is not a list: {type(parsed).__name__}")
    declared = set(parsed)
else:
    raise AssertionError(f"custom-audiences annotation has unexpected type {type(raw).__name__}")
missing = sorted(required - declared)
assert not missing, f"service is missing required ID-token audiences: {missing}"
' "$accepted_audiences"
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
require("readinessProbe" not in container, "inherited readiness probe")
require(not container.get("volumeMounts"), "inherited volume mount")

startup = container.get("startupProbe", {}).get("httpGet", {})
require(startup.get("path") == "/health", "startup probe path drift")
require(startup.get("port") == 8080, "startup probe port drift")

env_items = container.get("env", [])
env = {item.get("name"): item.get("value") for item in env_items}
require(len(env) == len(env_items), "duplicate environment variable")
require(env.get("NODE_ENV") == "production", "NODE_ENV drift")
# ALLOWED_VIDEO_BUCKETS is the documented narrowing of the GCS host policy
# (README, DEVELOPER_SETUP). Strict equality across the whole env block made
# that control impossible to turn on without failing the release as "drift",
# so it is permitted by name. Every other variable is still drift: this is an
# allowlist, not a relaxation.
allowed_env = {"NODE_ENV", "ALLOWED_VIDEO_BUCKETS"}
unexpected_env = sorted(set(env) - allowed_env)
require(not unexpected_env, f"unexpected environment: {unexpected_env}")
require(not spec.get("volumes"), "inherited volume")

annotations = revision.get("metadata", {}).get("annotations", {})
require(annotations.get("autoscaling.knative.dev/maxScale") == "10", "max instances drift")
require(annotations.get("autoscaling.knative.dev/minScale", "0") in {"", "0"}, "min instances drift")
require(annotations.get("run.googleapis.com/execution-environment") == "gen2", "execution environment drift")
require(not annotations.get("run.googleapis.com/cloudsql-instances"), "inherited Cloud SQL attachment")
require(not annotations.get("run.googleapis.com/vpc-access-connector"), "inherited VPC connector")
require(not annotations.get("run.googleapis.com/network-interfaces"), "inherited Direct VPC")
require(not annotations.get("run.googleapis.com/vpc-access-egress"), "inherited VPC egress")
# Custom audiences belong on the Service, not the revision template.
# A template-level copy would be inherited drift; the service-level pin
# is asserted separately after deploy.
require(not annotations.get("run.googleapis.com/custom-audiences"), "inherited revision custom audiences")
require(not annotations.get("run.googleapis.com/network"), "inherited network")
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

assert_platform_caller_present

candidate_attempted=true
gcloud run deploy "$service" \
  --project "$project" \
  --image "$deploy_image" \
  --region "$region" \
  --platform managed \
  --service-account "$runtime_service_account" \
  --no-allow-unauthenticated \
  --invoker-iam-check \
  --ingress=all \
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
  --clear-network \
  --set-custom-audiences="$accepted_audiences" \
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
# Cloud Build's user-managed SA cannot satisfy `gcloud auth print-identity-token`
# and its metadata server 404s /identity (a25d3818). Mint via IAM Credentials
# generateIdToken on this same identity, then fall back to gcloud so the local
# fake-gcloud suite still exercises the proof.
mint_id_token() {
  local audience="$1" token access
  # Cloud Build's metadata server 404s /identity for a user-managed SA
  # (observed on a25d3818). Try it anyway so the same script works on GCE.
  token="$(curl --fail --silent --show-error --max-time 5 \
    -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${audience}" \
    || true)"
  if [[ "$token" == *.* && "$token" != *' '* ]]; then
    printf '%s\n' "$token"
    return 0
  fi
  token="$(curl --fail --silent --show-error --max-time 5 \
    -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/${release_service_account}/identity?audience=${audience}" \
    || true)"
  if [[ "$token" == *.* && "$token" != *' '* ]]; then
    printf '%s\n' "$token"
    return 0
  fi
  # The worker *is* this SA. generateIdToken on itself requires the
  # serviceAccountOpenIdTokenCreator self-binding (preflight checks it).
  access="$(gcloud auth print-access-token)"
  creds_json="$(curl --silent --show-error --max-time 15 \
    -H "Authorization: Bearer ${access}" \
    -H 'Content-Type: application/json' \
    --data-binary "{\"audience\":\"${audience}\",\"includeEmail\":true}" \
    "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${release_service_account}:generateIdToken" \
    || true)"
  token="$(printf '%s' "$creds_json" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    print((json.loads(raw) or {}).get("token") or "")
except Exception:
    print("")
' || true)"
  if [[ "$token" == *.* && "$token" != *' '* ]]; then
    printf '%s\n' "$token"
    return 0
  fi
  echo "iamcredentials.generateIdToken did not return a token: ${creds_json:0:400}" >&2
  gcloud auth print-identity-token --audiences="$audience"
}

assert_runtime_revision "$candidate_revision"
assert_invocation_iam
assert_accepted_audiences <<<"$service_json"
id_token="$(mint_id_token "$service_url")"
# The platform caller mints for $platform_audience, not status.url. We cannot
# mint as the App Engine SA (getOpenIdToken is self-only on that identity).
# Audience is a property of the token, not the principal: a 200 here with a
# token whose aud is the platform origin proves Cloud Run will accept the
# token platform-api actually sends, once the edge is private.
platform_id_token="$(mint_id_token "$platform_audience")"

printf 'header = "Authorization: Bearer %s"\n' "$id_token" \
  | curl --config - --fail --silent --show-error --max-time 15 \
      "$candidate_url/health" \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "healthy"'
printf 'header = "Authorization: Bearer %s"\n' "$platform_id_token" \
  | curl --config - --fail --silent --show-error --max-time 15 \
      "$candidate_url/health" \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "healthy"'
anonymous_code="$(curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}' "$candidate_url/health")"
test "$anonymous_code" = 403

# Arm the rollback BEFORE the mutation, not after. gcloud can fail after the
# traffic change has already been applied server-side (a dropped connection
# while polling the operation is enough), and that failure mode would otherwise
# leave the candidate serving with `shifted=false` — meaning the trap declines
# to roll back exactly when it is most needed. Rolling back to the revision
# already at 100% is a harmless no-op, so arming early is strictly safer.
shifted=true
gcloud run services update-traffic "$service" \
  --project "$project" \
  --region "$region" \
  --to-revisions "$candidate_revision=100" \
  --quiet

live_service_json="$(gcloud run services describe "$service" \
  --project "$project" \
  --region "$region" \
  --format=json)"
live_revision="$(printf '%s' "$live_service_json" | active_revision)"
test "$live_revision" = "$candidate_revision"
assert_runtime_revision "$live_revision"
assert_invocation_iam

printf 'header = "Authorization: Bearer %s"\n' "$id_token" \
  | curl --config - --fail --silent --show-error --max-time 15 \
      "$service_url/health" \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "healthy"'
printf 'header = "Authorization: Bearer %s"\n' "$platform_id_token" \
  | curl --config - --fail --silent --show-error --max-time 15 \
      "$service_url/health" \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "healthy"'
anonymous_code="$(curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}' "$service_url/health")"
test "$anonymous_code" = 403

# Live proofs passed. Tag cleanup is hygiene and must not roll traffic back.
succeeded=true
gcloud run services update-traffic "$service" \
  --project "$project" \
  --region "$region" \
  --remove-tags "$candidate_tag" \
  --quiet \
  || echo "candidate tag cleanup failed" >&2
trap - EXIT

echo "released $candidate_revision from $deploy_image"
echo "platform OIDC proof: $oidc_proof"
