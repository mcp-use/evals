#!/usr/bin/env bash
# Assertions are single-quoted on purpose: each runs later in the scenario directory.
# shellcheck disable=SC2016
# Runs scripts/run.sh against test/mock-cloud.mjs in each scenario and checks
# the exit code, step outputs, job summary and pull request comment.
# Usage: EVALS_CLI_BIN=<path to @mcp-use/cli dist/bin.js> test/run.sh
# Without EVALS_CLI_BIN, the CLI comes from CLI_PACKAGE through npx.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$work"' EXIT
export CLI_PACKAGE="${CLI_PACKAGE:-$(sed -n 's/^ *CLI_PACKAGE: "\(.*\)"$/\1/p' "$root/action.yml")}"
export NO_COLOR=1 MCP_USE_POLL_INTERVAL_MS=200 HOME="$work/home" XDG_CONFIG_HOME="$work/home"
mkdir -p "$work/home" "$work/bin"

# A gh stand-in: lists no earlier comments and records what it would post.
cat > "$work/bin/gh" << 'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
for arg in "$@"; do
  case "$arg" in body=@*) cp "${arg#body=@}" "$GH_LOG.body" ;; esac
done
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"

failures=0
# scenario: mock results; event: pull_request or push; then KEY=VALUE env and assertions.
check() {
  local name=$1 scenario=$2 event=$3
  shift 3
  local dir="$work/$name"
  mkdir -p "$dir"
  MOCK_SCENARIO=$scenario MOCK_LOG="$dir/requests" node "$root/test/mock-cloud.mjs" "$dir/port" &
  local mock=$!
  for _ in $(seq 50); do [ -s "$dir/port" ] && break; sleep 0.1; done
  if [ "$event" = pull_request ]; then
    echo '{"pull_request":{"number":7,"head":{"sha":"abc"}}}' > "$dir/event.json"
  else
    echo '{}' > "$dir/event.json"
  fi
  local env=(
    MCP_USE_CLOUD_API_URL="http://127.0.0.1:$(cat "$dir/port")"
    MANUFACT_TOKEN=test-token
    MANUFACT_SERVER=11111111-1111-4111-8111-111111111111
    INPUT_SUITES= INPUT_TIMEOUT=30 INPUT_FAIL_ON=failed INPUT_COMMENT=true
    GITHUB_OUTPUT="$dir/output" GITHUB_STEP_SUMMARY="$dir/summary"
    GITHUB_EVENT_PATH="$dir/event.json" GITHUB_EVENT_NAME="$event"
    GITHUB_REPOSITORY=acme/weather RUNNER_TEMP="$dir" GH_LOG="$dir/gh"
  )
  local asserts=()
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Z_]+= ]]; then env+=("$arg"); else asserts+=("$arg"); fi
  done
  touch "$dir/output" "$dir/summary" "$dir/gh"
  set +e
  env "${env[@]}" "$root/scripts/run.sh" > "$dir/stdout" 2> "$dir/stderr"
  local code=$?
  set -e
  kill "$mock"
  wait "$mock" 2> /dev/null || true
  local ok=1
  for assertion in "${asserts[@]}"; do
    if ! (cd "$dir" && CODE=$code bash -c "$assertion"); then
      echo "  ✗ $assertion"
      ok=0
    fi
  done
  if [ "$ok" = 1 ]; then
    echo "✓ $name"
  else
    echo "✗ $name (exit $code)"
    sed 's/^/    /' "$dir/stdout" "$dir/stderr" "$dir/output"
    failures=$((failures + 1))
  fi
}

check "all suites pass" pass push \
  '[ "$CODE" = 0 ]' \
  'grep -qx "passed=true" output' \
  'grep -qx "passed-count=2" output' \
  'grep -qx "run-ids=run_suite_rome run_suite_cart" output' \
  'grep -qx "dashboard-url=https://manufact.com/cloud/acme/servers/11111111-1111-4111-8111-111111111111/evals/suites" output' \
  'grep -q "^## 🧪 Manufact Evals · Weather" summary' \
  'grep -q "^Production · 2 suites · ✅ 2 passed" summary' \
  '! grep -q "manufact-evals:" summary' \
  '[ ! -s gh ]' \
  '! grep -q suite_off requests'

check "a failing suite fails the step and comments" fail pull_request \
  '[ "$CODE" = 1 ]' \
  'grep -qx "passed=false" output' \
  'grep -qx "failed-count=1" output' \
  'grep -q "::error title=Manufact evals::1 of 2 eval suites did not pass" stdout' \
  'grep -q "Missing tool call: checkout" stdout' \
  'grep -q "🔗 https://.*/suite_cart?execution=exec_run_suite_cart&tab=report" stdout' \
  '! grep -q "execution=undefined" stdout' \
  'grep -q "<summary>Conversation</summary>" gh.body' \
  'grep -q "issues/7/comments -F body=@" gh' \
  'head -n 1 gh.body | grep -q "^<!-- manufact-evals:11111111-1111-4111-8111-111111111111:[0-9a-f]\{8\} -->$"' \
  'grep -qF "| [Checkout \\| cart](" gh.body'

check "fail-on none only warns" fail push INPUT_FAIL_ON=none \
  '[ "$CODE" = 0 ]' \
  'grep -qx "passed=false" output' \
  'grep -q "::warning title=Manufact evals::1 of 2" stdout'

check "suites by name, one per line" pass push $'INPUT_SUITES=\n  Checkout | cart  \n\n' \
  '[ "$CODE" = 0 ]' \
  'grep -qx "run-ids=run_suite_cart" output' \
  'grep -q "POST /api/v1/server-evals/.*/suite_cart/runs" requests' \
  '! grep -q "suite_rome/runs" requests'

check "an unknown suite starts nothing" pass pull_request INPUT_SUITES=Nope \
  '[ "$CODE" = 1 ]' \
  'grep -q "::error title=Manufact evals::No eval suite matches" stdout' \
  '! grep -q "^passed=" output' \
  '! grep -q "POST" requests' \
  'grep -q "^## ❌ Manufact evals couldn.t run" gh.body'

check "running out of credits reports the runs that started and fails" credits pull_request \
  '[ "$CODE" = 1 ]' \
  'grep -qx "passed=false" output' \
  'grep -qx "passed-count=1" output' \
  'grep -qx "failed-count=1" output' \
  'grep -qx "not-started-count=1" output' \
  'grep -qx "run-ids=run_suite_rome" output' \
  'grep -q "::error title=Manufact evals::1 of 2 eval suites did not pass. 1 could not start: Checkout | cart. See the report above." stdout' \
  'grep -q "⛔ 1 not started" gh.body' \
  'grep -q "Out of eval credits" gh.body'

check "a suite Cloud rejects doesn't stop the others" rejected push \
  '[ "$CODE" = 1 ]' \
  'grep -qx "passed=false" output' \
  'grep -qx "not-started-count=1" output' \
  'grep -qx "run-ids=run_suite_cart" output' \
  'grep -q "1 could not start: Rome weather" stdout' \
  'grep -q "No reachable URL for this server" summary'

check "fail-on none still only warns when a suite can't start" rejected push INPUT_FAIL_ON=none \
  '[ "$CODE" = 0 ]' \
  'grep -q "::warning title=Manufact evals::2 of 2 eval suites did not pass. 1 could not start: Rome weather." stdout'

check "a dropped start is retried" flaky push \
  '[ "$CODE" = 0 ]' \
  'grep -qx "passed=true" output' \
  'grep -qx "not-started-count=0" output' \
  '[ "$(grep -c "^POST .*/suite_cart/runs" requests)" = 2 ]'

check "a profile reaches every run" pass push INPUT_PROFILE=profile_free \
  '[ "$CODE" = 0 ]' \
  'grep -qx "passed=true" output' \
  '[ "$(grep -c "^POST .*/runs?profileId=profile_free$" requests)" = 2 ]'

check "a Cloud that ignores the profile fails the step" noprofile push INPUT_PROFILE=profile_free \
  '[ "$CODE" = 1 ]' \
  'grep -q "::error title=Manufact evals::.*did not apply --profile" stdout' \
  'grep -q "POST .*/runs/run_suite_rome/cancel" requests' \
  '! grep -q "^passed=" output'

check "a bad token fails without runs" pass push MANUFACT_TOKEN=wrong \
  '[ "$CODE" = 1 ]' \
  'grep -q "::error title=Manufact evals::Unauthorized" stdout' \
  '[ ! -s output ]'

check "a timeout fails with the runs left" timeout push INPUT_TIMEOUT=1 \
  '[ "$CODE" = 1 ]' \
  'grep -qx "passed=false" output' \
  'grep -q "Timed out after 1s with 2 of 2 eval runs unfinished" stdout' \
  'grep -q "⏳ 2 still running" summary'

check "a suite starting with - is refused" pass push INPUT_SUITES=-x \
  '[ "$CODE" = 1 ]' \
  'grep -q "Use its suite ID instead" stdout' \
  '[ ! -s requests ]'

check "fail-on must be known" pass push INPUT_FAIL_ON=warnings \
  '[ "$CODE" = 1 ]' \
  'grep -q "fail-on must be none or failed" stdout'

# Cancelling the job: SIGINT to the action's script while the CLI waits on
# runs that never finish must cancel both runs and exit 130.
cancel_check() {
  local dir="$work/cancel"
  mkdir -p "$dir"
  MOCK_SCENARIO=timeout MOCK_LOG="$dir/requests" node "$root/test/mock-cloud.mjs" "$dir/port" &
  local mock=$!
  for _ in $(seq 50); do [ -s "$dir/port" ] && break; sleep 0.1; done
  echo '{}' > "$dir/event.json"
  # A background job of a script starts with SIGINT ignored, which a script can't trap.
  # The Actions runner starts the step with the default handler, so restore it.
  python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    env MCP_USE_CLOUD_API_URL="http://127.0.0.1:$(cat "$dir/port")" MANUFACT_TOKEN=test-token \
    MANUFACT_SERVER=11111111-1111-4111-8111-111111111111 INPUT_SUITES= INPUT_TIMEOUT=60 \
    INPUT_FAIL_ON=failed INPUT_COMMENT=false GITHUB_OUTPUT="$dir/output" \
    GITHUB_STEP_SUMMARY="$dir/summary" GITHUB_EVENT_PATH="$dir/event.json" GITHUB_EVENT_NAME=push \
    GITHUB_REPOSITORY=acme/weather RUNNER_TEMP="$dir" GH_LOG="$dir/gh" \
    "$root/scripts/run.sh" > "$dir/stdout" 2> "$dir/stderr" &
  local action=$!
  # The CLI prints its progress line once it is waiting (and handling signals).
  for _ in $(seq 100); do grep -q "Waiting for" "$dir/manufact-evals.err" 2> /dev/null && break; sleep 0.1; done
  kill -INT "$action"
  local code=0
  wait "$action" || code=$?
  kill "$mock"
  wait "$mock" 2> /dev/null || true
  local ok=1
  [ "$code" = 130 ] || { echo "  ✗ exit code $code, expected 130"; ok=0; }
  for run in run_suite_rome run_suite_cart; do
    grep -q "POST .*/runs/$run/cancel" "$dir/requests" || { echo "  ✗ no cancel for $run"; ok=0; }
  done
  grep -q "::warning title=Manufact evals::The job was cancelled" "$dir/stdout" || { echo "  ✗ no cancel warning"; ok=0; }
  if [ "$ok" = 1 ]; then
    echo "✓ cancelling the job cancels its runs"
  else
    echo "✗ cancelling the job cancels its runs"
    sed 's/^/    /' "$dir/stdout" "$dir/stderr"
    failures=$((failures + 1))
  fi
}
cancel_check

[ "$failures" -eq 0 ] || { echo "$failures scenario(s) failed"; exit 1; }
echo "All scenarios passed."
