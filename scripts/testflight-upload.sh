#!/usr/bin/env bash
# Builds QBank from a git ref on this Mac and uploads it to TestFlight.
#
# usage: scripts/testflight-upload.sh [--no-upload] [--team-id TEAM_ID] [REF]
#
# REF is a qbank-vX.Y.Z tag or a commit on origin (default origin/main). The
# Apple team ID comes from --team-id or APPLE_TEAM_ID and is never committed.
# --no-upload stops after the export check, before the vault is read.
#
# Each step fails the run on error:
#   1. fetch origin, resolve REF to a commit on an origin branch, clone that
#      commit into a fresh temporary directory, and record it;
#   2. archive the QBank scheme in Release, signed through the Xcode account
#      signed in on this Mac (automatic signing, no API key);
#   3. export an App Store Connect IPA with scripts/ExportOptions.plist, the
#      team ID written only into a temporary copy, and check the IPA's
#      version, build number, provisioning profile, and signature;
#   4. upload it with altool, the App Store Connect key read from Automic
#      Vault through av inject for this step alone.
#
# docs/release.md has the version and build number rules. Logs go to the
# ignored build/testflight/<build number>/ directory. Everything else, the key
# included, lives in a temporary directory removed on every exit path, and the
# log stream process Apple's tools leave behind is ended on every exit path too.
#
# Compatible with the bash 3.2 that ships with macOS.
set -euo pipefail

SCHEME="QBank"
BUNDLE_ID="com.dimitrygallego.qbank"
# The app's one entitlement, for Password AutoFill: the web domain's webcredentials.
ASSOCIATED_DOMAIN="webcredentials:qbank.dimitrygallego.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

usage() {
  sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

log() {
  echo "testflight-upload.sh: $*" >&2
}

die() {
  log "error: $*"
  exit 1
}

# --- Upload, inside av inject ---------------------------------------------------
#
# av inject runs this script again as
#   testflight-upload.sh --inside-vault IPA KEY_DIR LOG
# with APP_STORE_CONNECT_KEY_ID on file descriptor 3, APP_STORE_CONNECT_ISSUER_ID
# on 4, and APP_STORE_CONNECT_API_KEY_P8 (the .p8 PEM text) on 5. The key is on
# disk only as KEY_DIR/AuthKey_<KEY_ID>.p8 while altool runs, and the EXIT trap
# removes it however this process ends. No vault value is ever printed.

key_dir=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
remove_key() {
  local status=$?
  if [ -n "$key_dir" ]; then
    rm -rf "$key_dir" || log "warning: could not remove $key_dir; delete it now"
  fi
  exit "$status"
}

upload_inside_vault() {
  [ $# -eq 3 ] || die "--inside-vault takes IPA KEY_DIR LOG"
  local ipa="$1" log_file="$3" key_id issuer_id p8 key_file
  local key_id_re='^[A-Z0-9]{10}$'
  local issuer_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  trap remove_key EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  if ! { true <&3 && true <&4 && true <&5; } 2>/dev/null; then
    die "the vault entries are not on file descriptors 3 to 5; run the script without --inside-vault"
  fi
  key_id="$(tr -d '[:space:]' <&3)"
  issuer_id="$(tr -d '[:space:]' <&4)"
  p8="$(cat <&5)"
  exec 3<&- 4<&- 5<&-

  [[ $key_id =~ $key_id_re ]] || die "APP_STORE_CONNECT_KEY_ID from the vault is empty or not a 10-character key ID"
  [[ $issuer_id =~ $issuer_re ]] || die "APP_STORE_CONNECT_ISSUER_ID from the vault is empty or not an issuer ID (a UUID)"
  case "$p8" in
    "-----BEGIN PRIVATE KEY-----"*"-----END PRIVATE KEY-----") ;;
    *) die "APP_STORE_CONNECT_API_KEY_P8 from the vault is empty or not the PEM text of a .p8 file" ;;
  esac

  mkdir -m 700 "$2" || die "could not create the key directory $2"
  key_dir="$2"
  key_file="$key_dir/AuthKey_$key_id.p8"
  (umask 077 && printf '%s\n' "$p8" >"$key_file")
  chmod 600 "$key_file"
  p8=""

  log "uploading $(basename "$ipa") to App Store Connect; log: $log_file"
  # --type ios is what older altool versions require; the current one accepts it.
  API_PRIVATE_KEYS_DIR="$key_dir" xcrun altool --upload-app -f "$ipa" --type ios \
    --apiKey "$key_id" --apiIssuer "$issuer_id" 2>&1 | tee "$log_file"
}

# --- Apple's leftover log stream ---------------------------------------------------
#
# Apple's delivery code (CDUploader in ContentDelivery.framework) runs
#   /usr/bin/log stream --predicate process contains "<process>" and subsystem == "com.apple.network" ...
# and leaves it running after its parent ends. xcodebuild -exportArchive starts
# one from its ITunesSoftwareService XPC service, which launchd runs outside this
# script's process tree. altool holds the same code.
#
# Other work on this Mac starts identical processes, so neither the command nor
# when it started says whose one is. A background process records each stream
# while its parent is alive to name it: the parent is under this script, or is
# an XPC service that launchctl lists for this run's own xcodebuild. It ends
# only those. If that link is ever missed the stream is left running and named
# in a warning. This never changes the run's outcome.

log_stream_watcher=""

# Prints the rows of table $2 for the processes in $1 and everything under them.
rows_under() {
  printf '%s\n' "$2" | awk -v roots="$1" '
    { row[$1] = $0; parent[$1] = $2 }
    END {
      n = split(roots, list, " ")
      for (i = 1; i <= n; i++) own[list[i]] = 1
      do {
        changed = 0
        for (p in parent) if (!(p in own) && (parent[p] in own)) { own[p] = 1; changed = 1 }
      } while (changed)
      for (p in own) if (p in row) print row[p]
    }'
}

# Adds to $services and $streams, which belong to watch_log_streams(). Rows are
# PID, parent, five words of start time, then the command.
scan_log_streams() {
  local table client found
  table="$(LC_ALL=C ps -A -ww -o pid= -o ppid= -o lstart= -o command=)" || return 0
  for client in $(rows_under "$main_pid $services" "$table" | awk '$8 ~ /(^|\/)xcodebuild$/ { print $1 }'); do
    found="$(launchctl print "pid/$client" 2>/dev/null |
      awk '/^[[:space:]]*services = \{/ { on = 1; next } on && /\}/ { on = 0 } on && $1 ~ /^[1-9][0-9]*$/ { print $1 }')"
    # shellcheck disable=SC2086 # the lists are PIDs, split on purpose
    [ -z "$found" ] || services="$(printf '%s\n' $services $found | sort -un | tr '\n' ' ')"
  done
  found="$(rows_under "$main_pid $services" "$table" |
    awk '$8 == "/usr/bin/log" && $9 == "stream" && $10 == "--predicate" { print $1, $3, $4, $5, $6, $7 }')"
  [ -z "$found" ] || streams="$(printf '%s\n' "$streams" "$found" | sort -u)"
}

end_log_streams() {
  local pid started ended=" " others
  while read -r pid started; do
    [ -n "$pid" ] || continue
    # The start time tells the stream from a later process that reused its PID.
    [ "$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | awk '{ print $1, $2, $3, $4, $5 }')" = "$started" ] || continue
    ended="$ended$pid "
    if kill "$pid" 2>/dev/null; then
      log "ended the log stream Apple's tools left running (process $pid)"
    else
      log "warning: could not end the log stream Apple's tools left running (process $pid)"
    fi
  done <<EOF
$streams
EOF
  others="$(LC_ALL=C ps -A -ww -o pid= -o ppid= -o lstart= -o command= | awk -v ended="$ended" '
    $2 == 1 && $8 == "/usr/bin/log" && $9 == "stream" && $10 == "--predicate" && index(ended, " " $1 " ") == 0 { printf " %s", $1 }')"
  if [ -n "$others" ]; then
    log "warning: orphaned log stream processes this run cannot tie to itself, left running:$others"
  fi
}

# shellcheck disable=SC2034 # main_pid is read by scan_log_streams()
watch_log_streams() {
  local main_pid="$1" services="" streams="" stopping=no
  set +e
  trap 'stopping=yes' USR1
  trap '' HUP INT TERM
  # A run killed outright runs no trap; this notices and still ends its streams.
  while [ "$stopping" = no ] && kill -0 "$main_pid" 2>/dev/null; do
    scan_log_streams
    sleep 0.5
  done
  scan_log_streams
  end_log_streams
}

start_log_stream_watcher() {
  watch_log_streams "$$" </dev/null >/dev/null 3<&- 4<&- 5<&- &
  log_stream_watcher=$!
}

# Waits a bounded time, so a stuck watcher can never hold up the run's exit.
stop_log_stream_watcher() {
  local tries=0
  [ -n "$log_stream_watcher" ] || return 0
  kill -USR1 "$log_stream_watcher" 2>/dev/null || return 0
  while kill -0 "$log_stream_watcher" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
      log "warning: the log stream watcher (process $log_stream_watcher) has not finished; check for a stray log stream"
      return 0
    fi
    sleep 0.1
  done
}

# --- Build, export, check, then upload --------------------------------------------

work=""
out=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  local status=$?
  cd /
  stop_log_stream_watcher || true
  if [ -n "$work" ]; then
    rm -rf "$work/asc-key" || log "warning: could not remove $work/asc-key; delete it now"
    chmod -R u+w "$work" 2>/dev/null || true
    rm -rf "$work" || log "warning: could not remove $work; delete it now"
  fi
  # A run that failed before writing anything leaves no empty log directory.
  if [ -n "$out" ]; then
    rmdir "$out" 2>/dev/null || true
  fi
  exit "$status"
}

fail_with_log() {
  tail -n 40 "$1" >&2 || true
  die "$2; full log: $1"
}

# Prints X.Y for X.Y.0 or X.Y, and X.Y.Z otherwise; fails for anything else.
marketing_version() {
  local re='^([0-9]+)\.([0-9]+)(\.([0-9]+))?$'
  [[ $1 =~ $re ]] || return 1
  if [ -z "${BASH_REMATCH[3]:-}" ] || [ "${BASH_REMATCH[4]:-}" = "0" ]; then
    echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  else
    echo "$1"
  fi
}

expect_plist() {
  local file="$1" key="$2" expected="$3" actual
  actual="$(plutil -extract "$key" raw -o - "$file" 2>/dev/null)" || actual="nothing"
  [ "$actual" = "$expected" ] || die "$(basename "$file") has $key $actual, expected $expected"
}

# Proves the IPA is the build this run meant to make, signed for App Store
# Connect distribution, before anything is uploaded.
check_export() {
  local ipa="$1" version="$2" build_number="$3" team_id="$4" app profile signature entitlements
  [ -f "$ipa" ] || die "the export made no $(basename "$ipa"); see $out/export.log"
  unzip -q "$ipa" -d "$work/ipa"
  app="$work/ipa/Payload/$SCHEME.app"
  [ -f "$app/Info.plist" ] || die "the IPA has no Payload/$SCHEME.app"

  expect_plist "$app/Info.plist" CFBundleIdentifier "$BUNDLE_ID"
  expect_plist "$app/Info.plist" CFBundleShortVersionString "$version"
  expect_plist "$app/Info.plist" CFBundleVersion "$build_number"
  # App Store Connect refuses a bundle without its app icon only after the upload.
  expect_plist "$app/Info.plist" CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName AppIcon
  expect_plist "$app/Info.plist" "CFBundleIcons~ipad.CFBundlePrimaryIcon.CFBundleIconName" AppIcon

  profile="$work/profile.plist"
  security cms -D -i "$app/embedded.mobileprovision" >"$profile" 2>/dev/null ||
    die "the IPA has no readable provisioning profile"
  expect_plist "$profile" TeamIdentifier.0 "$team_id"
  expect_plist "$profile" Entitlements.get-task-allow false
  if plutil -extract ProvisionedDevices xml1 -o /dev/null "$profile" 2>/dev/null ||
    plutil -extract ProvisionsAllDevices xml1 -o /dev/null "$profile" 2>/dev/null; then
    die "the provisioning profile is not an App Store profile"
  fi

  # Password AutoFill offers the web domain's password only in an app signed with its webcredentials, under a
  # profile whose App ID has Associated Domains (automatic signing adds it; see docs/release.md).
  /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.associated-domains' "$profile" >/dev/null 2>&1 ||
    die "the provisioning profile does not allow Associated Domains; see docs/release.md"
  entitlements="$work/entitlements.plist"
  codesign -d --entitlements - --xml "$app" >"$entitlements" 2>/dev/null ||
    die "could not read the entitlements of $SCHEME.app"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.associated-domains:0' "$entitlements" 2>/dev/null)" = "$ASSOCIATED_DOMAIN" ] ||
    die "$SCHEME.app is not signed with $ASSOCIATED_DOMAIN, so Password AutoFill would not offer the web domain's password"

  codesign --verify --deep --strict "$app" || die "$SCHEME.app fails codesign --verify"
  signature="$(codesign -d --verbose=2 "$app" 2>&1)" || die "could not read the signature of $SCHEME.app"
  case "$signature" in
    *"Authority=Apple Distribution: "* | *"Authority=iPhone Distribution: "*) ;;
    *) die "$SCHEME.app is not signed with a distribution certificate" ;;
  esac
  log "export check passed: $BUNDLE_ID $version ($build_number), App Store profile and distribution signature for team $team_id, $ASSOCIATED_DOMAIN"
}

upload_with_vault() {
  local ipa="$1"
  log "uploading: Automic Vault asks to allow APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, and APP_STORE_CONNECT_API_KEY_P8"
  # av inject --mode=fd refuses a descriptor that is already open. A parent
  # can inherit one: the worker runner that starts this script holds a pipe
  # on 3. Nothing above uses 3, 4, or 5.
  if { true <&3; } 2>/dev/null || { true >&3; } 2>/dev/null; then
    exec 3<&-
  fi
  if { true <&4; } 2>/dev/null || { true >&4; } 2>/dev/null; then
    exec 4<&-
  fi
  if { true <&5; } 2>/dev/null || { true >&5; } 2>/dev/null; then
    exec 5<&-
  fi
  if ! av inject --mode=fd \
    +APP_STORE_CONNECT_KEY_ID:3 \
    +APP_STORE_CONNECT_ISSUER_ID:4 \
    +APP_STORE_CONNECT_API_KEY_P8:5 \
    -- "$SELF" --inside-vault "$ipa" "$work/asc-key" "$out/upload.log"; then
    die "the upload step failed. If av refused or named a missing vault entry, nothing was uploaded; otherwise see $out/upload.log"
  fi
}

main() {
  local ref="origin/main" ref_given=no team_id="${APPLE_TEAM_ID:-}" upload=yes
  local team_id_re='^[A-Z0-9]{10}$' tag_version_re='^[0-9]+\.[0-9]+\.[0-9]+$'
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-upload)
        upload=no
        shift
        ;;
      --team-id)
        [ $# -ge 2 ] || usage
        team_id="$2"
        shift 2
        ;;
      -*)
        usage
        ;;
      *)
        [ "$ref_given" = no ] || usage
        ref="$1"
        ref_given=yes
        shift
        ;;
    esac
  done

  [ "$(uname -s)" = "Darwin" ] || die "this needs macOS with Xcode"
  [ -n "$team_id" ] ||
    die "no Apple team ID: pass --team-id TEAM_ID or set APPLE_TEAM_ID (developer.apple.com > Account > Membership details)"
  [[ $team_id =~ $team_id_re ]] || die "the Apple team ID must be 10 capital letters and digits"
  local tool
  for tool in git xcodebuild xcrun plutil security codesign unzip; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
  done
  if [ "$upload" = yes ]; then
    command -v av >/dev/null 2>&1 || die "av (Automic Vault) not found; pass --no-upload to stop before the upload"
  fi

  local repo_root build_number commit src raw_version version version_source
  repo_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" || die "$SCRIPT_DIR is not in a git checkout"

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  # The run's start time is its build number. Each run creates its log
  # directory exclusively, waiting for the next second if another run holds
  # this one, so two runs on this Mac never share a build number.
  mkdir -p "$repo_root/build/testflight"
  build_number="$(date -u +%s)"
  while ! mkdir "$repo_root/build/testflight/$build_number" 2>/dev/null; do
    [ -d "$repo_root/build/testflight/$build_number" ] ||
      die "could not create $repo_root/build/testflight/$build_number"
    sleep 1
    build_number="$(date -u +%s)"
  done
  out="$repo_root/build/testflight/$build_number"

  local tmp_root="${TMPDIR:-/tmp}"
  work="$(mktemp -d "${tmp_root%/}/qbank-testflight.XXXXXX")"
  cd "$work"
  start_log_stream_watcher

  log "fetching origin"
  git -C "$repo_root" fetch --quiet origin || die "could not fetch origin"
  commit="$(git -C "$repo_root" rev-parse --verify --quiet "$ref^{commit}")" ||
    die "$ref is not a commit in $repo_root"
  if [ -z "$(git -C "$repo_root" for-each-ref --contains "$commit" refs/remotes/origin)" ]; then
    die "$commit is on no origin branch; push it before uploading"
  fi

  # A fresh clone of the commit, so edits in this checkout never ship. It shares
  # no files with this checkout's object store.
  src="$work/src"
  git clone --quiet --no-checkout --no-hardlinks "$repo_root" "$src"
  git -C "$src" -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout --quiet --detach "$commit"
  [ "$(git -C "$src" rev-parse HEAD)" = "$commit" ] || die "the clone is not at $commit"
  [ -z "$(git -C "$src" status --porcelain)" ] || die "the clone of $commit is not clean"

  case "$ref" in
    qbank-v*)
      git -C "$repo_root" show-ref --verify --quiet "refs/tags/$ref" || die "$ref is not a tag"
      raw_version="${ref#qbank-v}"
      version_source="tag $ref"
      [[ $raw_version =~ $tag_version_re ]] || die "release tags are qbank-vX.Y.Z, not $ref"
      ;;
    *)
      raw_version="$(xcodebuild -project "$src/QBank.xcodeproj" -target "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null |
        awk '$1 == "MARKETING_VERSION" && !found { print $3; found = 1 }')" ||
        die "could not read MARKETING_VERSION from the project"
      version_source="the project's MARKETING_VERSION"
      ;;
  esac
  version="$(marketing_version "$raw_version")" ||
    die "version '$raw_version' from $version_source is not X.Y or X.Y.Z"

  {
    echo "ref: $ref"
    echo "commit: $commit"
    echo "version: $version (from $version_source)"
    echo "build: $build_number"
    echo "started: $(date -u -r "$build_number" +%Y-%m-%dT%H:%M:%SZ)"
    echo "xcode: $(xcodebuild -version | tr '\n' ' ')"
    echo "upload: $upload"
  } >"$out/build.txt"
  log "QBank $version ($build_number) from $ref at $commit; logs: $out"

  log "archiving"
  if ! xcodebuild archive \
    -project "$src/QBank.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$work/QBank.xcarchive" \
    -derivedDataPath "$work/DerivedData" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$team_id" \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    >"$out/archive.log" 2>&1; then
    fail_with_log "$out/archive.log" "the archive failed"
  fi

  log "exporting the IPA"
  cp "$SCRIPT_DIR/ExportOptions.plist" "$work/ExportOptions.plist"
  plutil -replace teamID -string "$team_id" "$work/ExportOptions.plist"
  if ! xcodebuild -exportArchive \
    -archivePath "$work/QBank.xcarchive" \
    -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist" \
    -allowProvisioningUpdates \
    >"$out/export.log" 2>&1; then
    fail_with_log "$out/export.log" "the export failed"
  fi
  check_export "$work/export/$SCHEME.ipa" "$version" "$build_number" "$team_id"

  if [ "$upload" = no ]; then
    log "stopped before the upload (--no-upload): nothing was read from the vault or sent to App Store Connect"
    exit 0
  fi
  upload_with_vault "$work/export/$SCHEME.ipa"
  log "uploaded QBank $version ($build_number) from $commit; Apple processes it in 5 to 30 minutes, then it shows in TestFlight"
}

if [ "${1:-}" = "--inside-vault" ]; then
  shift
  upload_inside_vault "$@"
else
  main "$@"
fi
