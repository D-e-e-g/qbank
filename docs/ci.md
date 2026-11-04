# CI

Two workflows run, with a trust boundary between them. `test/release-checks.sh` enforces every rule on this page that a file can show.

## Pull requests and `main`: `ci.yml`

Every pull request and every push to `main` runs two Linux jobs on GitHub-hosted Ubuntu machines.

`Linux checks`:

- `shellcheck` over `test/*.sh` and `scripts/*.sh`
- `test/release-checks.sh`: workflow pins and triggers, project settings, the privacy manifest (it exists, lints, matches [privacy-manifest.md](privacy-manifest.md), and the app target's synchronized `QBank` group includes it), the Debug-only launch seam, the frontend-only rule, and the TestFlight upload script's rules (the key read only in its upload step, its cleanup traps, the export options, and no key or team ID in Git)

`Secrets`: `test/leak-check.sh` runs [gitleaks](https://github.com/gitleaks/gitleaks), a pinned release whose checksum the job checks, over the commits the change adds and over every tracked file at HEAD, and fails on any finding. It uses gitleaks' own rules with no exceptions (`.gitleaks.toml` only extends the defaults). Findings print redacted. To run it on a Mac with gitleaks installed: `test/leak-check.sh origin/main HEAD`.

The workflow references no secrets, reads the repository with a `contents: read` token, and never runs on a Mac. There is no `pull_request_target` workflow.

## Trusted code: `xcode.yml`

Pull requests from this repository's own branches, pushes to `main`, `qbank-v*` tags, and manual runs (Actions > Xcode > Run workflow, or `gh workflow run xcode.yml -R D-e-e-g/qbank --ref <branch>`) run one Mac job:

1. `test/package-tests.sh`: `swift test` in every package under `Packages/` on the Mac host
2. `xcodebuild test` of the `QBank` scheme (unit and UI tests) on a run-scoped iPhone simulator through `test/sim.sh`, then again on a run-scoped iPad simulator, where the iPad layout's UI tests run and the iPhone layout's skip themselves
3. a Release build for `generic/platform=iOS` without signing, which proves Debug-only code stays out of Release

A pull request from a fork never runs the Mac job; its `Mac build skipped` job says why (see below).

A pull request's new commit cancels the build of its previous one. Every other run shares the `xcode-mac` concurrency group, because a self-hosted Mac also serves other CI: a new run waits for the running one, and GitHub keeps only one waiting run, replacing it with a newer one, so a burst of pushes to `main` builds the newest commit. A replaced tag or manual run can be run again from its page. The self-hosted Mac has one QBank runner, so it runs one QBank job at a time. The job stops after 90 minutes.

### Which Mac

The job runs on `${{ github.event_name == 'pull_request' && 'qbank-macbook-14' || vars.MAC_RUNNER || 'macos-26' }}`.

- A pull request runs only on the MacBook Pro 14's runner, `qbank-macbook-14`, the one runner whose job-started hook checks pull requests, and never on a GitHub-hosted Mac.
- With no `MAC_RUNNER` repository variable, tags and manual runs use GitHub's hosted `macos-26` image, free on a public repository, with that image's default Xcode at `/Applications/Xcode.app`. A pull request or a push to `main` skips the Mac job instead, so changes do not each start a hosted Mac; the run's `Mac build skipped` job says why.
- With `MAC_RUNNER` set, pushes to `main`, tags, and manual runs use the self-hosted runner with that label, and pull requests build on `qbank-macbook-14`.

To move the job to the MacBook Pro 14 once its runner is registered to this repository with the label `qbank-macbook-14` and Xcode at `/Applications/Xcode.app`:

```sh
gh variable set MAC_RUNNER --repo D-e-e-g/qbank --body qbank-macbook-14
```

Delete the variable to go back to the hosted Mac for tags and manual runs; pull requests and pushes to `main` then skip the Mac build. The job uses `DEVELOPER_DIR` rather than `sudo`, so the runner user needs no administrator rights.

### Keeping forks off the self-hosted Mac

A pull request from a branch of this repository builds on the self-hosted Mac: only a collaborator with write access, today only the owner, can push such a branch, so its code is as trusted as a manual run. A pull request from a fork must never reach the Mac, and four things keep it off:

- **The job's guard.** `xcode.yml`'s Mac job runs for a pull request only when `github.event.pull_request.head.repo.full_name` is `D-e-e-g/qbank`, so GitHub never even schedules a fork's pull request on the Mac. `test/release-checks.sh` refuses any other Mac or self-hosted job in a workflow that a pull request, comment, review or `workflow_run` can start, and any `pull_request_target` trigger.
- **Approval for forks.** A fork's pull request runs its own copy of the workflow files, which can drop the guard and name the runner's label, so the guard alone is not enough. Workflows from fork pull requests wait for approval for all outside collaborators, and the owner is the only collaborator. Approve a fork's run only after reading its diff, and never one that changes `.github/`.
- **The runner's job-started hook.** It refuses any job that is not `xcode.yml` running for a push to `main`, a `qbank-v*` tag, a manual run, or a pull request whose event payload, written by the runner itself, shows both its head and base repository as `D-e-e-g/qbank`. So even an approved fork run fails before it checks anything out. The hook lives on the Mac, not in this repository.
- **The runner's scope.** It is registered to this repository only, under its own label and none of the default ones (`self-hosted`, `macOS`, `ARM64`), so no other repository's jobs land on it and it takes no job that asks for a generic Mac.

These, not an absence of secrets, keep fork code off the Mac: `xcode.yml` references no secret today, and a check for same-repository pull requests that needs one may be given it.

### Package hosts

Every package declares a `.macOS` platform next to `.iOS(.v18)` so `swift test` can run on the Mac host.

## Repository settings that back this

- Secret scanning and push protection are on.
- A ruleset on `main` requires a pull request and the `Linux checks` and `Secrets` checks, and forbids force pushes and deletion.
- Private vulnerability reporting is on (see `SECURITY.md`).
- Workflows from forks wait for approval for all outside collaborators.

## TestFlight is not in CI

No workflow signs or uploads a build, and none holds an Apple credential. The owner's MacBook builds, signs, and uploads with `scripts/testflight-upload.sh`, which reads the App Store Connect key from Automic Vault for the upload step alone; see [release.md](release.md).
