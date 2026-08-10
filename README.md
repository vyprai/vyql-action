# VyQL scan action

Runs a [VyQL](https://github.com/vyprai/vyql) scan in GitHub Actions, fails the
build on what it finds, and puts the results in the Security tab.

VyQL is a multi-language security scanner that follows tainted data through your
code and tells you why each finding is a finding — naming the source, the sink,
and the neutralizing controls it looked for and did not find.

```yaml
- uses: vyprai/vyql-action@v1
```

That is the whole minimal usage. It scans the checked-out repository, fails on
any HIGH or CRITICAL finding, and uploads SARIF to code scanning.

## Two versions, and they are not the same thing

`@v1` is the **action**. `version:` is the **scanner**.

```yaml
- uses: vyprai/vyql-action@v1     # action: gets fixes automatically
  with:
    version: v0.2.3               # scanner: pinned, so results are reproducible
```

They move independently on purpose. Tracking `@v1` means a fix to this action
reaches you without waiting for a scanner release; pinning `version:` means a
new rule pack cannot change your build without you asking for it.

`version: latest` (the default) resolves the newest VyQL release at run time.
Convenient, and it means a new release can introduce findings your last run did
not report — which is the point of a scanner, but it is not reproducible. Pin it
if you need two runs of the same commit to agree.

## A complete workflow

```yaml
name: security
on: [push, pull_request]

jobs:
  vyql:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write     # required for the SARIF upload
    steps:
      - uses: actions/checkout@v5
      - uses: vyprai/vyql-action@v1
        with:
          path: .
          fail-on: high
```

## Inputs

| Input | Default | What it does |
|---|---|---|
| `path` | `.` | Path to scan, relative to the workspace |
| `version` | `latest` | VyQL release to use, e.g. `v0.2.3`. Pin it for reproducible runs |
| `fail-on` | `high` | Fail at or above this severity: `none`, `info`, `low`, `medium`, `high`, `critical` |
| `exit-code` | `1` | Status used when `fail-on` is met |
| `format` | `sarif` | `sarif`, `json` or `text` |
| `output` | `vyql-results.sarif` | File to write to. Empty writes to the log |
| `exclude` | | Comma-separated path segments to skip, e.g. `vendor,node_modules` |
| `profile` | `auto` | Analysis profile |
| `upload-sarif` | `true` | Upload to code scanning |
| `working-directory` | `.` | Directory to run from |
| `baseline` | `off` | `off`, `auto`, or a path to a baseline file. `auto` gates on what a branch added |
| `baseline-ref` | | Base ref `auto` measures against. Empty uses the PR's base, or the default branch |

## Outputs

| Output | What it is |
|---|---|
| `results-file` | Path to the report that was written |
| `findings` | Number of findings reported |
| `exit-code` | The scanner's status. `0` means nothing met the threshold |
| `baseline-source` | Where the baseline came from: `off`, `file`, `cache`, `merge-base`, `adopt` |

## Report without failing

```yaml
- uses: vyprai/vyql-action@v1
  with:
    fail-on: none
```

Findings still reach the Security tab; the build stays green. Useful for
adopting the scanner on a codebase with a backlog.

## Fail on what a pull request added

`fail-on: none` turns the gate off for the backlog and for everything new along
with it. A baseline is the other way to adopt the scanner on a codebase that
already has findings: known findings stop failing the build, and anything a
branch adds still does.

```yaml
- uses: actions/checkout@v5
  with:
    fetch-depth: 0            # baseline: auto compares against the merge base
- uses: vyprai/vyql-action@v1
  with:
    baseline: auto
    version: v0.2.5           # or newer; baseline needs it
```

`baseline: auto` carries the baseline in the Actions cache. A push to your
default branch records one; a pull request restores it and reports only what the
branch added. With no cached baseline, the run records one from the merge base of
the branch and its base ref and compares against that, so a cold cache never
turns into a wall of findings the branch did not introduce. Read
`baseline-source` to see which of those happened.

Prefer suppressions you can review in a diff? Point `baseline` at a file
instead. Generate it with the scanner and commit it:

```sh
vyql scan -baseline-write vyql-baseline.json .
```

```yaml
- uses: vyprai/vyql-action@v1
  with:
    baseline: vyql-baseline.json
```

Each entry carries a verdict — `accepted` or `false-positive` — and a reason
field left empty for you to fill in as findings are triaged. Adding a
suppression then shows up in the pull request that adds it.

### What to expect

**Code scanning shows what is new, not the backlog.** Under `baseline: auto` the
uploaded SARIF holds only un-baselined findings, so code scanning closes the
alerts for everything the baseline covers. That is the accepted backlog leaving
the Security tab.

**A new finding does not get absorbed by a failing build.** When a
default-branch run fails, the finding that failed it is deliberately left out of
the recorded baseline, so the next run fails too — until it is fixed, or triaged
into the baseline by hand.

**A cached baseline is taken at your default branch's tip.** A finding that
existed when a branch was cut and was fixed on the default branch afterwards is
absent from that baseline, so it reads as new on the branch. Rebasing clears it.

**`fetch-depth: 0`.** `actions/checkout` clones one commit by default, which
leaves no shared history to find a merge base in. Without it, a cold-cache run
stops with a message saying so rather than guessing.

## Telling findings apart from a broken scan

Both exit 1 by default. Give findings their own status if the difference
matters:

```yaml
- uses: vyprai/vyql-action@v1
  id: scan
  with:
    exit-code: "3"
```

`3` means findings met the threshold, `1` means VyQL could not complete the
scan, `2` means it was invoked incorrectly.

## Requirements

**Linux and macOS runners.** VyQL publishes `linux/amd64`, `linux/arm64`,
`darwin/amd64` and `darwin/arm64`. On Windows the action fails with that
message rather than something obscure.

**`security-events: write`** for the SARIF upload. On a *private* repository
that upload also needs GitHub Advanced Security; without it the upload step
fails while the scan result still stands, because the step is
`continue-on-error`. Set `upload-sarif: false` to skip it.

**VyQL v0.2.0 or newer.** The action passes `-fail-on` and `-exit-code`, which
earlier builds do not have. **`baseline` needs v0.2.5 or newer**, which is where
applying a baseline while recording the next one arrived; the action stops with
that message rather than scanning against a build that would read the flags
differently.

## What it does

Downloads the release archive for the runner's platform, verifies its published
SHA-256, extracts it, and runs the scan with `VYQL_HOME` pointed at the data
directory that shipped with that exact binary — so a `vyql/` directory in the
repository being scanned cannot change the result.

The archive is cached by exact version. A repeat run on the same version skips
the download and the extraction, which is most of the wall clock: the archive is
about 14 MB compressed and 200 MB extracted, nearly all of it the security
knowledge base.
