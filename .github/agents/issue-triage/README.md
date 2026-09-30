# AL-Go issue triage agent

Automated first-pass triage for issues opened against AL-Go. It decides whether a report is
actionable, which component actually owns the problem, whether the bug can be reproduced, and how
risky a fix would be. It posts one comment and applies labels. It never fixes anything and never
closes an issue.

This agent is exclusive to the AL-Go team and lives here. `microsoft/BC-ALAgents` was inspiration
for the job structure only - that repo ships an engine for customers, this one does not.

**Status: built, not yet enabled.** Publishing is set to `dryRun` and the workflow has never run on
a real issue. See "Rollout".

## Layout

| Path | Role |
| --- | --- |
| `issue-triage.agent.md` | Agent instructions: what to do, in what order, and how to stay calibrated |
| `skills/al-go-concepts.md` | What AL-Go is, settings layering, workflows, deprecated settings, where to look things up |
| `skills/routing.md` | AL-Go vs BcContainerHelper vs platform signature table |
| `skills/risk-tiers.md` | Critical-path file list and the lane each risk level maps to |
| `skills/completeness.md` | What makes a report actionable, and when to ask for more |
| `skills/repro.md` | The three reproduction tiers |
| `findings.schema.json` | The typed output contract |
| `triage.config.json` | Policy: model guardrails, label allow-list, critical paths, rollout mode |
| `labels.json` | The existing AL-Go labels the agent may apply |
| `scripts/Invoke-CopilotIssueTriage.ps1` | Phase-switched orchestrator |
| `scripts/TriageHelper.psm1` | The decisions: context extraction, validation, label filtering, comment rendering |
| `scripts/Sync-TriageLabels.ps1` | Verifies the labels the agent needs exist |
| `../../workflows/AiIssueTriage.yml` | The three-job workflow |
| `../../../Tests/Repro/` | Tier 1 repro harness and the action safety policy |
| `../../../Tests/Triage/` | Fixture corpus and the accuracy scorer |

Run artifacts (written to the output directory, not committed): `issue-context.json`, `prompt.txt`,
`cli-output.txt`, `findings.json` (adjudicated), `findings-raw.json` (as the model wrote it),
`comment.md`, `labels.json`, `usage.json`, `run-metadata.json`.

## How it is put together

Three jobs, because the split *is* the security model:

| Job | Permissions | Role |
| --- | --- | --- |
| `resolve` | `contents: read`, `issues: read` | Deterministic extraction. No model. |
| `triage` | plus `copilot-requests: write` | Runs Copilot CLI over the untrusted issue body. **Holds no write token.** |
| `publish` | `issues: write` | Validates the artifact and posts. **Never runs a model.** |

AL-Go is public, so an issue body is untrusted input from anyone on the internet, and AL-Go's
templates execute in many other repositories. Five consequences worth knowing before changing
anything here:

- **The agent never writes prose to an issue.** It emits `findings.json` against
  `findings.schema.json`; `Format-TriageComment` decides the wording. A prompt injection cannot
  dictate what is said to a reporter.
- **Labels are intersected with an allow-list** in `triage.config.json`. Anything the agent invents
  is dropped rather than trusted.
- **Untrusted text is fenced with a dynamically sized fence** (`Format-FencedBlock`). A reporter's
  own triple backticks would otherwise close the wrapper early and let the rest be read as
  instructions.
- **The model gets no network-capable tool.** The triage job holds `GITHUB_TOKEN` because Copilot
  CLI needs it for org-billed inference, so nothing there may be able to carry it off the runner:
  no `gh`, no `curl`, no arbitrary shell. Duplicate candidates are searched deterministically in
  the `resolve` phase precisely so the model never needs API access. Note that harden-runner's
  `egress-policy: audit` records traffic but does not block it - switching to `block` with an
  allowed-endpoints list is a TODO once the first runs reveal which endpoints Copilot CLI needs.
- **The publish job checks out the default branch, not the dispatched ref.** Branch dispatch is an
  encouraged part of testing, and this job holds `issues: write`; running branch-supplied code here
  would let anyone able to push a branch execute arbitrary code with the write token. The findings
  artifact is data, and the code acting on it stays trusted.

**Reproduction means running the action, not running the test suite.** The Pester suite is already
green, so it proves nothing about a reported bug. `Tests/Repro/Invoke-ActionRepro.ps1` invokes an
AL-Go action directly with parameters reconstructed from the issue.

## Running it locally

End to end against a fixture, posting nothing:

```powershell
$env:TRIAGE_SKIP_MODEL = 'true'   # omit to actually call Copilot CLI
./.github/agents/issue-triage/scripts/Invoke-CopilotIssueTriage.ps1 `
    -Phase all `
    -IssueFixture ./Tests/Triage/fixtures/seed-sarif-upload-failure.json `
    -OutputDirectory ./triage-output
```

Artifacts land in the output directory: `issue-context.json`, `prompt.txt`, `findings.json`,
`comment.md`, `labels.json`. A fixture always forces dry run.

Reproduce a bug from a manifest:

```powershell
./Tests/Repro/Invoke-ActionRepro.ps1 -Manifest ./my-repro.json -KeepWorkspace
```

Score triage output against the corpus:

```powershell
./Tests/Triage/Invoke-TriageScorer.ps1 -FindingsPath ./out/findings -FailUnder 80
```

Run every test for the above:

```powershell
. ./Tests/runtests.ps1 -Path "Tests"
```

## Rollout

`triage.config.json` carries `publish.mode`, starting at `dryRun`:

| Mode | Behaviour | Purpose |
| --- | --- | --- |
| `dryRun` | Renders output, posts nothing | Local iteration and the first live runs |
| `shadow` | Runs, uploads findings, posts nothing | Measures accuracy on real issues |
| `commentOnly` | Posts the comment, applies no labels | Low-blast-radius live trial |
| `full` | Comment and labels | Steady state |

### Where to run the tests

The production repository is not required. What the agent actually needs is:

1. **An organization with Copilot CLI billing enabled** - the policy is on the *organization*, not
   the repository, so any repository in a qualifying org works.
2. **The AL-Go source checked out** - Tier 0 tracing greps `Actions/`, and Tier 1 runs
   `Invoke-ActionRepro.ps1`.
3. **Read access to the issues being triaged** - `microsoft/AL-Go` is public, so any token can read
   its issues and search for duplicates from anywhere.

So a **private clone of AL-Go in a Copilot-enabled org** satisfies all three and is a better place
to iterate than the production default branch. Point it at the real issues with `target_repo`:

```powershell
gh workflow run AiIssueTriage.yml --repo myorg/AL-Go-clone `
    --ref my-branch -f issue_number=2285 -f target_repo=microsoft/AL-Go
```

**Reading another repository never implies writing to it.** When `target_repo` differs from the
repository the workflow runs in, publishing is forced off regardless of `publish.mode` or
`dry_run`, and the run says so. A test covers this.

Two things a clone does not prove: that the production repository's own token and org policy are
configured as expected, and that nothing in production's settings blocks the workflow. Those only
surface on the real repository, so plan one dispatch there before enabling shadow mode.

Keep the clone's `Actions/` reasonably current, or Tier 0 traces and Tier 1 repros will reflect
stale code.

### What a runner proves that a local run does not

Most prompt and knowledge iteration belongs in a local dry run: it is seconds per loop instead of
minutes, costs the organization nothing, and is far easier to debug.

A run on a runner is still necessary, because these can only fail there:

- **Org-billed inference.** `copilot-requests: write` plus the org policy is the whole billing
  story, and it cannot be exercised locally - a local run uses your own seat instead.
- **The tool allow-list.** Non-interactive Copilot CLI denies anything not pre-approved, with no
  prompt to fall back on. If `--allow-tool` is too narrow the agent quietly cannot do its job, and
  that only shows up in a headless run.
- **`GITHUB_TOKEN` permissions.** Whether `issues: read` in `resolve` and `issues: write` in
  `publish` are actually sufficient.
- **The job graph.** Artifact hand-off between three jobs, and the `if:` conditions.
- **Linux.** Everything here has so far been exercised on Windows only. The scripts avoid hardcoded
  separators, but `ubuntu-latest` is the first real test of that.

So: iterate locally, then use the runner to prove the plumbing, the billing path, and the
allow-list. Those four are exactly the things local testing cannot tell you anything about.

### Why the whole change must land on the default branch first

`issues:` events always run the copy of the workflow on the **default branch** - a repository-level
event has no head ref to run from. `workflow_dispatch` is the exception: it runs the ref you
select, but only if the workflow file already exists on the default branch.

So a feature branch cannot be tested until the change is merged once.

**Merge the whole change, not just the workflow file.** A dispatch would admittedly work with only
the YAML on the default branch, because `actions/checkout` here takes no explicit `ref` and so
defaults to `github.ref` - the dispatched branch - which supplies the scripts. But the
`issues: [labeled]` trigger runs with `github.ref` pointing at the default branch, so it would check
out a default branch that has no `.github/agents/issue-triage/scripts/`, and every run would fail
loudly on a public repository. Merging the tests at the same time also means CI guards the workflow
from the first commit.

That merge is safe because the workflow is deliberately inert:

- It triggers only on `workflow_dispatch`, or on the existing opt-in **`AI Review`** label.
- It does **not** trigger on `issues: [opened]`, so new issues do not start runs.
- `dry_run` defaults to `true` **and** `publish.mode` is `dryRun`. These are independent, so both
  have to change before a single comment is posted.

The one live behaviour gained on merge: a maintainer adding `AI Review` starts a real model run
that renders output and posts nothing, bounded by `engine.maxAiCredits`. To have no automatic
behaviour at all until dispatch testing is done, drop the `issues:` trigger and the `resolve` job's
`if:` from the first pull request and restore them in the next one.

Adding `issues: [opened]` later is the deliberate, reviewable change that moves this to shadow mode.

### The first pull request: two options

Both work. The difference is review size versus how long the default branch holds an incomplete
feature.

**Option A - merge the whole change.** One pull request, everything consistent, tests land with it
so CI guards the workflow immediately. The `AI Review` label becomes live but inert: a maintainer
adding it starts a real model run that renders output and posts nothing, bounded by
`engine.maxAiCredits`.

**Option B - merge the workflow file only, dispatch-only.** Comment out the `issues:` trigger, and
merge just `.github/workflows/AiIssueTriage.yml`:

```yaml
on:
  # issues:
  #   types: [labeled]
  workflow_dispatch:
```

This works because a dispatch runs the workflow file *and* the checked-out scripts from the ref you
select, so the default branch never needs the logic. The `resolve` job's `if:` already tolerates
it - `github.event_name == 'workflow_dispatch'` short-circuits, and `github.event.label.name`
evaluates to null on a dispatch rather than erroring. `Tests/WorkflowSanitation` only inspects
`Templates/`, so a lone workflow file does not fail the default branch's CI.

Two things to know if you take Option B:

- Dispatching with `--ref main` will fail, because the default branch has the workflow but not the
  scripts. Worth saying so in the pull request description.
- The commented-out trigger has to be restored in the next pull request. Commenting it out on the
  branch as well as on the default branch avoids having two versions to reconcile.

Option B gets to a first real model run with a one-file review, which is the fastest way to reach
the only genuinely unknown part of this. Option A is tidier. Either is defensible; if you take B,
keep the follow-up close behind.

### Testing a change from a branch

```powershell
gh workflow run AiIssueTriage.yml --ref my-feature-branch -f issue_number=2285 -f dry_run=true
gh run watch
gh run download --name triage-rendered-2285   # comment.md, findings.json, run-metadata.json
```

Pick a **closed** issue number so nothing would reach an active reporter even by accident.

## Current state

The agent has been exercised against real AL-Go issues locally, and gets the important decisions
right on the cases tried so far: it traces the failing code with ripgrep, routes BcContainerHelper
and platform issues away from AL-Go, redirects feature requests, and correctly rates shared-code
changes as critical. Runs cost roughly 1.7 to 4.2 AI credits, about two to four cents.

It has **not** run in GitHub Actions, and `publish.mode` is still `dryRun`, so it has never posted
anything.

## What is still missing

1. **More fixtures.** Eleven cases cover the decisions that matter most; roughly twenty more would
   make the scorer's numbers meaningful. See `Tests/Triage/fixtures/README.md`. The most valuable
   additions are issues where a human disagrees with the agent's verdict.
2. **A run on a runner.** Local runs bill your own Copilot seat and cannot exercise org-metered
   billing, the `GITHUB_TOKEN` job permissions, the tool allow-list under a headless non-interactive
   session, or Linux. Those four only fail on a runner.
3. **Calibration on the softer fields.** `reproduction_quality` and `troubleshooting_requirement`
   have been inconsistent between runs on the same issue. Harmless, but they are not yet crisply
   enough defined.
4. **`egress-policy: block`** for the triage job, once the first runs record which endpoints
   Copilot CLI needs. Audit mode records exfiltration; it does not prevent it.

Labels are **not** on this list: the agent reuses `Unrelated to AL-Go` and `Need more info`, which
already exist. `scripts/Sync-TriageLabels.ps1` verifies that and currently reports nothing to do.
