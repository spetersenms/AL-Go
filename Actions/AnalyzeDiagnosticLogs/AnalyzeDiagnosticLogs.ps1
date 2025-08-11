$errorLogsFolder = Join-Path $ENV:GITHUB_WORKSPACE "ErrorLogs"
$errorLogFiles = Get-ChildItem -Path $errorLogsFolder -Filter "*.errorLog.json" -File -Recurse

# Base SARIF structure
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
                shortDescription = @{ text = $issue.fullMessage }
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
        $relativePath = $absolutePath.Replace($workspacePath, '').TrimStart('\').Replace('\', '/')

        # Add result
        $sarif.runs[0].results += @{
            ruleId = $issue.ruleId
            message = @{ text = $issue.shortMessage }
            locations = @(@{
                physicalLocation = @{
                    artifactLocation = @{ uri = $relativePath }
                    region = $issue.locations[0].analysisTarget[0].region
                }
            })
            level = $issue.properties.severity
        }
    }
}

$errorLogFiles | ForEach-Object {
    OutputDebug -message "Found error log file: $($_.FullName)"
    $fileName = $_.Name
    try {
        $errorLogContent = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
        GenerateSARIFJson -errorLogContent $errorLogContent
    }
    catch {
        Write-Host "Failed to process $fileName"
        OutputDebug -message "Failed to read error log file: $_"
    }
}

$sarifJson = $sarif | ConvertTo-Json -Depth 10 -Compress
Write-Host ($sarifJson)
Set-Content -Path "$errorLogsFolder/output.sarif.json" -Value $sarifJson