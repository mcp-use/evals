<img src="https://manufact.com/branding/app-icon-dark.svg" alt="Manufact" width="64" height="64">

# Manufact Evals

Run your Manufact eval suites against your MCP server in GitHub Actions, and fail the job when a suite fails.

Each eval suite sends a conversation to your server through one or more AI clients, checks the tools they call, and has a judge score the answer. This action starts the suites you pick, waits for the results, and reports them in the job log, the job summary and the pull request.

## Before you start

1. **Create a Manufact account.** [Sign up at manufact.com](https://manufact.com/signup).
2. **Deploy or connect your MCP server.** [Deploy it from GitHub](https://docs.manufact.com/dashboard/quickstart), or [connect a server you host elsewhere](https://docs.manufact.com/dashboard/connect-existing-server). Note its [server ID](#find-your-server-id).
3. **Create eval suites.** Create them in the dashboard under **Evals**, or write them as YAML files and push them with `npx @mcp-use/cli evals push evals/`.
4. **Create an API key.** In the Manufact dashboard, open **API Keys** and click **Create key** ([how to create an API key](https://docs.manufact.com/dashboard/api-keys)).
5. **Store the key as a repository secret.** In your GitHub repository, go to **Settings > Secrets and variables > Actions** and add it as `MANUFACT_TOKEN`.

## Usage

```yaml
name: Evals

on:
  push:
    branches: [main]
  schedule:
    - cron: "0 6 * * *" # every day at 06:00 UTC
  workflow_dispatch:

jobs:
  evals:
    runs-on: ubuntu-latest
    steps:
      - uses: mcp-use/evals@v1
        with:
          token: ${{ secrets.MANUFACT_TOKEN }}
          server: e3b0c442-98fc-4c14-9afb-f4c8996fb924
```

This runs every enabled suite of the server and fails the job if any suite fails.

Evals run against your server's **production** deployment. Run the action after production has deployed: if your deploy runs in the same workflow, put this step after it. On a pull request, the results describe production, not the pull request's changes.

### Run some suites

List suites in `suites`, one per line. Each line is a suite ID, a suite name, or the path to a suite file in the repository:

```yaml
      - uses: mcp-use/evals@v1
        with:
          token: ${{ secrets.MANUFACT_TOKEN }}
          server: e3b0c442-98fc-4c14-9afb-f4c8996fb924
          suites: |
            Rome weather
            8d0f6b1e-2a4c-4e8b-9f3a-6c1d2e7b5a90
```

- A name matches exactly first, then ignoring case. If several suites share the name, the step fails and lists their IDs: use an ID instead.
- A path to a suite file, or a folder of them, runs the suite named in each file. It doesn't upload the file; the suite must already exist on Manufact Cloud. Paths need `actions/checkout` first.
- A line can't start with `-`. Use the suite's ID instead.

### Keep suites in the repository

Push the suite files before running them, so the suites on Manufact Cloud match the default branch:

```yaml
    steps:
      - uses: actions/checkout@v4
      - name: Push eval suites
        run: npx --yes @mcp-use/cli evals push evals/
        env:
          MANUFACT_TOKEN: ${{ secrets.MANUFACT_TOKEN }}
          MANUFACT_SERVER: e3b0c442-98fc-4c14-9afb-f4c8996fb924
      - uses: mcp-use/evals@v1
        with:
          token: ${{ secrets.MANUFACT_TOKEN }}
          server: e3b0c442-98fc-4c14-9afb-f4c8996fb924
          suites: evals/
```

Push only from your default branch. A push replaces the suite on Manufact Cloud for everyone, so pushing from a pull request would change the suites before the change is reviewed.

### Use the result in later steps

```yaml
      - id: evals
        uses: mcp-use/evals@v1
        with:
          token: ${{ secrets.MANUFACT_TOKEN }}
          server: e3b0c442-98fc-4c14-9afb-f4c8996fb924
          fail-on: none
      - if: steps.evals.outputs.passed == 'false'
        run: echo "${{ steps.evals.outputs.failed-count }} suites failed"
```

## Find your server ID

Open your server in the Manufact dashboard. The server ID is the UUID after `/servers/` in the URL:

```
https://manufact.com/cloud/<org>/servers/e3b0c442-98fc-4c14-9afb-f4c8996fb924/overview
                                         └─────────── server ID ────────────┘
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `token` | | Required. Manufact API key, scoped to the server's organization. Store it as a secret. See [how to create an API key](https://docs.manufact.com/dashboard/api-keys). |
| `server` | | Required. Server ID: the UUID in the server's dashboard URL. See [Find your server ID](#find-your-server-id). |
| `suites` | every enabled suite | Suites to run, one per line: IDs, names, or paths to suite files or folders. |
| `timeout` | `1800` | Seconds to wait for the runs. Runs still going at the timeout keep running on Manufact Cloud, and the step fails. |
| `fail-on` | `failed` | `failed` fails the job when a suite fails, is cancelled or times out. `none` only fails it when the suites can't run at all (for example, a bad token). |
| `comment` | `true` | On pull requests, comment the results. Set `false` to turn it off. |
| `github-token` | `github.token` | Token used to post the comment. |

## Outputs

| Output | Description |
| --- | --- |
| `run-ids` | Eval run IDs, one per suite, separated by spaces |
| `passed` | `true` when every suite passed, `false` otherwise; empty when the suites couldn't run |
| `passed-count` | Number of suites that passed |
| `failed-count` | Number of suites that failed, were cancelled, or were still running at the timeout |
| `results-file` | Path to the JSON results, with every run and its executions |
| `dashboard-url` | Link to the server's eval suites in the Manufact dashboard |

## Pull request comment

On `pull_request` events, the action comments the results on the pull request: a table of suites with their result and score, then a section per suite with a row per client and model showing its score, duration and tool calls. Suites that didn't pass start expanded. Each failed execution lists why it failed (a missing or disallowed tool call, an error, or the judge's main problems), the judge's assessment, a link to its report in the dashboard, and a collapsed conversation: the user's messages, the tool calls and the final answer.

While the suites run, the job log shows each suite's dashboard link, then a line as each client and model finishes, with why it failed and a link to its report.

There's one comment per server and `suites` selection. Later runs update it rather than adding a new comment. If the suites can't run at all (for example, the token is wrong or a suite name doesn't match), the comment shows the error instead.

Commenting needs the job to have `pull-requests: write`. Without it, the action logs a warning and carries on; the eval result is unaffected. Pull requests from forks get a read-only token, so there's no comment for those.

The full report also goes to the job log, and the same summary is added to the job summary page.

## Costs and timeouts

- Every suite the action starts is an eval run and uses your organization's eval credits, like a run started from the dashboard. Pick a trigger that matches your budget: a schedule or pushes to `main` cost less than every pull request.
- Cancelling the job cancels the eval runs it started that haven't finished.
- Runs still going when `timeout` runs out keep going on Manufact Cloud, and the step fails. Open the dashboard to see their results.

## Requirements

- Evals enabled on your Manufact plan.
- A runner with `jq`. GitHub-hosted runners have it. The action installs Node.js 22 itself.

Each release of this action pins the `@mcp-use/cli` version it was tested with.

## Development

`test/run.sh` runs the action script against a mock Manufact Cloud (`test/mock-cloud.mjs`) in each scenario, with a stand-in `gh`, so it spends no credits. It uses the CLI version `action.yml` pins; set `EVALS_CLI_BIN` to a locally built `@mcp-use/cli` `dist/bin.js` to test CLI changes.
