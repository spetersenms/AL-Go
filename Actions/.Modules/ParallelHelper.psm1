Import-Module (Join-Path -Path $PSScriptRoot "DebugLogHelper.psm1")

<#
    .SYNOPSIS
        Run a script block over a collection in parallel on PowerShell 7+, falling back to
        sequential execution on Windows PowerShell 5.x or when parallelism is disabled.
    .DESCRIPTION
        On PowerShell 7+, this uses `ForEach-Object -Parallel` with a configurable throttle limit
        (defaults to the number of logical processors). On Windows PowerShell 5.x — which does not
        ship with `ForEach-Object -Parallel` — the helper transparently runs the script block
        sequentially in the current runspace. Callers therefore get the same return semantics
        regardless of host PS version.

        Each parallel iteration runs in its own runspace and does NOT share variables, modules,
        functions, or `$script:`-scoped state with the caller. Anything the script block needs
        must be supplied via the `-Variables` hashtable (passed as the second positional argument
        to the script block) or re-imported inside the script block itself.

        Results are collected in a thread-safe bag; the helper preserves input order on return,
        regardless of completion order, so downstream code that depends on stable ordering does
        not need to re-sort.

        Note: PS7's `ForEach-Object -Parallel` does not allow `$using:` to reference a script block,
        so this helper transports the script block as text (`$ScriptBlock.ToString()`) and
        re-creates it inside each parallel iteration via `[scriptblock]::Create()`. This means the
        script block must NOT depend on closure state from the caller — pass everything it needs
        via `-Variables`.

    .PARAMETER InputObject
        The collection of items to iterate over. Each item is passed as the first positional
        argument to the script block.
    .PARAMETER ScriptBlock
        The script block to invoke per item. It will be called as `& $sb $item $Variables`.
        Use `param($item, $vars)` at the top of the script block.
    .PARAMETER ThrottleLimit
        Maximum number of concurrent iterations. Default is `[Environment]::ProcessorCount`.
        Ignored when running serially.
    .PARAMETER Variables
        Optional hashtable passed as the second positional argument to each iteration's script block.
        Use this for shared inputs that every iteration needs (e.g. base folder paths, module paths).
    .PARAMETER ForceSerial
        When set, always run sequentially regardless of host PS version. Use this to opt out
        of parallelism when a caller knows the work is not thread-safe.
    .OUTPUTS
        An array of the script block's outputs in the same order as `$InputObject`.
    .EXAMPLE
        Invoke-AlGoParallel -InputObject @('a','b','c') -Variables @{ Prefix = 'X-' } -ScriptBlock {
            param($item, $vars)
            "$($vars.Prefix)$item"
        }
        # Returns @('X-a','X-b','X-c'), parallel on PS7+, serial on PS5.
#>
function Invoke-AlGoParallel {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $InputObject,
        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 256)]
        [int] $ThrottleLimit = [Math]::Max(1, [Environment]::ProcessorCount),
        [Parameter(Mandatory = $false)]
        [hashtable] $Variables = @{},
        [Parameter(Mandatory = $false)]
        [switch] $ForceSerial
    )

    if (-not $InputObject -or $InputObject.Count -eq 0) {
        return @()
    }

    $useParallel = (-not $ForceSerial) -and ($PSVersionTable.PSVersion.Major -ge 7) -and ($InputObject.Count -gt 1) -and ($ThrottleLimit -gt 1)

    if (-not $useParallel) {
        OutputDebug -message "Invoke-AlGoParallel: running sequentially (PS$($PSVersionTable.PSVersion.Major), items=$($InputObject.Count), throttle=$ThrottleLimit, forceSerial=$ForceSerial)"
        $results = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $InputObject) {
            try {
                $r = & $ScriptBlock $item $Variables
            }
            catch {
                throw "Invoke-AlGoParallel (serial) iteration failed for item '$item': $($_.Exception.Message)`n$($_.ScriptStackTrace)"
            }
            [void]$results.Add($r)
        }
        # NOTE: do NOT use `@($results)` here. Under PowerShell 7 + StrictMode 2.0 wrapping a
        # System.Collections.Generic.List[object] in @() throws ArgumentException
        # ("Argument types do not match"). ToArray() is reliable on both PS5 and PS7.
        return ,$results.ToArray()
    }

    OutputDebug -message "Invoke-AlGoParallel: running in parallel (PS$($PSVersionTable.PSVersion.Major), items=$($InputObject.Count), throttle=$ThrottleLimit)"

    # PS7 ForEach-Object -Parallel does not allow $using: to reference a script block, so we
    # transport the script block as a string and re-create it inside each iteration.
    $scriptBlockText = $ScriptBlock.ToString()

    # Collect results with their original input index so the final array preserves input order.
    $bag = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    # Build an indexed input. We pipe (Index, Item) pairs through ForEach-Object -Parallel.
    $indexed = New-Object 'System.Collections.Generic.List[psobject]'
    for ($i = 0; $i -lt $InputObject.Count; $i++) {
        [void]$indexed.Add([pscustomobject]@{ Index = $i; Item = $InputObject[$i] })
    }

    $indexed | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $entry = $_
        $sb = [scriptblock]::Create($using:scriptBlockText)
        $vars = $using:Variables
        $bagRef = $using:bag
        try {
            $output = & $sb $entry.Item $vars
            $bagRef.Add([pscustomobject]@{ Index = $entry.Index; Output = $output; Error = $null })
        }
        catch {
            # Surface the original error message but keep the helper functional - we record
            # the failure and re-throw on the calling thread after collection so callers see
            # all per-item errors rather than a single mid-iteration exception.
            $bagRef.Add([pscustomobject]@{ Index = $entry.Index; Output = $null; Error = $_ })
        }
    } | Out-Null

    # Re-order by original index so callers don't have to.
    $byIndex = @{}
    foreach ($r in $bag) { $byIndex[[int]$r.Index] = $r }

    $errors = @()
    $ordered = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $InputObject.Count; $i++) {
        if (-not $byIndex.ContainsKey($i)) {
            throw "Invoke-AlGoParallel: missing result for input index $i (item: $($InputObject[$i]))"
        }
        $entry = $byIndex[$i]
        if ($entry.Error) { $errors += $entry.Error }
        [void]$ordered.Add($entry.Output)
    }

    if ($errors.Count -gt 0) {
        $detail = ($errors | ForEach-Object {
            $err = $_
            $msg = $err.Exception.Message
            $stack = $err.ScriptStackTrace
            "$msg`n$stack"
        }) -join "`n----`n"
        throw "Invoke-AlGoParallel: $($errors.Count) iteration(s) failed:`n$detail"
    }

    return ,$ordered.ToArray()
}

Export-ModuleMember -Function Invoke-AlGoParallel
