# Fix risk: how much blast radius would a fix have?

AL-Go is consumed by many repositories that pull its actions and templates directly. A change here
does not affect one product, it affects everyone's pipeline on their next run. Risk assessment
decides whether a fix can be automated at all, or whether it needs a human watching.

Assess the risk of the **likely fix**, not of the bug. A trivial-looking symptom can require a
change in a file that everything depends on.

## Tiers

### critical - never fix autonomously

A defect here breaks consumers' pipelines, or their ability to recover from the break.

| Path | Why |
| --- | --- |
| `Actions/AL-Go-Helper.ps1` | Dot-sourced by effectively every action |
| `Actions/.Modules/ReadSettings.psm1` | Settings resolution for every workflow |
| `Actions/Invoke-AlGoAction.ps1` | Wraps every action's execution |
| `Actions/Github-Helper.psm1` | Shared GitHub API surface |
| `Actions/CheckForUpdates/` | Rewrites consumers' workflow files. A bug here can break everyone's ability to update, including the ability to ship the fix |
| `Actions/ReadSecrets/` | Secret handling |
| `Actions/VerifyPRChanges/` | Fork-PR security boundary |
| `Templates/*/.github/workflows/` | Shipped verbatim into consumer repositories |
| Any change to an existing setting's **default value** | Silently changes behaviour for everyone who did not set it |
| Anything touching authentication, token handling, or secret masking | Security surface |

### medium - draft PR, human review required

Main CI/CD path. Wrong behaviour is disruptive but visible and recoverable.

`RunPipeline`, `CompileApps`, `Deploy`, `Deliver`, `Sign`, `DetermineProjectsToBuild`,
`IncrementVersionNumber`, `DetermineArtifactUrl`, `DetermineArtifactsForRelease`,
`CalculateArtifactNames`, `AnalyzeTests`, `DownloadProjectDependencies`.

Also: adding a **new** setting (additive, but becomes API you must support).

### low - safe to propose a concrete patch

Documentation, `RELEASENOTES.md`, tests, schema description text, and actions used only by one
optional workflow: `BuildPowerPlatform`, `DeployPowerPlatform`, `PullPowerPlatformChanges`,
`BuildReferenceDocumentation`, `CreateDevelopmentEnvironment`, `CreateApp`, `AddExistingApp`.

### unknown

The affected code could not be identified. **Use this rather than guessing `low`.** An unjustified
`low` is the one failure mode that could let a bad change through.

## Amplifiers

Raise the tier by one when any of these apply:

- The file is referenced by many others (check before deciding).
- The same file exists in **both** `Templates/Per Tenant Extension/` and `Templates/AppSource App/`,
  so the change must be made consistently in both.
- The change alters something consumers execute directly rather than something AL-Go executes.
- The fix would change a public setting's shape, name, or default.
- The change touches secrets, tokens, or permissions.

## Lanes

| Risk | `recommended_lane` | What happens |
| --- | --- | --- |
| `low` + repro confirmed | `ready-for-maintainer` | Propose a concrete patch in the comment; a human triggers the fix |
| `medium` | `ready-for-maintainer` | Draft PR, mandatory CODEOWNERS review |
| `critical` | `needs-human-fix` | **No patch proposed.** Post the analysis and label for a monitored local session |
| `unknown` | `needs-human-fix` | Treat as critical until someone identifies the code |

`fix_risk: critical` **must** be paired with `recommended_lane: needs-human-fix`.

Note that enforcement does not depend on this judgement: `CODEOWNERS` assigns
`@microsoft/d365-bc-engineering-systems` to everything, and branch protection still applies. The
risk score decides which automation is allowed to fire, it is not the safety net itself.
