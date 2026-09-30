# Completeness: can this issue be acted on?

The goal is **not** to check that template fields were filled in. It is to decide whether a
maintainer could actually start work. A report with every field populated but no usable evidence is
incomplete; a terse report with a full stack trace often is not.

Set `has_missing_information` on that basis, and be sparing - every request for more information
costs the reporter a round trip, and a wrong one is worse than no comment at all.

## The linked workflow run

Nearly every real AL-Go issue references a run:

```
https://github.com/<org>/<repo>/actions/runs/<id>
```

Try to read it. There are three outcomes, and they need different responses:

| Outcome | Meaning | Response |
| --- | --- | --- |
| Readable | Public repository. The log is the best evidence available - use it | Analyse; usually no need to ask for anything |
| 404 or 403 | Private repository, which is the **common case** for BC customers | Ask for the log, via the Troubleshooting workflow. This is not the reporter's fault - do not imply it is |
| No link at all | Nothing to go on | Ask for the run URL or the log |

Record what happened in `linked_run`.

## The Troubleshooting workflow

AL-Go ships `Actions/Troubleshooting`, which consumers can run to dump diagnostics. When logs are
needed and the run is unreadable, point at this rather than asking vaguely for "more information".

Set `troubleshooting_requirement`:

- `REQUIRED` - no usable logs, and the symptom cannot be traced statically from the description
- `RECOMMENDED` - the symptom is traceable but logs would confirm it
- `OPTIONAL` - there is enough to proceed
- `NOT_APPLICABLE` - not a bug, or the failure is entirely outside a workflow run

Always remind the reporter to redact secrets before sharing logs.

## Version

`preview` is ambiguous - it moves. If the reporter said `preview`, ask which commit their
`.github/AL-Go-Settings.json` template pin points at.

Then cross-check `RELEASENOTES.md`, which lists fixes in a machine-readable form:

```
### Issues
- Issue <number> - <description>
```

If the symptom matches an entry in a release **newer than the reporter's version**, the right
answer is "upgrade", not "we will investigate". Set `fixed_in_release` and
`recommended_lane: already-fixed-upgrade`. This is one of the highest-value, cheapest checks
available - do it before anything expensive.

## Settings

A large share of AL-Go issues are settings related and cannot be resolved without seeing the
reporter's settings JSON. Ask for it when the symptom touches project discovery, build modes,
versioning, delivery targets, or artifact resolution.

## What is genuinely required

1. What happened, and what was expected instead.
2. Enough to locate the failure: a log, a stack trace, or an error message.
3. The AL-Go version, specific enough to be actionable.
4. For settings-dependent symptoms, the settings JSON.

Steps to reproduce are valuable but are **not** always required - a clear stack trace from a real
run is often better evidence than a reconstructed sequence of steps.

## Issue kind

Only `BUG` proceeds to full triage. AL-Go disables blank issues and directs questions and feature
requests to Discussions (`.github/ISSUE_TEMPLATE/config.yml`), so:

- `QUESTION` or `FEATURE_REQUEST` filed as a bug - set
  `recommended_lane: redirect-to-discussions` and point at the relevant Discussions category,
  politely. Do not close it yourself.

The `bug` label means nothing here: the bug template applies it automatically, so every report
carries it. Judge from what the reporter is actually asking for.

Watch for the phrasing that distinguishes them:

| Reporter says | Kind |
| --- | --- |
| "X fails", "X produces the wrong result", "this used to work" | `BUG` |
| "can you also...", "it would be nice if...", "please add support for..." | `FEATURE_REQUEST` |
| "X does not do what Y does" | Judgement call. If X is documented or clearly intended to behave like Y, it is a `BUG`. If the reporter is asking to extend X to match Y, it is a `FEATURE_REQUEST`. |

When it is genuinely a judgement call, say so in `notes_for_maintainer` rather than picking
silently - the distinction decides whether it goes on a backlog or into a fix queue, and the
maintainer is better placed to make it. Trace the code either way: "this is a feature request and
here is exactly where it would go" is far more useful than a redirect on its own.
