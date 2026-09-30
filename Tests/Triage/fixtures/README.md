# Triage fixtures

Saved issue payloads plus the triage verdict a human considers correct. They serve two purposes:

1. **Local iteration (Level 0).** Run the triage orchestrator against a fixture with `-DryRun` and
   no GitHub involvement at all. Seconds per iteration, nothing posted anywhere.
2. **Regression scoring (Level 1).** Batch every fixture and compare the agent's findings against
   `expected`. This is the gate for changes to anything under `.github/agents/issue-triage/`.

## Format

One JSON file per case:

```jsonc
{
  "id": "short-stable-slug",
  "source": "https://github.com/microsoft/AL-Go/issues/1234",  // or "" for synthetic cases
  "issue": { "number": 1234, "title": "...", "body": "...", "labels": ["bug"] },
  "expected": { /* a subset of findings.schema.json fields to assert */ },
  "notes": "why this case is interesting, and any judgement calls in the expected values"
}
```

`expected` is deliberately a **subset**. Only assert fields this case is actually meant to exercise;
asserting everything makes fixtures brittle and tells you nothing about which behaviour regressed.

## Capturing a real issue

```powershell
gh api repos/microsoft/AL-Go/issues/2285 |
    ConvertFrom-Json |
    Select-Object number, title, body, labels, author_association
```

Then wrap it in the structure above and fill in `expected` by hand.

## Choosing cases

The corpus is for measuring judgement, not coverage. Aim for roughly 30 cases weighted toward the
decisions that are easy to get wrong:

- Issues that turned out **not** to be AL-Go, especially BcContainerHelper and AL compiler ones
- Issues already fixed in a later release, where the answer is "upgrade"
- Sparse reports where the correct action is to ask for specific information
- Duplicates
- Issues touching critical-path files, where `fix_risk` must come out `critical`
- Well-formed reports needing no follow-up at all, so the agent is scored on staying quiet too

The four `seed-*` fixtures are adapted from the `testData` of the retired
`.github/GitHubActionsPrompts/bug-review.prompt.yml`, which only evaluated completeness. Their
routing and risk expectations are new.
