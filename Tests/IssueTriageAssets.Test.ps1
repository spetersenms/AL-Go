Get-Module TestActionsHelper | Remove-Module -Force
Import-Module (Join-Path $PSScriptRoot 'TestActionsHelper.psm1')
$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Describe 'Issue triage assets' {

    BeforeAll {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'repoRoot', Justification = 'Used inside It blocks.')]
        $repoRoot = Join-Path $PSScriptRoot '..' -Resolve
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'agentRoot', Justification = 'Used inside It blocks.')]
        $agentRoot = Join-Path $repoRoot '.github/agents/issue-triage' -Resolve
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'schema', Justification = 'Used inside It blocks.')]
        $schema = Get-Content -Path (Join-Path $agentRoot 'findings.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'config', Justification = 'Used inside It blocks.')]
        $config = Get-Content -Path (Join-Path $agentRoot 'triage.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'fixtures', Justification = 'Used inside It blocks.')]
        $fixtures = @(Get-ChildItem -Path (Join-Path $repoRoot 'Tests/Triage/fixtures') -Filter '*.json' -File)
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'workflow', Justification = 'Used inside It blocks.')]
        $workflow = Get-Content -Path (Join-Path $repoRoot '.github/workflows/AiIssueTriage.yml') -Raw -Encoding UTF8
    }

    Context 'findings schema' {

        It 'declares every required property' {
            $properties = @($schema.properties.PSObject.Properties.Name)
            foreach ($required in $schema.required) {
                $properties | Should -Contain $required
            }
        }

        It 'forbids additional properties so unexpected fields cannot be smuggled through' {
            $schema.additionalProperties | Should -Be $false
        }

        It 'requires a critical fix risk to be routed to a human' {
            $schema.properties.fix_risk.enum | Should -Contain 'critical'
            $schema.properties.fix_risk.enum | Should -Contain 'unknown'
            $schema.properties.recommended_lane.enum | Should -Contain 'needs-human-fix'
        }

        It 'covers every area used by the routing rules' {
            $areas = @($schema.properties.suggested_area.enum)
            foreach ($area in @('al-go', 'bccontainerhelper', 'bc-platform', 'bc-saas', 'github', 'user-config', 'unknown')) {
                $areas | Should -Contain $area
            }
        }
    }

    Context 'configuration' {

        It 'references knowledge files that exist' {
            foreach ($skill in @($config.knowledge.skills)) {
                Test-Path -Path (Join-Path $agentRoot $skill) | Should -Be $true -Because "$skill is referenced by triage.config.json"
            }
            Test-Path -Path (Join-Path $agentRoot $config.knowledge.agent) | Should -Be $true
            Test-Path -Path (Join-Path $agentRoot $config.knowledge.schema) | Should -Be $true
        }

        It 'references a repro harness and policy that exist' {
            Test-Path -Path (Join-Path $repoRoot $config.repro.harness) | Should -Be $true
            Test-Path -Path (Join-Path $repoRoot $config.repro.policy) | Should -Be $true
        }

        It 'never allows a blocked label' {
            foreach ($blocked in @($config.publish.blockedLabels)) {
                @($config.publish.allowedLabels) | Should -Not -Contain $blocked
            }
        }

        It 'starts in a non-publishing mode' {
            # Flipping this on is a deliberate, reviewed act.
            @('dryRun', 'shadow') | Should -Contain $config.publish.mode
        }

        It 'treats critical and unknown risk as never auto-fixable' {
            @($config.safety.neverAutoFixRiskLevels) | Should -Contain 'critical'
            @($config.safety.neverAutoFixRiskLevels) | Should -Contain 'unknown'
        }

        It 'does not permit the agent to close issues' {
            $config.safety.allowIssueClose | Should -Be $false
        }

        It 'never applies its own trigger label' {
            # The agent must not be able to re-trigger itself.
            $config.publish.blockedLabels | Should -Contain $config.publish.triggerLabel
        }

        It 'caps AI credits per run within what the CLI accepts' {
            # Copilot CLI rejects anything below 30, which a live run found the hard way.
            $config.engine.maxAiCredits | Should -BeGreaterOrEqual 30
            $config.engine.maxAiCredits | Should -BeLessOrEqual 100
        }

        It 'defines every allowed label so it can actually be created' {
            # GitHub does not create labels on demand, so an allowed label with no definition would
            # be silently dropped at publish time.
            $defined = @((Get-Content -Path (Join-Path $agentRoot 'labels.json') -Raw -Encoding UTF8 | ConvertFrom-Json).labels | ForEach-Object { $_.name })
            foreach ($allowed in @($config.publish.allowedLabels)) {
                $defined | Should -Contain $allowed -Because "$allowed is allowed but has no definition in labels.json"
            }
        }

        It 'gives every defined label a colour and a description' {
            foreach ($label in @((Get-Content -Path (Join-Path $agentRoot 'labels.json') -Raw -Encoding UTF8 | ConvertFrom-Json).labels)) {
                $label.color | Should -Match '^[0-9A-Fa-f]{6}$' -Because "$($label.name) needs a hex colour"
                $label.description | Should -Not -BeNullOrEmpty -Because "$($label.name) needs a description"
            }
        }
    }

    Context 'workflow' {

        It 'only grants write permission to the job that does not run the model' {
            # The triage job reads untrusted input, so it must never hold issues: write.
            $triageJob = [regex]::Match($workflow, '(?ms)^  triage:.*?(?=^  publish:)').Value
            $triageJob | Should -Not -Match 'issues:\s*write'
            $triageJob | Should -Match 'copilot-requests:\s*write'

            $publishJob = [regex]::Match($workflow, '(?ms)^  publish:.*\z').Value
            $publishJob | Should -Match 'issues:\s*write'
            $publishJob | Should -Not -Match 'copilot-requests:\s*write'
        }

        It 'never persists credentials on checkout' {
            $checkouts = ([regex]::Matches($workflow, 'actions/checkout@')).Count
            $persistFalse = ([regex]::Matches($workflow, 'persist-credentials:\s*false')).Count
            $checkouts | Should -BeGreaterThan 0
            $persistFalse | Should -Be $checkouts
        }

        It 'supports dispatching a specific issue for testing' {
            # issues: events only ever run the default-branch copy, so dispatch is the only way to
            # exercise a feature branch.
            $workflow | Should -Match 'workflow_dispatch:'
            $workflow | Should -Match 'issue_number:'
            $workflow | Should -Match 'dry_run:'
        }

        It 'pins every action to a commit sha' {
            $uses = @([regex]::Matches($workflow, 'uses:\s*(\S+)@(\S+)'))
            $uses.Count | Should -BeGreaterThan 0
            foreach ($match in $uses) {
                $match.Groups[2].Value | Should -Match '^[0-9a-f]{40}$' -Because "$($match.Groups[1].Value) must be SHA pinned"
            }
        }

        It 'is opt-in: it does not run on every new issue' {
            # Reuses the existing AI Review convention, so landing this on the default branch
            # cannot start spending credits on its own. Adding issues: [opened] is the deliberate,
            # reviewable act that moves it to shadow mode.
            $workflow | Should -Match "github.event.label.name == 'AI Review'"
            $workflow | Should -Not -Match 'types:\s*\[opened\]'
        }

        It 'only applies labels the repository already has' {
            $defined = @((Get-Content -Path (Join-Path $agentRoot 'labels.json') -Raw -Encoding UTF8 | ConvertFrom-Json).labels | ForEach-Object { $_.name })
            foreach ($allowed in @($config.publish.allowedLabels)) {
                $defined | Should -Contain $allowed
            }
        }

        It 'only invokes scripts that exist in the repository' {
            # Guards a partial merge or a rename: the issues: trigger checks out the default
            # branch, so a workflow referencing a script that is not committed alongside it fails
            # every run rather than degrading quietly.
            $invoked = @([regex]::Matches($workflow, '\./(\.github/[^\s]+\.ps1)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
            $invoked.Count | Should -BeGreaterThan 0
            foreach ($script in $invoked) {
                Test-Path -Path (Join-Path $repoRoot $script) | Should -Be $true -Because "$script is invoked by the workflow"
            }
        }

        It 'never runs branch-supplied code in the job that can write' {
            # workflow_dispatch encourages selecting a feature branch. The publish job holds
            # issues: write, so it must check out the default branch rather than the dispatched
            # ref, or anyone who can push a branch could run arbitrary code with the write token.
            $publishJob = [regex]::Match($workflow, '(?ms)^  publish:.*\z').Value
            $publishJob | Should -Match 'ref:\s*\$\{\{\s*github\.event\.repository\.default_branch\s*\}\}'
        }

        It 'gives the model no network-capable tool' {
            # The triage job holds GITHUB_TOKEN for inference, so a prompt injection must have
            # nothing available that could carry it off the runner.
            $orchestrator = Get-Content -Path (Join-Path $agentRoot 'scripts/Invoke-CopilotIssueTriage.ps1') -Raw -Encoding UTF8
            $allowed = @([regex]::Matches($orchestrator, "'--allow-tool',\s*[`"']([^`"']+)") | ForEach-Object { $_.Groups[1].Value })
            $allowed.Count | Should -BeGreaterThan 0
            foreach ($tool in $allowed) {
                $tool | Should -Not -Match 'gh |curl|wget|Invoke-WebRequest|Invoke-RestMethod'
            }
            $orchestrator | Should -Match "'--deny-tool',\s*'shell\(gh\)'"
            $orchestrator | Should -Match "'--deny-tool',\s*'shell\(curl\)'"
        }

        It 'serialises runs per issue' {
            $workflow | Should -Match 'concurrency:'
        }
    }

    Context 'fixtures' {

        It 'has at least one fixture' {
            $fixtures.Count | Should -BeGreaterThan 0
        }

        It 'contains only well formed fixtures' {
            foreach ($file in $fixtures) {
                $fixture = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $fixture.id | Should -Not -BeNullOrEmpty -Because "$($file.Name) needs an id"
                $fixture.issue.number | Should -BeGreaterThan 0 -Because "$($file.Name) needs an issue number"
                $fixture.issue.body | Should -Not -BeNullOrEmpty -Because "$($file.Name) needs an issue body"
                $fixture.expected | Should -Not -BeNullOrEmpty -Because "$($file.Name) needs expected values"
            }
        }

        It 'only asserts fields and values the findings schema allows' {
            $properties = $schema.properties
            $knownFields = @($properties.PSObject.Properties.Name)
            foreach ($file in $fixtures) {
                $fixture = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($field in $fixture.expected.PSObject.Properties) {
                    $knownFields | Should -Contain $field.Name -Because "$($file.Name) asserts '$($field.Name)'"

                    $definition = $properties.$($field.Name)
                    if ($definition.PSObject.Properties.Name -contains 'enum') {
                        $definition.enum | Should -Contain $field.Value -Because "$($file.Name) sets $($field.Name) to '$($field.Value)'"
                    }
                }
            }
        }

        It 'uses unique fixture ids' {
            $ids = @($fixtures | ForEach-Object { (Get-Content -Path $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).id })
            ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        }
    }

    Context 'agent instructions' {

        It 'resolves every relative link' {
            $content = Get-Content -Path (Join-Path $agentRoot 'issue-triage.agent.md') -Raw -Encoding UTF8
            $links = @([regex]::Matches($content, '\]\((\.[^)]+)\)') | ForEach-Object { $_.Groups[1].Value })
            $links.Count | Should -BeGreaterThan 0
            foreach ($link in $links) {
                Test-Path -Path (Join-Path $agentRoot $link) | Should -Be $true -Because "$link is linked from issue-triage.agent.md"
            }
        }

        It 'tells the agent that the issue body is untrusted' {
            $content = Get-Content -Path (Join-Path $agentRoot 'issue-triage.agent.md') -Raw -Encoding UTF8
            $content | Should -Match 'untrusted'
            $content | Should -Match 'ignore previous instructions'
        }

        It 'keeps the deprecated-settings table in step with DEPRECATIONS.md' {
            # The concepts primer inlines the deprecation list so the agent does not have to look
            # it up. That copy rots silently unless something checks it.
            $concepts = Get-Content -Path (Join-Path $agentRoot 'skills/al-go-concepts.md') -Raw -Encoding UTF8
            $deprecations = Get-Content -Path (Join-Path $repoRoot 'DEPRECATIONS.md') -Raw -Encoding UTF8

            $declared = @([regex]::Matches($deprecations, '(?m)^###\s+Setting\s+`([^`]+)`') | ForEach-Object { $_.Groups[1].Value })
            $declared.Count | Should -BeGreaterThan 0
            foreach ($setting in $declared) {
                $concepts | Should -Match ([regex]::Escape($setting)) -Because "$setting is deprecated but missing from al-go-concepts.md"
            }
        }

        It 'points at reference files that exist' {
            $concepts = Get-Content -Path (Join-Path $agentRoot 'skills/al-go-concepts.md') -Raw -Encoding UTF8
            foreach ($reference in @('Scenarios/settings.md', 'Actions/.Modules/settings.schema.json', 'RELEASENOTES.md', 'DEPRECATIONS.md')) {
                $concepts | Should -Match ([regex]::Escape($reference))
                Test-Path -Path (Join-Path $repoRoot $reference) | Should -Be $true
            }
        }
    }
}
