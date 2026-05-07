# Retry Upload Artifact

A thin AL-Go composite action that wraps [`actions/upload-artifact@v7.0.1`](https://github.com/actions/upload-artifact) with a small retry loop, mitigating the transient

> Error: Failed to FinalizeArtifact: Unable to make request: ETIMEDOUT

failures that intermittently affect repositories running many parallel jobs.

## Behavior

The action attempts the upload up to **3 times**:

1. **Attempt 1** — `continue-on-error: true`. On failure, sleeps `initialBackoffSeconds` (default 30s).
2. **Attempt 2** — `continue-on-error: true`. Only runs if attempt 1 failed. On failure, sleeps `min(initialBackoffSeconds * 2, maxBackoffSeconds)` (default 60s, capped at 120s).
3. **Attempt 3** — Only runs if attempt 2 failed. **Not** marked `continue-on-error`, so a failure here surfaces in the workflow as expected.

A `::Notice::` annotation is emitted before each retry sleep, and another after a successful retry, so the build summary reflects what happened. When attempt 1 succeeds (the common case), no extra annotations are produced.

## Trade-off (visible annotations on retried uploads)

When attempt 1 fails and the retry succeeds, the `::error::` annotation emitted by the upstream `actions/upload-artifact` action against the failed attempt remains visible in the build summary. This is unavoidable: GitHub records annotations the moment the action emits them, and there is no API to delete or hide them after the fact. The workflow itself does **not** fail in this case.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `name` | yes | — | Mirrors `actions/upload-artifact`. |
| `path` | yes | — | Mirrors `actions/upload-artifact`. |
| `if-no-files-found` | no | `warn` | Mirrors `actions/upload-artifact`. |
| `retention-days` | no | `0` | Mirrors `actions/upload-artifact`. |
| `compression-level` | no | `6` | Mirrors `actions/upload-artifact`. |
| `overwrite` | no | `false` | Mirrors `actions/upload-artifact`. |
| `include-hidden-files` | no | `false` | Mirrors `actions/upload-artifact`. |
| `initialBackoffSeconds` | no | `30` | Sleep before the first retry. |
| `maxBackoffSeconds` | no | `120` | Cap for the doubled backoff before the final retry. |
| `shell` | no | `powershell` | Shell used for the retry/sleep helper steps. |

## Outputs

| Output | Notes |
|---|---|
| `artifact-id` | Forwarded from whichever attempt succeeded. |
| `artifact-url` | Forwarded from whichever attempt succeeded. |
| `artifact-digest` | Forwarded from whichever attempt succeeded. |

## Usage

```yaml
- name: Publish artifacts - test results
  uses: microsoft/AL-Go-Actions/RetryUploadArtifact@main
  if: (success() || failure()) && (hashFiles(format('{0}/.buildartifacts/TestResults.xml', inputs.project)) != '')
  with:
    name: ${{ steps.calculateArtifactsNames.outputs.TestResultsArtifactsName }}
    path: '${{ inputs.project }}/.buildartifacts/TestResults.xml'
    if-no-files-found: ignore
```
