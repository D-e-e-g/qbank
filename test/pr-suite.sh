#!/usr/bin/env bash
# Decides which Mac suite a pull request needs, from the changed paths on
# stdin, one per line. Prints a plan:
#
#   mode=skip|quick|full
#   ipad=true|false
#   iphone
#   <test id>
#   ipad
#   <test id>
#
# skip: documentation or CI files and scripts only. The Mac job does not run.
# quick: package tests, the Release compile, every unit test, the smoke walk
#   below, and every UI test class in a UI test file the change added or
#   edited. The iPad simulator starts only when one of those classes runs there.
# full: the whole suite. Shared test machinery, a path this script does not
#   know, or anything it cannot classify. When unsure, this runs more.
#
# --as-quick prints the quick plan even when the paths would be skip or full,
# so a manual run can time the quick check on a branch that changes machinery.
# --flags iphone|ipad reads a plan on stdin and prints `full`, `none`, or one
# line of -only-testing: arguments for xcodebuild. A test id that is not a
# test name fails, so a plan cannot smuggle a shell word.
#
# usage: git diff --name-only --no-renames BASE HEAD | test/pr-suite.sh [--as-quick]
#        test/pr-suite.sh --flags iphone|ipad
#
# Compatible with the bash 3.2 that ships with macOS.
set -euo pipefail

cd "$(dirname "$0")/.."

# The smoke walk, chosen by hand. One short test for each main screen, the
# same six on every quick check: sign in and Home, the course screen, one
# practice question, starting an exam, an import, and a folder.
smoke_tests=(
  "QBankUITests/QBankUITests/testSignInLandsOnHerLastCourseAndSignsOut"
  "QBankUITests/QBankUITests/testTilesOpenExamReviewAndTerms"
  "QBankUITests/SataAllCorrectUITests/testPickingEveryOptionIsFullyCorrect"
  "QBankUITests/ExamLifecycleUITests/testStartingOverARunningExamAsksAndEndsThatOne"
  "QBankUITests/AddUITests/testImportIntoUnsortedThenReplace"
  "QBankUITests/AddHereUITests/testAFoldersPlusOpensImportAtOnceAndMoreHoldsTheRest"
)

# Target, or Target/Class, or Target/Class/test. Nothing else reaches xcodebuild.
test_id='^(QBankTests|QBankUITests)(/[A-Za-z_][A-Za-z0-9_]*){0,2}$'

usage() {
  sed -n '25,26p' "$0" | sed 's/^# //' >&2
  exit 64
}

as_quick=0
flags=""
while [ $# -gt 0 ]; do
  case "$1" in
    --as-quick)
      as_quick=1
      shift
      ;;
    --flags)
      [ $# -ge 2 ] || usage
      flags="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
if [ "$as_quick" -eq 1 ] && [ -n "$flags" ]; then
  usage
fi
case "$flags" in
  "" | iphone | ipad) ;;
  *) usage ;;
esac

# iphone when setUp or every test method calls skipOnIPad() as its own
# statement. Anything else, including a file this cannot read, runs on iPad.
device_for() {
  local file="$1"
  sed 's|//.*||' "$file" | awk '
    BEGIN { kind = ""; skipped = 0; setup_skip = 0; tests = 0; test_skips = 0; block = 0 }
    function close_method() {
      if (kind == "setup" && skipped) setup_skip = 1
      if (kind == "test") {
        tests++
        if (skipped) test_skips++
      }
      kind = ""
      skipped = 0
    }
    {
      line = $0
      while (1) {
        if (block) {
          if (match(line, /\*\//)) {
            line = substr(line, RSTART + RLENGTH)
            block = 0
          } else {
            line = ""
            break
          }
        } else if (match(line, /\/\*/)) {
          before = substr(line, 1, RSTART - 1)
          line = substr(line, RSTART + RLENGTH)
          if (match(line, /\*\//)) {
            line = before substr(line, RSTART + RLENGTH)
          } else {
            line = before
            block = 1
            break
          }
        } else {
          break
        }
      }
      if (line ~ /^    (override |private |fileprivate |static )*func /) {
        close_method()
        if (line ~ /func[[:space:]]+setUp(WithError)?[[:space:]]*\(/) kind = "setup"
        else if (line ~ /func[[:space:]]+test[A-Z0-9_]/) kind = "test"
        else kind = "other"
      }
      if (kind != "" && line ~ /^[[:space:]]*try[[:space:]]+skipOnIPad\(\)[[:space:]]*$/) skipped = 1
    }
    END {
      close_method()
      if (setup_skip || (tests > 0 && test_skips == tests)) print "iphone"
      else print "ipad"
    }
  '
}

emit_flags() {
  local device="$1" mode="" ipad_line="" section="" line id
  local -a ids=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      mode=quick | mode=full | mode=skip) mode=$line ;;
      ipad=true | ipad=false) ipad_line=$line ;;
      iphone | ipad) section=$line ;;
      "") ;;
      *)
        if [ "$section" = "$device" ]; then
          if ! [[ "$line" =~ $test_id ]]; then
            printf 'pr-suite.sh: not a test name: %q\n' "$line" >&2
            exit 64
          fi
          ids+=("$line")
        elif [ "$section" != iphone ] && [ "$section" != ipad ]; then
          printf 'pr-suite.sh: bad plan line: %q\n' "$line" >&2
          exit 64
        elif ! [[ "$line" =~ $test_id ]]; then
          printf 'pr-suite.sh: not a test name: %q\n' "$line" >&2
          exit 64
        fi
        ;;
    esac
  done
  case "$mode" in
    mode=quick) ;;
    mode=full | mode=skip) printf 'full\n'; return 0 ;;
    *)
      echo "pr-suite.sh: plan has no mode" >&2
      exit 64
      ;;
  esac
  if [ "$device" = ipad ] && [ "$ipad_line" = ipad=false ]; then
    printf 'none\n'
    return 0
  fi
  if [ "${#ids[@]}" -eq 0 ]; then
    echo "pr-suite.sh: quick plan names no ${device} tests" >&2
    exit 64
  fi
  local -a args=()
  for id in "${ids[@]}"; do
    args+=("-only-testing:${id}")
  done
  printf '%s\n' "${args[*]}"
}

if [ -n "$flags" ]; then
  emit_flags "$flags"
  exit 0
fi

saw_any=0
saw_full=0
saw_quick=0
iphone_classes=()
ipad_classes=()

have_class() {
  local needle="$1" existing
  [ "${#iphone_classes[@]}" -eq 0 ] && return 1
  for existing in "${iphone_classes[@]}"; do
    [ "$existing" = "$needle" ] && return 0
  done
  return 1
}

while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  saw_any=1
  case "$path" in
    *..* | /*)
      saw_full=1
      continue
      ;;
    # Shared test machinery. A change here can make any test lie, so the
    # pull request runs the full suite. The selection script is one of them.
    QBankUITests/UITestSupport.swift | QBank/DebugLaunchScenario.swift | QBank.xcodeproj/project.pbxproj | .github/workflows/xcode.yml | test/sim.sh | test/pr-suite.sh | test/docs-only.sh)
      saw_full=1
      continue
      ;;
    QBankUITests/*UITests.swift) ;;
    QBankUITests/*)
      saw_full=1
      continue
      ;;
    QBank/* | QBankTests/* | Packages/*)
      saw_quick=1
      continue
      ;;
    # CI files and scripts, apart from the machinery matched above.
    .github/* | .gitleaks.toml | scripts/* | test/*)
      continue
      ;;
    *)
      if printf '%s\n' "$path" | ./test/docs-only.sh >/dev/null; then
        continue
      fi
      saw_full=1
      continue
      ;;
  esac

  # A UI test file. Select its class when this checkout still has it.
  if [ ! -f "$path" ]; then
    saw_quick=1
    continue
  fi
  class="${path##*/}"
  class="${class%.swift}"
  if ! grep -E -q "class ${class}([^A-Za-z0-9_]|$)" "$path"; then
    saw_full=1
    continue
  fi
  class_id="QBankUITests/${class}"
  if ! [[ "$class_id" =~ $test_id ]]; then
    saw_full=1
    continue
  fi
  saw_quick=1
  if have_class "$class_id"; then
    continue
  fi
  iphone_classes+=("$class_id")
  if [ "$(device_for "$path")" = ipad ]; then
    ipad_classes+=("$class_id")
  fi
done

if [ "$as_quick" -eq 1 ]; then
  mode=quick
elif [ "$saw_any" -eq 0 ] || [ "$saw_full" -eq 1 ]; then
  mode=full
elif [ "$saw_quick" -eq 1 ]; then
  mode=quick
else
  mode=skip
fi

if [ "$mode" != quick ]; then
  if [ "$mode" = full ]; then
    printf 'mode=full\nipad=true\n'
  else
    printf 'mode=skip\nipad=false\n'
  fi
  exit 0
fi

# Smoke methods whose class is already selected whole are covered.
iphone_ids=("QBankTests")
if [ "${#iphone_classes[@]}" -gt 0 ]; then
  for class_id in "${iphone_classes[@]}"; do
    iphone_ids+=("$class_id")
  done
fi
for id in "${smoke_tests[@]}"; do
  smoke_class="${id%/*}"
  if have_class "$smoke_class"; then
    continue
  fi
  class_file="QBankUITests/${smoke_class#QBankUITests/}.swift"
  method="${id##*/}"
  if [ ! -f "$class_file" ] || ! grep -E -q "func ${method}[[:space:]]*\\(" "$class_file"; then
    echo "pr-suite.sh: smoke test is not in the tree: $id" >&2
    exit 1
  fi
  iphone_ids+=("$id")
done

if [ "${#ipad_classes[@]}" -gt 0 ]; then
  printf 'mode=quick\nipad=true\n'
else
  printf 'mode=quick\nipad=false\n'
fi
printf 'iphone\n'
printf '%s\n' "${iphone_ids[@]}"
printf 'ipad\n'
if [ "${#ipad_classes[@]}" -gt 0 ]; then
  printf '%s\n' "${ipad_classes[@]}"
fi
