<#
.SYNOPSIS
    Verifies that the labels the AL-Go issue triage agent may apply exist on a repository.

.DESCRIPTION
    The agent reuses AL-Go's existing label vocabulary rather than introducing a parallel one, so
    on microsoft/AL-Go this should report everything as already present and change nothing. Its job
    is to catch the case where a required label has been renamed or removed, which would otherwise
    show up as labels silently not being applied.

    Verification only by default. Pass -Create to actually create anything missing. Labels present
    on the repository but absent from labels.json are ignored entirely: this agent is not the only
    thing that labels AL-Go issues, and it has no business tidying up after anyone else.

    Read-only verification needs any token. -Create needs issues write access.

.PARAMETER Repository
    Target repository in owner/repo form. Defaults to GITHUB_REPOSITORY, then microsoft/AL-Go.

.PARAMETER Token
    GitHub token. Defaults to GH_TOKEN, then GITHUB_TOKEN.

.PARAMETER Create
    Create or correct labels rather than only reporting on them.

.EXAMPLE
    $env:GH_TOKEN = (gh auth token)
    ./Sync-TriageLabels.ps1

.EXAMPLE
    ./Sync-TriageLabels.ps1 -Create -WhatIf

.OUTPUTS
    A hashtable listing missing, mismatched and matching labels, plus an 'ok' flag.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
Param(
    [Parameter(Mandatory = $false)]
    [string] $Repository = '',

    [Parameter(Mandatory = $false)]
    [string] $Token = '',

    [switch] $Create
)

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

if (-not $Repository) {
    $Repository = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'microsoft/AL-Go' }
}
if (-not $Token) {
    $Token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
}
if (-not $Token) {
    throw "No token. Set GH_TOKEN (for example: `$env:GH_TOKEN = (gh auth token)) or pass -Token."
}

$agentRoot = Split-Path -Path $PSScriptRoot -Parent
$definition = (Get-Content -Path (Join-Path $agentRoot 'labels.json') -Raw -Encoding UTF8) | ConvertFrom-Json
$apiUrl = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL.TrimEnd('/') } else { 'https://api.github.com' }
$headers = @{
    Accept                 = 'application/vnd.github+json'
    Authorization          = "Bearer $Token"
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'al-go-triage-labels'
}

Write-Host "Checking triage labels on $Repository"

$existing = @{}
$page = 1
while ($true) {
    $batch = Invoke-RestMethod -Uri "$apiUrl/repos/$Repository/labels?per_page=100&page=$page" -Headers $headers -Method GET
    if (-not $batch -or @($batch).Count -eq 0) { break }
    foreach ($label in @($batch)) { $existing[$label.name] = $label }
    if (@($batch).Count -lt 100) { break }
    $page++
}
Write-Host "Repository has $($existing.Count) labels."

$missing = @()
$mismatched = @()
$matching = @()

foreach ($wanted in @($definition.labels)) {
    $body = @{ name = $wanted.name; color = $wanted.color; description = $wanted.description }

    if (-not $existing.ContainsKey($wanted.name)) {
        $missing += $wanted.name
        if ($Create -and $PSCmdlet.ShouldProcess($wanted.name, 'Create label')) {
            Invoke-RestMethod -Uri "$apiUrl/repos/$Repository/labels" -Headers $headers -Method POST `
                -Body (ConvertTo-Json -InputObject $body -Compress) -ContentType 'application/json' | Out-Null
            Write-Host "Created '$($wanted.name)'."
        }
        continue
    }

    $current = $existing[$wanted.name]
    $currentDescription = if ($current.description) { $current.description } else { '' }
    if ($current.color -ne $wanted.color -or $currentDescription -ne $wanted.description) {
        $mismatched += $wanted.name
        # Only corrected on explicit request: the repository's own wording wins by default.
        if ($Create -and $PSCmdlet.ShouldProcess($wanted.name, 'Update label')) {
            $encoded = [uri]::EscapeDataString($wanted.name)
            Invoke-RestMethod -Uri "$apiUrl/repos/$Repository/labels/$encoded" -Headers $headers -Method PATCH `
                -Body (ConvertTo-Json -InputObject $body -Compress) -ContentType 'application/json' | Out-Null
            Write-Host "Updated '$($wanted.name)'."
        }
    }
    else {
        $matching += $wanted.name
    }
}

Write-Host ''
Write-Host "Present and correct : $(if ($matching) { $matching -join ', ' } else { 'none' })"
if ($mismatched) {
    Write-Host "Colour or description differs : $($mismatched -join ', ')"
    Write-Host "  (cosmetic only, the agent still applies them; pass -Create to align)"
}
if ($missing) {
    Write-Host "::Warning::Missing labels: $($missing -join ', ')"
    Write-Host "  The agent cannot apply these. Re-run with -Create, or update labels.json if they were renamed."
}
if (-not $missing -and -not $mismatched) {
    Write-Host 'Nothing to do.'
}

return @{
    repository = $Repository
    missing    = $missing
    mismatched = $mismatched
    matching   = $matching
    ok         = ($missing.Count -eq 0)
}
