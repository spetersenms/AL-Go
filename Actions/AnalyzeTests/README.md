# Analyze Tests

Analyzes normal, BCPT, and page scripting test results and writes a Markdown summary to `GITHUB_STEP_SUMMARY`.

For normal tests, reads runner-prepared method results from `<project>/AlToolTestResults/<app-id>/metadata.json` and run diagnostics from `response.json` when `AlToolTestResults` exists; otherwise reads `<project>/TestResults.xml` (JUnit). Native result errors are reported without falling back to XML.

Custom `RunTestsInBcContainer` overrides must produce one of these formats. See the [AlTool override format](../RunTests/README.md#altool-override-format).

## INPUT

### ENV variables

none

### Parameters

| Name | Required | Description | Default value |
| :-- | :-: | :-- | :-- |
| shell | | Shell to use: `powershell` or `pwsh` | powershell |
| project | Yes | Project folder, or `.` for a single-project repository | |
| testType | Yes | `normal`, `bcpt`, or `pageScripting` | |

## OUTPUT

### ENV variables

none

### OUTPUT variables

none

### SUMMARY

Writes the test result Markdown to `GITHUB_STEP_SUMMARY`.
