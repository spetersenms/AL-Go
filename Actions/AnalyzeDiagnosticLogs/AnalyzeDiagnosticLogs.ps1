Param(
    [Parameter(HelpMessage = "Project to analyze", Mandatory = $false)]
    [string] $project = '.'
)

$mdHelperPath = Join-Path -Path $PSScriptRoot -ChildPath "..\MarkDownHelper.psm1"
Import-Module $mdHelperPath

$errorLogsFolder = Join-Path $ENV:GITHUB_WORKSPACE "$project\.buildartifacts\ErrorLogs"
$errorLogFiles = Get-ChildItem -Path $errorLogsFolder -Filter "*.errorLog.json" -File -Recurse

$logHeaders = @('FileName', 'Warnings', 'Errors')
$logRows = [System.Collections.ArrayList]@()
$errorLogFiles | ForEach-Object {
    OutputDebug -message "Found error log file: $($_.FullName)"
    try {
        $errorLogContent = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
        $numWarnings = 0
        $numErrors = 0
        if ($errorLogContent -and $errorLogContent.issues) {
            $errorLogContent.issues | ForEach-Object {
                if ($_.properties -and $_.properties.severity) {
                    switch ($_.properties.severity) {
                        'Warning' { $numWarnings++ }
                        'Error' { $numErrors++ }
                        default { OutputDebug -message "Unknown severity: $($_.properties.severity)" }
                    }
                }
            }
        }
        else {
            OutputDebug -message "No issues found in error log file: $($_.FullName)"
        }
        $logRow = @($_.Name, $numWarnings, $numErrors)
        $logRows.Add($logRow) | Out-Null
    }
    catch {
        OutputDebug -message "Failed to read error log file: $($_.FullName)"
    }
}

$logTable = Build-MarkdownTable -Headers $logHeaders -Rows $logRows
Add-Content -Encoding UTF8 -path $ENV:GITHUB_STEP_SUMMARY -value "$logTable"