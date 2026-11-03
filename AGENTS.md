# Project agent memory

This public repository is QBank for iPhone and iPad: the native SwiftUI client of QBank, an NCLEX practice question bank. It talks to the private QBank server only through the server's public HTTPS API. The product choices it follows: app name QBank, bundle id `com.dimitrygallego.qbank`, iPhone first, iOS 18 minimum, Swift only. The root `README.md` is the public landing page; keep its status line truthful.

The app's service implementation and operations are maintained separately. Keep this repository frontend-only: do not add backend source, migrations, credentials, deployment assets, or infrastructure configuration here.

`QBank.xcodeproj` is hand-maintained (no project generator) with folder-synchronized groups: a file added under `QBank/`, `QBankTests/`, or `QBankUITests/` joins its target with no project edit. Edit `project.pbxproj` by hand only for targets, build settings, or local package references, keeping its deterministic hex ids. Never commit `DEVELOPMENT_TEAM`; the Apple team id stays out of Git. The project builds in the Swift 6 language mode with warnings as errors, and the app target defaults to main-actor isolation.

Unit tests use Swift Testing in `QBankTests`. UI tests use XCTest in `QBankUITests` and launch the real app in a scenario chosen through the Debug-only seam `QBank/DebugLaunchScenario.swift`, which owns its `QB_UITEST_*` environment variables and must stay wrapped in `#if DEBUG`. Scenarios use synthetic data and in-process fakes; tests never use real accounts or the production server. Every command-line or automated run that boots an iOS simulator goes through `test/sim.sh`, which creates one run-scoped device and deletes it on every exit path; device-less builds for `generic/platform=iOS` are exempt.

Local Swift packages live under `Packages/` and are tested by `test/package-tests.sh`: on Linux in pull requests unless the package holds a `.apple-only` marker file, and on macOS in `xcode.yml`, so every package declares a `.macOS` platform next to `.iOS(.v18)`.

`docs/ci.md` is authoritative for CI, runner selection, and the trust boundary: pull requests run only Linux checks with no secrets; the Mac build and tests run only for pushes to `main`, `qbank-v*` tags, and manual runs, on `vars.MAC_RUNNER` with GitHub's `macos-26` as the fallback. Never give a Mac job a pull request trigger. `test/release-checks.sh` guards these rules and the project settings; run it after touching `.github/`, `scripts/`, `test/`, or the Xcode project.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
