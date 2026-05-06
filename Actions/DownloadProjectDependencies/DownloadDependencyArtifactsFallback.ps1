Param(
    [Parameter(HelpMessage = "The project for which to download dependency artifacts", Mandatory = $true)]
    [string] $project,
    [Parameter(HelpMessage = "JSON object mapping each project to its dependency projects", Mandatory = $true)]
    [string] $projectDependenciesJson,
    [Parameter(HelpMessage = "The folder where dependency artifacts should be unpacked", Mandatory = $true)]
    [string] $destinationPath,
    [Parameter(HelpMessage = "GitHub token used to authenticate REST API calls", Mandatory = $true)]
    [string] $token
)

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "DownloadProjectDependencies.psm1" -Resolve) -DisableNameChecking
. (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)

$projectDependencies = $projectDependenciesJson | ConvertFrom-Json | ConvertTo-HashTable -recurse

Invoke-DownloadDependencyArtifactsFallback -Project $project -ProjectDependencies $projectDependencies -DestinationPath $destinationPath -Token $token | Out-Null
