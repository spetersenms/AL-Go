# Run tests

Run normal tests (`testFolders`) against the build container kept alive by the RunPipeline action.

Enable this action with `useSeparateTestAction.enabled`. It is used when normal tests are enabled and RunPipeline creates one local build container. Builds with `additionalCountries` or without a local build container continue to run normal tests in RunPipeline. BCPT and page scripting tests always remain in RunPipeline.

The action keeps `TestResults.xml` in the project folder for AnalyzeTests and copies a produced result to `.buildartifacts/TestResults.xml` for artifact upload. It does not create a result artifact when no result is produced. After the run, it refreshes `ContainerEventLog.evtx` in the project folder so failure diagnostics include test-time events.

Compiled apps are selected by matching their app IDs to `testFolders`, which excludes BCPT-only apps from the shared test-app artifact. When `runTestsInAllInstalledTestApps` is enabled, apps from `installTestAppsJson` are also included. The action honors `disabledTests.json` files found recursively under the matching test folder and project-wide `<appId>.disabledTests.json` files for both the default runner and overrides.

## Test runner

By default, AlTool runs enabled normal tests for each app through one batch and connection while BcContainerHelper provides app metadata, container configuration, company discovery, and server-side test enumeration. The optional `useSeparateTestAction.testType` value limits enumeration to `UnitTest`, `IntegrationTest`, or `Uncategorized`; blank runs all test types. The action writes JUnit output compatible with AL-Go AnalyzeTests and downstream processing.

To use another test runner, add `RunTestsInBcContainer.ps1` under the project's `.AL-Go` folder. When coverage is disabled, the historical signature accepts only `[hashtable] $parameters`, runs once per test app, receives the standard BcContainerHelper test parameters including `testType`, and returns a Boolean test result. Custom overrides may interpret additional test types such as `Legacy`.

Before enabling coverage, the repository owner must update the override to accept the contract-version 1 context parameter:

```powershell
param(
    [hashtable] $parameters,
    [hashtable] $codeCoverageContext
)
```

When coverage is disabled, AL-Go does not pass `codeCoverageContext`, does not create a coverage session or manifest, and retains the historical per-app invocation behavior. When coverage is requested and an override exists, AL-Go keeps the same per-app invocation and always adds the context parameter. AL-Go does not inspect the override signature or downgrade to noncoverage execution. An override that does not accept the parameter fails rather than running without the requested coverage.

The non-secret context contains `contractVersion`, `enabled`, `supported`, `reason`, `project`, `projectName`, `buildMode`, `testType`, current `app` metadata (`path`, `id`, `name`, and `disabledTests`), line `mode`, ordered `formats`, absolute ordered `sourceRoots`, repository-relative `sourceRootDetails`, the allocated `coverageOutputPath` and `outputDirectory`, the action-owned `alToolModulePath`, the resolved pinned `alToolPath` when coverage is supported, and a mutable `result.coverageIsComplete` output. AL-Go resolves current-project and direct `projectsToTest` roots centrally while its `AnalyzeRepo` callback is in scope. Repository overrides must not reconstruct or receive that callback. Credentials remain only in `$parameters` and must not be serialized into artifacts or diagnostics.

For supported coverage, the override imports `alToolModulePath`, invokes `Invoke-AlToolTestRun` once for the current app with the supplied coverage values, and copies the runner's completeness output into the context:

```powershell
Import-Module $codeCoverageContext.alToolModulePath -Force -DisableNameChecking
$coverageIsComplete = $null
$passed = Invoke-AlToolTestRun `
    -ContainerName $parameters.containerName `
    -Credential $parameters.credential `
    -ExtensionId $codeCoverageContext.app.id `
    -AppName $codeCoverageContext.app.name `
    -CompanyName $parameters.companyName `
    -Tenant 'default' `
    -TestType $codeCoverageContext.testType `
    -DisabledTests $codeCoverageContext.app.disabledTests `
    -AlToolPath $codeCoverageContext.alToolPath `
    -JUnitResultFileName $parameters.JUnitResultFileName `
    -CoverageMode $codeCoverageContext.mode `
    -CoverageOutputPath $codeCoverageContext.coverageOutputPath `
    -CoverageFormats $codeCoverageContext.formats `
    -CoverageSourceRoots $codeCoverageContext.sourceRoots `
    -CoverageIsComplete ([ref] $coverageIsComplete)
$codeCoverageContext.result.coverageIsComplete = $coverageIsComplete
return [bool]$passed
```

When capability is unavailable, the context has `supported = false`; the override must run the current app normally without requesting coverage. After every supported invocation, AL-Go validates completeness, path containment, fixed artifacts, and BC JSON schema/mode data. Missing or invalid output fails closed. AL-Go alone updates and finalizes `coverage-status.json`. The override continues to return the historical Boolean test result, and failed tests may retain valid coverage.

## Code coverage

Set `useSeparateTestAction.codeCoverageEnabled` to `true` to collect coverage with the built-in AlTool runner or an opted-in `RunTestsInBcContainer.ps1` override. Coverage uses the pinned `Microsoft.Dynamics.BusinessCentral.Development.Tools` `30.0.43.45776-beta` package and requires container platform 30.0.56026.0 or later. After RunPipeline creates the container, it hands the actual platform version to RunTests. Missing, malformed, older, or failed version detection produces a warning and tests continue normally without coverage. Once the platform requirement is confirmed, collection or export errors fail the run instead of silently retrying without coverage.

AL-Go collects executable-line coverage. Procedure coverage is not currently exposed because AlTool source enrichment cannot reliably construct a local method inventory in the separate-test environment. `codeCoverageFormats` accepts `bc-json` and `cobertura` and defaults to both. `codeCoverageSummary` accepts `none`, `project`, `repository`, or `both` and defaults to `both`; `none` disables visualization without disabling raw collection. Existing app and test folders in the current AL-Go project are passed automatically as source roots to improve source mapping. Test projects also use the analyzed app and test folders from their direct `projectsToTest` targets.

RunTests records repository-relative source-root identities in `coverage-status.json` so repository summaries can map raw report paths consistently across build jobs. Ordered source-root details classify each root as an app or test folder and include available app identity from `app.json`. These roots are action-level attribution data and are not repeated per test-app run.

Each built-in or override test-app run writes to `.buildartifacts/CodeCoverage/<app-id>/`, preserving the existing artifact layout and fixed `coverage.bc.json` and `coverage.cobertura.xml` names. `coverage-status.json` contains one AL-Go-owned run record per selected test app. Its state distinguishes complete, incomplete, failed, unsupported, and not-yet-run raw coverage. Coverage artifacts are retained and uploaded even when tests fail. BC JSON is authoritative for AL-Go summaries; Cobertura remains available for external tooling.

Project and repository summaries include only regular applications declared through `appFolders`. Lines from `testFolders` and external Microsoft objects remain in raw artifacts but are excluded from rates, uncovered-object lists, and completeness. Multiple test apps and repeated build dimensions contribute to one semantic line union per regular app.

### Known limitations

The built-in AlTool execution path does not run `Legacy` test-type codeunits or tests that require UI or client-callback interaction. Repositories that rely on those can retain the original override and optionally adopt the coverage context contract for supported execution buckets.

The current live E2E environment does not guarantee container platform 30.0.56026.0 or later. Automated tests therefore cover older and unavailable platform-version handoffs; live coverage collection awaits a deterministic BC30-capable E2E environment.

## INPUT

### ENV variables

| Name | Description |
| :-- | :-- |
| Settings | env.Settings must be set by a prior call to the ReadSettings Action |
| containerName | env.containerName is set by the RunPipeline action and identifies the container to run tests against (the container name is otherwise derived from the project) |
| containerCredential | env.containerCredential is set by the RunPipeline action and contains the masked, base64-encoded JSON credential used to reconnect to the kept-alive container |

### Parameters

| Name | Required | Description | Default value |
| :-- | :-: | :-- | :-- |
| shell | | The shell (powershell or pwsh) in which the PowerShell script should run | powershell |
| token | | The GitHub token running the action and exposed to test override scripts | github.token |
| project | | Project folder | '.' |
| installTestAppsJson | | Path to a JSON file containing a list of test apps to run tests in | '' |

## OUTPUT

None
