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

# A gh stand-in for `gh api` on one pull request's comments. It keeps them in
# gh.comments (seeded from GH_SEED), logs each call to gh, noting whether the CLI
# had started, and saves each body it sends as gh.body.1, gh.body.2... and gh.body.
# GH_FAIL makes every call fail, as without `pull-requests: write`.
cat > "$work/bin/gh" << 'EOF'
#!/usr/bin/env bash
started=no
[ ! -e "$RUNNER_TEMP/manufact-evals.err" ] || started=yes
echo "gh $* # cli started: $started" >> "$GH_LOG"
[ -z "${GH_FAIL:-}" ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
store="$GH_LOG.comments"
[ -f "$store" ] || echo "${GH_SEED:-[]}" > "$store"
method=GET path="" body="" filter=.
shift
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;;
    -F) body=${2#body=@}; shift ;;
    --jq) filter=$2; shift ;;
    --paginate) ;;
    *) path=$1 ;;
  esac
  shift
done
if [ -n "$body" ]; then
  n=$(($(cat "$GH_LOG.count" 2> /dev/null || echo 0) + 1))
  echo "$n" > "$GH_LOG.count"
  cp "$body" "$GH_LOG.body.$n"
  cp "$body" "$GH_LOG.body"
fi
case "$method" in
  GET) jq -r "$filter" "$store" ;;
  POST)
    id=$((100 + $(jq length "$store")))
    jq --argjson id "$id" --rawfile body "$body" '. + [{id: $id, body: $body}]' "$store" > "$store.new"
    mv "$store.new" "$store"
    jq -r --argjson id "$id" ".[] | select(.id == \$id) | $filter" "$store"
    ;;
  PATCH)
    id=${path##*/}
    jq -e --argjson id "$id" 'any(.id == $id)' "$store" > /dev/null || { echo "HTTP 404: Not Found" >&2; exit 1; }
    jq --argjson id "$id" --rawfile body "$body" 'map(if .id == $id then .body = $body else . end)' "$store" > "$store.new"
    mv "$store.new" "$store"
    ;;
esac
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
    GITHUB_REPOSITORY=acme/weather GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=4242
    RUNNER_TEMP="$dir" GH_LOG="$dir/gh"
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

check "suites by ID, one per line" pass push $'INPUT_SUITES=\n  suite_cart  \n\n' \
  '[ "$CODE" = 0 ]' \
  'grep -qx "run-ids=run_suite_cart" output' \
  'grep -q "POST /api/v1/server-evals/.*/suite_cart/runs" requests' \
  '! grep -q "suite_rome/runs" requests'

check "an unknown suite ID starts nothing" pass pull_request INPUT_SUITES=suite_nope \
  '[ "$CODE" = 1 ]' \
  'grep -q "::error title=Manufact evals::.*suite_nope" stdout' \
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

check "when no suite starts, the report still lists each one" allrejected pull_request \
  '[ "$CODE" = 1 ]' \
  'grep -qx "passed=false" output' \
  'grep -qx "failed-count=2" output' \
  'grep -qx "not-started-count=2" output' \
  'grep -q "::error title=Manufact evals::2 of 2 eval suites did not pass. 2 could not start: Rome weather, Checkout | cart." stdout' \
  'grep -q "^## 🧪 Manufact Evals · Weather" summary' \
  'grep -q "suite\\\\_rome has no clients" gh.body' \
  '! grep -q "couldn.t run" gh.body'

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
  'grep -qx "passed=false" output' \
  'grep -qx "not-started-count=2" output'

check "a bad API key fails without runs" pass push MANUFACT_TOKEN=wrong \
  '[ "$CODE" = 1 ]' \
  'grep -q "::error title=Manufact evals::Unauthorized" stdout' \
  '[ ! -s output ]'

check "a timeout fails with the runs left" timeout push INPUT_TIMEOUT=1 \
  '[ "$CODE" = 1 ]' \
  'grep -qx "passed=false" output' \
  'grep -q "Timed out after 1s with 2 of 2 eval runs unfinished" stdout' \
  'grep -q "⏳ 2 still running" summary'

check "the running comment comes first and the report replaces it" fail pull_request \
  '[ "$CODE" = 1 ]' \
  '[ "$(grep -c -- "-X POST" gh)" = 1 ]' \
  'grep -q -- "-X POST repos/acme/weather/issues/7/comments .*# cli started: no$" gh' \
  '[ "$(grep -c -- "-X PATCH repos/acme/weather/issues/comments/100 " gh)" = 1 ]' \
  'grep -q -- "-X PATCH .*# cli started: yes$" gh' \
  '[ -e gh.body.2 ] && [ ! -e gh.body.3 ]' \
  'head -n 1 gh.body.1 | grep -q "^<!-- manufact-evals:11111111-1111-4111-8111-111111111111:[0-9a-f]\{8\} -->$"' \
  'grep -qx "## 🧪 Manufact Evals" gh.body.1' \
  'grep -q "^⏳ Eval suites running" gh.body.1' \
  'grep -qF "[View the workflow run](https://github.com/acme/weather/actions/runs/4242)" gh.body.1' \
  '[ "$(head -n 1 gh.body.1)" = "$(head -n 1 gh.body.2)" ]' \
  'grep -q "^## 🧪 Manufact Evals · Weather" gh.body.2' \
  '[ "$(jq length gh.comments)" = 1 ]' \
  'jq -e ".[0].body | contains(\"Missing tool call\")" gh.comments > /dev/null' \
  '! grep -q "Eval suites running" summary'

# The comment an earlier run of the same job left on the pull request.
key=$(printf '\n' | { sha256sum 2> /dev/null || shasum -a 256; } | cut -c1-8)
earlier="[{\"id\":42,\"body\":\"<!-- manufact-evals:11111111-1111-4111-8111-111111111111:$key -->\\nearlier report\"}]"
check "a later run updates the earlier comment" pass pull_request "GH_SEED=$earlier" \
  '[ "$CODE" = 0 ]' \
  '! grep -q -- "-X POST" gh' \
  '[ "$(grep -c -- "-X PATCH repos/acme/weather/issues/comments/42 " gh)" = 2 ]' \
  '[ "$(grep -c -- "--paginate" gh)" = 1 ]' \
  'grep -q "⏳ Eval suites running" gh.body.1' \
  '[ "$(jq length gh.comments)" = 1 ]' \
  'jq -e ".[0].body | contains(\"Manufact Evals · Weather\")" gh.comments > /dev/null'

check "a comment that can't be posted warns once" fail pull_request GH_FAIL=1 \
  '[ "$CODE" = 1 ]' \
  'grep -qx "failed-count=1" output' \
  '[ "$(grep -c "::warning title=Manufact evals::Couldn.t comment on the pull request" stdout)" = 1 ]'

check "comment false posts nothing" fail pull_request INPUT_COMMENT=false \
  '[ "$CODE" = 1 ]' \
  '[ ! -s gh ]'

check "a suite starting with - is refused" pass push INPUT_SUITES=-x \
  '[ "$CODE" = 1 ]' \
  'grep -q "isn.t a suite ID" stdout' \
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
  echo '{"pull_request":{"number":7}}' > "$dir/event.json"
  touch "$dir/gh"
  # A background job of a script starts with SIGINT ignored, which a script can't trap.
  # The Actions runner starts the step with the default handler, so restore it.
  python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    env MCP_USE_CLOUD_API_URL="http://127.0.0.1:$(cat "$dir/port")" MANUFACT_TOKEN=test-token \
    MANUFACT_SERVER=11111111-1111-4111-8111-111111111111 INPUT_SUITES= INPUT_TIMEOUT=60 \
    INPUT_FAIL_ON=failed INPUT_COMMENT=true GITHUB_OUTPUT="$dir/output" \
    GITHUB_STEP_SUMMARY="$dir/summary" GITHUB_EVENT_PATH="$dir/event.json" GITHUB_EVENT_NAME=pull_request \
    GITHUB_REPOSITORY=acme/weather GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=4242 \
    RUNNER_TEMP="$dir" GH_LOG="$dir/gh" \
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
  grep -q "^⏳ Eval suites running" "$dir/gh.body.1" || { echo "  ✗ no running comment"; ok=0; }
  grep -q "^⚪ Cancelled" "$dir/gh.body.2" 2> /dev/null || { echo "  ✗ the running comment wasn't marked cancelled"; ok=0; }
  [ "$(jq length "$dir/gh.comments")" = 1 ] || { echo "  ✗ more than one comment"; ok=0; }
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
