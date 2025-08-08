Param(
    [Parameter(HelpMessage = "Project to analyze", Mandatory = $false)]
    [string] $project = '.'
)

$mdHelperPath = Join-Path -Path $PSScriptRoot -ChildPath "..\MarkDownHelper.psm1"
Import-Module $mdHelperPath

$errorLogsFolder = Join-Path $ENV:GITHUB_WORKSPACE "$project\.buildartifacts\ErrorLogs"
$errorLogFiles = Get-ChildItem -Path $errorLogsFolder -Filter "*.errorLog.json" -File -Recurse

$sarif = @{
    version = "2.1.0"
    '$schema' = "https://json.schemastore.org/sarif-2.1.0.json"
    runs = @(@{
        tool = @{
            driver = @{
                name = 'AL Code Analysis'
                informationUri = 'https://aka.ms/AL-Go'
                rules = @()
            }
        }
        results = @()
    })
}


function GenerateSARIFJson {
    param(
        [PSCustomObject] $errorLogContent
    )

    foreach ($issue in $errorLogContent.issues) {
        # Add rule if not already added
        if (-not ($sarif.runs[0].tool.driver.rules | Where-Object { $_.id -eq $issue.ruleId })) {
            $sarif.runs[0].tool.driver.rules += @{
                id = $issue.ruleId
                shortDescription = @{ text = $issue.shortMessage }
                fullDescription = @{ text = $issue.fullMessage }
                helpUri = $issue.properties.helpLink
                properties = @{
                    category = $issue.properties.category
                    severity = $issue.properties.severity
                }
            }
        }

        # Convert absolute path to relative path from repository root
        $absolutePath = $issue.locations[0].analysisTarget[0].uri
        $workspacePath = $ENV:GITHUB_WORKSPACE
        Write-Host $workspacePath
        $relativePath = $absolutePath.Replace('\', '/')
        $relativePath = $relativePath.Replace($workspacePath, '').TrimStart('/')
        $relativePath = $relativePath.Replace('D:/a/Al-Go_MultiProjectTest/Al-Go_MultiProjectTest/', '')

        # Add result
        $sarif.runs[0].results += @{
            ruleId = $issue.ruleId
            message = @{ text = $issue.fullMessage }
            locations = @(@{
                physicalLocation = @{
                    artifactLocation = @{ uri = $relativePath }
                    region = $issue.locations[0].analysisTarget[0].region
                }
            })
            level = "warning"
        }
    }
}

$logHeaders = @('App', 'Warnings', 'Errors')
$logRows = [System.Collections.ArrayList]@()
$errorLogFiles | ForEach-Object {
    OutputDebug -message "Found error log file: $($_.FullName)"
    $fileName = $_.Name
    Write-Host "Processing error log file: $fileName"
    try {
        $errorLogContent = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
        GenerateSARIFJson -errorLogContent $errorLogContent
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
            Write-Host "No issues found in error log file: $($_.FullName)"
            OutputDebug -message "No issues found in error log file: $($_.FullName)"
            Write-Host ($errorLogContent | ConvertTo-Json -Depth 10)
        }
        $appName = ($_.Name).Replace('.errorLog.json', '')
        $logRow = @($appName, $numWarnings, $numErrors)
        $logRows.Add($logRow) | Out-Null
    }
    catch {
        Write-Host "Failed to process $fileName"
        OutputDebug -message "Failed to read error log file: $_"
    }
}

try {
    Write-Host ($logRows | ConvertTo-Json -Depth 10)
    $logTable = Build-MarkdownTable -Headers $logHeaders -Rows $logRows
    Add-Content -Encoding UTF8 -path $ENV:GITHUB_STEP_SUMMARY -value "$($logTable.Replace("\n","`n"))"
} catch {
    Write-Host "Failed to build markdown table for error logs"
    OutputDebug -message "Failed to build markdown table: $_"
}


$sarifJson = $sarif | ConvertTo-Json -Depth 10 -Compress
Write-Host ($sarifJson)
Set-Content -Path "output.sarif.json" -Value $sarifJson