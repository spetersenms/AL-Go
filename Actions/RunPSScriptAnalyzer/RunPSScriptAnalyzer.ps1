param (
    [string]$Path,
    [string[]]$ExcludeRule,
    [string]$Recurse,
    [string]$Output
)

$analyzerModule = Get-Module -ListAvailable -Name PSScriptAnalyzer
if ($null -eq $analyzerModule) {
    Install-Module -Name PSScriptAnalyzer -Force
}

$sarifModule = Get-Module -ListAvailable -Name ConvertToSARIF
if ($null -eq $sarifModule) {
    Install-Module -Name ConvertToSARIF -Force
}
Import-Module -Name ConvertToSARIF -Force

$htPSA = [ordered]@{ Path = $Path }
Write-Output "Modules installed, now running tests."
if (![string]::IsNullOrEmpty($ExcludeRule)) { $htPSA.add('ExcludeRule', $ExcludeRule) }
if (![string]::IsNullOrEmpty($Recurse)) { $htPSA.add('Recurse', $true) }
$htCTS = [ordered]@{ FilePath = $Output }

$maxRetries = 3
$retryCount = 0
$success = $false

while (-not $success -and $retryCount -lt $maxRetries) {
    Try {
        Invoke-ScriptAnalyzer @htPSA -Verbose | ConvertTo-SARIF @htCTS
        $success = $true
    } Catch {
        Write-Host "::Error:: $_"
        $retryCount++
        Write-Output "Retrying... ($retryCount/$maxRetries)"
    }
}

if (-not $success) {
    Write-Host "::Error:: Failed after $maxRetries attempts."
    exit 1
}
