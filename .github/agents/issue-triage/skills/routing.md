# Routing: is this actually an AL-Go issue?

The single most valuable thing triage can do is decide which component owns a problem. Getting this
right early saves days; getting it wrong sends a reporter to the wrong repository.

This is mostly a mechanical decision, because the boundary between AL-Go and BcContainerHelper is
explicit in the code rather than a matter of judgement.

## The handoff points

AL-Go orchestrates. BcContainerHelper (BCH) does the Business Central work. There are two narrow
places where control crosses over:

| Crossing | Location |
| --- | --- |
| Build, compile, test | `Actions/RunPipeline/RunPipeline.ps1` calls `Run-AlPipeline` |
| Publish to an environment | `Actions/Deploy/Deploy.ps1` calls `Publish-BcContainerApp` |

**Anything that fails downstream of those calls is presumptively not AL-Go.** That single rule
resolves a large share of misrouted issues.

## Signature table

Match against the strongest available signal, in this order. A stack frame beats an error message;
an error message beats a symptom description.

| Signal | Area | Confidence |
| --- | --- | --- |
| Stack frame in `Actions/<Name>/<Name>.ps1`, `AL-Go-Helper.ps1`, `ReadSettings.psm1`, `CheckForUpdates` | `al-go` | HIGH - and it names the action |
| Error mentions an AL-Go setting name, or settings parsing or schema validation | `al-go` | HIGH |
| Workflow YAML problem: missing job, bad `needs:`, matrix, permissions, template file drift | `al-go` | HIGH |
| `Run-AlPipeline`, `New-BcContainer`, `Download-Artifacts`, `Compile-AppInBcContainer`, `Publish-BcContainerApp`, `Get-BcContainerAppInfo`, compiler-folder handling | `bccontainerhelper` | HIGH |
| Container creation, Docker image pull, artifact URL resolution, symbol download | `bccontainerhelper` | HIGH |
| `AL####` diagnostic codes, AL compilation errors, app runtime or upgrade-codeunit errors | `bc-platform` | HIGH - **but read the rule below first** |
| Admin Center API, environment provisioning, tenant or sandbox lifecycle | `bc-saas` | MEDIUM |
| Runner outage, Actions API 5xx, artifact retention, rate limiting, `actions/*` action failure | `github` | MEDIUM |
| Their own `settings.json`, their secrets, their branch protection, their fork setup | `user-config` | MEDIUM |
| No log, no stack, no reproducible description | `unknown` | LOW |

## Rules

- **Absence of evidence is `LOW` confidence, never `HIGH`.** If no concrete signal was found, say so
  and set `area_confidence` to `LOW`. Do not infer an area from the issue title alone.
- **Record the signal.** Put the actual stack frame or cmdlet name in `area_evidence`. A routing
  decision a maintainer cannot check is worth little.
- **AL-Go can still be at fault upstream of a BCH failure.** If AL-Go passed a wrong parameter into
  `Run-AlPipeline`, the failure surfaces in BCH but the bug is AL-Go's. When the BCH error is about
  a value AL-Go computed - a path, an artifact URL, a version, a folder list - trace back to where
  AL-Go produced it before routing away.
- **A compiler error is not automatically a compiler bug.** `AL0185 Table 'X' is missing` or
  `AL0247 target Page not found` usually means the symbols were never made available, not that the
  compiler is broken. Ask *why* the symbol is absent before routing to `bc-platform`:
  - Does the reporter say the object **does** exist in an installed dependency? Then the dependency
    was not resolved or downloaded - look at `appDependencyProbingPaths`, `trustedNuGetFeeds`,
    workspace compilation, or symbol download. That is AL-Go or user configuration.
  - Does it fail for one app but not others in the same repository? That points at that app's
    dependency declaration, not at the compiler.
  - Route to `bc-platform` only when the compiler genuinely misbehaves on input that is provably
    complete - for instance an internal compiler exception, or a null-reference inside
    `Microsoft.Dynamics.Nav.CodeAnalysis`.
- **Never close or redirect on your own.** Apply the area label, explain the reasoning, and let a
  maintainer decide. Being confidently wrong about routing is worse than being uncertain.

## Where things live

- AL-Go: `microsoft/AL-Go` (this repository)
- BcContainerHelper: `microsoft/navcontainerhelper` (public, so its source can be searched to
  confirm a cmdlet-level hypothesis)
- BC platform and AL compiler: not public; route by labelling and describing, not by filing

## Useful evidence, in order of value

1. The linked workflow run log. Most reporters' repositories are private, so this is often
   unreadable - that is normal and not the reporter's fault.
2. A stack trace or error text pasted into the issue.
3. The reporter's AL-Go settings JSON.
4. The AL-Go version, cross-checked against `RELEASENOTES.md`.
