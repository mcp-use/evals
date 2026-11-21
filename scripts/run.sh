#!/usr/bin/env bash
# Runs Manufact eval suites with the mcp-use CLI, reports the results to the
# job log, the job summary and the pull request, and sets the step outputs.
# Inputs arrive as environment variables; see action.yml.

# Keep going when the CLI fails, so the failure still gets reported.
set +e -uo pipefail

temp="${RUNNER_TEMP:-$(mktemp -d)}"
if [ -n "${EVALS_CLI_BIN:-}" ]; then
  # Testing only: run a locally built CLI instead of the pinned package.
  cli=(node "$EVALS_CLI_BIN")
else
  # Installed and run with node rather than npx, so a cancelled job's signal
  # reaches the CLI itself and it can cancel its runs.
  prefix="$temp/mcp-use-cli"
  if ! npm install --no-save --no-audit --no-fund --loglevel=error --prefix "$prefix" "$CLI_PACKAGE" > "$temp/mcp-use-cli-install.log" 2>&1; then
    echo "::error title=Manufact evals::Could not install $CLI_PACKAGE"
    cat "$temp/mcp-use-cli-install.log" >&2
    exit 1
  fi
  cli=(node "$prefix/node_modules/@mcp-use/cli/dist/bin.js")
fi
result="$temp/manufact-evals.json"
errors="$temp/manufact-evals.err"
markdown="$temp/manufact-evals.md"
rm -f "$result" "$errors" "$markdown" "$markdown.body" "$markdown.running"
output() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
error() { echo "::error title=Manufact evals::$1"; }

# One suite ID per line, passed to the CLI as they are.
suites=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  if [ "${line:0:1}" = "-" ]; then
    error "\"$line\" isn't a suite ID: it starts with '-', which the CLI reads as an option."
    exit 1
  fi
  suites+=("$line")
done <<< "${INPUT_SUITES:-}"

case "${INPUT_FAIL_ON:-failed}" in
  none | failed) ;;
  *)
    error "fail-on must be none or failed, not \"$INPUT_FAIL_ON\"."
    exit 1
    ;;
esac

# Evals run against the server's production deployment.
args=(evals run --wait --timeout "${INPUT_TIMEOUT:-1800}" --json-file "$result" --markdown-file "$markdown.body")
# Sign in with this profile instead of the server's own.
if [ -n "${INPUT_PROFILE:-}" ]; then args+=(--profile "$INPUT_PROFILE"); fi
if [ "${#suites[@]}" -eq 0 ]; then args+=(--all); else args+=("${suites[@]}"); fi

# One comment per server and suite selection, so several eval jobs can share a pull request.
hash() { if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi; }
key=$(printf '%s\n' "${suites[@]+"${suites[@]}"}" | hash | cut -c1-8)
marker="<!-- manufact-evals:$MANUFACT_SERVER:$key -->"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
pr=$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null)
comment_id=""
comment_warned=""

# Post a file as the pull request comment, or update the comment posted earlier.
# A comment that can't be posted is a warning, given once; the step carries on.
comment() {
  [ "${INPUT_COMMENT:-true}" = "true" ] && [ -n "$pr" ] || return 0
  local comments="repos/$GITHUB_REPOSITORY/issues" id
  if [ -z "$comment_id" ]; then
    comment_id=$(gh api --paginate "$comments/$pr/comments" --jq ".[] | select(.body | startswith(\"$marker\")) | .id" 2> /dev/null | head -n 1)
  fi
  # Update our earlier comment; post a new one if there's none, or if the
  # marked comment isn't ours to edit.
  if [ -n "$comment_id" ] && gh api -X PATCH "$comments/comments/$comment_id" -F body=@"$1" > /dev/null; then
    return 0
  fi
  if id=$(gh api -X POST "$comments/$pr/comments" -F body=@"$1" --jq .id); then
    comment_id=$id
    return 0
  fi
  [ -n "$comment_warned" ] ||
    echo "::warning title=Manufact evals::Couldn't comment on the pull request. Grant the job 'pull-requests: write', or set comment: false."
  comment_warned=1
}

# A short comment while there's no report yet: the heading, a status line and the run link.
status_comment() {
  printf '%s\n## 🧪 Manufact Evals\n\n%s\n\n[View the workflow run](%s)\n' "$marker" "$1" "$run_url" > "$markdown.running"
  comment "$markdown.running"
}

# Show on the pull request that the suites are running; the report replaces it.
status_comment "⏳ Eval suites running. The results replace this comment when they finish."

# The readable report goes to the log; JSON and Markdown go to files.
# Run the CLI in the background so this script can pass on a cancelled job's
# SIGINT and SIGTERM: the CLI then cancels the runs it started before exiting.
"${cli[@]}" "${args[@]}" 2> "$errors" &
cli_pid=$!
trap 'kill -INT "$cli_pid" 2> /dev/null' INT
trap 'kill -TERM "$cli_pid" 2> /dev/null' TERM
while :; do
  wait "$cli_pid"
  code=$?
  # A trapped signal ends `wait` early; keep waiting until the CLI has exited.
  kill -0 "$cli_pid" 2> /dev/null || break
done
trap - INT TERM
if [ "$code" -eq 130 ] || [ "$code" -eq 143 ]; then
  cat "$errors" >&2
  echo "::warning title=Manufact evals::The job was cancelled, so the eval runs it started were asked to cancel. The log above says which Cloud confirmed."
  # Don't leave the pull request saying the suites are still running.
  [ -z "$comment_id" ] ||
    status_comment "⚪ Cancelled. The job was cancelled before the eval suites finished, so the runs it started were asked to cancel."
  exit "$code"
fi
# Drop the progress line and npm's own notices; keep everything else the CLI said.
grep -v -E '^(Waiting for [0-9]+ eval runs?|npm (notice|warn)( .*)?)$' "$errors" > "$errors.clean"
mv "$errors.clean" "$errors"
cat "$errors" >&2

runs=$(jq -r '.runs | length' "$result" 2> /dev/null || echo 0)
# Suites the CLI could not start have no run, but they did not pass either.
unstarted=$(jq '.notStarted // [] | length' "$result" 2> /dev/null || echo 0)
if [ "${runs:-0}" -eq 0 ] && [ "${unstarted:-0}" -eq 0 ]; then
  # No results (bad API key, unknown server or suite ID, usage error...): use the CLI's error line.
  message=$(grep -v '^$' "$errors" | head -n 1)
  message="${message:-mcp-use evals run exited with code $code}"
  error "$message"
  {
    echo "$marker"
    echo "## ❌ Manufact evals couldn't run"
    echo
    echo "Server \`$MANUFACT_SERVER\`"
    echo
    echo '```text'
    cat "$errors"
    echo '```'
  } > "$markdown"
  code=1
else
  passed=$(jq '[.runs[] | select(.pass == true)] | length' "$result")
  pending=$(jq '[.runs[] | select(.status != "complete" and .status != "failed" and .status != "cancelled")] | length' "$result")
  total=$((runs + unstarted))
  failed=$((total - passed))
  output run-ids "$(jq -r '[.runs[].id] | join(" ")' "$result")"
  output passed "$([ "$failed" -eq 0 ] && echo true || echo false)"
  output passed-count "$passed"
  output failed-count "$failed"
  output not-started-count "$unstarted"
  output results-file "$result"
  output dashboard-url "$(jq -r '.dashboardUrl // empty' "$result")"

  { echo "$marker"; cat "$markdown.body"; } > "$markdown"

  if [ "$pending" -gt 0 ]; then
    message="Timed out after ${INPUT_TIMEOUT:-1800}s with $pending of $runs eval runs unfinished. They keep running on Manufact Cloud."
  else
    message="$failed of $total eval suites did not pass."
  fi
  if [ "$unstarted" -gt 0 ]; then
    message="$message $unstarted could not start: $(jq -r '[.notStarted[].name] | join(", ")' "$result")."
    # When nothing started, the CLI's error line says why.
    if [ "$runs" -eq 0 ]; then
      why=$(grep -v '^$' "$errors" | head -n 1)
      [ -z "$why" ] || message="$message $why"
    fi
  fi
  if [ "$failed" -eq 0 ]; then
    code=0
  elif [ "$INPUT_FAIL_ON" = none ]; then
    echo "::warning title=Manufact evals::$message"
    code=0
  else
    [ "$pending" -gt 0 ] || message="$message See the report above."
    error "$message"
    code=1
  fi
fi

tail -n +2 "$markdown" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

# Replace the running comment with the report.
comment "$markdown"

exit "$code"
