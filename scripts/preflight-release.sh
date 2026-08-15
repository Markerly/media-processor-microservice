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
# Usage: bash scripts/preflight-release.sh [PROJECT] [ACCOUNT]
#
# ACCOUNT is worth passing whenever more than one thing on the machine drives
# gcloud. `gcloud config set account` is global, so a concurrent agent or shell
# can move the active identity between two runs of this script and the answers
# would quietly become about a different principal. Passing it here exports
# CLOUDSDK_CORE_ACCOUNT for this process only — it never mutates shared config —
# and the effective account is echoed below so a result can always be attributed.
set -Eeuo pipefail

project="${1:-glassy-tube-622}"
account="${2:-${CLOUDSDK_CORE_ACCOUNT:-}}"
if [[ -n "$account" ]]; then
  export CLOUDSDK_CORE_ACCOUNT="$account"
fi
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

# Prove these credentials can actually reach THIS project before interpreting any
# absence as meaningful. Distinguish the two ways that fails, because they need
# opposite responses: a stale token means re-auth, a live token without access
# means you are pointed at the wrong identity entirely.
effective="$(gcloud config get-value account 2>/dev/null || true)"
[[ -n "$effective" && "$effective" != "(unset)" ]] || effective='(none)'

if ! gcloud auth print-access-token >/dev/null 2>&1; then
  echo "account $effective has no usable credentials." >&2
  echo "Run: gcloud auth login $effective" >&2
  exit 77
fi
if ! probe="$(gcloud projects describe "$project" --format='value(projectId)' 2>&1)"; then
  echo "account $effective cannot read project $project." >&2
  if grep -qi 'reauthentication\|invalid_grant\|refreshing your current auth' <<<"$probe"; then
    echo "Cause: the credential is stale." >&2
    echo "Run: gcloud auth login $effective" >&2
  else
    echo "Cause: authenticated, but this identity has no access to $project." >&2
    echo "Pass the right one: bash scripts/preflight-release.sh $project <account>" >&2
    echo "Credentialed accounts:" >&2
    gcloud auth list --format='value(account)' 2>/dev/null | sed 's/^/  /' >&2
  fi
  exit 77
fi

echo "Preflight for $service in $project"
echo "  using account: $effective"

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
echo "1b. Release identity can mint its own ID token"
# Cloud Build runs as this SA. gcloud auth print-identity-token does not work
# there, and the metadata /identity endpoint 404s. The health proof therefore
# calls iamcredentials generateIdToken on this same identity, which requires
# a self-binding of roles/iam.serviceAccountOpenIdTokenCreator.
if sa_policy="$(gcloud iam service-accounts get-iam-policy "$release_sa" \
     --project "$project" --format=json 2>/dev/null)"; then
  if python3 -c '
import json, sys
policy = json.loads(sys.argv[1])
needed = {
    "serviceAccount:" + sys.argv[2],
    "serviceAccount:132233585000@cloudbuild.gserviceaccount.com",
}
holders = {
    member
    for binding in policy.get("bindings", [])
    if binding.get("role") == "roles/iam.serviceAccountOpenIdTokenCreator"
    for member in binding.get("members", [])
}
missing = sorted(needed - holders)
if missing:
    print("missing OpenIdTokenCreator on release SA: " + ", ".join(missing))
    raise SystemExit(1)
' "$sa_policy" "$release_sa"; then
    pass "Cloud Build and the release SA can generateIdToken as $release_sa"
  else
    fail "missing serviceAccountOpenIdTokenCreator on $release_sa (Cloud Build worker and/or self); the /health proof cannot mint an ID token"
  fi
else
  unknown "cannot read IAM policy for $release_sa"
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

extra = sorted(set(members) - {caller, release} - set(public))
if extra:
    print("  FAIL     unexpected service-level invoker(s); release will refuse: "
          + ", ".join(extra))
    ok = False
else:
    print("  PASS     no service-level invoker beyond the platform caller and release identity")

# The release identity must be able to invoke, because the post-deploy health
# proof presents ITS token. A service-level binding is the narrow way to grant
# that; project-level (check 4) also works but confers invoke project-wide.
if release in members:
    if release in unconditional:
        print("  PASS     release identity can run its own health proof (service-level invoker)")
    else:
        print("  FAIL     release identity has only a conditional invoker binding; its health proof would 403")
        ok = False
else:
    print("  note     release identity is not a service-level invoker; it must hold "
          "project-level instead - see check 4")

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
echo "4. Project-level invoker (only needed if check 3 found no service-level binding)"
# Reported either way, because a project-level grant confers invoke on EVERY
# Cloud Run service in the project. It satisfies the release, and it is also
# worth seeing when a narrower service-level binding already covers the need.
release_service_level=false
if [[ -n "${policy:-}" ]] && python3 -c '
import json, sys
try:
    policy = json.loads(sys.argv[1])
except ValueError:
    raise SystemExit(1)
members = {m for b in policy.get("bindings", []) if b.get("role") == "roles/run.invoker"
           for m in b.get("members", [])}
raise SystemExit(0 if sys.argv[2] in members else 1)
' "$policy" "serviceAccount:$release_sa" 2>/dev/null; then
  release_service_level=true
fi

if project_invokers="$(gcloud projects get-iam-policy "$project" \
     --flatten='bindings[].members' \
     --filter='bindings.role=roles/run.invoker' \
     --format='value(bindings.members)' 2>/dev/null)"; then
  if grep -qxF "serviceAccount:$release_sa" <<<"$project_invokers"; then
    note "$release_sa also holds PROJECT-level roles/run.invoker (invoke on every Cloud Run service)"
  elif [[ "$release_service_level" == true ]]; then
    pass "not needed: the service-level binding in check 3 already covers the health proof"
  else
    fail "$release_sa has neither a service-level nor a project-level roles/run.invoker; the authenticated /health proof will 403"
  fi
else
  if [[ "$release_service_level" == true ]]; then
    note "cannot read the project IAM policy, but the service-level binding already covers the health proof"
  else
    unknown "cannot read the project IAM policy (needs resourcemanager.projects.getIamPolicy)"
  fi
fi

echo
echo "5. ID-token audiences"
# Service-level; empty today is expected (the cutover release pins them).
# Report what is there so a missing pin after the first private release is visible.
if [[ -n "${policy:-}" ]]; then
  if service_json="$(gcloud run services describe "$service" --project "$project" \
       --region "$region" --format=json 2>/dev/null)"; then
    python3 -c '
import json, sys
service = json.loads(sys.argv[1])
required = {
    "https://media-processor-132233585000.us-central1.run.app",
    "https://media-processor-65la52ndha-uc.a.run.app",
}
raw = (service.get("metadata") or {}).get("annotations", {}).get(
    "run.googleapis.com/custom-audiences", "[]"
)
try:
    declared = set(json.loads(raw) if isinstance(raw, str) else raw or [])
except ValueError:
    declared = set()
missing = sorted(required - declared)
if not declared:
    print("  note     no custom audiences yet — the cutover release will pin both run.app URLs")
elif missing:
    print("  FAIL     missing ID-token audiences the platform caller uses: " + ", ".join(missing))
    raise SystemExit(1)
else:
    print("  PASS     both production run.app URLs are accepted audiences")
' "$service_json" || failures=$((failures + 1))
  else
    unknown "cannot describe $service to read custom audiences"
  fi
fi

echo
echo "6. Proof value for the build approval"
if serving="$(curl --fail --silent --show-error --proto '=https' --max-time 15 \
     --max-filesize 16384 "$versionz" 2>/dev/null)"; then
  commit="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("commit",""))' \
    <<<"$serving" 2>/dev/null || true)"
  if [[ "$commit" =~ ^[a-f0-9]{40}$ ]]; then
    pass "platform-api is serving $commit"
    if [[ -n "${policy:-}" ]] && python3 -c '
import json, sys
members = {m for b in json.loads(sys.argv[1]).get("bindings", [])
           if b.get("role") == "roles/run.invoker"
           for m in b.get("members", [])}
raise SystemExit(0 if members & {"allUsers", "allAuthenticatedUsers"} else 1)
' "$policy"; then
      echo
      echo "  Approve the cutover build with:"
      echo "    _PLATFORM_OIDC_READY=true"
      echo "    _PLATFORM_OIDC_PROOF=platform-api@$commit"
      note "this SHA moves on every platform-api deploy - re-run immediately before approving"
    else
      note "service is already private — the release does not need these substitutions"
    fi
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
if [[ -n "${policy:-}" ]] && python3 -c '
import json, sys
members = {m for b in json.loads(sys.argv[1]).get("bindings", [])
           if b.get("role") == "roles/run.invoker"
           for m in b.get("members", [])}
raise SystemExit(0 if members & {"allUsers", "allAuthenticatedUsers"} else 1)
' "$policy"; then
  echo "PREFLIGHT PASSED. Remaining human steps: force a real thumbnail through"
  echo "platform-api and retain its request/log trace before approving the cutover."
else
  echo "PREFLIGHT PASSED. Service is already private."
fi
