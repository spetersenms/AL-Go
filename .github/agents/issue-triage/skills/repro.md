# Reproduction: three tiers, two of them automatable

"Run the test suite" is not reproduction. The AL-Go Pester suite is already green - passing tests
are a merge requirement - so running it proves nothing about a reported bug. Real reproduction means
driving the affected code with the reporter's inputs.

## Tier 0 - static code-path trace

Always do this. It is cheap and resolves a large share of issues on its own.

1. Take the error text verbatim.
2. Find the line in `Actions/` that emits it.
3. Read the surrounding code.
4. Decide whether the reported behaviour is what that code would actually do.

Put the traced path in `notes_for_maintainer`. Even when no repro is possible, a maintainer handed
the exact failing line has most of the work done.

## Tier 1 - run the action with the reporter's inputs

AL-Go action scripts can be invoked directly, outside a workflow. `Tests/Repro/Invoke-ActionRepro.ps1`
does this: it builds a scratch workspace, sets the `GITHUB_*` and AL-Go environment variables, runs
the action, and returns its outputs, its error, and the parsed `GITHUB_OUTPUT` / `GITHUB_ENV`.

Reconstruct a manifest from the issue (schema: `Tests/Repro/repro-manifest.schema.json`):

```json
{
  "action": "CalculateArtifactNames",
  "parameters": { "project": "MyProject", "buildMode": "Clean" },
  "settings": { "repoVersion": "22.0", "appBuild": 123, "appRevision": 0, "repoName": "AL-Go" },
  "env": { "GITHUB_REF_NAME": "release/1.0" },
  "issue": 1234,
  "reported": "artifact name contains the branch name unescaped",
  "expected": "branch separators replaced",
  "notes": "appBuild and appRevision were not stated in the issue and were assumed"
}
```

Run it, then compare the result against `expected` and set `repro_outcome`.

**Record every assumption in `notes`.** Reports rarely contain a complete parameter set, and a
repro built on invented values that happens to fail is worse than no repro. If a guessed value is
what makes the difference, say so explicitly.

### What can be reproduced

`Tests/Repro/action-repro-policy.json` classifies every action:

- `offline` - deterministic, no credentials. Ideal.
- `needs-api` - read-only GitHub API. Works with the workflow token.
- `needs-network` - reaches bcartifacts, template repos, or aldoc. Works, but slower and flakier.
- `unsafe` - needs BC containers, real secrets, or live tenants. **The harness refuses these.**

This split lines up closely with routing: the reproducible actions are AL-Go's own deterministic
logic, and the `unsafe` ones are mostly where the root cause turns out to be BcContainerHelper or
the platform anyway. If an issue lands on an `unsafe` action, prefer routing it over forcing a repro.

### COULD_NOT_CONSTRUCT is a normal outcome

Use it whenever the action is `unsafe`, the inputs cannot be reconstructed, or the failure depends
on a container or tenant. It is an honest and common result.

When reporting it to the reporter, **never imply the report was inadequate**. Say what could not be
reproduced and why, and what specifically would allow it. A wrong "cannot reproduce" is one of the
most damaging things triage can say.

## Tier 2 - full end-to-end

`e2eTests/` creates a real repository from a template and runs CI/CD against it. It needs
organization secrets and takes tens of minutes to hours.

**Never run this autonomously.** Name the scenario that would be needed, put it in
`notes_for_maintainer`, and stop. A maintainer dispatches it if it is warranted.

## Setting the fields

| `repro_outcome` | When |
| --- | --- |
| `REPRODUCED` | The harness ran and the reported behaviour occurred |
| `NOT_REPRODUCED` | The harness ran and the behaviour did not occur. Consider version, settings, or an incorrect assumption before concluding the report is wrong |
| `COULD_NOT_CONSTRUCT` | No runnable manifest could be built |
| `NOT_ATTEMPTED` | Tier 1 was not applicable, for instance a documentation issue |

`reproduction_quality` is about the **report**; `repro_outcome` is about **what was actually run**.
A report can have `SUFFICIENT` steps and still yield `COULD_NOT_CONSTRUCT`.
