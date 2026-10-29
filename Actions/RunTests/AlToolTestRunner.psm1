<#
.SYNOPSIS
    Executes tests with AlTool and preserves its native JSON response.

.DESCRIPTION
    This is the default RunTests executor when no RunTestsInBcContainer override is supplied.
    BcContainerHelper provides app metadata, container configuration, company discovery, and test
    enumeration. AlTool runs each app's enabled methods as one batch with per-app metadata.
#>

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot '..\AL-Go-Helper.ps1' -Resolve)
Import-Module (Join-Path $PSScriptRoot '..\.Modules\AlToolHelper.psm1' -Resolve) -DisableNameChecking -Force

<#
.SYNOPSIS
    Matches all native occurrences to requested methods and reports missing results as failures.
.DESCRIPTION
    Use this helper in native runner overrides to populate each codeunit's metadata results.
    It does not execute tests, modify native records, or write files.
.PARAMETER RequestedMethods
    Enabled method names sent to AlTool for one codeunit.
.PARAMETER MethodResults
    Verified native result occurrences belonging to the codeunit.
.OUTPUTS
    Matched native records, including failures for requested methods with no result.
#>
function Get-AlToolTestMethodResults {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $RequestedMethods,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $MethodResults
    )

    $resultsByMethod = @{}
    foreach ($method in $RequestedMethods) { $resultsByMethod[$method] = @() }
    foreach ($result in $MethodResults) {
        $name = "$($result.methodName)"
        if ($resultsByMethod.ContainsKey($name)) {
            $resultsByMethod[$name] += $result
        }
        elseif ($name -match '^([^\[]+)\[(.+)\]$' -and $resultsByMethod.ContainsKey($Matches[1])) {
            $resultsByMethod[$Matches[1]] += $result
        }
    }
    foreach ($method in $RequestedMethods) {
        if ($resultsByMethod[$method].Count -gt 0) {
            $resultsByMethod[$method]
        }
        else {
            @{
                methodName = $method
                status = 'failed'
                durationMs = [long]0
                output = 'No result produced by al runtests'
            }
        }
    }
}

<#
.SYNOPSIS
    Resolves the on-prem connection settings (server URL, instance, dev-service port) for a container.
.DESCRIPTION
    Reads the container server configuration required by AlTool and falls back to conventional
    defaults when it is unavailable.
.PARAMETER ContainerName
    The name of the build container.
.OUTPUTS
    [hashtable] @{ Server; ServerInstance; Port }
#>
function Get-AlToolConnection {
    param(
        [Parameter(Mandatory = $true)][string] $ContainerName
    )

    $server = "http://$ContainerName"
    $instance = "BC"
    $port = 7049

    try {
        $config = Get-BcContainerServerConfiguration -ContainerName $ContainerName
        if ($config) {
            if ($config.ServerInstance) { $instance = "$($config.ServerInstance)" }
            if ($config.DeveloperServicesPort) { $port = [int]$config.DeveloperServicesPort }
        }
    }
    catch {
        Write-Host "WARNING: Could not read server configuration for '$ContainerName' ($($_.Exception.Message)). Falling back to $server/${instance}:$port."
    }

    return @{ Server = $server; ServerInstance = $instance; Port = $port }
}

<#
.SYNOPSIS
    Resolves the company `al runtests` should target.
.DESCRIPTION
    Uses an explicitly requested company or selects a container company, preferring an evaluation
    company.
.PARAMETER ContainerName
    The name of the build container.
.PARAMETER Tenant
    The tenant to connect to.
.PARAMETER CompanyName
    The company name requested by the caller (optional).
.OUTPUTS
    [string] Company name, or empty string if none could be resolved.
#>
function Get-AlToolCompany {
    param(
        [Parameter(Mandatory = $true)][string] $ContainerName,
        [Parameter(Mandatory = $true)][string] $Tenant,
        [string] $CompanyName = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($CompanyName)) {
        return $CompanyName
    }

    try {
        $companies = @(Get-CompanyInBcContainer -containerName $ContainerName -tenant $Tenant)
        if ($companies.Count -gt 0) {
            $preferred = $companies | Where-Object { $_.evaluationCompany -eq $true } | Select-Object -First 1
            $company = if ($preferred) { $preferred.companyName } else { $companies[0].companyName }
            return "$company"
        }
    }
    catch {
        Write-Host "WARNING: Could not enumerate companies for '$ContainerName' ($($_.Exception.Message))."
    }
    return ""
}

<#
.SYNOPSIS
    Builds case-insensitive disabled-method and disabled-codeunit lookups.
.DESCRIPTION
    A `*` method disables the complete codeunit instead of a method named `*`.
.PARAMETER DisabledTests
    Array of disabled-test hashtables.
.OUTPUTS
    [hashtable] @{ Methods = <set of "<codeunitname>::<method>">; Codeunits = <set of "<codeunitname>"> }
#>
function Get-DisabledTestKeySet {
    param(
        [AllowEmptyCollection()][hashtable[]] $DisabledTests = @()
    )

    $methodSet = @{}
    $codeunitSet = @{}
    foreach ($entry in $DisabledTests) {
        if (-not $entry) { continue }
        $cuName = "$($entry['codeunitName'])".ToLowerInvariant()
        $methods = @()
        if ($entry.ContainsKey('method') -and $entry['method']) { $methods = @($entry['method']) }
        foreach ($m in $methods) {
            if ("$m" -eq '*') {
                $codeunitSet[$cuName] = $true
            }
            else {
                $methodSet["$cuName::$("$m".ToLowerInvariant())"] = $true
            }
        }
    }
    return @{ Methods = $methodSet; Codeunits = $codeunitSet }
}

<#
.SYNOPSIS
    Enumerates enabled test methods for an app in the container.
.DESCRIPTION
    Removes configured disabled methods and codeunits before AlTool execution.
.PARAMETER ContainerName
    Container whose tests are enumerated.
.PARAMETER Credential
    Credential used to access the container.
.PARAMETER ExtensionId
    App ID whose test codeunits are enumerated.
.PARAMETER Tenant
    Tenant used for test enumeration.
.PARAMETER TestType
    Optional platform test type. Supported values are UnitTest, IntegrationTest, and Uncategorized.
    Blank enumerates all test types.
.PARAMETER DisabledTests
    Hashtable entries describing test methods or codeunits excluded from the run.
.OUTPUTS
    [object[]] Codeunit objects with .Id, .Name, .Tests (enabled method name array).
#>
function Get-AlToolTestCodeunits {
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $ContainerName,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential] $Credential,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $ExtensionId,
        [string] $Tenant = "default",
        [string] $TestType = "",
        [AllowEmptyCollection()][hashtable[]] $DisabledTests = @()
    )

    $getTestsParams = @{
        containerName = $ContainerName
        tenant        = $Tenant
        credential    = $Credential
        extensionId   = $ExtensionId
        ignoreGroups  = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($TestType)) {
        $supportedTestTypes = @("UnitTest", "IntegrationTest", "Uncategorized")
        $matchingTestType = @($supportedTestTypes | Where-Object { $_ -eq $TestType })
        if ($matchingTestType.Count -eq 0) {
            throw "Unsupported testType '$TestType' for the built-in AlTool runner. Supported values are UnitTest, IntegrationTest, Uncategorized, or blank."
        }
        $getTestsParams["testType"] = $matchingTestType[0]
    }

    $codeunits = @(Get-TestsFromBcContainer @getTestsParams)

    $disabledMethods = @{}
    $disabledCodeunits = @{}
    if ($DisabledTests.Count -gt 0) {
        $lookup = Get-DisabledTestKeySet -DisabledTests $DisabledTests
        $disabledMethods = $lookup.Methods
        $disabledCodeunits = $lookup.Codeunits
    }

    $result = @()
    $disabledCount = 0
    foreach ($cu in $codeunits) {
        $cuNameLower = "$($cu.Name)".ToLowerInvariant()
        $methods = @($cu.Tests | ForEach-Object { "$_" })

        if ($disabledCodeunits.ContainsKey($cuNameLower)) {
            $disabledCount += $methods.Count
            continue
        }

        if ($disabledMethods.Count -gt 0) {
            $enabled = @($methods | Where-Object { -not $disabledMethods.ContainsKey("$cuNameLower::$("$_".ToLowerInvariant())") })
            $disabledCount += ($methods.Count - $enabled.Count)
            $methods = $enabled
        }
        if ($methods.Count -gt 0) {
            $result += [PSCustomObject]@{ Id = $cu.Id; Name = $cu.Name; Tests = $methods }
        }
    }

    if ($disabledCount -gt 0) {
        Write-Host "Excluded $disabledCount disabled test method(s) from altool enumeration."
    }
    return @($result)
}

<#
.SYNOPSIS
    Creates an AlTool test-groups input file.
.DESCRIPTION
    Writes the JSON file required by `al runtests --testgroups`, containing each codeunit and its
    enabled test methods.
.PARAMETER Codeunits
    Codeunits with Id and Tests properties to serialize.
.OUTPUTS
    [string] Path to the temporary JSON file.
.EXAMPLE
    $codeunits = @([pscustomobject]@{ Id = "130001"; Tests = @("TestOne", "TestTwo") })
    New-AlTestGroupsFile -Codeunits $codeunits

    # Generated JSON:
    # [{ "codeunitId": 130001, "testMethods": ["TestOne", "TestTwo"] }]
#>
function New-AlTestGroupsFile {
    param(
        [Parameter(Mandatory = $true)][object[]] $Codeunits
    )

    $groups = @()
    foreach ($codeunit in $Codeunits) {
        $codeunitIdText = "$($codeunit.Id)"
        [int] $codeunitId = 0
        if ([string]::IsNullOrWhiteSpace($codeunitIdText) -or
            -not [int]::TryParse(
                $codeunitIdText,
                [System.Globalization.NumberStyles]::Integer,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref] $codeunitId
            )) {
            throw "Test codeunit ID '$codeunitIdText' must be a valid Int32 value."
        }

        $methods = @($codeunit.Tests | ForEach-Object { "$_" })
        $groups += [ordered]@{
            codeunitId  = $codeunitId
            testMethods = [string[]] $methods
        }
    }

    $testGroupsFile = Join-Path (Get-Location).Path "altool-testgroups-$([Guid]::NewGuid().ToString('N')).json"
    ConvertTo-Json -InputObject @($groups) -Depth 5 -Compress |
        Set-Content -LiteralPath $testGroupsFile -Encoding UTF8
    return $testGroupsFile
}

<#
.SYNOPSIS
    Verifies the native al runtests response without reshaping its results.
.PARAMETER Response
    Deserialized native ToolResponse.
#>
function Verify-AlTestGroupsOutput {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Named for native AlTool output verification.')]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object] $Response)

    if ($Response -isnot [hashtable] -or -not $Response.ContainsKey('succeeded') -or $Response.succeeded -isnot [bool]) {
        throw "The structured response does not contain a valid Boolean ToolResponse succeeded value."
    }
    $entries = @()
    $hasResults = $false
    if ($Response.ContainsKey('data') -and $null -ne $Response.data) {
        if ($Response.data -isnot [hashtable]) {
            throw "The structured response contains an invalid ToolResponse data object."
        }
        if ($Response.data.ContainsKey('results')) {
            if ($Response.data.results -isnot [array]) {
                throw "The structured response contains a ToolResponse data.results value that is not an array."
            }
            $entries = @($Response.data.results)
            $hasResults = $true
        }
    }
    if ($Response.succeeded -and -not $hasResults) {
        throw "The successful structured response does not contain a ToolResponse data.results array."
    }
    foreach ($entry in $entries) {
        if ($entry -isnot [hashtable]) {
            throw "The structured response contains an invalid test result object."
        }
        foreach ($property in @('codeunitId', 'methodName', 'status', 'durationMs')) {
            if (-not $entry.ContainsKey($property)) {
                throw "The structured test result is missing '$property'."
            }
        }
        [int] $codeunitId = 0
        [long] $durationMs = 0
        if ($entry.ContainsKey('output') -and $null -ne $entry.output -and $entry.output -isnot [string]) {
            throw 'The structured response contains invalid test output.'
        }
        if (-not [int]::TryParse("$($entry.codeunitId)", [ref]$codeunitId) -or $codeunitId -lt 0 -or
            -not [long]::TryParse("$($entry.durationMs)", [ref]$durationMs) -or $durationMs -lt 0 -or
            $entry.methodName -isnot [string] -or $entry.status -isnot [string]) {
            throw "The structured response contains invalid test result fields."
        }
        if ($entry.status -notin @('passed', 'failed', 'skipped')) {
            throw "Result $codeunitId/$($entry.methodName) has unknown status '$($entry.status)'."
        }
        if ([string]::IsNullOrWhiteSpace($entry.methodName) -and -not ($codeunitId -eq 0 -and $entry.status -eq 'skipped')) {
            throw "Result $codeunitId has a blank method name."
        }
    }
}

<#
.SYNOPSIS
    Runs all enabled test groups for one app through one AlTool connection.
.DESCRIPTION
    Preserves native output and execution state even when structured response validation fails.
.PARAMETER TestResultsPath
    Required per-app folder initialized by Invoke-AlToolTestRun for native results.
.PARAMETER Metadata
    Current app metadata, updated with matched results, execution state, and the process exit code.
.OUTPUTS
    Overall success and elapsed execution time.
#>
function Invoke-AlRunTestsBatch {
    param(
        [Parameter(Mandatory = $true)][string] $AlToolPath,
        [Parameter(Mandatory = $true)][object[]] $Codeunits,
        [Parameter(Mandatory = $true)][string] $Company,
        [Parameter(Mandatory = $true)][string] $Tenant,
        [Parameter(Mandatory = $true)][hashtable] $Connection,
        [Parameter(Mandatory = $true)][string] $TestResultsPath,
        [Parameter(Mandatory = $true)][hashtable] $Metadata
    )

    $metadataPath = Join-Path $TestResultsPath 'metadata.json'
    $responsePath = Join-Path $TestResultsPath 'response.json'
    $testGroupsFile = $null
    $testRunError = $null
    $results = @()
    try {
        $testGroupsFile = New-AlTestGroupsFile -Codeunits $Codeunits
        $alArgs = @(
            'runtests',
            '--testgroups', $testGroupsFile,
            '--company', $Company,
            '--server', $Connection.Server,
            '--serverinstance', $Connection.ServerInstance,
            '--port', "$($Connection.Port)",
            '--environmenttype', 'OnPrem',
            '--authentication', 'UserPassword',
            '--tenant', $Tenant
        )

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $metadata.attempted = $true
        $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
        $nativeResult = Invoke-AlNativeCommand -FilePath $AlToolPath -ArgumentList $alArgs
        $sw.Stop()

        $metadata.exitCode = $nativeResult.ExitCode
        ($nativeResult.StandardOutput -join [Environment]::NewLine) |
            Set-Content -LiteralPath $responsePath -Encoding UTF8 -NoNewline
        $standardOutputText = ($nativeResult.StandardOutput -join [Environment]::NewLine).Trim()
        $standardErrorText = ($nativeResult.StandardError -join [Environment]::NewLine).Trim()
        if (-not [string]::IsNullOrWhiteSpace($standardErrorText)) {
            OutputDebug -message "al runtests stderr:$([Environment]::NewLine)$standardErrorText"
        }

        if ($nativeResult.ExitCode -notin @(0, 1)) {
            $details = @("al runtests exited with unexpected code $($nativeResult.ExitCode).")
            if (-not [string]::IsNullOrWhiteSpace($standardErrorText)) {
                $details += "stderr: $standardErrorText"
            }
            if (-not [string]::IsNullOrWhiteSpace($standardOutputText)) {
                $details += "stdout: $standardOutputText"
            }
            throw "AlTool process failure. $($details -join [Environment]::NewLine)"
        }

        if ([string]::IsNullOrWhiteSpace($standardOutputText)) {
            if (-not [string]::IsNullOrWhiteSpace($standardErrorText)) {
                throw "al runtests failed: $standardErrorText (exit code $($nativeResult.ExitCode))."
            }
            throw "al runtests returned no structured stdout or stderr (exit code $($nativeResult.ExitCode))."
        }

        try {
            $response = ($nativeResult.StandardOutput -join [Environment]::NewLine) |
                ConvertFrom-Json | ConvertTo-HashTable -recurse
            Verify-AlTestGroupsOutput -Response $response
            $metadata.verified = $true
        }
        catch {
            $details = @($_.Exception.Message, "stdout: $standardOutputText")
            if (-not [string]::IsNullOrWhiteSpace($standardErrorText)) {
                $details += "stderr: $standardErrorText"
            }
            throw "AlTool protocol failure. $($details -join [Environment]::NewLine)"
        }

        if ($response.ContainsKey('data') -and $response.data -and $response.data.ContainsKey('results')) {
            $results = @($response.data.results)
        }
        if (-not $response.succeeded -and $results.Count -eq 0) {
            $details = @()
            $message = ''
            if ($response.ContainsKey('message') -and $response.message -is [string]) {
                $message = $response.message
            }
            if (-not [string]::IsNullOrWhiteSpace($message)) {
                $details += $message
            }
            if (-not [string]::IsNullOrWhiteSpace($standardErrorText) -and
                -not [string]::Equals($standardErrorText, $message, [StringComparison]::OrdinalIgnoreCase)) {
                $details += "stderr: $standardErrorText"
            }
            if ($details.Count -eq 0) {
                $details += "No failure message or stderr was returned."
            }
            throw "al runtests failed: $($details -join [Environment]::NewLine)"
        }

        return @{
            Succeeded = [bool] ($response.succeeded -and ($nativeResult.ExitCode -eq 0))
            ElapsedSec = [Math]::Round($sw.Elapsed.TotalSeconds, 3)
        }
    }
    catch {
        $testRunError = $_
        throw
    }
    finally {
        try {
            $resultsByCodeunit = @{}
            if ($results.Count -gt 0) {
                $resultsByCodeunit = $results | Group-Object -Property { "$([int]$_.codeunitId)" } -AsHashTable -AsString
            }
            foreach ($codeunit in $metadata.codeunits) {
                $methodResults = $resultsByCodeunit["$($codeunit.id)"]
                if ($null -eq $methodResults) { $methodResults = @() }
                $codeunit.results = @(Get-AlToolTestMethodResults -RequestedMethods $codeunit.methods -MethodResults $methodResults)
            }
            $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
        }
        catch {
            if ($testRunError) {
                OutputWarning -message "The test run failed and its metadata could not be saved. $($_.Exception.Message)"
            }
            else {
                throw
            }
        }
        finally {
            if ($testGroupsFile) {
                Remove-Item -LiteralPath $testGroupsFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

<#
.SYNOPSIS
    Runs a single app's test codeunits and preserves the native AlTool response.
.DESCRIPTION
    Runs the app in one test-groups batch and stores metadata and stdout in an app-specific folder.
.PARAMETER ContainerName
    Container hosting the app under test.
.PARAMETER Credential
    Credential used to run tests.
.PARAMETER ExtensionId
    App ID whose tests are executed.
.PARAMETER AppName
    Optional app name included in logs and metadata.
.PARAMETER CompanyName
    Company used for the test run. The container default is used when omitted.
.PARAMETER Tenant
    Tenant used for container discovery and AlTool execution.
.PARAMETER TestType
    Optional platform test type used by BcContainerHelper for server-side test enumeration. Supported
    values are UnitTest, IntegrationTest, and Uncategorized. Blank enumerates all test types.
.PARAMETER DisabledTests
    Hashtable entries describing test methods or codeunits excluded from the run.
.PARAMETER AlToolPath
    Full path to the AlTool executable. The shared helper resolves it when omitted.
.PARAMETER TestResultsPath
    Required root folder for native results, normally AlToolTestResults.
.OUTPUTS
    [bool] $true if all executed methods passed; $false otherwise.
#>
function Invoke-AlToolTestRun {
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $ContainerName,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential] $Credential,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $ExtensionId,
        [string] $AppName = "",
        [string] $CompanyName = "",
        [string] $Tenant = "default",
        [string] $TestType = "",
        [AllowEmptyCollection()][hashtable[]] $DisabledTests = @(),
        [string] $AlToolPath = "",
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $TestResultsPath
    )

    $appId = [guid]::Empty
    if (-not [guid]::TryParse($ExtensionId, [ref]$appId)) {
        throw "Invoke-AlToolTestRun requires a valid GUID ExtensionId."
    }
    $ExtensionId = $appId.ToString('D')
    if ([string]::IsNullOrWhiteSpace($TestResultsPath)) {
        throw "Invoke-AlToolTestRun requires a nonblank TestResultsPath."
    }
    if ([string]::IsNullOrWhiteSpace($Tenant)) {
        $Tenant = "default"
    }

    $metadata = $null
    try {
        $appResultsPath = Join-Path $TestResultsPath $ExtensionId
        New-Item -ItemType Directory -Path $appResultsPath -Force | Out-Null
        $metadataPath = Join-Path $appResultsPath 'metadata.json'
        $responsePath = Join-Path $appResultsPath 'response.json'
        if (Test-Path -LiteralPath $responsePath) { Remove-Item -LiteralPath $responsePath -Force }
        $metadata = @{
            appId = $ExtensionId
            appName = $AppName
            codeunits = @()
            enumerated = $false
            attempted = $false
            verified = $false
            exitCode = $null
        }
        $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
        $env:BC_SERVER_USERNAME = $Credential.UserName
        $env:BC_SERVER_PASSWORD = $Credential.GetNetworkCredential().Password

        $codeunits = @(Get-AlToolTestCodeunits -ContainerName $ContainerName -Credential $Credential `
                -ExtensionId $ExtensionId -Tenant $Tenant -TestType $TestType -DisabledTests $DisabledTests)
        $metadata.codeunits = @($codeunits | ForEach-Object {
                @{ id = [int]$_.Id; name = "$($_.Name)"; methods = @($_.Tests | ForEach-Object { "$_" }) }
            })
        $metadata.enumerated = $true
        $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
        Write-Host "Enumerated $($codeunits.Count) test codeunit(s) for app '$AppName'."
        if ($codeunits.Count -eq 0) {
            Write-Host "No test codeunits to run for app '$AppName'; nothing to do."
            return $true
        }

        if ([string]::IsNullOrWhiteSpace($AlToolPath)) {
            $AlToolPath = GetAlToolPath
        }

        $connection = Get-AlToolConnection -ContainerName $ContainerName
        $company = Get-AlToolCompany -ContainerName $ContainerName -Tenant $Tenant -CompanyName $CompanyName
        if ([string]::IsNullOrWhiteSpace($company)) {
            throw "Could not resolve a company to run tests against in container '$ContainerName'."
        }

        Write-Host "altool run: app='$AppName' extensionId=$ExtensionId company='$company' server='$($connection.Server)' instance='$($connection.ServerInstance)' port=$($connection.Port) tenant='$Tenant'"

        $batch = Invoke-AlRunTestsBatch -AlToolPath $AlToolPath -Codeunits $codeunits -Company $company `
            -Tenant $Tenant -Connection $connection -TestResultsPath $appResultsPath -Metadata $metadata
        $allPassed = [bool] $batch.Succeeded

        $idx = 0
        foreach ($cu in $metadata.codeunits) {
            $idx++
            $failed = @($cu.results | Where-Object { $_.status -eq 'failed' }).Count

            if ($failed -gt 0) { $allPassed = $false }

            Write-Host ("[{0}/{1}] cu {2} '{3}' -> {4} failed result(s) from {5} requested method(s)" -f `
                    $idx, $codeunits.Count, $cu.id, $cu.name, $failed, $cu.methods.Count)
        }
        Write-Host ("Run for app '{0}': {1} codeunit(s) in {2}s real al wall-clock." -f `
                $AppName, $codeunits.Count, [Math]::Round([double] $batch.ElapsedSec, 2))

        Write-Host "Wrote native AlTool results for app '$AppName' to $appResultsPath"

        return $allPassed
    }
    catch {
        $testRunError = $_
        try {
            $metadataChanged = $false
            if ($metadata) {
                foreach ($codeunit in $metadata.codeunits) {
                    if (-not $codeunit.ContainsKey('results')) {
                        $codeunit.results = @(Get-AlToolTestMethodResults -RequestedMethods $codeunit.methods -MethodResults @())
                        $metadataChanged = $true
                    }
                }
                if ($metadataChanged) {
                    $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
                }
            }
        }
        catch {
            OutputWarning -message "The test run failed and its metadata could not be saved. $($_.Exception.Message)"
        }
        throw $testRunError
    }
    finally {
        # Do not retain container credentials after the run.
        Remove-Item Env:\BC_SERVER_USERNAME -ErrorAction SilentlyContinue
        Remove-Item Env:\BC_SERVER_PASSWORD -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Invoke-AlToolTestRun, Get-AlToolTestMethodResults
