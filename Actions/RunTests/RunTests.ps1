Param(
    [Parameter(HelpMessage = "Project folder", Mandatory = $false)]
    [string] $project = "",
    [Parameter(HelpMessage = "A path to a JSON-formatted list of test apps to run tests in", Mandatory = $false)]
    [string] $installTestAppsJson = '',
    [Parameter(HelpMessage = "Dependencies of the built project in compressed JSON format", Mandatory = $false)]
    [string] $projectDependenciesJson = '{}'
)

<#
.SYNOPSIS
    Runs the normal tests (testFolders) for an AL-Go project against the build container
    created and kept alive by the RunPipeline action.
.DESCRIPTION
    This action is the second half of the "split" between building/publishing apps and running
    tests. It only does anything when the useSeparateTestAction setting is enabled. In that
    case, RunPipeline compiles, publishes and installs the apps, skips the normal tests and
    keeps the build container alive. This action then runs the normal tests against that same
    container and writes the results to TestResults.xml in the project folder (the location the
    AnalyzeTests action reads from).

    Only normal tests (testFolders) are handled here. BCPT and page scripting tests continue
    to be executed by the RunPipeline action.
.PARAMETER project
    Project folder.
.PARAMETER installTestAppsJson
    A path to a JSON-formatted list of test apps (produced by previous jobs) to run tests in.
.PARAMETER projectDependenciesJson
    Compressed JSON mapping each project to the projects it depends on. Used to resolve parent
    projects' app source folders when producing code coverage.
.EXAMPLE
    RunTests.ps1 -project 'MyProject'
#>

. (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)
Import-Module (Join-Path $PSScriptRoot '..\TelemetryHelper.psm1' -Resolve)
Import-Module (Join-Path $PSScriptRoot 'RunTests.psm1' -Resolve) -DisableNameChecking -Force
DownloadAndImportBcContainerHelper

function Get-TestRunnerCredential {
    <#
    .SYNOPSIS
        Returns the credential used by the test runner to connect to the build container.
    .DESCRIPTION
        RunPipeline creates the container and keeps it alive when useSeparateTestAction is set.
        When RunPipeline surfaces the container credential (masked, as base64-encoded JSON in
        the containerCredential environment variable), it is used here so the test runner can
        connect to the same container. Otherwise a default credential is used.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The container credential is surfaced by RunPipeline as plain text')]
    param()
    if ($ENV:containerCredential) {
        $credentialJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ENV:containerCredential)) | ConvertFrom-Json
        $securePassword = ConvertTo-SecureString -String $credentialJson.password -AsPlainText -Force
        return New-Object System.Management.Automation.PSCredential($credentialJson.username, $securePassword)
    }
    $securePassword = ConvertTo-SecureString -String ([GUID]::NewGuid().ToString()) -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential("admin", $securePassword)
}

if ($project -eq ".") { $project = "" }

$baseFolder = $ENV:GITHUB_WORKSPACE
$projectPath = Join-Path $baseFolder $project

Write-Host "Use settings"
$settings = $env:Settings | ConvertFrom-Json | ConvertTo-HashTable

# This action is a no-op unless normal test execution has been delegated from RunPipeline via
# the useSeparateTestAction setting. In all other cases tests are executed inside RunPipeline.
if (-not $settings.useSeparateTestAction) {
    if ($settings.enableCodeCoverage) {
        OutputWarning -message "enableCodeCoverage is set, but useSeparateTestAction is not enabled. Code coverage is only produced by the separate RunTests action; no coverage will be generated. Enable useSeparateTestAction to collect code coverage."
    }
    Write-Host "useSeparateTestAction is not enabled. Tests are executed by the RunPipeline action. Skipping."
    return
}

# Analyze the repository to determine the test folders (and other test related settings)
$settings = AnalyzeRepo -settings $settings -baseFolder $baseFolder -project $project -doNotCheckArtifactSetting

# Resolve the container kept alive by the RunPipeline action.
# The container name is deterministic per project and is also exported to the environment by RunPipeline.
$containerName = $ENV:containerName
if (-not $containerName) {
    $containerName = GetContainerName($project)
}

# Credentials used to connect to the build container.
$credential = Get-TestRunnerCredential

# Container client-services URL surfaced by the RunPipeline action. The local (BcContainerHelper-free)
# test runner connects directly to this URL, so RunTests itself makes no BcContainerHelper calls.
$serviceUrl = $ENV:containerServiceUrl

# NOTE: RunTestsInBcContainer is the seam for a custom test runner. By default the local AL test
# runner (Run-AlTests) is used against the container created by RunPipeline; a user who supplies a
# RunTestsInBcContainer override script gets a BcContainerHelper-compatible parameter hashtable
# instead, so existing overrides keep working.
$overrideParams = Get-ScriptOverrides -ALGoFolderName (Join-Path $projectPath ".AL-Go") -OverrideScriptNames @("RunTestsInBcContainer")
$runTestsOverride = $overrideParams['RunTestsInBcContainer']

# When no custom override is supplied, the local test runner connects to the build container via the
# service URL surfaced by RunPipeline. RunPipeline only surfaces that URL when it created and kept a
# container alive to run tests against (for example, it creates none when apps are not published). If
# no service URL is present there is no container to test against, so skip. A custom override manages
# its own connection and is therefore not subject to this check.
if ((-not $runTestsOverride) -and (-not $serviceUrl)) {
    Write-Host "No build container was kept alive for this project (RunPipeline surfaced no container service URL). Skipping test execution."
    return
}

# Only import the local test runner module when no custom override is supplied. Importing it loads
# the bundled BC client-services assemblies, which is unnecessary when the user runs their own runner.
if (-not $runTestsOverride) {
    Import-Module (Join-Path $PSScriptRoot '..\.Modules\TestRunner\ALTestRunner.psm1' -Resolve) -DisableNameChecking -Force
}

Invoke-AlGoTestRun `
    -settings $settings `
    -projectPath $projectPath `
    -containerName $containerName `
    -serviceUrl $serviceUrl `
    -credential $credential `
    -installTestAppsJson $installTestAppsJson `
    -runTestsOverride $runTestsOverride `
    -enableCodeCoverage ([bool]$settings.enableCodeCoverage) `
    -codeCoverageSetup $settings.codeCoverageSetup `
    -buildArtifactFolder (Join-Path $projectPath ".buildartifacts") `
    -baseFolder $baseFolder `
    -project $project `
    -projectDependenciesJson $projectDependenciesJson
