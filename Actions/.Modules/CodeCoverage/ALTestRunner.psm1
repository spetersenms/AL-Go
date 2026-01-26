function Run-AlTests
(
    [string] $TestSuite = $script:DefaultTestSuite,
    [string] $TestCodeunitsRange = "",
    [string] $TestProcedureRange = "",
    [string] $ExtensionId = "",
    [ValidateSet('None','Disabled','Codeunit','Function')]
    [string] $RequiredTestIsolation = "None",
    [ValidateSet('','None','UnitTest','IntegrationTest','Uncategorized','AITest')]
    [string] $TestType = "",
    [ValidateSet("Disabled", "Codeunit")]
    [string] $TestIsolation = "Codeunit",
    [ValidateSet('Windows','NavUserPassword','AAD')]
    [string] $AutorizationType = $script:DefaultAuthorizationType,
    [string] $TestPage = $global:DefaultTestPage,
    [switch] $DisableSSLVerification,
    [Parameter(Mandatory=$true)]
    [string] $ServiceUrl,
    [Parameter(Mandatory=$false)]
    [pscredential] $Credential,
    [array] $DisabledTests = @(),
    [bool] $Detailed = $true,
    [ValidateSet('no','error','warning')]
    [string] $AzureDevOps = 'no',
    [bool] $SaveResultFile = $true,
    [string] $ResultsFilePath = "$PSScriptRoot\TestResults.xml",
    [ValidateSet('XUnit','JUnit')]
    [string] $ResultsFormat = 'JUnit',
    [string] $AppName = '',
    [ValidateSet('Disabled', 'PerRun', 'PerCodeunit', 'PerTest')]
    [string] $CodeCoverageTrackingType = 'Disabled',
    [ValidateSet('Disabled','PerCodeunit','PerTest')]
    [string] $ProduceCodeCoverageMap = 'Disabled',
    [string] $CodeCoverageOutputPath = "$PSScriptRoot\CodeCoverage",
    [string] $CodeCoverageExporterId = $script:DefaultCodeCoverageExporter,
    [switch] $CodeCoverageTrackAllSessions,
    [string] $CodeCoverageFilePrefix = ("TestCoverageMap_" + (get-date -Format 'yyyymmdd')),
    [bool] $StabilityRun
)
{
    $testRunArguments = @{
        TestSuite = $TestSuite
        TestCodeunitsRange = $TestCodeunitsRange
        TestProcedureRange = $TestProcedureRange
        ExtensionId = $ExtensionId
        RequiredTestIsolation = $RequiredTestIsolation
        TestType = $TestType
        TestRunnerId = (Get-TestRunnerId -TestIsolation $TestIsolation)
        CodeCoverageTrackingType = $CodeCoverageTrackingType
        ProduceCodeCoverageMap = $ProduceCodeCoverageMap
        CodeCoverageOutputPath = $CodeCoverageOutputPath
        CodeCoverageFilePrefix = $CodeCoverageFilePrefix
        CodeCoverageExporterId = $CodeCoverageExporterId
        AutorizationType = $AutorizationType
        TestPage = $TestPage
        DisableSSLVerification = $DisableSSLVerification
        ServiceUrl = $ServiceUrl
        Credential = $Credential
        DisabledTests = $DisabledTests
        Detailed = $Detailed
        StabilityRun = $StabilityRun
    }
    
    [array]$testRunResult = Run-AlTestsInternal @testRunArguments

    if($SaveResultFile)
    {
        # Import the formatter module
        $formatterPath = Join-Path $PSScriptRoot "TestResultFormatter.psm1"
        Import-Module $formatterPath -Force

        Save-TestResults -TestRunResultObject $testRunResult -ResultsFilePath $ResultsFilePath -Format $ResultsFormat -ExtensionId $ExtensionId -AppName $AppName
    }

    if($AzureDevOps  -ne 'no')
    {
        Report-ErrorsInAzureDevOps -AzureDevOps $AzureDevOps -TestRunResultObject $TestRunResultObject
    }
}

function Save-ResultsAsXUnitFile
(
    $TestRunResultObject,
    [string] $ResultsFilePath
)
{
    [xml]$XUnitDoc = New-Object System.Xml.XmlDocument
    $XUnitDoc.AppendChild($XUnitDoc.CreateXmlDeclaration("1.0","UTF-8",$null)) | Out-Null
    $XUnitAssemblies = $XUnitDoc.CreateElement("assemblies")
    $XUnitDoc.AppendChild($XUnitAssemblies) | Out-Null

    foreach($testResult in $TestRunResultObject)
    {
        $name = $testResult.name
        $startTime =  [datetime]($testResult.startTime)
        $finishTime = [datetime]($testResult.finishTime)
        $duration = $finishTime.Subtract($startTime)
        $durationSeconds = [Math]::Round($duration.TotalSeconds,3)

        $XUnitAssembly = $XUnitDoc.CreateElement("assembly")
        $XUnitAssemblies.AppendChild($XUnitAssembly) | Out-Null
        $XUnitAssembly.SetAttribute("name",$name)
        $XUnitAssembly.SetAttribute("x-code-unit",$testResult.codeUnit)
        $XUnitAssembly.SetAttribute("test-framework", "PS Test Runner")
        $XUnitAssembly.SetAttribute("run-date", $startTime.ToString("yyyy-MM-dd"))
        $XUnitAssembly.SetAttribute("run-time", $startTime.ToString("HH:mm:ss"))
        $XUnitAssembly.SetAttribute("total",0)
        $XUnitAssembly.SetAttribute("passed",0)
        $XUnitAssembly.SetAttribute("failed",0)
        $XUnitAssembly.SetAttribute("time", $durationSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture))
        $XUnitCollection = $XUnitDoc.CreateElement("collection")
        $XUnitAssembly.AppendChild($XUnitCollection) | Out-Null
        $XUnitCollection.SetAttribute("name",$name)
        $XUnitCollection.SetAttribute("total",0)
        $XUnitCollection.SetAttribute("passed",0)
        $XUnitCollection.SetAttribute("failed",0)
        $XUnitCollection.SetAttribute("skipped",0)
        $XUnitCollection.SetAttribute("time", $durationSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture))

        foreach($testMethod in $testResult.testResults)
        {
            $testMethodName = $testMethod.method
            $XUnitAssembly.SetAttribute("total",([int]$XUnitAssembly.GetAttribute("total") + 1))
            $XUnitCollection.SetAttribute("total",([int]$XUnitCollection.GetAttribute("total") + 1))
            $XUnitTest = $XUnitDoc.CreateElement("test")
            $XUnitCollection.AppendChild($XUnitTest) | Out-Null
            $XUnitTest.SetAttribute("name", $XUnitAssembly.GetAttribute("name") + ':' + $testMethodName)
            $XUnitTest.SetAttribute("method", $testMethodName)
            $startTime =  [datetime]($testMethod.startTime)
            $finishTime = [datetime]($testMethod.finishTime)
            $duration = $finishTime.Subtract($startTime)
            $durationSeconds = [Math]::Round($duration.TotalSeconds,3)
            $XUnitTest.SetAttribute("time", $durationSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture))

            switch($testMethod.result)
            {
                $script:SuccessTestResultType
                {
                    $XUnitAssembly.SetAttribute("passed",([int]$XUnitAssembly.GetAttribute("passed") + 1))
                    $XUnitCollection.SetAttribute("passed",([int]$XUnitCollection.GetAttribute("passed") + 1))
                    $XUnitTest.SetAttribute("result", "Pass")
                    break;
                }
                $script:FailureTestResultType
                {
                    $XUnitAssembly.SetAttribute("failed",([int]$XUnitAssembly.GetAttribute("failed") + 1))
                    $XUnitCollection.SetAttribute("failed",([int]$XUnitCollection.GetAttribute("failed") + 1))
                    $XUnitTest.SetAttribute("result", "Fail")
                    $XUnitFailure = $XUnitDoc.CreateElement("failure")
                    $XUnitMessage = $XUnitDoc.CreateElement("message")
                    $XUnitMessage.InnerText = $testMethod.message;
                    $XUnitFailure.AppendChild($XUnitMessage) | Out-Null
                    $XUnitStacktrace = $XUnitDoc.CreateElement("stack-trace")
                    $XUnitStacktrace.InnerText = $($testMethod.stackTrace).Replace(";","`n")
                    $XUnitFailure.AppendChild($XUnitStacktrace) | Out-Null
                    $XUnitTest.AppendChild($XUnitFailure) | Out-Null
                    break;
                }
                $script:SkippedTestResultType
                {
                    $XUnitCollection.SetAttribute("skipped",([int]$XUnitCollection.GetAttribute("skipped") + 1))
                    break;
                }
            }
        }
    }

    $XUnitDoc.Save($ResultsFilePath)
}

function Invoke-ALTestResultVerification
(
    [string] $TestResultsFolder = $(throw "Missing argument TestResultsFolder"),
    [switch] $IgnoreErrorIfNoTestsExecuted
)
{
    $failedTestList = Get-FailedTestsFromXMLFiles -TestResultsFolder $TestResultsFolder

    if($failedTestList.Count -gt 0) 
    {
        $testsExecuted = $true;
        Write-Log "Failed tests:"
        $testsFailed = ""
        foreach($failedTest in $failedTestList)
        {
            $testsFailed += "Name: " + $failedTest.name + [environment]::NewLine
            $testsFailed += "Method: " + $failedTest.method + [environment]::NewLine
            $testsFailed += "Time: " + $failedTest.time + [environment]::NewLine
            $testsFailed += "Message: " + [environment]::NewLine + $failedTest.message + [environment]::NewLine
            $testsFailed += "StackTrace: "+ [environment]::NewLine + $failedTest.stackTrace + [environment]::NewLine  + [environment]::NewLine
        }

        Write-Log $testsFailed
        throw "Test execution failed due to the failing tests, see the list of the failed tests above."
    }

    if(-not $testsExecuted)
    {
        [array]$testResultFiles = Get-ChildItem -Path $TestResultsFolder -Filter "*.xml" | Foreach { "$($_.FullName)" }

        foreach($resultFile in $testResultFiles)
        {
            [xml]$xmlDoc = Get-Content "$resultFile"
            [array]$otherTests = $xmlDoc.assemblies.assembly.collection.ChildNodes | Where-Object {$_.result -ne 'Fail'}
            if($otherTests.Length -gt 0)
            {
                return;
            }

        }

        if (-not $IgnoreErrorIfNoTestsExecuted) {
            throw "No test codeunits were executed"
        }
    }
}

function Get-FailedTestsFromXMLFiles
(
    [string] $TestResultsFolder = $(throw "Missing argument TestResultsFolder")
)
{
    $failedTestList = New-Object System.Collections.ArrayList
    $testsExecuted = $false
    [array]$testResultFiles = Get-ChildItem -Path $TestResultsFolder -Filter "*.xml" | Foreach { "$($_.FullName)" }

    if($testResultFiles.Length -eq 0)
    {
        throw "No test results were found"
    }

    foreach($resultFile in $testResultFiles)
    {
        [xml]$xmlDoc = Get-Content "$resultFile"
        [array]$failedTests = $xmlDoc.assemblies.assembly.collection.ChildNodes | Where-Object {$_.result -eq 'Fail'}
        if($failedTests)
        {
            $testsExecuted = $true
            foreach($failedTest in $failedTests)
            {
                $failedTestObject = @{
                    codeunitID = [int]($failedTest.ParentNode.ParentNode.'x-code-unit');
                    codeunitName = $failedTest.name;
                    method = $failedTest.method;
                    time = $failedTest.time;
                    message = $failedTest.failure.message;
                    stackTrace = $failedTest.failure.'stack-trace';
                }

                $failedTestList.Add($failedTestObject) > $null
            }
        }
    }

    return $failedTestList
}

function Write-DisabledTestsJson
(
    $FailedTests,
    [string] $OutputFolder = $(throw "Missing argument OutputFolder"),
    [string] $FileName = 'DisabledTests.json'
)
{
    $testsToDisable = New-Object -TypeName "System.Collections.ArrayList"
    foreach($failedTest in $failedTests)
    {
        $test = @{
                    codeunitID = $failedTest.codeunitID;
                    codeunitName = $failedTest.name;
                    method = $failedTest.method;
                }

       $testsToDisable.Add($test)
    }

    $oututFile = Join-Path $OutputFolder $FileName
    if(-not (Test-Path $outputFolder))
    {
        New-Item -Path $outputFolder -ItemType Directory
    }

    Add-Content -Value (ConvertTo-Json $testsToDisable) -Path $oututFile
}

function Report-ErrorsInAzureDevOps
(
    [ValidateSet('no','error','warning')]
    [string] $AzureDevOps = 'no',
    $TestRunResultObject
)
{
    if ($AzureDevOps -eq 'no')
    {
        return
    }

    $failedCodeunits = $TestRunResultObject | Where-Object { $_.result -eq $script:FailureTestResultType }
    $failedTests = $failedCodeunits.testResults | Where-Object { $_.result -eq $script:FailureTestResultType }

    foreach($failedTest in $failedTests)
    {
        $methodName = $failedTest.method;
        $errorMessage = $failedTests.message
        Write-Host "##vso[task.logissue type=$AzureDevOps;sourcepath=$methodName;]$errorMessage"
    }
}

function Get-DisabledAlTests
(
    [string] $DisabledTestsPath
)
{
    $DisabledTests = @()
    if(Test-Path $DisabledTestsPath)
    {
        $DisabledTests = Get-Content $DisabledTestsPath | ConvertFrom-Json
    }

    return $DisabledTests
}

function Get-TestRunnerId
(
    [ValidateSet("Disabled", "Codeunit")]
    [string] $TestIsolation = "Codeunit"
)
{
    switch($TestIsolation)
    {
        "Codeunit" 
        {
            return Get-CodeunitTestIsolationTestRunnerId
        }
        "Disabled"
        {
            return Get-DisabledTestIsolationTestRunnerId
        }
    }
}

function Get-DisabledTestIsolationTestRunnerId()
{
    return $global:TestRunnerIsolationDisabled
}

function Get-CodeunitTestIsolationTestRunnerId()
{
    return $global:TestRunnerIsolationCodeunit
}

$script:CodeunitLineType = '0'
$script:FunctionLineType = '1'

$script:FailureTestResultType = '1';
$script:SuccessTestResultType = '2';
$script:SkippedTestResultType = '3';

$script:DefaultAuthorizationType = 'NavUserPassword'
$script:DefaultTestSuite = 'DEFAULT'
$global:TestRunnerAppId = "23de40a6-dfe8-4f80-80db-d70f83ce8caf"
# XMLport 130470 (Code Coverage Results) - exports covered/partially covered lines as CSV
# XMLport 130007 (Code Coverage Internal) - exports all lines including not covered as XML
$script:DefaultCodeCoverageExporter = 130470;
Import-Module "$PSScriptRoot\Internal\ALTestRunnerInternal.psm1"