Param(
    [Parameter(HelpMessage = "Project folder", Mandatory = $false)]
    [string] $project = "."
)

try {
    . (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)
    Import-Module (Join-Path $PSScriptRoot '..\.Modules\BuildResources.psm1' -Resolve) -Force -DisableNameChecking
    if (-not $env:_ALGoBuildId) {
        Write-Host "::Notice::No AL-Go build resource identity was assigned. Skipping container cleanup."
        return
    }
    DownloadAndImportBcContainerHelper

    Write-Host "Cleaning up build resources for project '$project'."
    Remove-BuildContainer -parameters @{ containerName = (Get-BuildContainerName) }
}
catch {
    Write-Host "::Warning::Pipeline Cleanup failed: $($_.Exception.Message)"
}
