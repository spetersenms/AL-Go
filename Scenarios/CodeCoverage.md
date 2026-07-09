# Collect Code Coverage

> **Preview:** This feature is work-in-progress and is not guaranteed to work in all scenarios and setups yet. If you encounter issues, disable the setting and report the problem.

AL-Go for GitHub supports collecting code coverage data during test runs. When enabled, tests run through the built-in AL Test Runner (the same runner used by the separate test action), which executes tests and collects line-level coverage information. The result is output as a Cobertura XML file in the build artifacts.

## Prerequisites

Code coverage is produced only by the separate test action (`RunTests`), which uses the built-in AL Test Runner instead of BcContainerHelper. You must therefore also enable `useSeparateTestAction`:

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

## Advanced Configuration

Use the `codeCoverageSetup` object to customize coverage behavior:

```json
{
    "useSeparateTestAction": true,
    "enableCodeCoverage": true,
    "codeCoverageSetup": {
        "excludeFilesPattern": ["*.PermissionSet.al", "*.PermissionSetExtension.al"],
        "trackingType": "PerRun",
        "produceCodeCoverageMap": "PerCodeunit"
    }
}
```

| Property | Description | Default |
|---|---|---|
| `excludeFilesPattern` | Array of glob patterns for files to exclude from the coverage denominator. Patterns are matched against both the file name and relative path. Example: `["*.PermissionSet.al"]` excludes all permission set files. | `[]` |
| `trackingType` | Coverage tracking granularity: `PerRun`, `PerCodeunit`, or `PerTest`. | `PerRun` |
| `produceCodeCoverageMap` | Code coverage map granularity: `Disabled`, `PerCodeunit`, or `PerTest`. | `PerCodeunit` |

Read more about settings at [Settings](settings.md#codeCoverageSetup).

## Output

The coverage output is available in the build artifacts under the `CodeCoverage` folder:

- **`cobertura.xml`** - Coverage data in Cobertura XML format, suitable for integration with coverage visualization tools.
- **`.dat` files** - Raw coverage data from the AL Test Runner.

When a build has multiple projects, each project publishes its own `CodeCoverage` artifact. The `MergeCoverage` job downloads all of them and produces a single `MergedCodeCoverage` artifact with a combined `cobertura.xml`.

## Limitations

- **Requires the separate test action:** Code coverage is only produced when `useSeparateTestAction` is enabled. It is not available through the standard BcContainerHelper test path in `RunPipeline`.
- **Custom `RunTestsInBcContainer` overrides:** If your repository supplies a custom `RunTestsInBcContainer.ps1` override in the `.AL-Go` folder, the built-in AL Test Runner is not used and code coverage is not collected. A warning is emitted in the build log when both `enableCodeCoverage` and a custom override are present.
- **Work-in-progress:** The AL Test Runner is a new component and may not support all test configurations that the standard BcContainerHelper test runner supports. If you experience test failures or missing test results after enabling code coverage, disable the setting and report the issue.
- **Method-level detail lost in multi-job merge:** When coverage is collected across multiple build jobs, the merge uses union semantics at the line level. Method-level detail from individual jobs is not preserved in the merged output.
- **No branch coverage:** Business Central does not expose branch-level coverage data. Only line-level coverage (hit/not hit) is reported.
- **No threshold enforcement:** Coverage data is informational only. There is no built-in mechanism to fail the build if coverage drops below a threshold.
- **Performance impact:** Coverage collection adds overhead to test execution. Large codebases with many test apps may see increased build times. Use `trackingType: PerRun` (the default) for best performance.
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
