function Run-AlTestsInternal
(
    [string] $TestSuite = $script:DefaultTestSuite,
    [string] $TestCodeunitsRange = "",
    [string] $TestProcedureRange = "",
    [string] $ExtensionId = "",
    [ValidateSet('None','Disabled','Codeunit','Function')]
    [string] $RequiredTestIsolation = "None",
    [string] $TestType,
    [int] $TestRunnerId = $global:DefaultTestRunner,
    [ValidateSet('Windows','NavUserPassword','AAD')]
    [string] $AutorizationType = $script:DefaultAuthorizationType,
    [string] $TestPage = $global:DefaultTestPage,
    [switch] $DisableSSLVerification,
    [Parameter(Mandatory=$true)]
    [string] $ServiceUrl,
    [Parameter(Mandatory=$false)]
    [pscredential] $Credential,
    [bool] $Detailed = $true,
    [array] $DisabledTests = @(),
    [ValidateSet('Disabled', 'PerRun', 'PerCodeunit', 'PerTest')]
    [string] $CodeCoverageTrackingType = 'Disabled',
    [ValidateSet('Disabled','PerCodeunit','PerTest')]
    [string] $ProduceCodeCoverageMap = 'Disabled',
    [string] $CodeCoverageOutputPath = "$PSScriptRoot\CodeCoverage",
    [string] $CodeCoverageExporterId,
    [switch] $CodeCoverageTrackAllSessions,
    [string] $CodeCoverageFilePrefix,
    [bool] $StabilityRun
)
{
    $ErrorActionPreference = $script:DefaultErrorActionPreference
   
    Setup-TestRun -DisableSSLVerification:$DisableSSLVerification -AutorizationType $AutorizationType -Credential $Credential -ServiceUrl $ServiceUrl -TestSuite $TestSuite `
        -TestCodeunitsRange $TestCodeunitsRange -TestProcedureRange $TestProcedureRange -ExtensionId $ExtensionId -RequiredTestIsolation $RequiredTestIsolation -TestType $TestType `
        -TestRunnerId $TestRunnerId -TestPage $TestPage -DisabledTests $DisabledTests -CodeCoverageTrackingType $CodeCoverageTrackingType -CodeCoverageTrackAllSessions:$CodeCoverageTrackAllSessions -CodeCoverageOutputPath $CodeCoverageOutputPath -CodeCoverageExporterId $CodeCoverageExporterId -ProduceCodeCoverageMap $ProduceCodeCoverageMap -StabilityRun $StabilityRun
            
    $testRunResults = New-Object System.Collections.ArrayList 
    $testResult = ''
    $numberOfUnexpectedFailures = 0;

    do
    {
        try
        {
            $testStartTime = $(Get-Date)
            $testResult = Run-NextTest -DisableSSLVerification:$DisableSSLVerification -AutorizationType $AutorizationType -Credential $Credential -ServiceUrl $ServiceUrl -TestSuite $TestSuite
            if($testResult -eq $script:AllTestsExecutedResult)
            {
                return [Array]$testRunResults
            }
 
            $testRunResultObject = ConvertFrom-Json $testResult
            if($CodeCoverageTrackingType -ne 'Disabled') {
                $null = CollectCoverageResults -TrackingType $CodeCoverageTrackingType -OutputPath $CodeCoverageOutputPath -DisableSSLVerification:$DisableSSLVerification -AutorizationType $AutorizationType -Credential $Credential -ServiceUrl $ServiceUrl -CodeCoverageFilePrefix $CodeCoverageFilePrefix
            }
       }
        catch
        {
            $numberOfUnexpectedFailures++

            $stackTrace = $_.Exception.StackTrace + "Script stack trace: " + $_.ScriptStackTrace 
            $testMethodResult = @{
                method = "Unexpected Failure"
                codeUnit = "Unexpected Failure"
                startTime = $testStartTime.ToString($script:DateTimeFormat)
                finishTime = ($(Get-Date).ToString($script:DateTimeFormat))
                result = $script:FailureTestResultType
                message = $_.Exception.Message
                stackTrace = $stackTrace
            }

            $testRunResultObject = @{
                name = "Unexpected Failure"
                codeUnit = "UnexpectedFailure"
                startTime = $testStartTime.ToString($script:DateTimeFormat)
                finishTime = ($(Get-Date).ToString($script:DateTimeFormat))
                result = $script:FailureTestResultType
                testResults = @($testMethodResult)
            }
        }
        
        $testRunResults.Add($testRunResultObject) > $null
        if($Detailed)
        {
            Print-TestResults -TestRunResultObject $testRunResultObject
        }
    }
    until((!$testRunResultObject) -or ($NumberOfUnexpectedFailuresBeforeAborting -lt $numberOfUnexpectedFailures))

    throw "Expected to end the test execution, something went wrong with returning test results."      
}

function CollectCoverageResults {
    param (
        [ValidateSet('PerRun', 'PerCodeunit', 'PerTest')]
        [string] $TrackingType,
        [string] $OutputPath,
        [switch] $DisableSSLVerification,
        [ValidateSet('Windows','NavUserPassword','AAD')]
        [string] $AutorizationType = $script:DefaultAuthorizationType,
        [Parameter(Mandatory=$false)]
        [pscredential] $Credential,
        [Parameter(Mandatory=$true)]
        [string] $ServiceUrl,
        [string] $CodeCoverageFilePrefix
    )
    try{
        $clientContext = Open-ClientSessionWithWait -DisableSSLVerification:$DisableSSLVerification -AuthorizationType $AutorizationType -Credential $Credential -ServiceUrl $ServiceUrl
        $form = Open-TestForm -TestPage $TestPage -ClientContext $clientContext
        do {
            $clientContext.InvokeAction($clientContext.GetActionByName($form, "GetCodeCoverage"))

            $CCResultControl = $clientContext.GetControlByName($form, "CCResultsCSVText")
            $CCInfoControl = $clientContext.GetControlByName($form, "CCInfo")
            $CCResult = $CCResultControl.StringValue
            $CCInfo = $CCInfoControl.StringValue
            if($CCInfo -ne $script:CCCollectedResult){
                $CCInfo = $CCInfo -replace ",","-"
                $CCOutputFilename = $CodeCoverageFilePrefix +"_$CCInfo.dat"
                Write-Host "Storing coverage results of $CCCodeunitId in:  $OutputPath\$CCOutputFilename"
                Set-Content -Path "$OutputPath\$CCOutputFilename" -Value $CCResult
            }
        } while ($CCInfo -ne $script:CCCollectedResult)
       
        if($ProduceCodeCoverageMap -ne 'Disabled') {
            $codeCoverageMapPath = Join-Path $OutputPath "TestCoverageMap"
            SaveCodeCoverageMap -OutputPath $codeCoverageMapPath  -DisableSSLVerification:$DisableSSLVerification -AutorizationType $AutorizationType -Credential $Credential -ServiceUrl $ServiceUrl
        }

        $clientContext.CloseForm($form)
    }
    finally{
        if($clientContext){
            $clientContext.Dispose()
        }
    }
}

function SaveCodeCoverageMap {
    param (
        [string] $OutputPath,
        [switch] $DisableSSLVerification,
        [ValidateSet('Windows','NavUserPassword','AAD')]
        [string] $AutorizationType = $script:DefaultAuthorizationType,
        [Parameter(Mandatory=$false)]
        [pscredential] $Credential,
        [Parameter(Mandatory=$true)]
        [string] $ServiceUrl
    )
    try{
        $clientContext = Open-ClientSessionWithWait -DisableSSLVerification:$DisableSSLVerification -AuthorizationType $AutorizationType -Credential $Credential -ServiceUrl $ServiceUrl
        $form = Open-TestForm -TestPage $TestPage -ClientContext $clientContext

        $clientContext.InvokeAction($clientContext.GetActionByName($form, "GetCodeCoverageMap"))

        $CCResultControl = $clientContext.GetControlByName($form, "CCMapCSVText")
        $CCMap = $CCResultControl.StringValue

        if (-not (Test-Path $OutputPath))
        {
            New-Item $OutputPath -ItemType Directory
        }
        
        $codeCoverageMapFileName = Join-Path $codeCoverageMapPath "TestCoverageMap.txt"
        if (-not (Test-Path $codeCoverageMapFileName))
        {
            New-Item $codeCoverageMapFileName -ItemType File
        }

        Add-Content -Path $codeCoverageMapFileName -Value $CCMap

        $clientContext.CloseForm($form)
    }
    finally{
        if($clientContext){
            $clientContext.Dispose()
        }
    }
}

function Print-TestResults
(
    $TestRunResultObject
)
{              
    $startTime = Convert-ResultStringToDateTimeSafe -DateTimeString $TestRunResultObject.startTime
    $finishTime = Convert-ResultStringToDateTimeSafe -DateTimeString $TestRunResultObject.finishTime
    $duration = $finishTime.Subtract($startTime)
    $durationSeconds = [Math]::Round($duration.TotalSeconds,3)

    switch($TestRunResultObject.result)
    {
        $script:SuccessTestResultType
        {
            Write-Host -ForegroundColor Green "Success - Codeunit $($TestRunResultObject.name) - Duration $durationSeconds seconds"
            break;
        }
        $script:FailureTestResultType
        {
            Write-Host -ForegroundColor Red "Failure - Codeunit $($TestRunResultObject.name) -  Duration $durationSeconds seconds"
            break;
        }
        default
        {
            if($codeUnitId -ne "0")
            {
                Write-Host -ForegroundColor Yellow "No tests were executed - Codeunit $"
            }
        }
    }

    if($TestRunResultObject.testResults)
    {
        foreach($testFunctionResult in $TestRunResultObject.testResults)
        {
            $durationSeconds = 0;
            $methodName = $testFunctionResult.method

            if($testFunctionResult.result -ne $script:SkippedTestResultType)
            {
                $startTime = Convert-ResultStringToDateTimeSafe -DateTimeString $testFunctionResult.startTime
                $finishTime = Convert-ResultStringToDateTimeSafe -DateTimeString $testFunctionResult.finishTime
                $duration = $finishTime.Subtract($startTime)
                $durationSeconds = [Math]::Round($duration.TotalSeconds,3)
            }

            switch($testFunctionResult.result)
            {
                $script:SuccessTestResultType
                {
                    Write-Host -ForegroundColor Green "   Success - Test method: $methodName - Duration $durationSeconds seconds)"
                    break;
                }
                $script:FailureTestResultType
                {
                    $callStack = $testFunctionResult.stackTrace
                    Write-Host -ForegroundColor Red "   Failure - Test method: $methodName - Duration $durationSeconds seconds"
                    Write-Host -ForegroundColor Red "      Error:"
                    Write-Host -ForegroundColor Red "         $($testFunctionResult.message)"
                    Write-Host -ForegroundColor Red "      Call Stack:"                    
                    if($callStack)
                    {
                        Write-Host -ForegroundColor Red "         $($callStack.Replace(';',"`n         "))"
                    }
                    break;
                }
                $script:SkippedTestResultType
                {
                    Write-Host -ForegroundColor Yellow "   Skipped - Test method: $methodName"
                    break;
                }
            }
        }
    }            
}

function Setup-TestRun
(
    [switch] $DisableSSLVerification,
    [ValidateSet('Windows','NavUserPassword','AAD')]
    [string] $AutorizationType = $script:DefaultAuthorizationType,
    [Parameter(Mandatory=$false)]
    [pscredential] $Credential,
    [Parameter(Mandatory=$true)]
    [string] $ServiceUrl,
    [string] $TestSuite = $script:DefaultTestSuite,
    [string] $TestCodeunitsRange = "",
    [string] $TestProcedureRange = "",
    [string] $ExtensionId = "",
    [ValidateSet('None','Disabled','Codeunit','Function')]
    [string] $RequiredTestIsolation = "None",
    [string] $TestType,
    [int] $TestRunnerId = $global:DefaultTestRunner,
    [string] $TestPage = $global:DefaultTestPage,
    [array] $DisabledTests = @(),
    [ValidateSet('Disabled', 'PerRun', 'PerCodeunit', 'PerTest')]
    [string] $CodeCoverageTrackingType = 'Disabled',
    [ValidateSet('Disabled','PerCodeunit','PerTest')]
    [string] $ProduceCodeCoverageMap = 'Disabled',
    [string] $CodeCoverageOutputPath = "$PSScriptRoot\CodeCoverage",
    [string] $CodeCoverageExporterId,
    [switch] $CodeCoverageTrackAllSessions,
    [bool] $StabilityRun
)
{
    Write-Log "Setting up test run: $CodeCoverageTrackingType - $CodeCoverageOutputPath"
    if($CodeCoverageTrackingType -ne 'Disabled')
    {
        if (-not (Test-Path -Path $CodeCoverageOutputPath))
        {
            $null = New-Item -Path $CodeCoverageOutputPath -ItemType Directory
        }
    }

    try
    {
        $clientContext = Open-ClientSessionWithWait -DisableSSLVerification:$DisableSSLVerification -AuthorizationType $AutorizationType -Credential $Credential -ServiceUrl $ServiceUrl 

        $form = Open-TestForm -TestPage $TestPage -DisableSSLVerification:$DisableSSLVerification -AuthorizationType $AutorizationType -ClientContext $clientContext
        Set-TestSuite -TestSuite $TestSuite -ClientContext $clientContext -Form $form
        Set-ExtensionId -ExtensionId $ExtensionId -Form $form -ClientContext $clientContext
        if (![string]::IsNullOrEmpty($TestType)) {
            Set-RequiredTestIsolation -RequiredTestIsolation $RequiredTestIsolation -Form $form -ClientContext $clientContext
            Set-TestType -TestType $TestType -Form $form -ClientContext $clientContext
        }
        Set-TestCodeunits -TestCodeunitsFilter $TestCodeunitsRange -Form $form -ClientContext $clientContext
        Set-TestProcedures -Filter $TestProcedureRange -Form $form $ClientContext $clientContext
        Set-TestRunner -TestRunnerId $TestRunnerId -Form $form -ClientContext $clientContext
        Set-RunFalseOnDisabledTests -DisabledTests $DisabledTests -Form $form -ClientContext $clientContext
        Set-StabilityRun -StabilityRun $StabilityRun -Form $form -ClientContext $clientContext
        Clear-TestResults -Form $form -ClientContext $clientContext
        if($CodeCoverageTrackingType -ne 'Disabled'){
            Set-CCTrackingType -Value $CodeCoverageTrackingType -Form $form -ClientContext $clientContext
            Set-CCTrackAllSessions -Value:$CodeCoverageTrackAllSessions -Form $form -ClientContext $clientContext
            Set-CCExporterID -Value $CodeCoverageExporterId -Form $form -ClientContext $clientContext
            Clear-CCResults -Form $form -ClientContext $clientContext
            Set-CCProduceCodeCoverageMap -Value $ProduceCodeCoverageMap -Form $form -ClientContext $clientContext
        }
        $clientContext.CloseForm($form)
    }
    finally
    {
        if($clientContext)
        {
            $clientContext.Dispose()
        }
        Write-Log "Complete Test Setup"
    }
}

function Run-NextTest
(
    [switch] $DisableSSLVerification,
    [ValidateSet('Windows','NavUserPassword','AAD')]
    [string] $AutorizationType = $script:DefaultAuthorizationType,
    [Parameter(Mandatory=$false)]
    [pscredential] $Credential,
    [Parameter(Mandatory=$true)]
    [string] $ServiceUrl,
    [string] $TestSuite = $script:DefaultTestSuite
)
{
    try
    {
        $clientContext = Open-ClientSessionWithWait -DisableSSLVerification:$DisableSSLVerification -AuthorizationType $AutorizationType -Credential $Credential -ServiceUrl $ServiceUrl
        $form = Open-TestForm -TestPage $TestPage -DisableSSLVerification:$DisableSSLVerification -AuthorizationType $AutorizationType -ClientContext $clientContext
        if($TestSuite -ne $script:DefaultTestSuite)
        {
            Set-TestSuite -TestSuite $TestSuite -ClientContext $clientContext -Form $form
        }

        $clientContext.InvokeAction($clientContext.GetActionByName($form, "RunNextTest"))
        
        $testResultControl = $clientContext.GetControlByName($form, "TestResultJson")
        $testResultJson = $testResultControl.StringValue
        $clientContext.CloseForm($form)
        return $testResultJson
    }
    finally
    {
        if($clientContext)
        {
            $clientContext.Dispose()
        }
    } 
}

function Open-ClientSessionWithWait
(
    [ValidateSet('Windows','NavUserPassword','AAD')]
    [string] $AuthorizationType = $script:DefaultAuthorizationType,
    [switch] $DisableSSLVerification,
    [string] $ServiceUrl,
    [pscredential] $Credential,
    [int] $ClientSessionTimeout = 20,
    [timespan] $TransactionTimeout = $script:DefaultTransactionTimeout,
    [string] $Culture = $script:DefaultCulture
)
{
        $lastErrorMessage = ""
        while(($ClientSessionTimeout -gt 0))
        {
            try
            {
                $clientContext = Open-ClientSession -DisableSSLVerification:$DisableSSLVerification -AuthorizationType $AuthorizationType -Credential $Credential -ServiceUrl $ServiceUrl -TransactionTimeout $TransactionTimeout -Culture $Culture
                return $clientContext
            }
            catch
            {
                Start-Sleep -Seconds 1
                $ClientSessionTimeout--
                $lastErrorMessage = $_.Exception.Message
            }
        }

        throw "Could not open the client session. Check if the web server is running and you can log in. Last error: $lastErrorMessage"
}

function Set-TestCodeunits
(
    [string] $TestCodeunitsFilter,
    [ClientContext] $ClientContext,
    $Form
)
{
    if(!$TestCodeunitsFilter)
    {
        return
    }

    $testCodeunitRangeFilterControl = $ClientContext.GetControlByName($Form, "TestCodeunitRangeFilter")
    $ClientContext.SaveValue($testCodeunitRangeFilterControl, $TestCodeunitsFilter)
}

function Set-TestRunner
(
    [int] $TestRunnerId,
    [ClientContext] $ClientContext,
    $Form
)
{
    if(!$TestRunnerId)
    {
        return
    }

    $testRunnerCodeunitIdControl = $ClientContext.GetControlByName($Form, "TestRunnerCodeunitId")
    $ClientContext.SaveValue($testRunnerCodeunitIdControl, $TestRunnerId)
}

function Clear-TestResults
(
    [ClientContext] $ClientContext,
    $Form
)
{
    $ClientContext.InvokeAction($ClientContext.GetActionByName($Form, "ClearTestResults"))
}

function Set-ExtensionId
(
    [string] $ExtensionId,
    [ClientContext] $ClientContext,
    $Form
)
{
    if(!$ExtensionId)
    {
        return
    }

    $extensionIdControl = $ClientContext.GetControlByName($Form, "ExtensionId")
    $ClientContext.SaveValue($extensionIdControl, $ExtensionId)
}

function Set-RequiredTestIsolation {
    param (
        [ValidateSet('None','Disabled','Codeunit','Function')]
        [string] $RequiredTestIsolation = "None",
        [ClientContext] $ClientContext,
        $Form
    )
    $TestIsolationValues = @{
        None = 0
        Disabled = 1
        Codeunit = 2
        Function = 3
    }
    $testIsolationControl = $ClientContext.GetControlByName($Form, "RequiredTestIsolation")
    $ClientContext.SaveValue($testIsolationControl, $TestIsolationValues[$RequiredTestIsolation])
}

function Set-TestType {
    param (
        [ValidateSet("UnitTest","IntegrationTest","Uncategorized")]
        [string] $TestType,
        [ClientContext] $ClientContext,
        $Form
    )
    $TypeValues = @{    
        UnitTest = 1
        IntegrationTest = 2
        Uncategorized = 3
    }
    $testTypeControl = $ClientContext.GetControlByName($Form, "TestType")
    $ClientContext.SaveValue($testTypeControl, $TypeValues[$TestType])
}

function Set-TestSuite
(
    [string] $TestSuite = $script:DefaultTestSuite,
    [ClientContext] $ClientContext,
    $Form
)
{
    $suiteControl = $ClientContext.GetControlByName($Form, "CurrentSuiteName")
    $ClientContext.SaveValue($suiteControl, $TestSuite)
}

function Set-CCTrackingType
{
    param (
        [ValidateSet('Disabled', 'PerRun', 'PerCodeunit', 'PerTest')]
        [string] $Value,
        [ClientContext] $ClientContext,
        $Form
    )
    $TypeValues = @{
        Disabled = 0
        PerRun = 1
        PerCodeunit=2
        PerTest=3
    }
    $suiteControl = $ClientContext.GetControlByName($Form, "CCTrackingType")
    $ClientContext.SaveValue($suiteControl, $TypeValues[$Value])
}

function Set-CCTrackAllSessions
{
    param (
        [switch] $Value,
        [ClientContext] $ClientContext,
        $Form
    )
    if($Value){
        $suiteControl = $ClientContext.GetControlByName($Form, "CCTrackAllSessions");
        $ClientContext.SaveValue($suiteControl, $Value)
    }
}

function Set-CCExporterID
{
    param (
        [string] $Value,
        [ClientContext] $ClientContext,
        $Form
    )
    if($Value){
        $suiteControl = $ClientContext.GetControlByName($Form, "CCExporterID");
        $ClientContext.SaveValue($suiteControl, $Value)
    }
}

function Set-CCProduceCodeCoverageMap
{

    param (
        [ValidateSet('Disabled', 'PerCodeunit', 'PerTest')]
        [string] $Value,
        [ClientContext] $ClientContext,
        $Form
    )
    $TypeValues = @{
        Disabled = 0
        PerCodeunit = 1
        PerTest=2
    }
    $suiteControl = $ClientContext.GetControlByName($Form, "CCMap")
    $ClientContext.SaveValue($suiteControl, $TypeValues[$Value])
}

function Set-TestProcedures
{
    param (
        [string] $Filter,
        [ClientContext] $ClientContext,
        $Form
    )
    $Control = $ClientContext.GetControlByName($Form, "TestProcedureRangeFilter")
    $ClientContext.SaveValue($Control, $Filter)
}

function Clear-CCResults
{
    param (
        [ClientContext] $ClientContext,
        $Form
    )
    $ClientContext.InvokeAction($ClientContext.GetActionByName($Form, "ClearCodeCoverage"))
}
function Set-StabilityRun
(
    [bool] $StabilityRun,
    [ClientContext] $ClientContext,
    $Form
)
{
    $stabilityRunControl = $ClientContext.GetControlByName($Form, "StabilityRun")
    $ClientContext.SaveValue($stabilityRunControl, $StabilityRun)
}

function Set-RunFalseOnDisabledTests
(
    [ClientContext] $ClientContext,
    [array] $DisabledTests,
    $Form
)
{
    if(!$DisabledTests)
    {
        return
    }

    foreach($disabledTestMethod in $DisabledTests)
    {
        $testKey = $disabledTestMethod.codeunitName + "," + $disabledTestMethod.method
        $removeTestMethodControl = $ClientContext.GetControlByName($Form, "DisableTestMethod")
        $ClientContext.SaveValue($removeTestMethodControl, $testKey)
    }
}

function Open-TestForm(
    [int] $TestPage = $global:DefaultTestPage,
    [ClientContext] $ClientContext
)
{ 
    $form = $ClientContext.OpenForm($TestPage)
    if (!$form) 
    {
        throw "Cannot open page $TestPage. Verify if the test tool and test objects are imported and can be opened manually."
    }

    return $form;
}

function Open-ClientSession
(
    [switch] $DisableSSLVerification,
    [ValidateSet('Windows','NavUserPassword','AAD')]
    [string] $AuthorizationType,
    [Parameter(Mandatory=$false)]
    [pscredential] $Credential,
    [Parameter(Mandatory=$true)]
    [string] $ServiceUrl,
    [string] $Culture = $script:DefaultCulture,
    [timespan] $TransactionTimeout = $script:DefaultTransactionTimeout,
    [timespan] $TcpKeepActive = $script:DefaultTcpKeepActive
)
{
    [System.Net.ServicePointManager]::SetTcpKeepAlive($true, [int]$TcpKeepActive.TotalMilliseconds, [int]$TcpKeepActive.TotalMilliseconds)

    if($DisableSSLVerification)
    {
        Disable-SslVerification
    }

    switch ($AuthorizationType)
    {
        "Windows" 
        {
            $clientContext = [ClientContext]::new($ServiceUrl, $TransactionTimeout, $Culture)
            break;
        }
        "NavUserPassword" 
        {
            if ($Credential -eq $null -or $Credential -eq [System.Management.Automation.PSCredential]::Empty) 
            {
                throw "You need to specify credentials if using NavUserPassword authentication"
            }
        
            $clientContext = [ClientContext]::new($ServiceUrl, $Credential, $TransactionTimeout, $Culture)
            break;
        }
        "AAD"
        {
            $AadTokenProvider = $global:AadTokenProvider
            if ($AadTokenProvider -eq $null) 
            {
                throw "You need to specify the AadTokenProvider for obtaining the token if using AAD authentication"
            }

            $token = $AadTokenProvider.GetToken($Credential)
            $tokenCredential = [Microsoft.Dynamics.Framework.UI.Client.TokenCredential]::new($token)
            $clientContext = [ClientContext]::new($ServiceUrl, $tokenCredential, $TransactionTimeout, $Culture)
        }
    }

    return $clientContext;
}

function Disable-SslVerification
{
    if (-not ([System.Management.Automation.PSTypeName]"SslVerification").Type)
    {
        Add-Type -TypeDefinition  @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SslVerification
{
    private static bool ValidationCallback(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; }
    public static void Disable() { System.Net.ServicePointManager.ServerCertificateValidationCallback = ValidationCallback; }
    public static void Enable()  { System.Net.ServicePointManager.ServerCertificateValidationCallback = null; }
}
"@
    }
    [SslVerification]::Disable()
}

function Enable-SslVerification
{
    if (([System.Management.Automation.PSTypeName]"SslVerification").Type)
    {
        [SslVerification]::Enable()
    }
}


function Convert-ResultStringToDateTimeSafe([string] $DateTimeString)
{
    [datetime]$parsedDateTime = New-Object DateTime
    
    try
    {
        [datetime]$parsedDateTime = [datetime]$DateTimeString
    }
    catch
    {
        Write-Host -ForegroundColor Red "Failed parsing DateTime: $DateTimeString"
    }

    return $parsedDateTime
}

function Install-WcfDependencies {
    <#
    .SYNOPSIS
    Downloads and extracts WCF NuGet packages required for .NET Core/5+/6+ environments.
    These are needed because Microsoft.Dynamics.Framework.UI.Client.dll depends on WCF types
    that are not included in modern .NET runtimes (only in full .NET Framework).
    #>
    param(
        [string]$TargetPath = $PSScriptRoot
    )

    $wcfPackages = @(
        @{ Name = "System.ServiceModel.Primitives"; Version = "6.0.0" },
        @{ Name = "System.ServiceModel.Http"; Version = "6.0.0" },
        @{ Name = "System.Private.ServiceModel"; Version = "4.10.3" }
    )

    $tempFolder = Join-Path ([System.IO.Path]::GetTempPath()) "WcfPackages_$([Guid]::NewGuid().ToString().Substring(0,8))"
    
    try {
        foreach ($package in $wcfPackages) {
            $packageName = $package.Name
            $packageVersion = $package.Version
            $expectedDll = Join-Path $TargetPath "$packageName.dll"
            
            # Skip if already exists
            if (Test-Path $expectedDll) {
                Write-Host "WCF dependency $packageName already exists"
                continue
            }

            Write-Host "Downloading WCF dependency: $packageName v$packageVersion"
            
            $nugetUrl = "https://www.nuget.org/api/v2/package/$packageName/$packageVersion"
            $packageZip = Join-Path $tempFolder "$packageName.zip"
            $packageExtract = Join-Path $tempFolder $packageName

            if (-not (Test-Path $tempFolder)) {
                New-Item -Path $tempFolder -ItemType Directory -Force | Out-Null
            }

            # Download the package
            Invoke-WebRequest -Uri $nugetUrl -OutFile $packageZip -UseBasicParsing

            # Extract
            Expand-Archive -Path $packageZip -DestinationPath $packageExtract -Force

            # Find the appropriate DLL (prefer net6.0, then netstandard2.0)
            $dllPath = $null
            $searchPaths = @(
                (Join-Path $packageExtract "lib\net6.0\$packageName.dll"),
                (Join-Path $packageExtract "lib\netstandard2.1\$packageName.dll"),
                (Join-Path $packageExtract "lib\netstandard2.0\$packageName.dll"),
                (Join-Path $packageExtract "lib\netcoreapp3.1\$packageName.dll")
            )
            
            foreach ($searchPath in $searchPaths) {
                if (Test-Path $searchPath) {
                    $dllPath = $searchPath
                    break
                }
            }

            if ($dllPath -and (Test-Path $dllPath)) {
                Copy-Item -Path $dllPath -Destination $TargetPath -Force
                Write-Host "Installed $packageName to $TargetPath"
            } else {
                Write-Warning "Could not find DLL for $packageName in package"
            }
        }
    }
    finally {
        # Cleanup temp folder
        if (Test-Path $tempFolder) {
            Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if(!$script:TypesLoaded)
{
    # Load order matters - dependencies must be loaded before the client DLL
    # See: https://github.com/microsoft/navcontainerhelper/blob/main/AppHandling/PsTestFunctions.ps1
    
    # Check if we're running on .NET Core/5+/6+ (PowerShell 7+) vs .NET Framework (Windows PowerShell 5.1)
    $isNetCore = $PSVersionTable.PSVersion.Major -ge 6
    
    if ($isNetCore) {
        # On .NET Core/5+/6+, we need to install WCF packages as they're not included by default
        Write-Host "Running on .NET Core/.NET 5+, ensuring WCF dependencies are installed..."
        Install-WcfDependencies -TargetPath $PSScriptRoot
        
        # Load WCF dependencies first
        $wcfDlls = @(
            "System.Private.ServiceModel.dll",
            "System.ServiceModel.Primitives.dll", 
            "System.ServiceModel.Http.dll"
        )
        foreach ($dll in $wcfDlls) {
            $dllPath = Join-Path $PSScriptRoot $dll
            if (Test-Path $dllPath) {
                try {
                    Add-Type -Path $dllPath -ErrorAction SilentlyContinue
                } catch {
                    # Ignore errors for already loaded assemblies
                }
            }
        }
    }
    
    # Now load the BC client dependencies in the correct order
    Add-Type -Path "$PSScriptRoot\NewtonSoft.Json.dll"
    Add-Type -Path "$PSScriptRoot\Microsoft.Internal.AntiSSRF.dll"
    Add-Type -Path "$PSScriptRoot\Microsoft.Dynamics.Framework.UI.Client.dll"
    
    $clientContextScriptPath = Join-Path $PSScriptRoot "ClientContext.ps1"
    . "$clientContextScriptPath"
}

$script:TypesLoaded = $true;

$script:ActiveDirectoryDllsLoaded = $false;
$script:DateTimeFormat = 's';

# Console test tool
$global:DefaultTestPage = 130455;
$global:AadTokenProvider = $null

# Test Isolation Disabled
$global:TestRunnerIsolationCodeunit = 130450
$global:TestRunnerIsolationDisabled = 130451
$global:DefaultTestRunner = $global:TestRunnerIsolationCodeunit
$global:TestRunnerAppId = "23de40a6-dfe8-4f80-80db-d70f83ce8caf"

$script:CodeunitLineType = '0'
$script:FunctionLineType = '1'

$script:FailureTestResultType = '1';
$script:SuccessTestResultType = '2';
$script:SkippedTestResultType = '3';

$script:NumberOfUnexpectedFailuresBeforeAborting = 50;

$script:DefaultAuthorizationType = 'NavUserPassword'
$script:DefaultTestSuite = 'DEFAULT'
$script:DefaultErrorActionPreference = 'Stop'

$script:DefaultTcpKeepActive = [timespan]::FromMinutes(2);
$script:DefaultTransactionTimeout = [timespan]::FromMinutes(10);
$script:DefaultCulture = "en-US";

$script:AllTestsExecutedResult = "All tests executed."
$script:CCCollectedResult = "Done."
Export-ModuleMember -Function Run-AlTestsInternal,Open-ClientSessionWithWait, Open-TestForm, Open-ClientSession