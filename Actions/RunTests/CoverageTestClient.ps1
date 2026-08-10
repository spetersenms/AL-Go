# CoverageTestClient.ps1
#
# Loads the Business Central client assemblies and exposes New-ClientContext for the AlTool
# code-coverage path. This is a trimmed, vendored copy of the assembly-loading preamble and the
# New-ClientContext function from BcContainerHelper's PsTestFunctions.ps1
# (https://github.com/microsoft/navcontainerhelper, MIT licensed). The rest of PsTestFunctions.ps1
# (the BcContainerHelper test-runner harness) is not used by the coverage collector and is not
# vendored. Vendoring keeps this path independent of whichever BcContainerHelper version is
# installed on the runner.
#
# The DLL paths are supplied at runtime (the assemblies are copied from the build container).

Param(
    [Parameter(Mandatory = $true)]
    [string] $clientDllPath,
    [Parameter(Mandatory = $true)]
    [string] $newtonSoftDllPath,
    [string] $clientContextScriptPath = $null
)

$antiSSRFdll = Join-Path ([System.IO.Path]::GetDirectoryName($clientDllPath)) 'Microsoft.Internal.AntiSSRF.dll'

# Load the client assemblies before the ClientContext class script is dot-sourced, so the class
# method signatures that reference these types resolve.
Add-Type -Path $newtonSoftDllPath
if (Test-Path $antiSSRFdll) {
    Add-Type -Path $antiSSRFdll
}
Add-Type -Path $clientDllPath

if (!($clientContextScriptPath)) {
    $clientContextScriptPath = Join-Path $PSScriptRoot "CoverageClientContext.ps1"
}

. $clientContextScriptPath -clientDllPath $clientDllPath

function New-ClientContext {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $serviceUrl,
        [ValidateSet('Windows', 'NavUserPassword', 'AAD')]
        [string] $auth = 'NavUserPassword',
        [Parameter(Mandatory = $false)]
        [pscredential] $credential,
        [timespan] $interactionTimeout = [timespan]::FromMinutes(10),
        [string] $culture = "en-US",
        [string] $timezone = "",
        [switch] $debugMode
    )

    if ($auth -eq "Windows") {
        $clientContext = [ClientContext]::new($serviceUrl, $interactionTimeout, $culture, $timezone)
    }
    elseif ($auth -eq "NavUserPassword") {
        if ($null -eq $Credential -or $credential -eq [System.Management.Automation.PSCredential]::Empty) {
            throw "You need to specify credentials if using NavUserPassword authentication"
        }
        $clientContext = [ClientContext]::new($serviceUrl, $credential, $interactionTimeout, $culture, $timezone)
    }
    elseif ($auth -eq "AAD") {

        if ($null -eq $Credential -or $credential -eq [System.Management.Automation.PSCredential]::Empty) {
            throw "You need to specify credentials (Username and AccessToken) if using AAD authentication"
        }
        $accessToken = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password))
        $clientContext = [ClientContext]::new($serviceUrl, $accessToken, $interactionTimeout, $culture, $timezone)
    }
    else {
        throw "Unsupported authentication setting"
    }
    if ($clientContext) {
        $clientContext.debugMode = $debugMode
    }
    return $clientContext
}
