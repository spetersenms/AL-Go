$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

<#
.SYNOPSIS
    Shared logic for the AL-Go issue triage agent.
.DESCRIPTION
    Everything here is deliberately free of network and Copilot CLI calls so it can be unit tested.
    The orchestrator supplies the side effects; this module supplies the decisions.
#>

<#
.SYNOPSIS
    Converts a deserialized JSON object graph into nested hashtables.
#>
function ConvertTo-TriageHashTable {
    Param(
        [Parameter(ValueFromPipeline)]
        $Object
    )

    Process {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            $result = @{}
            foreach ($key in @($Object.Keys)) {
                $result[$key] = ConvertTo-TriageHashTable -Object $Object[$key]
            }
            return $result
        }
        if ($Object -is [System.Management.Automation.PSCustomObject]) {
            $result = @{}
            foreach ($property in $Object.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-TriageHashTable -Object $property.Value
            }
            return $result
        }
        if ($Object -is [System.Array]) {
            # The unary comma is load-bearing: without it a function returning an empty array
            # yields $null, and a single-element array unrolls to its element. Settings and
            # duplicate_candidates both hit this.
            $items = @()
            foreach ($item in $Object) {
                $items += , (ConvertTo-TriageHashTable -Object $item)
            }
            return , $items
        }
        return $Object
    }
}

<#
.SYNOPSIS
    Reads triage.config.json.
.PARAMETER Path
    Path to the configuration file.
#>
function Read-TriageConfig {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Triage configuration not found: $Path"
    }
    return ConvertTo-TriageHashTable -Object ((Get-Content -Path $Path -Raw -Encoding UTF8) | ConvertFrom-Json)
}

<#
.SYNOPSIS
    Extracts the deterministic facts about an issue that the model should not have to work out.
.DESCRIPTION
    This is the 'resolve' phase. Pulling these out with regular expressions rather than asking the
    model is cheaper, reproducible, and not susceptible to instructions embedded in the issue body.

    No network calls are made. Linked run accessibility is filled in separately by the orchestrator.
.PARAMETER Issue
    The issue object, with at least number, title and body.
#>
function Get-IssueContext {
    Param(
        [Parameter(Mandatory = $true)]
        $Issue
    )

    $issueData = ConvertTo-TriageHashTable -Object $Issue
    $body = ''
    if ($issueData.ContainsKey('body') -and $issueData['body']) { $body = [string]$issueData['body'] }

    # Linked workflow runs. Nearly every real AL-Go bug report references one.
    $runs = @()
    foreach ($match in [regex]::Matches($body, 'https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/actions/runs/(\d+)')) {
        $runs += @{
            url        = $match.Value
            owner      = $match.Groups[1].Value
            repo       = $match.Groups[2].Value
            runId      = $match.Groups[3].Value
            accessible = $null
        }
    }

    # AL-Go version, from the bug template section.
    $version = ''
    $versionMatch = [regex]::Match($body, '(?ms)^###\s*AL-Go version\s*\r?\n+(.+?)(?=\r?\n###|\z)')
    if ($versionMatch.Success) {
        $version = $versionMatch.Groups[1].Value.Trim()
    }

    # Fenced blocks that parse as JSON objects are very likely the reporter's settings.
    $jsonBlocks = @()
    foreach ($match in [regex]::Matches($body, '(?ms)```[A-Za-z]*\s*\r?\n(.*?)```')) {
        $candidate = $match.Groups[1].Value.Trim()
        if ($candidate.StartsWith('{') -and $candidate.EndsWith('}')) {
            try {
                ConvertFrom-Json -InputObject $candidate -ErrorAction Stop | Out-Null
                $jsonBlocks += $candidate
            }
            catch {
                # Not JSON. Skip it rather than guessing at the reporter's intent.
                Write-Verbose "Ignoring fenced block that is not valid JSON: $($_.Exception.Message)"
            }
        }
    }

    # Issue references, used as duplicate and already-fixed candidates.
    $referenced = @()
    foreach ($match in [regex]::Matches($body, '(?<![A-Za-z0-9/])#(\d{1,6})\b')) {
        $referenced += [int]$match.Groups[1].Value
    }

    $templateSections = @()
    foreach ($match in [regex]::Matches($body, '(?m)^###\s*(.+?)\s*$')) {
        $templateSections += $match.Groups[1].Value
    }

    # 'No response' placeholders mean the reporter skipped a field.
    $emptySections = @()
    foreach ($match in [regex]::Matches($body, '(?ms)^###\s*(.+?)\s*\r?\n+_No response_')) {
        $emptySections += $match.Groups[1].Value.Trim()
    }

    # Attachments. The agent once asked a reporter to produce logs they had already attached, which
    # is the rudest mistake this thing can make, so these are surfaced explicitly rather than left
    # for the model to notice in the body.
    $attachments = @()
    foreach ($match in [regex]::Matches($body, '\[([^\]]+)\]\((https://github\.com/user-attachments/files/[^\)]+)\)')) {
        $attachments += @{ name = $match.Groups[1].Value; url = $match.Groups[2].Value; kind = 'file' }
    }
    foreach ($match in [regex]::Matches($body, '<img[^>]*src="(https://github\.com/user-attachments/assets/[^"]+)"')) {
        $attachments += @{ name = 'image'; url = $match.Groups[1].Value; kind = 'image' }
    }
    foreach ($match in [regex]::Matches($body, '!\[([^\]]*)\]\((https://[^\)]+)\)')) {
        $attachments += @{ name = $match.Groups[1].Value; url = $match.Groups[2].Value; kind = 'image' }
    }

    $issueNumber = 0
    if ($issueData.ContainsKey('number') -and $issueData['number']) { $issueNumber = [int]$issueData['number'] }

    return @{
        issue_number        = $issueNumber
        title               = if ($issueData.ContainsKey('title')) { [string]$issueData['title'] } else { '' }
        author_association  = if ($issueData.ContainsKey('author_association')) { [string]$issueData['author_association'] } else { '' }
        algo_version_raw    = $version
        version_is_specific = ($version -ne '' -and $version -notmatch '^(?i)\s*preview\s*$')
        linked_runs         = $runs
        json_blocks         = $jsonBlocks
        referenced_issues   = @($referenced | Select-Object -Unique)
        template_sections   = $templateSections
        empty_sections      = $emptySections
        attachments         = $attachments
        has_attachments     = ($attachments.Count -gt 0)
        body_length         = $body.Length
    }
}

<#
.SYNOPSIS
    Validates a findings object against the findings schema.
.DESCRIPTION
    This runs at the trust boundary between the model job and the privileged publish job, so it is
    intentionally strict and hand-written rather than delegating to Test-Json, which is unavailable
    on Windows PowerShell 5.1. It supports the subset of JSON Schema the findings contract uses:
    required, additionalProperties, type, enum, const, minimum, minLength, maxLength, maxItems, and
    nested properties and array items.
.PARAMETER Findings
    The findings object to validate.
.PARAMETER Schema
    The parsed findings schema.
.PARAMETER ExpectedIssueNumber
    When supplied, the findings must target this issue. Prevents a confused or manipulated run from
    posting to an unrelated issue.
.OUTPUTS
    A hashtable with 'valid' and 'errors'.
#>
function Test-TriageFindings {
    Param(
        [Parameter(Mandatory = $true)]
        $Findings,
        [Parameter(Mandatory = $true)]
        $Schema,
        [Parameter(Mandatory = $false)]
        [int] $ExpectedIssueNumber = 0
    )

    $findingsData = ConvertTo-TriageHashTable -Object $Findings
    $schemaData = ConvertTo-TriageHashTable -Object $Schema
    $validationErrors = New-Object System.Collections.ArrayList

    function Test-TriageNode {
        Param($Value, $Definition, [string] $Path, $ErrorList)

        if ($null -eq $Definition) { return }

        if ($Definition.ContainsKey('const') -and $Value -ne $Definition['const']) {
            [void]$ErrorList.Add("$Path must be '$($Definition['const'])'.")
            return
        }

        if ($Definition.ContainsKey('type')) {
            $expectedTypes = @($Definition['type'])
            $actualType = 'null'
            if ($Value -is [bool]) { $actualType = 'boolean' }
            elseif ($Value -is [int] -or $Value -is [long]) { $actualType = 'integer' }
            elseif ($Value -is [double] -or $Value -is [decimal]) { $actualType = 'number' }
            elseif ($Value -is [string]) { $actualType = 'string' }
            elseif ($Value -is [System.Collections.IDictionary]) { $actualType = 'object' }
            elseif ($Value -is [System.Array]) { $actualType = 'array' }

            if ($expectedTypes -notcontains $actualType) {
                [void]$ErrorList.Add("$Path must be of type $($expectedTypes -join '/'), got $actualType.")
                return
            }
        }

        if ($Definition.ContainsKey('enum') -and @($Definition['enum']) -notcontains $Value) {
            [void]$ErrorList.Add("$Path has value '$Value', which is not one of: $(@($Definition['enum']) -join ', ').")
        }
        if ($Definition.ContainsKey('minimum') -and ($Value -is [int]) -and $Value -lt $Definition['minimum']) {
            [void]$ErrorList.Add("$Path must be at least $($Definition['minimum']).")
        }
        if ($Definition.ContainsKey('minLength') -and ($Value -is [string]) -and $Value.Length -lt $Definition['minLength']) {
            [void]$ErrorList.Add("$Path must be at least $($Definition['minLength']) characters.")
        }
        if ($Definition.ContainsKey('maxLength') -and ($Value -is [string]) -and $Value.Length -gt $Definition['maxLength']) {
            [void]$ErrorList.Add("$Path must be at most $($Definition['maxLength']) characters.")
        }
        if ($Definition.ContainsKey('maxItems') -and ($Value -is [System.Array]) -and $Value.Count -gt $Definition['maxItems']) {
            [void]$ErrorList.Add("$Path must have at most $($Definition['maxItems']) items.")
        }

        if (($Value -is [System.Collections.IDictionary]) -and $Definition.ContainsKey('properties')) {
            $properties = $Definition['properties']
            if ($Definition.ContainsKey('required')) {
                foreach ($required in @($Definition['required'])) {
                    if (-not $Value.ContainsKey($required)) {
                        [void]$ErrorList.Add("$Path is missing required property '$required'.")
                    }
                }
            }
            if ($Definition.ContainsKey('additionalProperties') -and $Definition['additionalProperties'] -eq $false) {
                foreach ($key in @($Value.Keys)) {
                    if (-not $properties.ContainsKey($key)) {
                        [void]$ErrorList.Add("$Path has unexpected property '$key'.")
                    }
                }
            }
            foreach ($key in @($Value.Keys)) {
                if ($properties.ContainsKey($key)) {
                    Test-TriageNode -Value $Value[$key] -Definition $properties[$key] -Path "$Path.$key" -ErrorList $ErrorList
                }
            }
        }

        if (($Value -is [System.Array]) -and $Definition.ContainsKey('items')) {
            for ($i = 0; $i -lt $Value.Count; $i++) {
                Test-TriageNode -Value $Value[$i] -Definition $Definition['items'] -Path "$Path[$i]" -ErrorList $ErrorList
            }
        }
    }

    if ($null -eq $findingsData -or -not ($findingsData -is [System.Collections.IDictionary])) {
        [void]$validationErrors.Add('findings is not an object.')
    }
    else {
        Test-TriageNode -Value $findingsData -Definition $schemaData -Path 'findings' -ErrorList $validationErrors

        if ($ExpectedIssueNumber -gt 0) {
            $actual = 0
            if ($findingsData.ContainsKey('issue_number') -and $findingsData['issue_number']) {
                $actual = [int]$findingsData['issue_number']
            }
            if ($actual -ne $ExpectedIssueNumber) {
                [void]$validationErrors.Add("findings.issue_number is $actual but this run is for issue $ExpectedIssueNumber.")
            }
        }
    }

    return @{
        valid  = ($validationErrors.Count -eq 0)
        errors = @($validationErrors)
    }
}

<#
.SYNOPSIS
    Wraps untrusted content in a fence that the content itself cannot terminate.
.DESCRIPTION
    A reporter's issue body frequently contains its own triple-backtick fences, and a hostile one
    can contain them deliberately. If the wrapper fence is the same length, the embedded content
    closes it early and everything after it is read as instructions rather than data - a fence
    breakout. Choosing a fence longer than any backtick run in the content removes that.
.PARAMETER Content
    The untrusted content to embed.
.PARAMETER Language
    Optional language hint for the opening fence.
#>
function Format-FencedBlock {
    Param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Content,
        [Parameter(Mandatory = $false)]
        [string] $Language = ''
    )

    $longestRun = 0
    foreach ($match in [regex]::Matches($Content, '`+')) {
        if ($match.Value.Length -gt $longestRun) { $longestRun = $match.Value.Length }
    }
    $fenceLength = [Math]::Max(3, $longestRun + 1)
    $fence = '`' * $fenceLength

    return "$fence$Language`n$Content`n$fence"
}

<#
.SYNOPSIS
    Extracts the last complete top-level JSON object from a block of text.
.DESCRIPTION
    Used to recover findings when the model prints them instead of writing the file. Scans for
    balanced braces while ignoring braces inside strings, and returns the last candidate that
    parses, which is the model's final answer rather than any earlier draft.
.PARAMETER Text
    Text to search.
#>
function Get-EmbeddedJsonObject {
    Param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text
    )

    if (-not $Text) { return $null }

    $candidates = @()
    $depth = 0
    $start = -1
    $inString = $false
    $escaped = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]

        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }

        if ($ch -eq '"') { $inString = $true; continue }
        if ($ch -eq '{') {
            if ($depth -eq 0) { $start = $i }
            $depth++
            continue
        }
        if ($ch -eq '}') {
            $depth--
            if ($depth -eq 0 -and $start -ge 0) {
                $candidates += $Text.Substring($start, $i - $start + 1)
                $start = -1
            }
            elseif ($depth -lt 0) {
                $depth = 0
                $start = -1
            }
        }
    }

    # Last parseable candidate wins: it is the final answer, not an earlier draft.
    for ($i = $candidates.Count - 1; $i -ge 0; $i--) {
        try {
            $parsed = $candidates[$i] | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.PSObject.Properties.Name -contains 'schema_version') {
                return $candidates[$i]
            }
        }
        catch {
            Write-Verbose "Candidate $i is not valid JSON: $($_.Exception.Message)"
        }
    }
    return $null
}

<#
.SYNOPSIS
    Reduces the agent's suggested labels to the ones policy permits.
.DESCRIPTION
    Blocked labels are removed first, then the result is intersected with the allow-list and capped.
    Anything the agent invents is silently dropped rather than trusted.
.PARAMETER Findings
    The validated findings object.
.PARAMETER Config
    The parsed triage configuration.
#>
function Select-TriageLabels {
    Param(
        [Parameter(Mandatory = $true)]
        $Findings,
        [Parameter(Mandatory = $true)]
        $Config
    )

    $findingsData = ConvertTo-TriageHashTable -Object $Findings
    $configData = ConvertTo-TriageHashTable -Object $Config
    $publish = $configData['publish']
    $allowed = @($publish['allowedLabels'])
    $blocked = @($publish['blockedLabels'])
    $maxLabels = [int]$publish['maxLabels']

    $suggested = @()
    if ($findingsData.ContainsKey('suggested_labels') -and $findingsData['suggested_labels']) {
        $suggested = @($findingsData['suggested_labels'])
    }

    $selected = New-Object System.Collections.ArrayList
    foreach ($label in $suggested) {
        $name = [string]$label
        if ($blocked -contains $name) { continue }
        if ($allowed -notcontains $name) { continue }
        if ($selected -contains $name) { continue }
        [void]$selected.Add($name)
    }

    if ($selected.Count -gt $maxLabels) {
        return @($selected[0..($maxLabels - 1)])
    }
    # Note for callers: PowerShell collapses an empty array on output, so this yields $null when
    # nothing was selected. Normalise with a null check rather than @(), which would wrap $null
    # into a one-element array.
    return @($selected)
}

<#
.SYNOPSIS
    Applies the safety overrides that must not depend on the model's judgement.
.DESCRIPTION
    Three guards, each earned from an observed failure:

    1. A traced file on the critical-path list forces `fix_risk` to critical. The model rated a
       defect in Github-Helper.psm1 as 'unknown' risk because it did not recognise the file as
       shared surface; this does not rely on it recognising anything.
    2. No traced location means the model never searched, so confident claims are downgraded rather
       than trusted.
    3. Critical or unknown risk is forced into the human-fix lane - but only when an AL-Go fix is
       actually on the table. For an issue routed to another component, 'unknown' is the correct
       answer and forcing human-fix would contradict the routing.
.PARAMETER Findings
    The validated findings object.
.PARAMETER Config
    The parsed triage configuration.
.OUTPUTS
    A hashtable with the adjusted 'findings' and a list of 'overrides' describing what changed.
#>
function Resolve-TriageSafetyOverrides {
    Param(
        [Parameter(Mandatory = $true)]
        $Findings,
        [Parameter(Mandatory = $true)]
        $Config
    )

    $findings = ConvertTo-TriageHashTable -Object $Findings
    $configData = ConvertTo-TriageHashTable -Object $Config
    $safety = $configData['safety']
    $overrides = New-Object System.Collections.ArrayList

    $traced = @()
    if ($findings.ContainsKey('traced_locations') -and $findings['traced_locations']) {
        $traced = @($findings['traced_locations'])
    }

    if ($safety.ContainsKey('criticalPaths')) {
        foreach ($location in $traced) {
            $file = ([string]$location['file']).Replace('\', '/')
            while ($file.StartsWith('./')) { $file = $file.Substring(2) }
            foreach ($criticalPath in @($safety['criticalPaths'])) {
                if ($file.StartsWith($criticalPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    if ([string]$findings['fix_risk'] -ne 'critical') {
                        [void]$overrides.Add("'$file' is a critical path; raising fix_risk from '$($findings['fix_risk'])' to 'critical'.")
                        $findings['fix_risk'] = 'critical'
                        $findings['fix_risk_reason'] = "$file is shared or shipped code. " + [string]$findings['fix_risk_reason']
                    }
                    break
                }
            }
        }
    }

    if ($safety.ContainsKey('requireTraceForHighConfidence') -and $safety['requireTraceForHighConfidence'] -and $traced.Count -eq 0) {
        if ([string]$findings['area_confidence'] -eq 'HIGH') {
            [void]$overrides.Add('area_confidence HIGH with no traced location; downgrading to MEDIUM.')
            $findings['area_confidence'] = 'MEDIUM'
        }
        if (@('low', 'medium') -contains [string]$findings['fix_risk']) {
            [void]$overrides.Add("fix_risk '$($findings['fix_risk'])' with no traced location is a guess; setting to 'unknown'.")
            $findings['fix_risk'] = 'unknown'
        }
    }

    $lanesImplyingAlGoWork = @('ready-for-maintainer')
    if (@($safety['neverAutoFixRiskLevels']) -contains [string]$findings['fix_risk'] -and
        $lanesImplyingAlGoWork -contains [string]$findings['recommended_lane']) {
        [void]$overrides.Add("fix_risk '$($findings['fix_risk'])' requires the needs-human-fix lane; overriding.")
        $findings['recommended_lane'] = 'needs-human-fix'
    }

    return @{
        findings  = $findings
        overrides = @($overrides)
    }
}

<#
.SYNOPSIS
    Renders the findings into the comment that gets posted on the issue.
.DESCRIPTION
    All prose comes from here, not from the model. The model chooses values; this decides wording.
    That keeps tone consistent and means a prompt injection cannot dictate what is said to a
    reporter.
.PARAMETER Findings
    The validated findings object.
#>
function Format-TriageComment {
    Param(
        [Parameter(Mandatory = $true)]
        $Findings
    )

    $f = ConvertTo-TriageHashTable -Object $Findings
    $lines = New-Object System.Collections.ArrayList

    $areaNames = @{
        'al-go'             = 'AL-Go'
        'bccontainerhelper' = 'BcContainerHelper'
        'bc-platform'       = 'the Business Central platform or AL compiler'
        'bc-saas'           = 'Business Central online'
        'github'            = 'GitHub itself'
        'user-config'       = 'repository configuration'
        'unknown'           = 'an area we could not determine yet'
    }

    [void]$lines.Add('### AL-Go issue triage')
    [void]$lines.Add('')
    [void]$lines.Add([string]$f['summary'])
    [void]$lines.Add('')

    switch ([string]$f['recommended_lane']) {
        'redirect-to-discussions' {
            [void]$lines.Add('This looks like a question or a feature request rather than a bug. Those are handled in [Discussions](https://github.com/microsoft/AL-Go/discussions), where more people will see it. A maintainer will confirm.')
        }
        'already-fixed-upgrade' {
            [void]$lines.Add("This looks like something that was already fixed in **$([string]$f['fixed_in_release'])**, which is newer than the version reported here. Upgrading may well resolve it. If it still happens afterwards, please say so and we will take another look.")
        }
        'route-to-other-component' {
            $area = $areaNames[[string]$f['suggested_area']]
            [void]$lines.Add("Based on the evidence, this looks like it originates in **$area** rather than in AL-Go itself. A maintainer will confirm and redirect it if needed - please do not re-file it yet.")
        }
        'needs-information' {
            [void]$lines.Add('We need a little more information before this can be investigated.')
        }
        'possible-duplicate' {
            [void]$lines.Add('This may already be tracked by an existing issue. A maintainer will confirm before anything is closed.')
        }
        'needs-human-fix' {
            [void]$lines.Add('This one touches sensitive parts of AL-Go, so it is being routed to a maintainer for hands-on investigation rather than handled automatically.')
        }
        default {
            [void]$lines.Add('This report has what we need to start looking into it. A maintainer will pick it up.')
        }
    }
    [void]$lines.Add('')

    if ($f['has_missing_information'] -and [string]$f['missing_information'] -ne 'None') {
        [void]$lines.Add('**What would help**')
        [void]$lines.Add('')
        [void]$lines.Add([string]$f['missing_information'])
        [void]$lines.Add('')
    }

    $requirement = [string]$f['troubleshooting_requirement']
    if ($requirement -eq 'REQUIRED' -or $requirement -eq 'RECOMMENDED') {
        $runNote = ''
        if ($f.ContainsKey('linked_run') -and $f['linked_run'] -and
            $f['linked_run'].ContainsKey('accessible') -and $f['linked_run']['accessible'] -eq $false) {
            # Do not imply the reporter did anything wrong: private repositories are the norm here.
            $runNote = ' The workflow run you linked is in a private repository, so we cannot read it from here.'
        }
        [void]$lines.Add("**Logs**$runNote Running the **Troubleshooting** workflow in your repository and pasting the output is usually the fastest way to get this moving. Please redact any secrets, tokens, or URLs containing credentials before sharing.")
        [void]$lines.Add('')
    }

    $duplicates = @()
    if ($f.ContainsKey('duplicate_candidates') -and $f['duplicate_candidates']) {
        $duplicates = @($f['duplicate_candidates'])
    }
    if ($duplicates.Count -gt 0) {
        [void]$lines.Add('**Possibly related**')
        [void]$lines.Add('')
        foreach ($duplicate in $duplicates) {
            $confidence = ([string]$duplicate['confidence']).ToLowerInvariant()
            [void]$lines.Add("- #$($duplicate['number']) - $($duplicate['reason']) _($confidence confidence)_")
        }
        [void]$lines.Add('')
    }

    switch ([string]$f['repro_outcome']) {
        'REPRODUCED' {
            [void]$lines.Add('We reproduced this locally, so it is confirmed.')
            [void]$lines.Add('')
        }
        'COULD_NOT_CONSTRUCT' {
            [void]$lines.Add('We could not build an automated reproduction for this one. That is common and does not mean the report is wrong - it usually just means the failure depends on a container, tenant, or credential we cannot recreate here.')
            [void]$lines.Add('')
        }
    }

    [void]$lines.Add('<sub>Automated triage. A maintainer reviews every issue, and this comment may be wrong - please say so if it is.</sub>')
    [void]$lines.Add('<!-- al-go-issue-triage -->')

    return ($lines -join "`n")
}

Export-ModuleMember -Function ConvertTo-TriageHashTable, Read-TriageConfig, Get-IssueContext, Test-TriageFindings, Select-TriageLabels, Resolve-TriageSafetyOverrides, Format-TriageComment, Format-FencedBlock, Get-EmbeddedJsonObject
