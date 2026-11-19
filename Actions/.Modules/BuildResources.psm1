$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

function Get-BuildContainerName {
    <#
    .SYNOPSIS
        Gets the container name assigned to this build job without creating an identity.
    #>
    if ($env:_ALGoBuildId -cnotmatch '^[a-f0-9]{32}$') {
        throw "The AL-Go build resource identity is missing or invalid. Initialize build resources before creating a container."
    }
    # Encode 64 random GUID bits in base 36 to stay within the Windows hostname limit.
    $randomHex = $env:_ALGoBuildId.Substring(0, 8) + $env:_ALGoBuildId.Substring(24, 8)
    $number = [bigint]::Parse("0$randomHex", [Globalization.NumberStyles]::HexNumber)
    $suffix = ''
    do {
        $suffix = '0123456789abcdefghijklmnopqrstuvwxyz'[[int]($number % 36)] + $suffix
        $number = [bigint]::Divide($number, 36)
    } while ($number -gt 0)
    return "bc$($suffix.PadLeft(13, '0'))"
}

function Initialize-BuildResources {
    <#
    .SYNOPSIS
        Assigns and persists a resource identity for this build job.
    .DESCRIPTION
        Reuses an identity initialized by the workflow or an earlier action in the job.
        Also updates the current process because GITHUB_ENV only affects later steps.
    #>
    if (-not $env:_ALGoBuildId) {
        $env:_ALGoBuildId = [guid]::NewGuid().ToString('N')
    }
    $env:containerName = Get-BuildContainerName
    Add-Content -Encoding UTF8 -LiteralPath $env:GITHUB_ENV -Value @(
        "_ALGoBuildId=$env:_ALGoBuildId"
        "containerName=$env:containerName"
    )
}

function Get-OwnedBuildContainer {
    <#
    .SYNOPSIS
        Gets an existing container ID only after verifying this job's ownership labels.
    .PARAMETER containerName
        The container name assigned to this build job.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $containerName
    )

    if ($containerName -cne (Get-BuildContainerName)) {
        throw "Container '$containerName' is not assigned to this AL-Go build job."
    }
    $result = @(docker container ls --all --no-trunc --filter "name=^/$containerName`$" --format '{{.ID}}' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to find build container '$containerName': $($result -join [Environment]::NewLine)"
    }
    if ($result.Count -eq 0) {
        return $null
    }
    if ($result.Count -ne 1 -or "$($result[0])" -notmatch '^[a-f0-9]{64}$') {
        throw "Docker returned an unexpected container identity for '$containerName'."
    }
    $id = "$($result[0])"
    $result = @(docker container ls --all --no-trunc --filter "id=$id" --filter 'label=creator=AL-Go' --filter "label=al-go.build-id=$env:_ALGoBuildId" --format '{{.ID}}' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect build container '$containerName': $($result -join [Environment]::NewLine)"
    }
    if ($result.Count -ne 1 -or "$($result[0])" -cne $id) {
        throw "Container '$containerName' does not belong to this AL-Go build job. It will not be replaced or removed."
    }
    return $id
}

function New-OwnedBuildContainer {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $parameters,
        [scriptblock] $override
    )

    Get-OwnedBuildContainer -containerName $parameters.containerName | Out-Null
    $parameters = $parameters.Clone()
    $additionalParameters = @()
    if ($parameters.ContainsKey('additionalParameters')) {
        $additionalParameters += $parameters.additionalParameters
    }
    $labels = [ordered]@{
        'creator' = 'AL-Go'
        'al-go.build-id' = $env:_ALGoBuildId
        'al-go.repository' = $env:GITHUB_REPOSITORY
        'al-go.run-id' = $env:GITHUB_RUN_ID
        'al-go.run-attempt' = $env:GITHUB_RUN_ATTEMPT
    }
    foreach ($key in $labels.Keys) {
        if ($labels[$key]) {
            $additionalParameters += "--label `"$key=$($labels[$key])`""
        }
    }
    $parameters['additionalParameters'] = $additionalParameters
    if ($override) {
        & $override $parameters
    }
    else {
        New-BcContainer @parameters
        Invoke-ScriptInBcContainer $parameters.containerName -scriptblock { $ProgressPreference = 'SilentlyContinue' }
    }
    if (-not (Get-OwnedBuildContainer -containerName $parameters.containerName)) {
        throw "Container creation did not produce the assigned AL-Go build container."
    }
}

function Remove-BuildContainer {
    <#
    .SYNOPSIS
        Removes only a container owned by the current build job.
    .PARAMETER parameters
        BcContainerHelper removal parameters, including the assigned containerName.
    .PARAMETER override
        Optional project removal callback, invoked only after ownership is verified.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $parameters,
        [scriptblock] $override
    )

    if (-not (Get-OwnedBuildContainer -containerName $parameters.containerName)) {
        Write-Host "Build container '$($parameters.containerName)' is not present. No container resources will be removed."
        return
    }
    if ($override) {
        & $override $parameters
    }
    else {
        Remove-BcContainerSession -containerName $parameters.containerName -killPsSessionProcess
        Remove-BcContainer @parameters
    }
    if (Get-OwnedBuildContainer -containerName $parameters.containerName) {
        throw "Build container '$($parameters.containerName)' still exists after cleanup."
    }
}

function Set-BuildContainerOverrides {
    <#
    .SYNOPSIS
        Adds job ownership checks and labels to the pipeline container callbacks.
    .PARAMETER runAlPipelineParams
        Pipeline parameters containing any existing project callbacks.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $runAlPipelineParams
    )

    Get-OwnedBuildContainer -containerName (Get-BuildContainerName) | Out-Null
    $createOverride = $null
    $removeOverride = $null
    if ($runAlPipelineParams.ContainsKey('NewBcContainer')) {
        $createOverride = $runAlPipelineParams.NewBcContainer
    }
    if ($runAlPipelineParams.ContainsKey('RemoveBcContainer')) {
        $removeOverride = $runAlPipelineParams.RemoveBcContainer
    }
    $createContainer = ${function:New-OwnedBuildContainer}
    $removeContainer = ${function:Remove-BuildContainer}
    $runAlPipelineParams['NewBcContainer'] = {
        param([hashtable] $parameters)
        & $createContainer -parameters $parameters -override $createOverride
    }.GetNewClosure()
    $runAlPipelineParams['RemoveBcContainer'] = {
        param([hashtable] $parameters)
        & $removeContainer -parameters $parameters -override $removeOverride
    }.GetNewClosure()
}

Export-ModuleMember -Function Initialize-BuildResources, Get-BuildContainerName, Get-OwnedBuildContainer, Remove-BuildContainer, Set-BuildContainerOverrides
