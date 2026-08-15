#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
release_script="$script_dir/release-cloud-run.sh"
test_parent="${RELEASE_TEST_TMPDIR:-/tmp}"
mkdir -p "$test_parent"
test_root="$(mktemp -d "$test_parent/release-test.XXXXXX")"
fake_bin="$test_root/bin"
state_dir="$test_root/state"
mkdir -p "$fake_bin" "$state_dir"
trap 'rm -rf "$test_root"' EXIT

cat >"$fake_bin/gcloud" <<'FAKE_GCLOUD'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FAKE_GCLOUD_LOG"

if [[ "$*" == 'artifacts docker images describe '* ]]; then
  printf 'sha256:%064d\n' 0
  exit 0
fi

if [[ "$1 $2 $3" == 'run services describe' ]]; then
  active='media-old'
  [[ -f "$FAKE_STATE_DIR/active" ]] && active="$(<"$FAKE_STATE_DIR/active")"
  if [[ -f "$FAKE_STATE_DIR/tag" ]]; then
    tag="$(<"$FAKE_STATE_DIR/tag")"
    tag_percent=''
    [[ "$active" == media-candidate ]] && tag_percent=',"percent":100'
    printf '{"status":{"url":"https://media.example","traffic":[{"revisionName":"%s","percent":100},{"revisionName":"media-candidate","tag":"%s"%s,"url":"https://candidate.example"}]}}\n' "$active" "$tag" "$tag_percent"
  else
    printf '{"status":{"url":"https://media.example","traffic":[{"revisionName":"%s","percent":100}]}}\n' "$active"
  fi
  exit 0
fi

if [[ "$1 $2 $3" == 'run services get-iam-policy' ]]; then
  if [[ "${FAKE_PUBLIC_IAM:-false}" == true ]]; then
    # Includes the platform caller so this case still exercises the POST-deploy
    # public-binding rejection rather than tripping the pre-flight caller check.
    printf '{"bindings":[{"role":"roles/run.invoker","members":["allUsers","serviceAccount:glassy-tube-622@appspot.gserviceaccount.com"]}]}\n'
  elif [[ "${FAKE_MISSING_CALLER_IAM:-false}" == true ]]; then
    printf '{"bindings":[{"role":"roles/run.invoker","members":["serviceAccount:media-processor-release@glassy-tube-622.iam.gserviceaccount.com"]}]}\n'
  elif [[ "${FAKE_EXTRA_INVOKER_IAM:-false}" == true ]]; then
    printf '{"bindings":[{"role":"roles/run.invoker","members":["serviceAccount:glassy-tube-622@appspot.gserviceaccount.com","user:attacker@example.com"]}]}\n'
  elif [[ "${FAKE_CONDITIONAL_RELEASE_IAM:-false}" == true ]]; then
    printf '{"bindings":[{"role":"roles/run.invoker","members":["serviceAccount:glassy-tube-622@appspot.gserviceaccount.com"]},{"role":"roles/run.invoker","members":["serviceAccount:media-processor-release@glassy-tube-622.iam.gserviceaccount.com"],"condition":{"title":"t","expression":"false"}}]}\n'
  else
    # The real shape on glassy-tube-622 once --no-allow-unauthenticated strips
    # allUsers: the platform caller AND the release identity, which needs invoke
    # to run its own authenticated health proof.
    printf '{"bindings":[{"role":"roles/run.invoker","members":["serviceAccount:glassy-tube-622@appspot.gserviceaccount.com","serviceAccount:media-processor-release@glassy-tube-622.iam.gserviceaccount.com"]}]}\n'
  fi
  exit 0
fi

if [[ "$1 $2 $3" == 'run revisions describe' ]]; then
  memory='2Gi'
  [[ "${FAKE_DRIFT_REVISION:-false}" == true ]] && memory='1Gi'
  extra_annotation=''
  [[ "${FAKE_DIRECT_VPC:-false}" == true ]] && extra_annotation=',"run.googleapis.com/network-interfaces":"[{\\"network\\":\\"default\\"}]"'
  printf '{"metadata":{"annotations":{"autoscaling.knative.dev/maxScale":"10","run.googleapis.com/execution-environment":"gen2"%s}},"status":{"imageDigest":"us-central1-docker.pkg.dev/glassy-tube-622/media-processor-repo/media-processor@sha256:%064d","conditions":[{"type":"Ready","status":"True"}]},"spec":{"serviceAccountName":"media-processor-runtime@glassy-tube-622.iam.gserviceaccount.com","containerConcurrency":2,"timeoutSeconds":300,"containers":[{"resources":{"limits":{"cpu":"2","memory":"%s"}},"ports":[{"containerPort":8080}],"env":[{"name":"NODE_ENV","value":"production"}],"startupProbe":{"httpGet":{"path":"/health","port":8080}}}],"volumes":[]}}\n' "$extra_annotation" 0 "$memory"
  exit 0
fi

if [[ "$1 $2" == 'run deploy' ]]; then
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == --tag ]]; then
      printf '%s\n' "$2" >"$FAKE_STATE_DIR/tag"
      break
    fi
    shift
  done
  exit 0
fi

if [[ "$1 $2" == 'auth print-identity-token' ]]; then
  printf 'fake-id-token\n'
  exit 0
fi

if [[ "$1 $2 $3" == 'run services update-traffic' ]]; then
  if [[ "$*" == *'media-candidate=100'* ]]; then
    : >"$FAKE_STATE_DIR/shifted"
    printf 'media-candidate\n' >"$FAKE_STATE_DIR/active"
  fi
  if [[ "$*" == *'media-old=100'* ]]; then
    : >"$FAKE_STATE_DIR/rolled-back"
    printf 'media-old\n' >"$FAKE_STATE_DIR/active"
  fi
  if [[ "$*" == *'--remove-tags'* ]]; then
    rm -f "$FAKE_STATE_DIR/tag"
  fi
  exit 0
fi

echo "unexpected fake gcloud invocation: $*" >&2
exit 99
FAKE_GCLOUD

cat >"$fake_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
write_out=false
url=''
for argument in "$@"; do
  [[ "$argument" == --write-out ]] && write_out=true
  [[ "$argument" == --config ]] && read_config=true
  [[ "$argument" == http* ]] && url="$argument"
done
[[ "${read_config:-false}" == true ]] && cat >/dev/null

if [[ "$url" == 'https://platform-api-dot-glassy-tube-622.appspot.com/versionz' ]]; then
  [[ "${FAKE_PLATFORM_UNAVAILABLE:-false}" == true ]] && exit 22
  if [[ "${FAKE_PLATFORM_MALFORMED:-false}" == true ]]; then
    printf 'not-json\n'
  else
    printf '{"ok":true,"commit":"%s","gae_service":"platform-api","gae_version":"production"}\n' "$FAKE_PLATFORM_COMMIT"
  fi
  exit 0
fi

# --write-out is only used by the anonymous probes, so this branch decides what
# the public edge looks like. The two probes are distinguished by the shift
# marker, which lets a test open the edge at the candidate stage (must abort
# before traffic moves) or only after the shift (must roll back).
if [[ "$write_out" == true ]]; then
  if [[ -f "$FAKE_STATE_DIR/shifted" ]]; then
    printf '%s' "${FAKE_ANONYMOUS_CODE_LIVE:-${FAKE_ANONYMOUS_CODE:-403}}"
  else
    printf '%s' "${FAKE_ANONYMOUS_CODE:-403}"
  fi
  exit 0
fi

if [[ "$url" == 'https://media.example/health' && "${FAIL_LIVE_PROBE:-false}" == true && -f "$FAKE_STATE_DIR/shifted" ]]; then
  exit 22
fi

printf '{"status":"healthy"}\n'
FAKE_CURL

chmod +x "$fake_bin/gcloud" "$fake_bin/curl"

commit_sha='1111111111111111111111111111111111111111'
build_id='22222222-2222-2222-2222-222222222222'
oidc_proof="platform-api@$(printf '%040d' 3)"
platform_commit="${oidc_proof#platform-api@}"

reset_state() {
  rm -f "$state_dir/tag" "$state_dir/active" "$state_dir/shifted" "$state_dir/rolled-back" "$state_dir/gcloud.log"
  : >"$state_dir/gcloud.log"
}

run_release_raw() {
  PATH="$fake_bin:$PATH" \
  FAKE_STATE_DIR="$state_dir" \
  FAKE_GCLOUD_LOG="$state_dir/gcloud.log" \
  FAIL_LIVE_PROBE="${FAIL_LIVE_PROBE:-false}" \
  FAKE_DRIFT_REVISION="${FAKE_DRIFT_REVISION:-false}" \
  FAKE_PUBLIC_IAM="${FAKE_PUBLIC_IAM:-false}" \
  FAKE_MISSING_CALLER_IAM="${FAKE_MISSING_CALLER_IAM:-false}" \
  FAKE_EXTRA_INVOKER_IAM="${FAKE_EXTRA_INVOKER_IAM:-false}" \
  FAKE_CONDITIONAL_RELEASE_IAM="${FAKE_CONDITIONAL_RELEASE_IAM:-false}" \
  FAKE_DIRECT_VPC="${FAKE_DIRECT_VPC:-false}" \
  FAKE_PLATFORM_COMMIT="${FAKE_PLATFORM_COMMIT:-$platform_commit}" \
  FAKE_PLATFORM_MALFORMED="${FAKE_PLATFORM_MALFORMED:-false}" \
  FAKE_PLATFORM_UNAVAILABLE="${FAKE_PLATFORM_UNAVAILABLE:-false}" \
  FAKE_ANONYMOUS_CODE="${FAKE_ANONYMOUS_CODE:-403}" \
  FAKE_ANONYMOUS_CODE_LIVE="${FAKE_ANONYMOUS_CODE_LIVE:-}" \
    bash "$release_script" "$@"
}

run_release() {
  run_release_raw glassy-tube-622 "$commit_sha" "$build_id" "$1" "$2"
}

# The public-to-private cutover must be impossible without explicit evidence.
reset_state
set +e
run_release false UNSET >/dev/null 2>&1
status=$?
set -e
test "$status" -eq 78
test ! -s "$state_dir/gcloud.log"

# A prose receipt is not proof. The caller cutover must identify one exact
# serving platform commit before the release can touch Cloud Run.
reset_state
set +e
run_release true platform-api@reviewed-commit >/dev/null 2>&1
status=$?
set -e
test "$status" -eq 64
test ! -s "$state_dir/gcloud.log"

# Wrong-project and non-Cloud-Build identifiers fail before any cloud lookup.
reset_state
set +e
run_release_raw other-project "$commit_sha" "$build_id" true "$oidc_proof" >/dev/null 2>&1
wrong_project_status=$?
run_release_raw glassy-tube-622 "$commit_sha" local-build true "$oidc_proof" >/dev/null 2>&1
wrong_build_status=$?
set -e
test "$wrong_project_status" -eq 64
test "$wrong_build_status" -eq 64
test ! -s "$state_dir/gcloud.log"

# A 40-hex receipt must match the commit the production caller attests through
# /versionz. Stale, malformed, and unavailable evidence all fail before the
# first gcloud read or mutation.
for proof_case in stale malformed unavailable; do
  reset_state
  set +e
  case "$proof_case" in
    stale) FAKE_PLATFORM_COMMIT="$(printf '%040d' 4)" run_release true "$oidc_proof" >/dev/null 2>&1 ;;
    malformed) FAKE_PLATFORM_MALFORMED=true run_release true "$oidc_proof" >/dev/null 2>&1 ;;
    unavailable) FAKE_PLATFORM_UNAVAILABLE=true run_release true "$oidc_proof" >/dev/null 2>&1 ;;
  esac
  proof_status=$?
  set -e
  test "$proof_status" -eq 78
  test ! -s "$state_dir/gcloud.log"
done

# Happy path: immutable digest, private zero-traffic candidate, traffic shift,
# live proof, and candidate-tag cleanup. No rollback should occur.
reset_state
run_release true "$oidc_proof" >/dev/null
grep -q 'run deploy media-processor .*--image .*@sha256:' "$state_dir/gcloud.log"
grep -q -- '--no-allow-unauthenticated' "$state_dir/gcloud.log"
grep -q -- '--no-traffic' "$state_dir/gcloud.log"
grep -q -- '--cpu 2 --concurrency 2' "$state_dir/gcloud.log"
grep -q -- '--command= --args= --liveness-probe=' "$state_dir/gcloud.log"
grep -q -- '--clear-secrets --clear-cloudsql-instances --clear-vpc-connector --clear-network --clear-custom-audiences' "$state_dir/gcloud.log"
grep -q -- '--ingress=all' "$state_dir/gcloud.log"
grep -q 'run revisions describe media-candidate' "$state_dir/gcloud.log"
grep -q 'run services get-iam-policy media-processor' "$state_dir/gcloud.log"
grep -q 'media-candidate=100' "$state_dir/gcloud.log"
grep -q -- '--remove-tags candidate-' "$state_dir/gcloud.log"
test ! -f "$state_dir/rolled-back"

# A candidate that cannot prove the exact reviewed revision contract receives
# no traffic even when its HTTP health endpoint would have answered.
reset_state
set +e
FAKE_DRIFT_REVISION=true run_release true "$oidc_proof" >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test ! -f "$state_dir/shifted"

# Service IAM is part of the candidate contract; application health alone
# cannot prove the public edge closed.
reset_state
set +e
FAKE_PUBLIC_IAM=true run_release true "$oidc_proof" >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test ! -f "$state_dir/shifted"

# Private is not synonymous with operational. The exact App Engine runtime
# principal must have an unconditional invoker binding BEFORE the deploy, not
# merely before traffic moves: --no-allow-unauthenticated closes the public edge
# service-wide the moment the candidate lands, and no rollback reopens it. So
# this must fail without ever reaching `run deploy`.
reset_state
set +e
FAKE_MISSING_CALLER_IAM=true run_release true "$oidc_proof" >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test ! -f "$state_dir/shifted"
grep -q 'run services get-iam-policy media-processor' "$state_dir/gcloud.log"
# Counted rather than negated: `! grep ...` is exempt from errexit, so it would
# report nothing and assert nothing. `|| true` keeps the expected zero-match
# case from tripping errexit inside the substitution.
test "$(grep -c 'run deploy media-processor' "$state_dir/gcloud.log" || true)" -eq 0

# Extra invokers are not equivalent to the reviewed platform caller. The default
# fake policy already carries the release identity alongside the caller, so the
# happy path above proves that pair is ACCEPTED; this proves a third principal is
# still rejected, i.e. the allowance is a named pair and not a blanket relaxation.
reset_state
set +e
FAKE_EXTRA_INVOKER_IAM=true run_release true "$oidc_proof" >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test ! -f "$state_dir/shifted"

# The release identity may hold invoker at service scope, but not conditionally:
# a condition it does not satisfy would 403 its own post-deploy health proof.
reset_state
set +e
FAKE_CONDITIONAL_RELEASE_IAM=true run_release true "$oidc_proof" >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test ! -f "$state_dir/shifted"

# Inherited Direct VPC is an SSRF expansion and must receive zero traffic.
reset_state
set +e
FAKE_DIRECT_VPC=true run_release true "$oidc_proof" >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test ! -f "$state_dir/shifted"

# The anonymous probe is the only check that reads the live edge rather than the
# declared policy, and IAM propagation is explicitly eventual ("may take a few
# moments to take effect"). An edge that still answers an unauthenticated caller
# must therefore stop the release even when every declarative assertion passed.
reset_state
set +e
FAKE_ANONYMOUS_CODE=200 run_release true "$oidc_proof" >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test ! -f "$state_dir/shifted"

# Same proof after the shift: the stable URL answering anonymously is the exact
# condition this release exists to eliminate, so it must roll back rather than
# leave a publicly reachable revision serving 100%.
reset_state
set +e
FAKE_ANONYMOUS_CODE_LIVE=200 run_release true "$oidc_proof" >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test -f "$state_dir/shifted"
test -f "$state_dir/rolled-back"
test "$(<"$state_dir/active")" = media-old

# Adversarial path: once traffic has shifted, a failed live proof must restore
# and re-describe the exact prior revision, then remove the candidate tag.
reset_state
set +e
FAIL_LIVE_PROBE=true run_release true "$oidc_proof" >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test -f "$state_dir/shifted"
test -f "$state_dir/rolled-back"
test "$(<"$state_dir/active")" = media-old
grep -q 'media-old=100' "$state_dir/gcloud.log"
test "$(grep -c 'run services describe media-processor' "$state_dir/gcloud.log")" -ge 4
grep -q -- '--remove-tags candidate-' "$state_dir/gcloud.log"

echo 'release state-machine tests: pass'
