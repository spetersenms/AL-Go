<#
.SYNOPSIS
    Runs a single AL-Go action script in isolation, using parameters and environment reconstructed from a repro manifest.

.DESCRIPTION
    Invoke-ActionRepro is the Tier 1 reproduction harness used by the AL-Go issue triage agent, and
    usable standalone by maintainers.

    Given a repro manifest (see repro-manifest.schema.json) describing an action, its parameters, the
    AL-Go settings and the GitHub environment, this script:

      1. Validates the action name and resolves it inside the Actions folder.
      2. Checks the action against action-repro-policy.json and refuses classes that need BC
         containers, real secrets or live tenants unless -Force is supplied.
      3. Creates a scratch workspace and seeds any files named in the manifest.
      4. Sets the GITHUB_* and AL-Go environment variables the action expects, preserving and
         restoring whatever was there before.
      5. Invokes the action script, capturing all output streams and any terminating error.
      6. Parses the resulting GITHUB_OUTPUT and GITHUB_ENV files and returns a structured result.

    The action name in a manifest usually originates from an automated reading of an untrusted bug
    report, so it is treated as hostile input and validated against path traversal before use.

.PARAMETER Manifest
    Path to a repro manifest JSON file.

.PARAMETER InputObject
    A repro manifest supplied as a hashtable or PSCustomObject instead of a file.

.PARAMETER OutputPath
    Optional path to write the result as JSON. The result object is always returned regardless.

.PARAMETER WorkspacePath
    Optional scratch workspace to use. When omitted a temporary folder is created and removed again,
    unless -KeepWorkspace is supplied.

.PARAMETER KeepWorkspace
    Keep the scratch workspace after the run so its contents can be inspected.

.PARAMETER Force
    Allow actions classified as 'unsafe' in action-repro-policy.json to be invoked. These need BC
    containers, real secrets or live tenants, so this should only be used deliberately and locally.

.EXAMPLE
    ./Invoke-ActionRepro.ps1 -Manifest ./manifests/2285.json

.EXAMPLE
    ./Invoke-ActionRepro.ps1 -Manifest ./manifests/2285.json -OutputPath ./result.json -KeepWorkspace

.OUTPUTS
    A hashtable describing the invocation: whether it succeeded, the captured output, the parsed
    action outputs and environment, and any error that was thrown.
#>
[CmdletBinding(DefaultParameterSetName = 'FromFile')]
Param(
    [Parameter(Mandatory = $true, ParameterSetName = 'FromFile')]
    [string] $Manifest,

    [Parameter(Mandatory = $true, ParameterSetName = 'FromObject')]
    $InputObject,

    [Parameter(Mandatory = $false)]
    [string] $OutputPath = '',

    [Parameter(Mandatory = $false)]
    [string] $WorkspacePath = '',

    [switch] $KeepWorkspace,

    [switch] $Force
)

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

<#
.SYNOPSIS
    Converts a deserialized JSON object graph into nested hashtables.
.DESCRIPTION
    Kept local so the harness has no dependency on AL-Go-Helper.ps1 and can run standalone.
#>
function ConvertTo-ReproHashTable {
    Param(
        [Parameter(ValueFromPipeline)]
        $Object
    )

    Process {
        if ($null -eq $Object) {
            return $null
        }
        if ($Object -is [System.Collections.IDictionary]) {
            $result = @{}
            foreach ($key in @($Object.Keys)) {
                $result[$key] = ConvertTo-ReproHashTable -Object $Object[$key]
            }
            return $result
        }
        if ($Object -is [System.Management.Automation.PSCustomObject]) {
            $result = @{}
            foreach ($property in $Object.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-ReproHashTable -Object $property.Value
            }
            return $result
        }
        if ($Object -is [System.Array]) {
            # The unary comma is load-bearing: without it a function returning an empty array
            # yields $null, and a single-element array unrolls to its element. Settings values such
            # as appFolders hit this.
            $items = @()
            foreach ($item in $Object) {
                $items += , (ConvertTo-ReproHashTable -Object $item)
            }
            return , $items
        }
        return $Object
    }
}

<#
.SYNOPSIS
    Returns the value for a key, or a default when the key is absent.
.DESCRIPTION
    Strict mode makes direct indexing of a missing key an error, so manifest reads go through this.
#>
function Get-ReproValue {
    Param(
        [hashtable] $Table,
        [string] $Key,
        $Default = $null
    )

    if ($Table -and $Table.ContainsKey($Key) -and $null -ne $Table[$Key]) {
        return $Table[$Key]
    }
    return $Default
}

<#
.SYNOPSIS
    Throws unless the resolved path sits inside the supplied root folder.
.DESCRIPTION
    Guards against path traversal in manifest-supplied names and relative file paths, which may have
    been derived from an untrusted bug report.
#>
function Assert-PathWithinRoot {
    Param(
        [string] $Path,
        [string] $Root,
        [string] $Description
    )

    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullRoot.EndsWith($separator)) {
        $fullRoot = "$fullRoot$separator"
    }
    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description resolves outside the permitted root. Path traversal is not allowed."
    }
    return $fullPath
}

<#
.SYNOPSIS
    Parses a GitHub Actions key/value file, supporting both simple and heredoc delimited entries.
#>
function Read-GitHubKeyValueFile {
    Param(
        [string] $Path
    )

    $result = @{}
    if (-not $Path -or -not (Test-Path -Path $Path)) {
        return $result
    }

    $lines = @(Get-Content -Path $Path -Encoding UTF8 -ErrorAction SilentlyContinue)
    $index = 0
    while ($index -lt $lines.Count) {
        $line = $lines[$index]
        if ($line -match '^([^=<]+)<<(.+)$') {
            $key = $matches[1]
            $delimiter = $matches[2]
            $index++
            $buffer = @()
            while ($index -lt $lines.Count -and $lines[$index] -ne $delimiter) {
                $buffer += $lines[$index]
                $index++
            }
            $result[$key] = ($buffer -join "`n")
        }
        elseif ($line -match '^([^=]+)=(.*)$') {
            $result[$matches[1]] = $matches[2]
        }
        $index++
    }
    return $result
}

<#
.SYNOPSIS
    Replaces known secret values in a string with a fixed placeholder.
#>
function Hide-SecretValues {
    Param(
        [string] $Text,
        [string[]] $SecretValues
    )

    if (-not $Text) {
        return $Text
    }
    foreach ($secretValue in $SecretValues) {
        if ($secretValue -and $secretValue.Length -ge 4) {
            $Text = $Text.Replace($secretValue, '***')
        }
    }
    return $Text
}

# --- Load and validate the manifest -----------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'FromFile') {
    if (-not (Test-Path -Path $Manifest)) {
        throw "Repro manifest not found: $Manifest"
    }
    $manifestJson = Get-Content -Path $Manifest -Raw -Encoding UTF8
    $manifestData = ConvertTo-ReproHashTable -Object ($manifestJson | ConvertFrom-Json)
}
else {
    $manifestData = ConvertTo-ReproHashTable -Object $InputObject
}

if (-not $manifestData -or -not ($manifestData -is [hashtable])) {
    throw "The repro manifest could not be read as an object."
}

$actionName = Get-ReproValue -Table $manifestData -Key 'action' -Default ''
if (-not $actionName) {
    throw "The repro manifest does not specify an action."
}
if ($actionName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Invalid action name '$actionName'. Action names must not contain path separators."
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '..'))
$actionsRoot = Join-Path $repoRoot 'Actions'
$actionFolder = Assert-PathWithinRoot -Path (Join-Path $actionsRoot $actionName) -Root $actionsRoot -Description "Action '$actionName'"

if (-not (Test-Path -Path $actionFolder -PathType Container)) {
    throw "Unknown action '$actionName'. No such folder under Actions."
}

$actionScript = $null
$requestedScript = Get-ReproValue -Table $manifestData -Key 'script' -Default ''
if ($requestedScript) {
    if ($requestedScript -notmatch '^[A-Za-z0-9._-]+\.ps1$') {
        throw "Invalid script name '$requestedScript'. It must be a plain .ps1 file name within the action folder."
    }
    $actionScript = Assert-PathWithinRoot -Path (Join-Path $actionFolder $requestedScript) -Root $actionFolder -Description "Script '$requestedScript'"
    if (-not (Test-Path -Path $actionScript -PathType Leaf)) {
        throw "Action '$actionName' has no script named '$requestedScript'."
    }
}
else {
    # Most actions use <Name>.ps1, a few use <Name>.Action.ps1, and a few have a single
    # differently named entry script. Anything more ambiguous must be named explicitly.
    foreach ($candidate in @("$actionName.ps1", "$actionName.Action.ps1")) {
        $candidatePath = Join-Path $actionFolder $candidate
        if (Test-Path -Path $candidatePath -PathType Leaf) {
            $actionScript = $candidatePath
            break
        }
    }
    if (-not $actionScript) {
        $scripts = @(Get-ChildItem -Path $actionFolder -Filter '*.ps1' -File)
        if ($scripts.Count -eq 1) {
            $actionScript = $scripts[0].FullName
        }
        elseif ($scripts.Count -eq 0) {
            throw "Action '$actionName' has no PowerShell entry script and cannot be reproduced directly."
        }
        else {
            $names = ($scripts | Select-Object -ExpandProperty Name) -join ', '
            throw "Action '$actionName' has multiple candidate scripts ($names). Set 'script' in the manifest to choose one."
        }
    }
}

# --- Apply the repro policy -------------------------------------------------------------------

$policyPath = Join-Path $PSScriptRoot 'action-repro-policy.json'
$policy = ConvertTo-ReproHashTable -Object ((Get-Content -Path $policyPath -Raw -Encoding UTF8) | ConvertFrom-Json)
$policyActions = Get-ReproValue -Table $policy -Key 'actions' -Default @{}
$actionClass = Get-ReproValue -Table $policyActions -Key $actionName -Default 'unknown'

if ($actionClass -eq 'unsafe' -and -not $Force) {
    throw "Action '$actionName' is classified as 'unsafe' and needs BC containers, real secrets or a live tenant. Re-run with -Force only if you understand the consequences."
}
if ($actionClass -eq 'unknown') {
    Write-Host "::Warning::Action '$actionName' is not classified in action-repro-policy.json. Treating it as best effort."
}

# --- Prepare the scratch workspace ------------------------------------------------------------

$createdWorkspace = $false
if ($WorkspacePath) {
    $workspace = [System.IO.Path]::GetFullPath($WorkspacePath)
    if (-not (Test-Path -Path $workspace)) {
        New-Item -Path $workspace -ItemType Directory -Force | Out-Null
        $createdWorkspace = $true
    }
}
else {
    $workspace = Join-Path ([System.IO.Path]::GetTempPath()) "algo-repro-$([Guid]::NewGuid().ToString('N'))"
    New-Item -Path $workspace -ItemType Directory -Force | Out-Null
    $createdWorkspace = $true
}

$files = Get-ReproValue -Table $manifestData -Key 'files' -Default @{}
foreach ($relativePath in @($files.Keys)) {
    $targetPath = Assert-PathWithinRoot -Path (Join-Path $workspace $relativePath) -Root $workspace -Description "Seeded file '$relativePath'"
    $targetFolder = Split-Path -Path $targetPath -Parent
    if (-not (Test-Path -Path $targetFolder)) {
        New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
    }
    Set-Content -Path $targetPath -Value ([string]$files[$relativePath]) -Encoding UTF8 -NoNewline
}

$outputFile = Join-Path $workspace '_github_output'
$envFile = Join-Path $workspace '_github_env'
$stepSummaryFile = Join-Path $workspace '_github_step_summary'
foreach ($file in @($outputFile, $envFile, $stepSummaryFile)) {
    Set-Content -Path $file -Value '' -Encoding UTF8 -NoNewline
}

# --- Build the environment --------------------------------------------------------------------

$settings = Get-ReproValue -Table $manifestData -Key 'settings' -Default @{}
$secrets = Get-ReproValue -Table $manifestData -Key 'secrets' -Default @{}
$secretValues = @(@($secrets.Values) | Where-Object { $_ -is [string] })

$environment = @{
    'GITHUB_WORKSPACE'    = $workspace
    'GITHUB_OUTPUT'       = $outputFile
    'GITHUB_ENV'          = $envFile
    'GITHUB_STEP_SUMMARY' = $stepSummaryFile
    'GITHUB_REPOSITORY'   = 'microsoft/AL-Go'
    'GITHUB_API_URL'      = 'https://api.github.com'
    'GITHUB_SERVER_URL'   = 'https://github.com'
    'GITHUB_REF_NAME'     = 'main'
    'GITHUB_EVENT_NAME'   = 'workflow_dispatch'
    'GITHUB_RUN_ID'       = '1'
    'GITHUB_RUN_NUMBER'   = '1'
    'GITHUB_RUN_ATTEMPT'  = '1'
    'GITHUB_ACTOR'        = 'al-go-repro'
    'RUNNER_TEMP'         = $workspace
    'Settings'            = (ConvertTo-Json -InputObject $settings -Depth 99 -Compress)
    'Secrets'             = (ConvertTo-Json -InputObject $secrets -Depth 99 -Compress)
}

$manifestEnv = Get-ReproValue -Table $manifestData -Key 'env' -Default @{}
foreach ($key in @($manifestEnv.Keys)) {
    $environment[$key] = [string]$manifestEnv[$key]
}

$previousEnvironment = @{}
foreach ($key in @($environment.Keys)) {
    $previousEnvironment[$key] = [System.Environment]::GetEnvironmentVariable($key)
}

# --- Invoke the action ------------------------------------------------------------------------

$parameters = @{}
$manifestParameters = Get-ReproValue -Table $manifestData -Key 'parameters' -Default @{}
foreach ($key in @($manifestParameters.Keys)) {
    $parameters[$key] = $manifestParameters[$key]
}

$result = @{
    action       = $actionName
    actionClass  = $actionClass
    issue        = Get-ReproValue -Table $manifestData -Key 'issue' -Default $null
    reported     = Get-ReproValue -Table $manifestData -Key 'reported' -Default ''
    expected     = Get-ReproValue -Table $manifestData -Key 'expected' -Default ''
    parameters   = $parameters
    succeeded    = $false
    error        = $null
    errorType    = $null
    output       = @()
    outputs      = @{}
    environment  = @{}
    stepSummary  = ''
    durationMs   = 0
    workspace    = $workspace
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Push-Location -Path $workspace
try {
    foreach ($key in @($environment.Keys)) {
        [System.Environment]::SetEnvironmentVariable($key, $environment[$key])
    }

    $captured = @()
    try {
        $captured = @(& $actionScript @parameters *>&1)
        $result.succeeded = $true
    }
    catch {
        $result.succeeded = $false
        $result.error = $_.Exception.Message
        $result.errorType = $_.Exception.GetType().FullName
    }

    $result.output = @($captured | ForEach-Object { Hide-SecretValues -Text ([string]$_) -SecretValues $secretValues })
    $result.outputs = Read-GitHubKeyValueFile -Path $outputFile
    $result.environment = Read-GitHubKeyValueFile -Path $envFile
    if (Test-Path -Path $stepSummaryFile) {
        $result.stepSummary = Hide-SecretValues -Text ((Get-Content -Path $stepSummaryFile -Raw -Encoding UTF8)) -SecretValues $secretValues
    }
    if ($result.error) {
        $result.error = Hide-SecretValues -Text $result.error -SecretValues $secretValues
    }
}
finally {
    Pop-Location
    foreach ($key in @($previousEnvironment.Keys)) {
        [System.Environment]::SetEnvironmentVariable($key, $previousEnvironment[$key])
    }
    $stopwatch.Stop()
    $result.durationMs = [int]$stopwatch.ElapsedMilliseconds

    if ($createdWorkspace -and -not $KeepWorkspace) {
        Remove-Item -Path $workspace -Recurse -Force -ErrorAction SilentlyContinue
        $result.workspace = ''
    }
}

if ($OutputPath) {
    $outputFolder = Split-Path -Path $OutputPath -Parent
    if ($outputFolder -and -not (Test-Path -Path $outputFolder)) {
        New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
    }
    ConvertTo-Json -InputObject $result -Depth 99 | Set-Content -Path $OutputPath -Encoding UTF8
}

Write-Host "Action        : $actionName ($actionClass)"
Write-Host "Succeeded     : $($result.succeeded)"
Write-Host "Duration (ms) : $($result.durationMs)"
if ($result.error) {
    Write-Host "Error         : $($result.error)"
}

return $result
