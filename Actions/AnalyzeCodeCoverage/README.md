# Analyze Code Coverage

Creates a focused Markdown job summary from Business Central JSON coverage reports produced by the separate test action. Raw coverage artifacts are read without modification.

Project summaries are emitted only when `useSeparateTestAction.codeCoverageSummary` is `project` or `both`. Repository execution is expected to be workflow-gated and uses the expected build dimensions in `buildOrderJson`.

Completeness is evaluated independently for repository-scoped line and procedure facts. A globally incomplete BC JSON report can still produce line coverage when its mapped local line facts are reliable; unavailable metrics are hidden with a concise reason.

Project and repository summaries include application coverage for regular `appFolders`. Each app row unions canonical line facts across all relevant test-app runs and excludes `testFolders`; repeated build dimensions do not double-count the same repository line. Older artifacts without ordered source-root classification remain analyzable but do not render application rows.

## Inputs

| Name | Required | Description | Default |
| :-- | :-: | :-- | :-- |
| `shell` | No | PowerShell host, `powershell` or `pwsh` | `powershell` |
| `scope` | Yes | Summary scope, `project` or `repository` | |
| `project` | No | Project folder | `.` |
| `coveragePath` | Yes | Path containing project coverage artifacts or separately downloaded repository artifacts | |
| `buildOrderJson` | No | Build order JSON containing expected repository `buildDimensions` across dependency depths | `[]` |

Repository source attribution uses the exact source-root order recorded by RunTests. The primary root receives unprefixed exporter paths, while `external-N` paths resolve only against root index `N`. Absolute legacy paths use most-specific root matching. Every mapped path must resolve to an existing file within both its declared root and the repository; unmapped or external facts are counted and excluded.

## Outputs

None. The action can append a bounded summary to `GITHUB_STEP_SUMMARY`.
