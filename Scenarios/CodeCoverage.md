# Collect Code Coverage

> **Preview:** This feature is work-in-progress and is not guaranteed to work in all scenarios and setups yet. If you encounter issues, disable the setting and report the problem.

AL-Go for GitHub can collect code coverage data while running your tests. When enabled, the separate test action (`RunTests`) runs the tests through the built-in AlTool (`al runtests`) runner and, in parallel, records line-level coverage on the build container. The result is output as a Cobertura XML file in the build artifacts.

## Prerequisites

Code coverage is produced only by the separate test action (`RunTests`), which uses the built-in AlTool runner instead of BcContainerHelper. You must therefore also enable `useSeparateTestAction`:

```json
{
    "useSeparateTestAction": true,
    "enableCodeCoverage": true
}
```

If `enableCodeCoverage` is set without `useSeparateTestAction`, a warning is emitted and no coverage is collected.

## Enabling Code Coverage

Add the following to your `.AL-Go/settings.json` or `.github/AL-Go-Settings.json`:

```json
{
    "useSeparateTestAction": true,
    "enableCodeCoverage": true
}
```

Read more about settings at [Settings](settings.md#enableCodeCoverage).

## How it works

Business Central records code coverage globally per server instance. The built-in collector opens a single persistent client session against the build container, starts global coverage recording, lets the AlTool runner execute the tests in its own sessions, then reads back the accumulated per-line coverage and stops recording. The collected data is converted to Cobertura XML using your app source folders as the coverage denominator.

The collector uses a BcContainerHelper client session to drive the coverage page on the container. This is the only BcContainerHelper touchpoint in the AlTool coverage path and is used only when `enableCodeCoverage` is set.

## Advanced Configuration

Use the `codeCoverageSetup` object to customize coverage behavior:

```json
{
    "useSeparateTestAction": true,
    "enableCodeCoverage": true,
    "codeCoverageSetup": {
        "excludeFilesPattern": ["*.PermissionSet.al", "*.PermissionSetExtension.al"],
        "filterToRepoObjectIds": true
    }
}
```

| Property | Description | Default |
|---|---|---|
| `excludeFilesPattern` | Array of glob patterns for files to exclude from the coverage denominator. Patterns are matched against both the file name and relative path. Example: `["*.PermissionSet.al"]` excludes all permission set files. | `[]` |
| `trackingType` | Coverage tracking granularity: `PerRun`, `PerCodeunit`, or `PerTest`. The built-in AlTool collector only supports `PerRun`; other values are ignored (with a warning). | `PerRun` |
| `produceCodeCoverageMap` | Code coverage map granularity: `Disabled`, `PerCodeunit`, or `PerTest`. Not supported by the built-in AlTool collector; any value other than `Disabled` is ignored (with a warning). | `Disabled` |
| `filterToRepoObjectIds` | When `true`, the External Objects section of the report only lists objects whose ID falls within your apps' declared `idRanges` (from `app.json`), hiding Microsoft/system objects. When no `idRanges` are found, all external objects are shown. | `true` |

Read more about settings at [Settings](settings.md#codeCoverageSetup).

## Output

The coverage output is available in the build artifacts under the `CodeCoverage` folder:

- **`cobertura.xml`** - Coverage data in Cobertura XML format, suitable for integration with coverage visualization tools.
- **`.dat` files** - Raw coverage data collected from the build container.

When a build has multiple projects, each project publishes its own `CodeCoverage` artifact. The `MergeCoverage` job downloads all of them and produces a single `MergedCodeCoverage` artifact with a combined `cobertura.xml`.

## Limitations

- **Requires the separate test action:** Code coverage is only produced when `useSeparateTestAction` is enabled. It is not available through the standard BcContainerHelper test path in `RunPipeline`.
- **PerRun granularity only:** The built-in AlTool collector records coverage globally for the whole test run (`PerRun`). Finer granularity (`PerCodeunit`, `PerTest`) and a code coverage map (`produceCodeCoverageMap`) are not supported by the built-in collector; those values are ignored with a warning. Projects that need finer granularity or a coverage map should supply a `RunTestsInBcContainer` override that runs tests (and collects coverage) through BcContainerHelper.
- **Custom `RunTestsInBcContainer` overrides:** If your repository supplies a custom `RunTestsInBcContainer.ps1` override in the `.AL-Go` folder, the built-in AlTool runner is not used and the built-in code coverage collector does not run. A warning is emitted in the build log when both `enableCodeCoverage` and a custom override are present.
- **Legacy and UI tests:** The built-in AlTool runner does not run Legacy test-type codeunits or tests that require UI/client-callback interaction, so those are not represented in the coverage output. Projects that need those should supply a `RunTestsInBcContainer` override to run via BcContainerHelper.
- **Method-level detail lost in multi-job merge:** When coverage is collected across multiple build jobs, the merge uses union semantics at the line level. Method-level detail from individual jobs is not preserved in the merged output.
- **No branch coverage:** Business Central does not expose branch-level coverage data. Only line-level coverage (hit/not hit) is reported.
- **No threshold enforcement:** Coverage data is informational only. There is no built-in mechanism to fail the build if coverage drops below a threshold.
- **Performance impact:** Coverage collection adds overhead to test execution. Large codebases with many test apps may see increased build times.
- **File size:** Coverage data files can be significant for large codebases. The GitHub Step Summary is automatically truncated if it exceeds size limits; download the CodeCoverage artifact for full details.

## Integration with Third-Party Tools

The `cobertura.xml` output follows the standard [Cobertura XML format](https://cobertura.github.io/cobertura/), which is widely supported by coverage visualization and CI/CD tools. You can download the `CodeCoverage` (per project) or `MergedCodeCoverage` (whole build) artifact from your workflow run and upload it to services such as:

- **SonarQube / SonarCloud** - Import via the `sonar.coverageReportPaths` property
- **Codecov.io** - Upload using the [Codecov GitHub Action](https://github.com/codecov/codecov-action) with the artifact path
- **Azure DevOps** - Use the [Publish Code Coverage Results](https://learn.microsoft.com/en-us/azure/devops/pipelines/tasks/test/publish-code-coverage-results) task

Example workflow step to upload coverage to a third-party tool after the build:

```yaml
- name: Download coverage artifact
  uses: actions/download-artifact@v4
  with:
    name: MergedCodeCoverage
    path: .coverage
- name: Upload to Codecov
  uses: codecov/codecov-action@v4
  with:
    files: .coverage/cobertura.xml
```
