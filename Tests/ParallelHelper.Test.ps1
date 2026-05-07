Import-Module (Join-Path $PSScriptRoot 'TestActionsHelper.psm1') -Force
$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot '../Actions/.Modules/ParallelHelper.psm1') -Force

Describe "Invoke-AlGoParallel" {

    Context "serial path (basic semantics)" {
        It 'returns an empty array for empty input' {
            $r = Invoke-AlGoParallel -InputObject @() -ScriptBlock { param($x, $v) $x }
            @($r).Count | Should -Be 0
        }

        It 'invokes the script block once per item and returns results in input order' {
            $items = @('a', 'b', 'c', 'd', 'e')
            $r = Invoke-AlGoParallel -InputObject $items -ForceSerial -ScriptBlock {
                param($item, $vars)
                "[$item]"
            }
            @($r) | Should -BeExactly @('[a]', '[b]', '[c]', '[d]', '[e]')
        }

        It 'passes the Variables hashtable as the second positional argument' {
            $r = Invoke-AlGoParallel -InputObject @(1, 2) -Variables @{ Multiplier = 10 } -ForceSerial -ScriptBlock {
                param($item, $vars)
                $item * $vars.Multiplier
            }
            @($r) | Should -BeExactly @(10, 20)
        }

        It 'forces serial execution when ThrottleLimit is 1, even on PowerShell 7+' {
            $r = Invoke-AlGoParallel -InputObject @('x', 'y') -ThrottleLimit 1 -ScriptBlock {
                param($i, $v) $i
            }
            @($r) | Should -BeExactly @('x', 'y')
        }

        It 'wraps a serial iteration error with item context' {
            {
                Invoke-AlGoParallel -InputObject @('boom') -ForceSerial -ScriptBlock {
                    param($i, $v)
                    throw 'inner failure'
                }
            } | Should -Throw "*serial*item 'boom'*inner failure*"
        }

        It 'returns single-item results without unwrapping when input has 1 element' {
            $r = Invoke-AlGoParallel -InputObject @('only') -ScriptBlock {
                param($i, $v)
                [pscustomobject]@{ Got = $i }
            }
            @($r).Count | Should -Be 1
            @($r)[0].Got | Should -Be 'only'
        }
    }

    Context "parallel path (PowerShell 7+ only)" -Skip:($PSVersionTable.PSVersion.Major -lt 7) {

        It 'produces identical output to serial mode for the same script block (preserved input order)' {
            $items = 1..20
            $sb = {
                param($i, $v)
                $sum = 0
                for ($k = 0; $k -lt 1000; $k++) { $sum += ($i * $k) % 7 }
                [pscustomobject]@{ I = $i; Sum = $sum }
            }

            $serial = Invoke-AlGoParallel -InputObject $items -ForceSerial -ScriptBlock $sb
            $parallel = Invoke-AlGoParallel -InputObject $items -ScriptBlock $sb -ThrottleLimit 4

            @($parallel).Count | Should -Be @($serial).Count
            for ($i = 0; $i -lt @($serial).Count; $i++) {
                @($parallel)[$i].I   | Should -Be @($serial)[$i].I
                @($parallel)[$i].Sum | Should -Be @($serial)[$i].Sum
            }
        }

        It 'preserves input order even when iterations complete out of order' {
            $items = 1..6
            $sb = {
                param($i, $v)
                Start-Sleep -Milliseconds (500 - ($i * 60))
                $i
            }
            $r = Invoke-AlGoParallel -InputObject $items -ScriptBlock $sb -ThrottleLimit 6
            @($r) | Should -BeExactly @(1, 2, 3, 4, 5, 6)
        }

        It 'aggregates errors across iterations and re-throws on the calling thread' {
            {
                Invoke-AlGoParallel -InputObject @(1, 2, 3) -ScriptBlock {
                    param($i, $v)
                    if ($i -ne 2) { throw "fail-$i" }
                    $i
                } -ThrottleLimit 3
            } | Should -Throw "*Invoke-AlGoParallel*iteration(s) failed*fail-1*fail-3*"
        }

        It 'passes Variables across runspace boundaries via the second positional arg' {
            $r = Invoke-AlGoParallel -InputObject @('a', 'b', 'c') -Variables @{ Suffix = '!' } -ScriptBlock {
                param($i, $v)
                "$i$($v.Suffix)"
            } -ThrottleLimit 3
            @($r) | Should -BeExactly @('a!', 'b!', 'c!')
        }
    }

    Context "fallback path (PowerShell 5)" -Skip:($PSVersionTable.PSVersion.Major -ge 7) {
        It 'runs sequentially on PowerShell 5 even when ForceSerial is not set' {
            $r = Invoke-AlGoParallel -InputObject @('p', 'q') -ScriptBlock {
                param($i, $v) $i.ToUpper()
            }
            @($r) | Should -BeExactly @('P', 'Q')
        }
    }
}
