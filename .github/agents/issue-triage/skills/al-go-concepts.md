# AL-Go concepts

Enough of a mental model to triage accurately. This is not a user manual - when a specific
behaviour matters, look it up (see "Where to look things up" below) rather than guessing from here.

## What AL-Go is

AL-Go for GitHub is a set of GitHub Actions and workflow templates for building, testing and
shipping Business Central apps written in AL. Consumers do not copy code from it - their repository
holds workflow files that call AL-Go's actions by reference, and an **Update AL-Go System Files**
workflow keeps those files in sync with the template.

Two consequences that matter constantly in triage:

- A change in `Templates/` reaches consumers on their next update, so it affects everyone.
- A change in `Actions/` affects everyone **immediately**, because their workflows call those
  actions at whatever ref they are pinned to.

## Repository shapes

- **Single-project**: app folders at the repository root.
- **Multi-project**: each project in its own folder, each with its own `.AL-Go/settings.json`.
  A "project" is a unit that builds and releases together, not a single app.
- Two templates exist: **Per Tenant Extension (PTE)** and **AppSource App**. They share most
  workflows; AppSource adds submission-related ones. A workflow present in both must be changed in
  both.

## Settings

Layered, most specific winning: organization -> repository (`.github/AL-Go-Settings.json`) ->
project (`.AL-Go/settings.json`) -> workflow-specific -> user-specific. `conditionalSettings` apply
a block when branch, workflow, build mode or user matches.

A reported behaviour is frequently a settings interaction rather than a defect. Ask for the
settings JSON when the symptom touches project discovery, build modes, versioning, artifacts,
delivery or environments. The resolve phase already extracts JSON blocks from the issue body into
`json_blocks`.

## The main workflows

| Workflow | Does what |
| --- | --- |
| `CICD` | The main build. Calls `_BuildALGoProject` per project and build mode. |
| `PullRequestHandler` | PR validation. Runs a build, honours incremental builds. |
| `CreateRelease` | Turns built artifacts into a GitHub release. |
| `PublishToEnvironment` | Deploys artifacts to a Business Central environment. |
| `IncrementVersionNumber` | Bumps versions, usually as a PR. |
| `UpdateGitHubGoSystemFiles` | Pulls newer AL-Go files from the template into the consumer repo. |
| `Troubleshooting` | Dumps diagnostics. This is what to ask reporters to run. |
| `Current` / `NextMinor` / `NextMajor` | Build against current and upcoming BC releases. |

## Vocabulary

- **Artifact** is overloaded. A *BC artifact* is the Business Central version payload that
  `artifact` in settings selects (country, version, sandbox/onprem). A *GitHub artifact* is a build
  output uploaded by a workflow run. Read carefully which one a reporter means.
- **Build mode**: `Default`, `Clean`, `Translated`, or custom. Affects compilation and artifact
  naming.
- **Delivery target**: where built apps are delivered (AppSource, NuGet, Storage, custom
  `DeliverTo*.ps1`).
- **Environment**: a Business Central environment for deployment, configured through GitHub
  environments plus AL-Go settings, with custom `DeployTo*.ps1` overrides possible.
- **Compiler folder vs container**: builds either use a lightweight compiler folder or a full
  Docker container. Which one is in play changes whether a failure is plausibly AL-Go's.

## Deprecated settings

Reporters routinely use these. A symptom caused by one of them is **not** a defect - the answer is
to migrate. Full detail in `DEPRECATIONS.md`.

| Deprecated | Replacement |
| --- | --- |
| `unusedALGoSystemFiles` | `customALGoFiles.filesToExclude` |
| `alwaysBuildAllProjects` | `incrementalBuilds.onPull_Request: false` |
| `<workflow>Schedule` (e.g. `CICDSchedule`) | `workflowSchedule` with `conditionalSettings` |
| `cleanModePreprocessorSymbols` | `preprocessorSymbols` with `conditionalSettings` on `buildModes` |

Also relevant: **old AL-Go versions may simply stop working**, because they pin old GitHub Actions
that eventually break. If a reporter is on an old version and the symptom looks environmental,
upgrading is a legitimate first answer.

## Where to look things up

You have the repository checked out. Search it rather than guessing:

| Question | Where |
| --- | --- |
| What does setting X do, what are its valid values? | `Scenarios/settings.md`, `Actions/.Modules/settings.schema.json` |
| Was this already fixed? | `RELEASENOTES.md` - entries read `- Issue <number> - <description>` |
| Is this setting deprecated? | `DEPRECATIONS.md` |
| Which action emits this message? | grep `Actions/`, including the shared files at its root |
| What does this workflow do? | `Templates/Per Tenant Extension/.github/workflows/` |
| How is this behaviour meant to work? | `Scenarios/` |

`Scenarios/settings.md` is large - grep it for the setting name rather than reading it whole.
