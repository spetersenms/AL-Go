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
        [OrderedHashtable] $errorLogContent
    )

    foreach ($issue in $customJson.issues) {
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

        # Add result
        $sarif.runs[0].results += @{
            ruleId = $issue.ruleId
            message = @{ text = $issue.fullMessage }
            locations = @(@{
                physicalLocation = @{
                    artifactLocation = @{ uri = $issue.locations[0].analysisTarget[0].uri }
                    region = $issue.locations[0].analysisTarget[0].region
                }
            })
            level = "warning"
        }
    }
}

$logHeaders = @('App', 'Warnings', 'Errors')
$logRows = [System.Collections.ArrayList]@()
Write-Host ($errorLogFiles | ConvertTo-Json)
$errorLogFiles | ForEach-Object {
    OutputDebug -message "Found error log file: $($_.FullName)"
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
            OutputDebug -message "No issues found in error log file: $($_.FullName)"
        }
        $appName = ($_.Name).Replace('.errorLog.json', '')
        $logRow = @($appName, $numWarnings, $numErrors)
        $logRows.Add($logRow) | Out-Null
    }
    catch {
        OutputDebug -message "Failed to read error log file: $($_.FullName)"
    }
}

$logTable = Build-MarkdownTable -Headers $logHeaders -Rows $logRows
Add-Content -Encoding UTF8 -path $ENV:GITHUB_STEP_SUMMARY -value "$($logTable.Replace("\n","`n"))"

$sarifJson = $sarif | ConvertTo-Json -Depth 10
Write-Host ($sarifJson)
Set-Content -Path "output.sarif.json" -Value $sarifJson