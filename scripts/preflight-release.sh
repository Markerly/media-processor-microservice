#!/usr/bin/env bash
# Read-only preflight for the private-media cutover.
#
# Rollout steps 2 and 3 in README are operator checklist items, which makes them
# exactly as reliable as the operator working through them. This answers all of
# them in one command and prints the exact substitution string to paste into the
# build approval — so the failure mode is "the script said no", not "someone
# assumed the binding was already there".
#
# It mutates nothing. Everything here is a describe/list/get call, so it is safe
# to run repeatedly, including against a service mid-release.
#
# A check that could not run reports UNKNOWN, never FAIL. Expired credentials and
# a missing binding are opposite situations — one means "look again", the other
# means "do not release" — and a preflight that renders them identically is the
# guard-shaped-object INV-43 describes. Exit codes: 0 pass, 1 failed, 2
# inconclusive, 77 unauthenticated.
#
# Usage: bash scripts/preflight-release.sh [PROJECT]
set -Eeuo pipefail

project="${1:-glassy-tube-622}"
service='media-processor'
region='us-central1'
repo='media-processor-repo'
platform_caller="serviceAccount:$project@appspot.gserviceaccount.com"
release_sa="media-processor-release@$project.iam.gserviceaccount.com"
runtime_sa="media-processor-runtime@$project.iam.gserviceaccount.com"
versionz='https://platform-api-dot-glassy-tube-622.appspot.com/versionz'

failures=0
unknowns=0
pass() { printf '  PASS     %s\n' "$1"; }
fail() { printf '  FAIL     %s\n' "$1" >&2; failures=$((failures + 1)); }
unknown() { printf '  UNKNOWN  %s\n' "$1" >&2; unknowns=$((unknowns + 1)); }
note() { printf '  note     %s\n' "$1"; }

# Prove the credentials can actually reach THIS project before interpreting any
# absence as meaningful.
if ! gcloud auth print-access-token >/dev/null 2>&1; then
  echo "not authenticated. Run: gcloud auth login" >&2
  exit 77
fi
if ! gcloud projects describe "$project" --format='value(projectId)' >/dev/null 2>&1; then
  echo "cannot read project $project with the active gcloud account." >&2
  echo "Run: gcloud auth login   (or: gcloud config set account <account>)" >&2
  exit 77
fi

echo "Preflight for $service in $project"

echo
echo "1. Least-privilege identities exist"
if accounts="$(gcloud iam service-accounts list --project "$project" \
     --format='value(email)' 2>/dev/null)"; then
  for sa in "$release_sa" "$runtime_sa"; do
    if grep -qxF "$sa" <<<"$accounts"; then pass "$sa"; else fail "$sa does not exist"; fi
  done
else
  unknown "cannot list service accounts in $project"
fi

echo
echo "2. Immutable image repository exists"
if repo_out="$(gcloud artifacts repositories describe "$repo" --project "$project" \
     --location "$region" --format='value(name)' 2>&1)"; then
  pass "$region/$repo"
elif grep -qiE 'not found|does not exist' <<<"$repo_out"; then
  fail "Artifact Registry repository $region/$repo does not exist"
else
  unknown "cannot describe Artifact Registry repository $region/$repo"
fi

echo
echo "3. Invocation boundary"
if policy="$(gcloud run services get-iam-policy "$service" --project "$project" \
     --region "$region" --format=json 2>&1)"; then
  # Only double quotes inside this block: it is delimited by shell single quotes.
  if ! python3 -c '
import json, sys

policy = json.loads(sys.argv[1] or "{}")
caller, release = sys.argv[2], "serviceAccount:" + sys.argv[3]

invoker = [b for b in policy.get("bindings", []) if b.get("role") == "roles/run.invoker"]
members = [m for b in invoker for m in b.get("members", [])]
unconditional = [m for b in invoker if not b.get("condition") for m in b.get("members", [])]
public = sorted(m for m in members if m in {"allUsers", "allAuthenticatedUsers"})

if public:
    print("  note     service is still PUBLIC (" + ", ".join(public)
          + ") - this release performs the cutover")
else:
    print("  note     service is already private - the cutover has already happened")

ok = True
if caller in unconditional:
    print("  PASS     platform caller unconditional run.invoker: " + caller)
else:
    print("  FAIL     platform caller has NO unconditional run.invoker: " + caller)
    ok = False

extra = sorted(set(members) - {caller} - set(public))
if extra:
    print("  FAIL     unexpected service-level invoker(s); release will refuse: "
          + ", ".join(extra))
    ok = False
else:
    print("  PASS     no unexpected service-level invoker")

# Advisory: the release identity is expected to hold invoker at PROJECT level,
# which a service-policy read cannot see (INV-43 / README scope note).
if release in members:
    print("  FAIL     " + release + " holds a SERVICE-level invoker binding; the release "
          "asserts the platform caller is the only one, so this will abort")
    ok = False

sys.exit(0 if ok else 1)
' "$policy" "$platform_caller" "$release_sa"; then
    failures=$((failures + 1))
  fi
elif grep -qiE 'not found|does not exist' <<<"$policy"; then
  fail "Cloud Run service $service does not exist in $region"
else
  unknown "cannot read the $service IAM policy"
fi

echo
echo "4. Release identity can run its own authenticated health proof"
# Project-level, because the service-level policy is asserted to hold the
# platform caller and nothing else. Without this the post-deploy 200 proof 403s.
if project_invokers="$(gcloud projects get-iam-policy "$project" \
     --flatten='bindings[].members' \
     --filter='bindings.role=roles/run.invoker' \
     --format='value(bindings.members)' 2>/dev/null)"; then
  if grep -qxF "serviceAccount:$release_sa" <<<"$project_invokers"; then
    pass "$release_sa holds project-level roles/run.invoker"
  else
    fail "$release_sa has no project-level roles/run.invoker; the authenticated /health proof will 403"
  fi
else
  unknown "cannot read the project IAM policy (needs resourcemanager.projects.getIamPolicy)"
fi

echo
echo "5. Proof value for the build approval"
if serving="$(curl --fail --silent --show-error --proto '=https' --max-time 15 \
     --max-filesize 16384 "$versionz" 2>/dev/null)"; then
  commit="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("commit",""))' \
    <<<"$serving" 2>/dev/null || true)"
  if [[ "$commit" =~ ^[a-f0-9]{40}$ ]]; then
    pass "platform-api is serving $commit"
    echo
    echo "  Approve the build with:"
    echo "    _PLATFORM_OIDC_READY=true"
    echo "    _PLATFORM_OIDC_PROOF=platform-api@$commit"
    note "this SHA moves on every platform-api deploy - re-run immediately before approving"
  else
    fail "/versionz did not report a 40-character commit"
  fi
else
  unknown "/versionz is unreachable"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "PREFLIGHT FAILED: $failures check(s) failed, $unknowns inconclusive." >&2
  echo "Do not approve the release build." >&2
  exit 1
fi
if [[ "$unknowns" -gt 0 ]]; then
  echo "PREFLIGHT INCONCLUSIVE: $unknowns check(s) could not run." >&2
  echo "Nothing here says the release is unsafe - it says it is unverified. Fix access and re-run." >&2
  exit 2
fi
echo "PREFLIGHT PASSED. Remaining human steps: force a real thumbnail through"
echo "platform-api and retain its request/log trace before approving."
