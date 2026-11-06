# Testing and retrying

A full run of `xcode.yml` holds the MacBook Pro 14 (mb14) for about an hour, and the runner serves one job at a time. So a failed test is retried on its own first, and the full suite runs only after that test passes.

## The retry rule

When a check fails on one test or a few:

1. Read the failing names from the run: `gh run view <run id> -R D-e-e-g/qbank --log-failed`.
2. Fix what failed, and commit.
3. Run only those tests. Run them here if the failure reproduces here, otherwise on mb14. Do not push to the pull request's branch yet, because that push starts the full suite.
4. If they fail, go back to step 2. Each try costs minutes, not an hour.
5. When they pass, push to the pull request's branch. The full suite runs on that push, and it is what counts: a named-tests run never stands in for it.

If a retry shows that many tests fail for one cause, fix the cause and go back to step 3 with one of them. Rerun a whole check without a code change only for a run that was cancelled or broke before any test ran.

## Run named tests on this Mac

```sh
test/only-testing.sh QBankUITests/StudyUITests/testCoursePageOpensExamPagesAndFolders
test/only-testing.sh --device ipad QBankUITests/IPadUITests
```

It builds, creates one run-scoped simulator through `test/sim.sh`, runs the names, and deletes the simulator. A name is `Target/Class` or `Target/Class/test`, and a Swift Testing function keeps its parentheses, as in `QBankTests/PaletteTests/theScreensFollowTheAccountsScheme()`. It takes at most 10 names.

`xcodebuild` reports `TEST SUCCEEDED` for a name that matches no test and for a test that skips itself on this device. The script fails in both cases, so run an iPad layout test with `--device ipad`.

## Run named tests on mb14

For a failure that does not reproduce on this Mac, or when this Mac has no simulator free, give the fix a scratch branch. A branch with no pull request starts no Mac job until you ask for one:

```sh
git push origin HEAD:refs/heads/retry/<your branch>
gh workflow run xcode.yml -R D-e-e-g/qbank --ref retry/<your branch> \
  -f only_testing='QBankUITests/StudyUITests/testCoursePageOpensExamPagesAndFolders' \
  -f device=iphone
```

`only_testing` takes names separated by spaces. The run's check is named `Named tests`, not `Build and test`, and it runs only those tests on the same runner, under the same guards as any manual run. It skips the packages, the Release build, and the other device. A failed run uploads `TestResults-named.xcresult`. Delete the scratch branch once the tests pass:

```sh
git push origin --delete retry/<your branch>
```

Only someone with write access can start a manual run. The workflow still treats the names as hostile, because they reach a self-hosted Mac: they pass through `env`, never into a shell line, and `test/only-testing.sh` refuses anything but a test name before it runs anything. `test/release-checks.sh` checks both.

## What each run holds

[ci.md](ci.md) describes the jobs and the rules for who may run them.
