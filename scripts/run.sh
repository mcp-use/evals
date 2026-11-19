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
rm -f "$result" "$errors" "$markdown" "$markdown.body"
output() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
error() { echo "::error title=Manufact evals::$1"; }

# One suite per line. Names can contain spaces and commas, so lines are the only separator.
suites=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  if [ "${line:0:1}" = "-" ]; then
    error "Suite \"$line\" starts with '-', which the CLI reads as an option. Use its suite ID instead."
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
  echo "::warning title=Manufact evals::The job was cancelled, so the eval runs it started were cancelled too."
  exit "$code"
fi
# Drop the progress line and npm's own notices; keep everything else the CLI said.
grep -v -E '^(Waiting for [0-9]+ eval runs?|npm (notice|warn)( .*)?)$' "$errors" > "$errors.clean"
mv "$errors.clean" "$errors"
cat "$errors" >&2

# One comment per server and suite selection, so several eval jobs can share a pull request.
hash() { if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi; }
key=$(printf '%s\n' "${suites[@]+"${suites[@]}"}" | hash | cut -c1-8)
marker="<!-- manufact-evals:$MANUFACT_SERVER:$key -->"

runs=$(jq -r '.runs | length' "$result" 2> /dev/null || echo 0)
if [ "${runs:-0}" -eq 0 ]; then
  # No results (bad token, unknown server or suite, usage error...): use the CLI's error line.
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
  failed=$((runs - passed))
  output run-ids "$(jq -r '[.runs[].id] | join(" ")' "$result")"
  output passed "$([ "$failed" -eq 0 ] && echo true || echo false)"
  output passed-count "$passed"
  output failed-count "$failed"
  output results-file "$result"
  output dashboard-url "$(jq -r '.dashboardUrl // empty' "$result")"

  { echo "$marker"; cat "$markdown.body"; } > "$markdown"

  if [ "$pending" -gt 0 ]; then
    message="Timed out after ${INPUT_TIMEOUT:-1800}s with $pending of $runs eval runs unfinished. They keep running on Manufact Cloud."
  else
    message="$failed of $runs eval suites did not pass."
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

# Post or update the comment on the pull request.
pr=$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null)
if [ "${INPUT_COMMENT:-true}" = "true" ] && [ -n "$pr" ]; then
  comments="repos/$GITHUB_REPOSITORY/issues"
  existing=$(gh api --paginate "$comments/$pr/comments" --jq ".[] | select(.body | startswith(\"$marker\")) | .id" 2> /dev/null | head -n 1)
  # Update our earlier comment; post a new one if there's none, or if the
  # marked comment isn't ours to edit.
  if ! { [ -n "$existing" ] && gh api -X PATCH "$comments/comments/$existing" -F body=@"$markdown" > /dev/null; } &&
    ! gh api -X POST "$comments/$pr/comments" -F body=@"$markdown" > /dev/null; then
    echo "::warning title=Manufact evals::Couldn't comment on the pull request. Grant the job 'pull-requests: write', or set comment: false."
  fi
fi

exit "$code"
