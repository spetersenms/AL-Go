<#
.SYNOPSIS
    Runner-agnostic AL code coverage collector for the RunTests action.
.DESCRIPTION
    Collects line-level AL code coverage while the built-in AlTool (`al runtests`) runner executes
    tests against the kept-alive build container. AlTool has no native coverage flag, so coverage is
    captured with the server-instance-global collector built into the BaseApp "Code Coverage" page
    (page 9990):

      1. A single persistent client session opens page 9990 and invokes Start. Start always records
         in MultiSession mode, so every session on the server instance (including the sessions AlTool
         opens to run tests) is recorded.
      2. AlTool runs the tests in its own sessions while the collector session is kept open.
      3. The collector invokes Refresh (flushes the in-memory coverage store) and then the page's
         detailed export, downloads the per-line result and converts it to the .dat format the
         CoverageProcessor module (BCCoverageParser) consumes.
      4. The collector invokes Stop and closes the session.

    The collector requires the server setting TestAutomationEnabled=true. It is opt-in (only used when
    the enableCodeCoverage setting is set and no RunTestsInBcContainer override is supplied).

    THIN CLIENT SEAM (single BcContainerHelper touchpoint):
    All dependencies on a live client session are isolated in New-CoverageClientSession /
    Open-CoveragePage / Invoke-CoveragePageAction / Invoke-CoveragePageExport / Close-CoverageClientSession.
    These are the only functions that know about the BcContainerHelper ClientContext. The collector
    orchestration (Start-CodeCoverageCollection / Stop-CodeCoverageCollection) and the format
    conversion (Convert-CodeCoverageDetailedToDat) do not reference the client directly, so the BCH
    ClientContext can be replaced with a standalone client later without touching the collector logic.
#>

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

$script:CodeCoveragePageId = 9990

function Get-CoverageClientToolFolder {
    <#
    .SYNOPSIS
        Prepares a host folder with the client DLLs and BcContainerHelper client scripts.
    .DESCRIPTION
        Copies the UI client assemblies from the container's "C:\Test Assemblies" folder and the
        BcContainerHelper PsTestFunctions.ps1 / ClientContext.ps1 scripts to a temporary host folder,
        mirroring how BcContainerHelper sets up a host-side client session (connectFromHost). Returns
        the folder path together with the resolved DLL and script paths.
    .PARAMETER containerName
        The name of the build container to copy the client assemblies from.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [string] $containerName
    )

    $toolFolder = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
    New-Item -Path $toolFolder -ItemType Directory | Out-Null

    $bchModule = Get-Module BcContainerHelper
    if (-not $bchModule) {
        $bchModule = Get-Module BcContainerHelper -ListAvailable | Select-Object -First 1
    }
    if (-not $bchModule) {
        throw "BcContainerHelper module is not loaded; cannot set up the coverage client session."
    }
    $appHandling = Join-Path $bchModule.ModuleBase 'AppHandling'
    Copy-Item -Path (Join-Path $appHandling 'PsTestFunctions.ps1') -Destination $toolFolder -Force
    Copy-Item -Path (Join-Path $appHandling 'ClientContext.ps1') -Destination $toolFolder -Force

    $clientDllPath = Join-Path $toolFolder 'Microsoft.Dynamics.Framework.UI.Client.dll'
    $newtonSoftDllPath = Join-Path $toolFolder 'Newtonsoft.Json.dll'
    $antiSSRFDllPath = Join-Path $toolFolder 'Microsoft.Internal.AntiSSRF.dll'

    Copy-FileFromBcContainer -containerName $containerName -containerPath 'C:\Test Assemblies\Microsoft.Dynamics.Framework.UI.Client.dll' -localPath $clientDllPath
    Copy-FileFromBcContainer -containerName $containerName -containerPath 'C:\Test Assemblies\Newtonsoft.Json.dll' -localPath $newtonSoftDllPath
    try {
        Copy-FileFromBcContainer -containerName $containerName -containerPath 'C:\Test Assemblies\Microsoft.Internal.AntiSSRF.dll' -localPath $antiSSRFDllPath
    }
    catch {
        # AntiSSRF is not present on every version; the client loads without it when absent.
        Write-Host "Note: Microsoft.Internal.AntiSSRF.dll was not copied ($($_.Exception.Message)). Continuing."
    }

    return @{
        ToolFolder           = $toolFolder
        ClientDllPath        = $clientDllPath
        NewtonSoftDllPath    = $newtonSoftDllPath
        PsTestFunctionsPath  = Join-Path $toolFolder 'PsTestFunctions.ps1'
        ClientContextPath    = Join-Path $toolFolder 'ClientContext.ps1'
    }
}

function New-CoverageClientSession {
    <#
    .SYNOPSIS
        Opens a client session against the build container (thin BcContainerHelper seam).
    .DESCRIPTION
        This is the single BcContainerHelper client touchpoint in the AlTool coverage path. It
        resolves the container's web endpoint and credential type, prepares the client assemblies,
        dot-sources the BcContainerHelper client scripts and opens a ClientContext. The returned
        session object exposes only the state the rest of the collector needs, so the underlying
        client can be swapped later without changing the collector logic.
    .PARAMETER containerName
        The name of the build container to connect to.
    .PARAMETER credential
        The credential used to connect to the container.
    .PARAMETER tenant
        The tenant to connect to. Defaults to 'default'.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [string] $containerName,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential] $credential,
        [string] $tenant = 'default'
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Collecting code coverage with the built-in AlTool runner requires PowerShell 7."
    }

    $serverConfig = Get-BcContainerServerConfiguration -ContainerName $containerName
    $publicWebBaseUrl = "$($serverConfig.PublicWebBaseUrl)".TrimEnd('/')
    if (-not $publicWebBaseUrl) {
        throw "Container '$containerName' has no PublicWebBaseUrl; the WebClient is required to collect code coverage."
    }
    $auth = "$($serverConfig.ClientServicesCredentialType)"
    if (-not $auth) { $auth = 'NavUserPassword' }

    $tool = Get-CoverageClientToolFolder -containerName $containerName

    $serviceUrl = "$publicWebBaseUrl/cs?tenant=$tenant"

    # Dot-source the BcContainerHelper client scripts (loads the client assemblies and ClientContext).
    . $tool.PsTestFunctionsPath -newtonSoftDllPath $tool.NewtonSoftDllPath -clientDllPath $tool.ClientDllPath -clientContextScriptPath $tool.ClientContextPath

    $clientContext = New-ClientContext -serviceUrl $serviceUrl -auth $auth -credential $credential -culture 'en-US' -timezone ''

    $uriCaptureFile = Join-Path $tool.ToolFolder 'exporturi.txt'
    $captureEvent = Register-ObjectEvent -InputObject $clientContext.clientSession -EventName UriToShow -MessageData $uriCaptureFile -Action {
        Add-Content -Path $Event.MessageData -Value $EventArgs.UriToShow
    }

    return @{
        ClientContext    = $clientContext
        PublicWebBaseUrl = $publicWebBaseUrl
        Auth             = $auth
        Credential       = $credential
        Tenant           = $tenant
        ToolFolder       = $tool.ToolFolder
        UriCaptureFile   = $uriCaptureFile
        CaptureEvent     = $captureEvent
    }
}

function Open-CoveragePage {
    <#
    .SYNOPSIS
        Opens a page in the coverage client session (thin seam).
    .PARAMETER session
        The session object returned by New-CoverageClientSession.
    .PARAMETER pageId
        The page (form) id to open.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [hashtable] $session,
        [Parameter(Mandatory = $true)]
        [int] $pageId
    )

    $form = $session.ClientContext.OpenForm($pageId)
    if ($null -eq $form) {
        throw "Could not open page $pageId in the coverage client session."
    }
    return $form
}

function Invoke-CoveragePageAction {
    <#
    .SYNOPSIS
        Invokes a named action on an open coverage page (thin seam).
    .PARAMETER session
        The session object returned by New-CoverageClientSession.
    .PARAMETER form
        The open form to invoke the action on.
    .PARAMETER actionName
        The name of the action to invoke.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [hashtable] $session,
        [Parameter(Mandatory = $true)]
        $form,
        [Parameter(Mandatory = $true)]
        [string] $actionName
    )

    $action = $session.ClientContext.GetActionByName($form, $actionName)
    if ($null -eq $action) {
        throw "Action '$actionName' was not found on the coverage page."
    }
    $session.ClientContext.InvokeAction($action)
}

function Invoke-CoveragePageExport {
    <#
    .SYNOPSIS
        Invokes an export action and downloads the produced file (thin seam).
    .DESCRIPTION
        Invokes the given page action, captures the file download URI raised by the client session
        (UriToShow) and downloads the file to the given local path using the same credential as the
        client session. Returns the local file path.
    .PARAMETER session
        The session object returned by New-CoverageClientSession.
    .PARAMETER form
        The open form to invoke the export action on.
    .PARAMETER actionName
        The name of the export action to invoke.
    .PARAMETER localPath
        The local path to download the exported file to.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [hashtable] $session,
        [Parameter(Mandatory = $true)]
        $form,
        [Parameter(Mandatory = $true)]
        [string] $actionName,
        [Parameter(Mandatory = $true)]
        [string] $localPath
    )

    if (Test-Path $session.UriCaptureFile) {
        Remove-Item $session.UriCaptureFile -Force
    }

    $exportAction = $session.ClientContext.GetActionByName($form, $actionName)
    if ($null -eq $exportAction) {
        throw "Export action '$actionName' was not found on the coverage page."
    }
    # The export raises a file download interaction rather than opening a form.
    $null = $session.ClientContext.InvokeActionAndCatchForm($exportAction)

    $uri = $null
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-Path $session.UriCaptureFile) {
            $uri = (Get-Content -Path $session.UriCaptureFile | Where-Object { $_ } | Select-Object -Last 1)
            if ($uri) { break }
        }
        Start-Sleep -Milliseconds 200
    }
    if (-not $uri) {
        throw "No download URI was produced by the '$actionName' export action."
    }
    $uri = $uri.Trim()

    $baseUri = [System.Uri]::new($session.PublicWebBaseUrl)
    $downloadUrl = "$($baseUri.Scheme)://$($baseUri.Authority)/$($uri.TrimStart('/'))"

    Get-CoverageDownload -downloadUrl $downloadUrl -auth $session.Auth -credential $session.Credential -localPath $localPath
    return $localPath
}

function Get-CoverageDownload {
    <#
    .SYNOPSIS
        Downloads a file from the container web endpoint using the client credential.
    .PARAMETER downloadUrl
        The absolute URL to download.
    .PARAMETER auth
        The authentication type ('NavUserPassword', 'Windows' or 'AAD').
    .PARAMETER credential
        The credential used for the download.
    .PARAMETER localPath
        The local path to write the downloaded bytes to.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'No secure string is created; the plain password is only handed to the HTTP client credential for the download')]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $downloadUrl,
        [Parameter(Mandatory = $true)]
        [string] $auth,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential] $credential,
        [Parameter(Mandatory = $true)]
        [string] $localPath
    )

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    try {
        if ($auth -eq 'Windows') {
            $handler.UseDefaultCredentials = $true
        }
        else {
            $networkCredential = $credential.GetNetworkCredential()
            $handler.Credentials = New-Object System.Net.NetworkCredential($networkCredential.UserName, $networkCredential.Password)
        }
        $httpClient = New-Object System.Net.Http.HttpClient($handler)
        try {
            $bytes = $httpClient.GetByteArrayAsync($downloadUrl).GetAwaiter().GetResult()
            [System.IO.File]::WriteAllBytes($localPath, $bytes)
        }
        finally {
            $httpClient.Dispose()
        }
    }
    finally {
        $handler.Dispose()
    }
}

function Close-CoverageClientSession {
    <#
    .SYNOPSIS
        Closes the coverage client session and cleans up temporary files (thin seam).
    .PARAMETER session
        The session object returned by New-CoverageClientSession.
    #>
    Param(
        [hashtable] $session
    )

    if ($null -eq $session) { return }

    if ($session.CaptureEvent) {
        try { Unregister-Event -SourceIdentifier $session.CaptureEvent.Name -ErrorAction SilentlyContinue } catch { Write-Host "Note: could not unregister the download-capture event." }
    }
    if ($session.ClientContext) {
        try { $session.ClientContext.Dispose() } catch { Write-Host "Note: could not dispose the coverage client session." }
    }
    if ($session.ToolFolder -and (Test-Path $session.ToolFolder)) {
        try { Remove-Item -Path $session.ToolFolder -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Host "Note: could not remove the coverage client tool folder." }
    }
}

function Convert-CodeCoverageDetailedToDat {
    <#
    .SYNOPSIS
        Converts the BaseApp "Code Coverage Detailed" export to the BCCoverageParser .dat format.
    .DESCRIPTION
        The detailed export produced by page 9990 is a quoted CSV hit list with four columns:
        "ObjectType","ObjectID","LineNo","NoOfHits". Every listed line was executed at least once.
        The CoverageProcessor .dat format expects five columns:
        ObjectType,ObjectID,LineNo,CoverageStatus,NoOfHits (CoverageStatus 0=Covered). This function
        strips the quotes and inserts CoverageStatus=0 for every hit line. Lines that were not
        executed are simply absent from the hit list; the CoverageProcessor derives not-covered lines
        from the AL source.
    .PARAMETER detailedFilePath
        Path to the downloaded "Code Coverage Detailed" file.
    .PARAMETER datFilePath
        Path to write the converted .dat file to.
    .OUTPUTS
        The number of coverage rows written.
    #>
    [OutputType([int])]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $detailedFilePath,
        [Parameter(Mandatory = $true)]
        [string] $datFilePath
    )

    if (-not (Test-Path $detailedFilePath)) {
        throw "Code coverage detailed file not found: $detailedFilePath"
    }

    # The detailed export is a single-byte encoded (UTF-8) text file; detect a BOM defensively.
    $bytes = [System.IO.File]::ReadAllBytes($detailedFilePath)
    $lines = @()
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $lines = @(Get-Content -Path $detailedFilePath -Encoding Unicode)
    }
    else {
        $lines = @(Get-Content -Path $detailedFilePath -Encoding UTF8)
    }

    $outputLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Trim().Trim('"') -split '","'
        if ($parts.Count -lt 4) { continue }
        $objectType = $parts[0].Trim()
        $objectId = $parts[1].Trim()
        $lineNo = $parts[2].Trim()
        $hits = $parts[3].Trim()
        if (-not ($objectId -match '^\d+$') -or -not ($lineNo -match '^\d+$')) { continue }
        if (-not ($hits -match '^\d+$')) { $hits = '0' }
        # Every listed line is a hit -> CoverageStatus 0 (Covered).
        $outputLines.Add("$objectType,$objectId,$lineNo,0,$hits")
    }

    $outputFolder = Split-Path -Path $datFilePath -Parent
    if ($outputFolder -and -not (Test-Path $outputFolder)) {
        New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($datFilePath, ($outputLines -join "`n") + "`n", $utf8NoBom)

    return $outputLines.Count
}

function Confirm-CodeCoveragePrerequisite {
    <#
    .SYNOPSIS
        Ensures the container has TestAutomationEnabled so coverage can be recorded.
    .DESCRIPTION
        The BaseApp code coverage collector only records when the server setting
        TestAutomationEnabled is true. When it is not, this enables it (which restarts the service).
    .PARAMETER containerName
        The name of the build container.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [string] $containerName
    )

    $serverConfig = Get-BcContainerServerConfiguration -ContainerName $containerName
    $testAutomation = "$($serverConfig.TestAutomationEnabled)"
    if ($testAutomation -ne 'true' -and $testAutomation -ne 'True') {
        Write-Host "::Notice::Enabling TestAutomationEnabled on container '$containerName' (required for code coverage). The service will restart."
        Set-BcContainerServerConfiguration -ContainerName $containerName -KeyName 'TestAutomationEnabled' -KeyValue 'true'
    }
}

function Start-CodeCoverageCollection {
    <#
    .SYNOPSIS
        Starts global code coverage recording on the build container.
    .DESCRIPTION
        Ensures TestAutomationEnabled, opens a persistent client session against the BaseApp
        "Code Coverage" page (9990) and invokes Start (MultiSession). The returned collector must be
        kept until Stop-CodeCoverageCollection is called so recording stays active across the AlTool
        test sessions.
    .PARAMETER containerName
        The name of the build container to collect coverage from.
    .PARAMETER credential
        The credential used to connect to the container.
    .PARAMETER tenant
        The tenant to connect to. Defaults to 'default'.
    .OUTPUTS
        A collector object to pass to Stop-CodeCoverageCollection.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [string] $containerName,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential] $credential,
        [string] $tenant = 'default'
    )

    Confirm-CodeCoveragePrerequisite -containerName $containerName

    Write-Host "Starting code coverage recording on container '$containerName' (page $script:CodeCoveragePageId, MultiSession)."
    $session = New-CoverageClientSession -containerName $containerName -credential $credential -tenant $tenant
    $form = Open-CoveragePage -session $session -pageId $script:CodeCoveragePageId
    Invoke-CoveragePageAction -session $session -form $form -actionName 'Start'

    return @{
        Session = $session
        Form    = $form
    }
}

function Stop-CodeCoverageCollection {
    <#
    .SYNOPSIS
        Refreshes, exports and stops global code coverage recording.
    .DESCRIPTION
        Invokes Refresh to flush the in-memory coverage store, exports the per-line detailed coverage,
        converts it to the .dat format the CoverageProcessor consumes, invokes Stop and closes the
        client session. The client session is always closed, even on failure.
    .PARAMETER collector
        The collector object returned by Start-CodeCoverageCollection.
    .PARAMETER outputDatPath
        The path to write the converted coverage .dat file to.
    .OUTPUTS
        The path of the written .dat file, or $null when no coverage was produced.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [hashtable] $collector,
        [Parameter(Mandatory = $true)]
        [string] $outputDatPath
    )

    if ($null -eq $collector -or -not $collector.Session) {
        return $null
    }

    $session = $collector.Session
    $form = $collector.Form
    $result = $null
    try {
        Invoke-CoveragePageAction -session $session -form $form -actionName 'Refresh'

        $detailedPath = Join-Path $session.ToolFolder 'CodeCoverageDetailed.txt'
        Invoke-CoveragePageExport -session $session -form $form -actionName 'Backup/Restore' -localPath $detailedPath | Out-Null

        $rowCount = Convert-CodeCoverageDetailedToDat -detailedFilePath $detailedPath -datFilePath $outputDatPath
        Write-Host "Collected $rowCount covered code line(s) to $outputDatPath"
        $result = $outputDatPath

        try { Invoke-CoveragePageAction -session $session -form $form -actionName 'Stop' } catch { Write-Host "Note: could not invoke Stop on the coverage page." }
        try { $session.ClientContext.CloseForm($form) } catch { Write-Host "Note: could not close the coverage page." }
    }
    finally {
        Close-CoverageClientSession -session $session
    }

    return $result
}

Export-ModuleMember -Function Start-CodeCoverageCollection, Stop-CodeCoverageCollection, Convert-CodeCoverageDetailedToDat
