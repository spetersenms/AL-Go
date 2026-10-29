# Run tests

Run normal tests from `testFolders` against an existing Business Central container.

The action reads analyzed settings from `Settings` and reconnects to the kept-alive build container using `containerName` and `containerCredential`; `project` selects the project folder, and `installTestAppsJson` supplies installed test-app paths from earlier jobs.

Compiled apps are matched to normal `testFolders`; eligible installed test apps are added from `installTestAppsJson`, and matching disabled-test files are applied. The built-in runner uses AlTool and BcContainerHelper metadata to execute each selected app. It produces only native AlTool JSON, not JUnit.

## Native results

Each app's results are saved under `AlToolTestResults/<app-id>/` in the project folder:

| File | Contents |
| :-- | :-- |
| `response.json` | AlTool's structured stdout, without conversion or JSON reserialization. It retains the full `ToolResponse` envelope and every result occurrence. |
| `metadata.json` | Normalized app ID, app name, requested codeunit IDs/names/methods and matched results, whether enumeration completed, execution was attempted, and the response was verified (`verified`), plus the process exit code when available. |

The runner matches results to requested methods once and saves them in each codeunit's `results` array in metadata. Missing requested results are saved as failures without adding synthetic entries to `response.json`. Repeated and data-driven result occurrences are retained. AnalyzeTests reads these saved records without matching them again. If no enabled codeunits exist, metadata records that no execution was attempted and no response is fabricated.

Produced results remain in the project folder for AnalyzeTests and are copied to `.buildartifacts/AlToolTestResults/`. The workflow publishes that directory in the existing **TestResults** artifact. Captured responses are retained even when AlTool returns a failed or malformed response, and results from completed apps remain available if a later app fails. The action refreshes `ContainerEventLog.evtx` after execution.

AnalyzeTests automatically selects native analysis when `AlToolTestResults` exists. Invalid or incomplete native artifacts are diagnosed explicitly rather than falling back to an old XML result. Previous native and XML results are cleared before each separate test run to prevent stale summaries when changing runners.

This metadata is independent of code-coverage artifacts. Test analysis does not require code coverage.

## Custom runners and legacy results

The override `.AL-Go/RunTestsInBcContainer.ps1` replaces the built-in test runner. It is invoked once per selected test app with `-parameters` containing the standard BcContainerHelper test arguments and returns whether all tests passed. Overrides keep `JUnitResultFileName` and `AppendToJUnitResultFile` and may continue producing `TestResults.xml`, copied to `.buildartifacts/TestResults.xml`. The original RunPipeline runner also retains its JUnit behavior.

Direct callers of the built-in `Invoke-AlToolTestRun` must supply `TestResultsPath`, the root native-results directory, instead of `JUnitResultFileName`. The built-in runner has no JUnit output mode.

### AlTool override format

Overrides using AlTool must write `response.json` and `metadata.json` under `<project>/AlToolTestResults/<app-id>/`. The action copies these files to the build artifacts. The analyzer reads this contract directly, without metadata schema validation.

`response.json` is the unchanged native AlTool `ToolResponse`. It contains Boolean `succeeded` and `data.results`; each result has `codeunitId`, `methodName`, `status` (`passed`, `failed`, or `skipped`), and `durationMs` (non-negative integer milliseconds). `output` is optional and may be a string or null. Failed responses may omit `data.results` and include a diagnostic `message`.

The expected `metadata.json` format is:

```json
{
  "appId": "11111111-1111-1111-1111-111111111111",
  "appName": "Test App",
  "codeunits": [
    {
      "id": 130001,
      "name": "My Tests",
      "methods": ["TestOne"],
      "results": [
        {
          "codeunitId": 130001,
          "methodName": "TestOne",
          "status": "passed",
          "durationMs": 12,
          "output": ""
        }
      ]
    }
  ],
  "enumerated": true,
  "attempted": true,
  "verified": true,
  "exitCode": 0
}
```

All app and codeunit properties shown are required; use the JSON types shown. `appId` is the lowercase GUID without braces used as the folder name. `appName` may be empty, in which case the app ID is displayed. `codeunits` lists the requested codeunit IDs, names, and enabled method names after disabled-test filtering. Each codeunit's `results` contains matched native occurrences and failures for missing methods.

The runner exports `Get-AlToolTestMethodResults` for overrides. Import the already-loaded runner module into the override's scope, then populate results from verified native output:

```powershell
Import-Module (Get-Module -Name AlToolTestRunner -All).Path -Force -DisableNameChecking
foreach ($codeunit in $metadata.codeunits) {
    $methodResults = @($response.data.results | Where-Object { $_.codeunitId -eq $codeunit.id })
    $codeunit.results = @(Get-AlToolTestMethodResults -RequestedMethods $codeunit.methods -MethodResults $methodResults)
}
```

The helper performs no execution or file I/O. For setup failures or unusable output, pass an empty `MethodResults` array to record every requested method as failed. Save metadata even when the run fails. Matched native records retain their original fields; generated missing-result records contain `methodName`, `status: "failed"`, `durationMs: 0`, and `output: "No result produced by al runtests"`.

| Field | Meaning |
| :-- | :-- |
| `enumerated` | Enumeration completed successfully, including when no enabled tests were found. |
| `attempted` | AlTool invocation was attempted. |
| `verified` | The native response structure was verified. This does not mean the tests passed. |
| `exitCode` | Actual AlTool process exit code, or null if no exit code was obtained. |

After a successful empty enumeration, use an empty `codeunits` array, `enumerated: true`, `attempted: false`, `verified: false`, and `exitCode: null`; omit `response.json`.
