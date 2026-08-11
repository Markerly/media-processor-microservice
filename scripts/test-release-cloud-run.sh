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
  if [[ -f "$FAKE_STATE_DIR/tag" ]]; then
    tag="$(<"$FAKE_STATE_DIR/tag")"
    printf '{"status":{"url":"https://media.example","traffic":[{"revisionName":"media-old","percent":100},{"revisionName":"media-candidate","tag":"%s","url":"https://candidate.example"}]}}\n' "$tag"
  else
    printf '{"status":{"url":"https://media.example","traffic":[{"revisionName":"media-old","percent":100}]}}\n'
  fi
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
  fi
  if [[ "$*" == *'media-old=100'* ]]; then
    : >"$FAKE_STATE_DIR/rolled-back"
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
  [[ "$argument" == http* ]] && url="$argument"
done

if [[ "$write_out" == true ]]; then
  printf '403'
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

reset_state() {
  rm -f "$state_dir/tag" "$state_dir/shifted" "$state_dir/rolled-back" "$state_dir/gcloud.log"
  : >"$state_dir/gcloud.log"
}

run_release() {
  PATH="$fake_bin:$PATH" \
  FAKE_STATE_DIR="$state_dir" \
  FAKE_GCLOUD_LOG="$state_dir/gcloud.log" \
  FAIL_LIVE_PROBE="${FAIL_LIVE_PROBE:-false}" \
    bash "$release_script" glassy-tube-622 "$commit_sha" "$build_id" "$1" "$2"
}

# The public-to-private cutover must be impossible without explicit evidence.
reset_state
set +e
run_release false UNSET >/dev/null 2>&1
status=$?
set -e
test "$status" -eq 78
test ! -s "$state_dir/gcloud.log"

# Happy path: immutable digest, private zero-traffic candidate, traffic shift,
# live proof, and candidate-tag cleanup. No rollback should occur.
reset_state
run_release true platform-api@reviewed-commit >/dev/null
grep -q 'run deploy media-processor .*--image .*@sha256:' "$state_dir/gcloud.log"
grep -q -- '--no-allow-unauthenticated' "$state_dir/gcloud.log"
grep -q -- '--no-traffic' "$state_dir/gcloud.log"
grep -q -- '--cpu 2 --concurrency 2' "$state_dir/gcloud.log"
grep -q 'media-candidate=100' "$state_dir/gcloud.log"
grep -q -- '--remove-tags candidate-' "$state_dir/gcloud.log"
test ! -f "$state_dir/rolled-back"

# Adversarial path: once traffic has shifted, a failed live proof must restore
# the exact prior revision and still remove the candidate tag.
reset_state
set +e
FAIL_LIVE_PROBE=true run_release true platform-api@reviewed-commit >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test -f "$state_dir/shifted"
test -f "$state_dir/rolled-back"
grep -q 'media-old=100' "$state_dir/gcloud.log"
grep -q -- '--remove-tags candidate-' "$state_dir/gcloud.log"

echo 'release state-machine tests: pass'
