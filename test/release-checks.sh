#!/usr/bin/env bash
# Repository and pipeline rule checks.
#
# Credential-free by construction: these checks read repository files only.
# They never touch Apple credentials, App Store Connect, or the network, and
# they run the same on a Linux CI machine and on a developer Mac. They need
# bash, git, grep, and ruby (for YAML).
# shellcheck disable=SC2016 # the Ruby programs are single-quoted on purpose
set -u

cd "$(dirname "$0")/.." || exit 1

FAILURES=0

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "ok: $1"
}

require_grep() {
  local pattern="$1" file="$2" message="$3"
  if grep -qE -- "$pattern" "$file"; then
    pass "$message"
  else
    fail "$message ($file does not match: $pattern)"
  fi
}

forbid_grep() {
  local pattern="$1" file="$2" message="$3"
  if grep -qE -- "$pattern" "$file"; then
    fail "$message ($file matches forbidden pattern: $pattern)"
  else
    pass "$message"
  fi
}

# Runs a Ruby program over the YAML workflow named by $1 and reports its
# result. The program aborts with a reason on failure.
ruby_check() {
  local message="$1" file="$2" program="$3" out
  if out="$(ruby -ryaml -e "$program" "$file" 2>&1)"; then
    pass "$message"
  else
    fail "$message: $out"
  fi
}

CI=.github/workflows/ci.yml
XCODE=.github/workflows/xcode.yml
MAC_RUNS_ON="\${{ vars.MAC_RUNNER || 'macos-26' }}"

if ! command -v ruby >/dev/null 2>&1; then
  echo "FAIL: ruby is required to parse the workflows" >&2
  exit 1
fi

# --- Workflow syntax --------------------------------------------------------

for workflow in "$CI" "$XCODE"; do
  [ -f "$workflow" ] || fail "workflow exists: $workflow"
done

WORKFLOWS=()
for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$workflow" ] && WORKFLOWS+=("$workflow")
done

for workflow in "${WORKFLOWS[@]}"; do
  if ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$workflow" >/dev/null 2>&1; then
    pass "workflow parses as YAML: $workflow"
  else
    fail "workflow parses as YAML: $workflow"
  fi
done

# --- Every workflow ---------------------------------------------------------

for workflow in "${WORKFLOWS[@]}"; do
  unpinned="$(grep -nE '^[[:space:]]*(- )?uses:' "$workflow" | grep -vE 'uses:[[:space:]]*[^[:space:]]+@[0-9a-f]{40}( |$)' || true)"
  if [ -n "$unpinned" ]; then
    fail "every action is pinned to a full commit SHA in $workflow: $unpinned"
  else
    pass "every action is pinned to a full commit SHA in $workflow"
  fi

  forbid_grep 'pull_request_target' "$workflow" "no pull_request_target trigger in $workflow"
  require_grep '^permissions:' "$workflow" "$workflow sets top-level permissions"

  # A job off GitHub's hosted Linux may run on the self-hosted MAC_RUNNER, so
  # only events that need write access here may start it: pushes and manual
  # runs. Code from a pull request (possibly from a fork), a comment, a review,
  # or a workflow_run must never reach it. A fork's own workflow file is kept
  # off the runner by repository settings instead (see docs/ci.md).
  ruby_check "$workflow runs Mac or self-hosted jobs only on pushes and manual runs" "$workflow" '
    wf = YAML.load_file(ARGV[0])
    on = wf[true] || wf["on"]
    events = on.is_a?(Hash) ? on.keys.map(&:to_s) : Array(on).map(&:to_s)
    untrusted = events - %w[push workflow_dispatch]
    exit 0 if untrusted.empty?
    (wf["jobs"] || {}).each do |name, job|
      runs_on = job["runs-on"]
      next if runs_on.is_a?(String) && runs_on.start_with?("ubuntu-")
      abort "job #{name} runs on #{runs_on.inspect} and the workflow triggers on #{untrusted.inspect}"
    end
  '
done

# --- ci.yml: pull requests, Linux only, no secrets ---------------------------

forbid_grep 'secrets\.' "$CI" "ci.yml references no secrets"
require_grep '^  contents: read$' "$CI" "ci.yml permissions are contents: read"
forbid_grep ':[[:space:]]*write' "$CI" "ci.yml grants no write permission"
ruby_check "ci.yml triggers only on pull_request and pushes to main, and runs only on Linux" "$CI" '
  wf = YAML.load_file(ARGV[0])
  on = wf[true] || wf["on"]
  abort "on: must be a mapping" unless on.is_a?(Hash)
  keys = on.keys.map(&:to_s)
  abort "on: keys are #{keys.inspect}, expected [\"pull_request\", \"push\"]" unless keys == %w[pull_request push]
  push = on["push"]
  unless push.is_a?(Hash) && push.keys.map(&:to_s) == %w[branches] && push["branches"] == ["main"]
    abort "push must be exactly branches: [main] (got #{push.inspect})"
  end
  jobs = wf["jobs"] || {}
  abort "no jobs" if jobs.empty?
  jobs.each do |name, job|
    runs_on = job["runs-on"]
    abort "job #{name} runs on #{runs_on.inspect}" unless runs_on.is_a?(String) && runs_on.start_with?("ubuntu-")
  end
'
require_grep 'release-checks\.sh' "$CI" "ci.yml runs test/release-checks.sh"
require_grep 'package-tests\.sh --linux' "$CI" "ci.yml tests the Swift packages on Linux"
# The "Secrets" job is a required check on main, so its name is part of the
# repository settings. It reads every commit and installs the one gitleaks
# release whose checksum it pins.
ruby_check "ci.yml has a Secrets job that runs test/leak-check.sh over the full history" "$CI" '
  jobs = YAML.load_file(ARGV[0])["jobs"] || {}
  job = jobs.values.find { |j| j["name"] == "Secrets" } or abort "no job is named Secrets"
  steps = job["steps"] || []
  checkout = steps.find { |s| s["uses"].to_s.start_with?("actions/checkout@") } or abort "the Secrets job checks nothing out"
  abort "the Secrets checkout needs fetch-depth: 0" unless (checkout["with"] || {})["fetch-depth"] == 0
  install = steps.map { |s| s["run"].to_s }.find { |r| r.include?("gitleaks") && r.include?("sha256sum --check") }
  abort "the Secrets job does not install gitleaks with a checksum check" unless install
  abort "the Secrets job does not pin a gitleaks version" unless install =~ /^version=\d+\.\d+\.\d+$/
  abort "the Secrets job does not pin a sha256" unless install =~ /^sha256=[0-9a-f]{64}$/
  abort "the Secrets job does not run test/leak-check.sh" unless steps.any? { |s| s["run"].to_s.include?("test/leak-check.sh") }
'
require_grep '^useDefault = true$' .gitleaks.toml ".gitleaks.toml keeps gitleaks' own rules"

# --- xcode.yml: trusted events only, MAC_RUNNER with hosted fallback ---------

forbid_grep 'secrets\.' "$XCODE" "xcode.yml references no secrets"
require_grep '^  contents: read$' "$XCODE" "xcode.yml permissions are contents: read"
forbid_grep ':[[:space:]]*write' "$XCODE" "xcode.yml grants no write permission"
ruby_check "xcode.yml triggers only on pushes to main, qbank-v* tags, and manual runs" "$XCODE" '
  wf = YAML.load_file(ARGV[0])
  on = wf[true] || wf["on"]
  abort "on: must be a mapping" unless on.is_a?(Hash)
  keys = on.keys.map(&:to_s)
  abort "on: keys are #{keys.inspect}, expected [\"push\", \"workflow_dispatch\"]" unless keys == %w[push workflow_dispatch]
  push = on["push"]
  unless push.is_a?(Hash) && push.keys.map(&:to_s) == %w[branches tags] && push["branches"] == ["main"] && push["tags"] == ["qbank-v*"]
    abort "push must be exactly branches: [main] and tags: [qbank-v*] (got #{push.inspect})"
  end
'
# With no MAC_RUNNER a push to main must not fall back to a hosted Mac on every
# merge: the Mac job skips and a Linux job says why. Every Mac job shares one
# concurrency group that queues rather than cancels, so the self-hosted Mac,
# which other CI shares, runs one QBank job at a time.
ruby_check "xcode.yml's Mac jobs run on $MAC_RUNS_ON one at a time and skip a push to main without MAC_RUNNER" "$XCODE" '
  jobs = YAML.load_file(ARGV[0])["jobs"] || {}
  q = "'"'"'"
  mac = "${{ vars.MAC_RUNNER || #{q}macos-26#{q} }}"
  build_if = "github.event_name != #{q}push#{q} || github.ref != #{q}refs/heads/main#{q} || vars.MAC_RUNNER != #{q}#{q}"
  skip_if = "github.event_name == #{q}push#{q} && github.ref == #{q}refs/heads/main#{q} && vars.MAC_RUNNER == #{q}#{q}"
  mac_jobs, other_jobs = jobs.partition { |_, job| job["runs-on"] == mac }
  abort "no job runs on #{mac}" if mac_jobs.empty?
  mac_jobs.each do |name, job|
    abort "job #{name} if: is #{job["if"].inspect}, expected #{build_if.inspect}" unless job["if"] == build_if
    abort "job #{name} sets no timeout-minutes" unless job["timeout-minutes"].is_a?(Integer)
    concurrency = job["concurrency"]
    unless concurrency.is_a?(Hash) && concurrency["group"] == "xcode-mac" && concurrency["cancel-in-progress"] == false
      abort "job #{name} concurrency must be group: xcode-mac, cancel-in-progress: false (got #{concurrency.inspect})"
    end
  end
  other_jobs.each do |name, job|
    abort "job #{name} runs on #{job["runs-on"].inspect}" unless job["runs-on"].to_s.start_with?("ubuntu-")
    abort "job #{name} if: is #{job["if"].inspect}, expected #{skip_if.inspect}" unless job["if"] == skip_if
  end
'
require_grep 'package-tests\.sh --macos' "$XCODE" "xcode.yml tests the Swift packages on macOS"
forbid_grep '^[^#]*sudo[[:space:]]' "$XCODE" "xcode.yml needs no sudo (the self-hosted runner has none)"

# --- Simulators only through test/sim.sh -------------------------------------

for workflow in "${WORKFLOWS[@]}"; do
  forbid_grep 'simctl' "$workflow" "$workflow never drives simctl directly"
  bad_destination="$(grep -nE 'platform=iOS Simulator' "$workflow" | grep -vF 'platform=iOS Simulator,id={{UDID}}' || true)"
  if [ -n "$bad_destination" ]; then
    fail "$workflow targets simulators only through test/sim.sh's {{UDID}}: $bad_destination"
  else
    pass "$workflow targets simulators only through test/sim.sh's {{UDID}}"
  fi
done

# --- Xcode project ------------------------------------------------------------

PBXPROJ=QBank.xcodeproj/project.pbxproj
SCHEME=QBank.xcodeproj/xcshareddata/xcschemes/QBank.xcscheme

if [ -f "$SCHEME" ]; then
  pass "shared QBank scheme exists"
else
  fail "shared QBank scheme exists: $SCHEME"
fi

targets="$(grep -oE 'IPHONEOS_DEPLOYMENT_TARGET = [^;]+;' "$PBXPROJ" | sort -u)"
if [ "$targets" = "IPHONEOS_DEPLOYMENT_TARGET = 18.0;" ]; then
  pass "iOS deployment target is 18.0 everywhere"
else
  fail "iOS deployment target is 18.0 everywhere (found: ${targets:-none})"
fi

families="$(grep -oE 'TARGETED_DEVICE_FAMILY = [^;]+;' "$PBXPROJ" | sort -u)"
if [ "$families" = 'TARGETED_DEVICE_FAMILY = "1,2";' ]; then
  pass "every target is iPhone and iPad"
else
  fail "every target is iPhone and iPad (found: ${families:-none})"
fi
# An iPad app that shares the screen must support every orientation.
require_grep 'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";' "$PBXPROJ" "the iPad supports every orientation"
require_grep 'INFOPLIST_KEY_NSFaceIDUsageDescription = "[^"]+";' "$PBXPROJ" "the app says why it asks for Face ID"
# Password AutoFill needs the web domain's webcredentials to offer its saved
# password, and that is the app's one entitlement. Associated Domains needs the paid team (a free Personal Team
# cannot sign it), and every capability needs its App ID step in
# docs/release.md, so no other one comes in unnoticed.
ENTITLEMENTS=QBank/QBank.entitlements
entitlement_files="$(git ls-files | grep -E '\.entitlements$' || true)"
if [ "$entitlement_files" = "$ENTITLEMENTS" ]; then
  pass "$ENTITLEMENTS is the only entitlements file"
else
  fail "$ENTITLEMENTS is the only entitlements file (found: ${entitlement_files:-none})"
fi
entitlement_settings="$(grep -oE 'CODE_SIGN_ENTITLEMENTS = [^;]+;' "$PBXPROJ" | sort | uniq -c | sed 's/^ *//')"
if [ "$entitlement_settings" = "2 CODE_SIGN_ENTITLEMENTS = $ENTITLEMENTS;" ]; then
  pass "the app's Debug and Release builds sign with $ENTITLEMENTS"
else
  fail "the app's Debug and Release builds sign with $ENTITLEMENTS (found: ${entitlement_settings:-none})"
fi
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$ENTITLEMENTS" >/dev/null; then
    pass "plutil -lint accepts $ENTITLEMENTS"
  else
    fail "plutil -lint accepts $ENTITLEMENTS"
  fi
fi
ruby_check "the app's only entitlement is webcredentials:qbank.dimitrygallego.com" "$ENTITLEMENTS" '
  require "rexml/document"
  doc = REXML::Document.new(File.read(ARGV[0]))
  dict = doc.root&.elements&.[]("dict") or abort "#{ARGV[0]} has no dict"
  keys = dict.get_elements("key").map(&:text)
  abort "the entitlements are #{keys.inspect}" unless keys == ["com.apple.developer.associated-domains"]
  domains = dict.get_elements("array").first.get_elements("string").map(&:text)
  abort "the associated domains are #{domains.inspect}" unless domains == ["webcredentials:qbank.dimitrygallego.com"]
'

require_grep 'PRODUCT_BUNDLE_IDENTIFIER = com\.dimitrygallego\.qbank;' "$PBXPROJ" "app bundle id is com.dimitrygallego.qbank"
require_grep 'INFOPLIST_KEY_CFBundleDisplayName = QBank;' "$PBXPROJ" "app display name is QBank"
# App Store Connect refuses an upload whose bundle has no app icon (90022,
# 90023, 90713), so every slot of the icon set must name an image that exists.
require_grep 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' "$PBXPROJ" "app icon set is AppIcon"
ruby_check "every AppIcon slot names a 1024x1024 PNG that exists, the default one opaque" QBank/Assets.xcassets/AppIcon.appiconset/Contents.json '
  require "json"
  dir = File.dirname(ARGV[0])
  images = JSON.parse(File.read(ARGV[0]))["images"]
  abort "the icon set has no images" if images.empty?
  images.each do |image|
    name = image["filename"] or abort "the #{image.dig("appearances", 0, "value") || "default"} slot has no image"
    png = File.binread(File.join(dir, name)) rescue abort("#{name} is missing")
    abort "#{name} is not a PNG" unless png.start_with?("\x89PNG\r\n\x1A\n".b)
    width, height = png[16, 8].unpack("NN")
    abort "#{name} is #{width}x#{height}, not 1024x1024" unless [width, height] == [1024, 1024]
    # The App Store icon (the slot with no appearance) must be opaque (90717):
    # an RGB or gray PNG with no transparency chunk.
    next if image["appearances"]
    abort "#{name} has an alpha channel" unless [0, 2].include?(png.getbyte(25)) && !png.include?("tRNS")
  end
'
# The Apple team id comes from the uploader's shell, never from Git.
forbid_grep 'DEVELOPMENT_TEAM = [^";]' "$PBXPROJ" "no Apple team id is committed in the project"

# --- Privacy manifest -----------------------------------------------------------
#
# The app target's folder-synchronized QBank group is the file's membership.
# A file under QBank/ joins that target and no other, so project.pbxproj does
# not name PrivacyInfo.xcprivacy. plutil is the lint on a Mac; Linux CI has no
# plutil, and the ruby check below is the lint there.

MANIFEST=QBank/PrivacyInfo.xcprivacy
if [ -f "$MANIFEST" ]; then
  pass "privacy manifest exists at $MANIFEST"
else
  fail "privacy manifest exists at $MANIFEST"
fi

if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$MANIFEST" >/dev/null; then
    pass "plutil -lint accepts the privacy manifest"
  else
    fail "plutil -lint accepts the privacy manifest"
  fi
fi

ruby_check "privacy manifest lints and matches docs/privacy-manifest.md" "$MANIFEST" '
  require "rexml/document"
  raw = File.read(ARGV[0])
  abort "#{ARGV[0]} is empty" if raw.empty?
  begin
    doc = REXML::Document.new(raw)
  rescue REXML::ParseException => e
    abort "privacy manifest is not well-formed XML: #{e.message.lines.first}"
  end
  plist = doc.root
  abort "root element is #{plist&.name.inspect}, expected plist" unless plist&.name == "plist"
  abort "plist version is #{plist.attributes["version"].inspect}" unless plist.attributes["version"] == "1.0"

  def elements_of(node)
    node.elements.to_a
  end

  def expect_dict(node, where)
    abort "#{where} is #{node&.name.inspect}, expected dict" unless node&.name == "dict"
    list = elements_of(node)
    abort "#{where} has an odd number of children" unless list.size.even?
    pairs = {}
    list.each_slice(2) do |key, value|
      abort "#{where} key is #{key.name.inspect}" unless key.name == "key" && key.text && !key.text.empty?
      abort "#{where} repeats #{key.text}" if pairs.key?(key.text)
      pairs[key.text] = value
    end
    pairs
  end

  root_dict = elements_of(plist)
  abort "plist has #{root_dict.size} elements, expected one dict" unless root_dict.size == 1
  root = expect_dict(root_dict[0], "plist")
  abort "NSPrivacyTracking is not false" unless root["NSPrivacyTracking"]&.name == "false"
  domains = root["NSPrivacyTrackingDomains"]
  abort "NSPrivacyTrackingDomains is not an empty array" unless domains&.name == "array" && elements_of(domains).empty?

  collected = root["NSPrivacyCollectedDataTypes"]
  abort "NSPrivacyCollectedDataTypes is missing" unless collected&.name == "array"
  expected_types = %w[
    NSPrivacyCollectedDataTypeEmailAddress
    NSPrivacyCollectedDataTypeUserID
    NSPrivacyCollectedDataTypePhotosorVideos
    NSPrivacyCollectedDataTypeOtherUserContent
    NSPrivacyCollectedDataTypeProductInteraction
  ]
  types = elements_of(collected)
  names = types.map { |entry| expect_dict(entry, "collected type")["NSPrivacyCollectedDataType"]&.text }
  abort "collected types are #{names.inspect}" unless names == expected_types
  types.each do |entry|
    item = expect_dict(entry, "collected type")
    abort "#{item["NSPrivacyCollectedDataType"]&.text} is not linked" unless item["NSPrivacyCollectedDataTypeLinked"]&.name == "true"
    abort "#{item["NSPrivacyCollectedDataType"]&.text} is marked for tracking" unless item["NSPrivacyCollectedDataTypeTracking"]&.name == "false"
    purposes = elements_of(item["NSPrivacyCollectedDataTypePurposes"] || REXML::Element.new("array"))
    abort "#{item["NSPrivacyCollectedDataType"]&.text} purposes are #{purposes.map(&:text).inspect}" unless purposes.map(&:text) == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
  end

  accessed = root["NSPrivacyAccessedAPITypes"]
  abort "NSPrivacyAccessedAPITypes is missing" unless accessed&.name == "array"
  apis = elements_of(accessed)
  abort "accessed API count is #{apis.size}, expected 1" unless apis.size == 1
  api = expect_dict(apis[0], "accessed API")
  abort "accessed API is #{api["NSPrivacyAccessedAPIType"]&.text.inspect}" unless api["NSPrivacyAccessedAPIType"]&.text == "NSPrivacyAccessedAPICategoryUserDefaults"
  reasons = elements_of(api["NSPrivacyAccessedAPITypeReasons"] || REXML::Element.new("array")).map(&:text)
  abort "UserDefaults reasons are #{reasons.inspect}" unless reasons == ["CA92.1"]

  fence = File.read("docs/privacy-manifest.md")[/```xml\n(.*?)```/m, 1]
  abort "docs/privacy-manifest.md has no ```xml fence" unless fence
  abort "QBank/PrivacyInfo.xcprivacy differs from the plist in docs/privacy-manifest.md" unless raw == fence
'

ruby_check "privacy manifest belongs only to the QBank app target" "$PBXPROJ" '
  def each_object(text)
    lines = text.lines
    index = 0
    while index < lines.size
      unless lines[index] =~ /^\t\t([0-9A-F]{24}) \/\* (.*) \*\/ = \{$/
        index += 1
        next
      end
      id = Regexp.last_match(1)
      depth = 1
      body = +""
      index += 1
      while index < lines.size && depth.positive?
        depth += lines[index].count("{")
        depth -= lines[index].count("}")
        body << lines[index] if depth.positive?
        index += 1
      end
      yield id, body
    end
  end

  groups = {}
  targets = {}
  each_object(File.read(ARGV[0])) do |id, body|
    if body.include?("isa = PBXFileSystemSynchronizedRootGroup;")
      groups[id] = body[/^\t\t\tpath = ([^;]+);$/, 1]
    elsif body.include?("isa = PBXNativeTarget;")
      name = body[/^\t\t\tname = ([^;]+);$/, 1]
      sync = body[/fileSystemSynchronizedGroups = \((.*?)\);/m, 1].to_s
      targets[name] = {
        groups: sync.scan(/[0-9A-F]{24}/),
        product: body[/productType = "([^"]+)";/, 1],
        body: body,
      }
    end
  end

  qbank = groups.select { |_, path| path == "QBank" }
  abort "expected one synchronized root named QBank, found #{qbank.size}" unless qbank.size == 1
  group_id, = qbank.first
  app = targets["QBank"] or abort "no QBank target"
  abort "QBank is not an application target" unless app[:product] == "com.apple.product-type.application"
  abort "the QBank target does not synchronize the QBank group" unless app[:groups] == [group_id]
  %w[QBankTests QBankUITests].each do |name|
    target = targets[name] or abort "no #{name} target"
    abort "#{name} synchronizes the app group" if target[:groups].include?(group_id)
  end

  text = File.read(ARGV[0])
  if text.include?("PrivacyInfo.xcprivacy")
    abort "project.pbxproj names PrivacyInfo.xcprivacy; the synchronized QBank group already includes it"
  end
  # The files Git would commit, so a build under the ignored build/ or DerivedData/ is not counted.
  files = `git ls-files --cached --others --exclude-standard`.split("\n")
  extras = files.select { |path| path.end_with?("PrivacyInfo.xcprivacy") }.reject { |path| path == "QBank/PrivacyInfo.xcprivacy" }
  abort "privacy manifest is outside the app target: #{extras.join(", ")}" unless extras.empty?
'

# --- TestFlight upload script ---------------------------------------------------
#
# scripts/testflight-upload.sh runs on the owner's Mac and is the only thing
# that reads the App Store Connect key. These checks read its text; they never
# run it.

UPLOAD=scripts/testflight-upload.sh
EXPORT_OPTIONS=scripts/ExportOptions.plist

if [ -x "$UPLOAD" ] && bash -n "$UPLOAD" 2>/dev/null; then
  pass "$UPLOAD is executable and parses (bash -n)"
else
  fail "$UPLOAD is executable and parses (bash -n)"
fi
require_grep 'shellcheck test/\*\.sh scripts/\*\.sh' "$CI" "ci.yml runs shellcheck over test/ and scripts/"

# Joins backslash-continued lines, drops comment-only lines, and finds function
# bodies, so the checks below see each command whole.
SCRIPT_RUBY='
  lines = File.read(ARGV[0]).lines.map(&:chomp)
  logical = []
  buf = nil
  first = nil
  lines.each_with_index do |line, i|
    next if buf.nil? && line =~ /^\s*#/
    if buf then buf << " " << line.strip else buf = line.strip.dup; first = i end
    if buf.end_with?("\\") then buf.chop!.rstrip! else logical << [first, buf]; buf = nil end
  end
  body = lambda do |name|
    s = lines.index("#{name}() {") or abort "no #{name}() function"
    e = (s + 1...lines.size).find { |i| lines[i] == "}" } or abort "#{name}() never closes"
    (s + 1...e)
  end
  line_in = lambda { |range, text| range.find { |i| lines[i].strip == text } }
'

ruby_check "$UPLOAD uploads only inside upload_inside_vault(), through API_PRIVATE_KEYS_DIR" "$UPLOAD" "$SCRIPT_RUBY"'
  hits = logical.select { |_, t| t =~ /\baltool\b/ }
  abort "altool runs #{hits.size} times, expected once" unless hits.size == 1
  i, t = hits[0]
  abort "altool runs outside upload_inside_vault()" unless body.call("upload_inside_vault").cover?(i)
  abort "not xcrun altool --upload-app with --apiKey and --apiIssuer: #{t}" unless t.include?("xcrun altool --upload-app") && t.include?("--apiKey") && t.include?("--apiIssuer")
  abort "altool does not find the key through API_PRIVATE_KEYS_DIR" unless t.start_with?(%q{API_PRIVATE_KEYS_DIR="$key_dir" })
'
ruby_check "$UPLOAD reads the vault only in upload_with_vault(), through av inject --mode=fd" "$UPLOAD" "$SCRIPT_RUBY"'
  avs = logical.select { |_, t| t =~ /\bav inject\b/ }
  abort "av inject runs #{avs.size} times, expected once" unless avs.size == 1
  i, t = avs[0]
  vault = body.call("upload_with_vault")
  abort "av inject runs outside upload_with_vault()" unless vault.cover?(i)
  want = "av inject --mode=fd +APP_STORE_CONNECT_KEY_ID:3 +APP_STORE_CONNECT_ISSUER_ID:4 +APP_STORE_CONNECT_API_KEY_P8:5 -- \"$SELF\" --inside-vault "
  abort "av inject is not: #{want}..." unless t.include?(want)
  [3, 4, 5].each do |fd|
    closed = line_in.call(vault, "exec #{fd}<&-") or abort "upload_with_vault() does not close inherited fd #{fd}"
    abort "upload_with_vault() closes fd #{fd} after av inject" unless closed < i
  end
  selfs = logical.select { |_, l| l.include?(%q{"$SELF" --inside-vault}) }
  abort "the script runs its --inside-vault step outside av inject" unless selfs.size == 1
  dispatch = logical.index { |_, l| l == %q{if [ "${1:-}" = "--inside-vault" ]; then} } or abort "no --inside-vault dispatch"
  calls = logical.each_index.select { |k| logical[k][1] =~ /^upload_inside_vault\b/ && logical[k][1] !~ /\(\) \{$/ }
  abort "upload_inside_vault() runs other than from the --inside-vault dispatch" unless calls == [dispatch + 2]
'
ruby_check "$UPLOAD checks the export, then stops for --no-upload, before the vault step" "$UPLOAD" "$SCRIPT_RUBY"'
  main = body.call("main")
  gate = line_in.call(main, %q{if [ "$upload" = no ]; then}) or abort "main() has no --no-upload gate"
  gate_end = (gate + 1...main.end).find { |i| lines[i].strip == "fi" }
  abort "the --no-upload gate does not exit 0" unless (gate + 1...gate_end).any? { |i| lines[i].strip == "exit 0" }
  check = main.find { |i| lines[i] =~ /^\s*check_export "/ } or abort "main() never runs check_export"
  abort "check_export runs after the --no-upload gate" unless check < gate
  uploads = logical.select { |_, t| t =~ /^upload_with_vault "/ }
  abort "upload_with_vault runs #{uploads.size} times, expected once" unless uploads.size == 1
  abort "upload_with_vault runs before the --no-upload gate" unless uploads[0][0] > gate_end && main.cover?(uploads[0][0])
'
ruby_check "$UPLOAD removes its temporary directory and the key on every exit path" "$UPLOAD" "$SCRIPT_RUBY"'
  traps = ["trap '"'"'exit 130'"'"' INT", "trap '"'"'exit 143'"'"' TERM", "trap '"'"'exit 129'"'"' HUP"]
  main = body.call("main")
  made = main.find { |i| lines[i].include?(%q{work="$(mktemp -d }) } or abort "main() makes no temporary directory"
  (["trap cleanup EXIT"] + traps).each do |t|
    i = line_in.call(main, t) or abort "main() does not set #{t}"
    abort "main() sets #{t} after making the temporary directory" unless i < made
  end
  cleanup = body.call("cleanup")
  [%q{rm -rf "$work/asc-key"}, %q{rm -rf "$work"}].each do |rm|
    abort "cleanup() does not run #{rm}" unless cleanup.any? { |i| lines[i].include?(rm) }
  end
  inside = body.call("upload_inside_vault")
  key_dir = inside.find { |i| lines[i].include?(%q{mkdir -m 700 "$2"}) } or abort "upload_inside_vault() makes no mode-700 key directory"
  (["trap remove_key EXIT"] + traps).each do |t|
    i = line_in.call(inside, t) or abort "upload_inside_vault() does not set #{t}"
    abort "upload_inside_vault() sets #{t} after making the key directory" unless i < key_dir
  end
  abort "remove_key() does not remove the key directory" unless body.call("remove_key").any? { |i| lines[i].include?(%q{rm -rf "$key_dir"}) }
  [%q{key_file="$key_dir/AuthKey_$key_id.p8"}, %q{(umask 077 && printf '"'"'%s\n'"'"' "$p8" >"$key_file")}, %q{chmod 600 "$key_file"}].each do |l|
    abort "upload_inside_vault() does not have: #{l}" unless line_in.call(inside, l)
  end
'
ruby_check "$UPLOAD never prints a vault value" "$UPLOAD" "$SCRIPT_RUBY"'
  secret = /\$\{?(p8|key_id|issuer_id)\b/
  key_write = %q{(umask 077 && printf '"'"'%s\n'"'"' "$p8" >"$key_file")}
  logical.each do |i, t|
    next if t == key_write
    t.scan(/(?:^|[;&|(]\s*|\s)(?:echo|printf|log|die)\s(.*)$/) do |(rest)|
      abort "line #{i + 1} may print a vault value: #{t}" if rest =~ secret
    end
  end
'
forbid_grep '(^|[;&|[:space:]])set[[:space:]]+-[[:alnum:]]*x|xtrace' "$UPLOAD" "$UPLOAD never turns on xtrace"
require_grep 'CODE_SIGN_STYLE=Automatic' "$UPLOAD" "$UPLOAD archives with automatic signing"
require_grep '-allowProvisioningUpdates' "$UPLOAD" "$UPLOAD lets the Xcode account provision the archive"
require_grep '^ASSOCIATED_DOMAIN="webcredentials:qbank\.dimitrygallego\.com"$' "$UPLOAD" "$UPLOAD checks the IPA is signed for Password AutoFill"
forbid_grep '-authenticationKey(Path|ID|IssuerID)' "$UPLOAD" "$UPLOAD signs through the Xcode account, never an API key"
require_grep 'DEVELOPMENT_TEAM="\$team_id"' "$UPLOAD" "$UPLOAD takes the team id from --team-id or APPLE_TEAM_ID"
require_grep 'die "no Apple team ID' "$UPLOAD" "$UPLOAD fails when the team id is missing"
require_grep '^  out="\$repo_root/build/testflight/\$build_number"$' "$UPLOAD" "$UPLOAD logs to build/testflight/"
require_grep '^build/$' .gitignore "build/ is ignored, so upload logs stay out of Git"

ruby_check "$EXPORT_OPTIONS exports for App Store Connect with automatic signing and no team id" "$EXPORT_OPTIONS" '
  plist = File.read(ARGV[0])
  {
    "method" => "<string>app-store-connect</string>",
    "destination" => "<string>export</string>",
    "signingStyle" => "<string>automatic</string>",
    "manageAppVersionAndBuildNumber" => "<false/>",
  }.each do |key, value|
    abort "#{key} is not #{value}" unless plist =~ /<key>#{key}<\/key>\s*#{Regexp.escape(value)}/
  end
  abort "teamID is committed; the script adds it to a temporary copy" if plist.include?("<key>teamID</key>")
'

# --- No key material or team id in Git -------------------------------------------

ruby_check "no private key is committed" "$UPLOAD" '
  files = `git ls-files -z`.split("\0")
  abort "git ls-files failed" unless $?.success?
  files.each do |path|
    next unless File.file?(path)
    text = File.binread(path)
    next if text.include?("\0")
    if text =~ /-----BEGIN [A-Z ]*PRIVATE KEY-----\r?\n[A-Za-z0-9+\/=]{16,}/
      abort "#{path} holds a PEM private key"
    end
  end
'
team_ids="$(git grep -nE '(DEVELOPMENT_TEAM|APPLE_TEAM_ID|teamID)[[:space:]]*[=:][[:space:]]*"?[A-Z0-9]{10}([^A-Za-z0-9_]|$)' || true)"
if [ -n "$team_ids" ]; then
  fail "no Apple team id is committed: $team_ids"
else
  pass "no Apple team id is committed"
fi

# --- Debug-only launch seam -----------------------------------------------------

SEAM=QBank/DebugLaunchScenario.swift
if [ -f "$SEAM" ] && [ "$(head -n 1 "$SEAM")" = "#if DEBUG" ] && [ "$(tail -n 1 "$SEAM")" = "#endif" ]; then
  pass "the launch seam is wrapped in #if DEBUG"
else
  fail "the launch seam is wrapped in #if DEBUG ($SEAM must start with #if DEBUG and end with #endif)"
fi

# --- Frontend only ----------------------------------------------------------------

require_grep 'Keep this repository frontend-only: do not add backend source, migrations, credentials, deployment assets, or infrastructure configuration here\.' AGENTS.md "AGENTS.md carries the frontend-only rule"

forbidden_files="$(git ls-files | grep -iE '(^|/)(migrations?|deploy|infra|terraform)/|(^|/)(Dockerfile|docker-compose[^/]*|Caddyfile)$|\.(sql|tf|tfvars|p8|p12|pem|key|cer|mobileprovision)$|(^|/)\.env($|\.)' || true)"
if [ -n "$forbidden_files" ]; then
  fail "no backend, deployment, infrastructure, or credential files are tracked: $forbidden_files"
else
  pass "no backend, deployment, infrastructure, or credential files are tracked"
fi

# --- Words the app shows --------------------------------------------------------

# Her own AI agent is "agent" or "your agent" in the app, never a product's name.
named="$(git grep -il --untracked 'firstmate' -- QBank Packages || true)"
if [ -n "$named" ]; then
  fail "the app and its packages say agent, never Firstmate: $named"
else
  pass "the app and its packages say agent, never Firstmate"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed." >&2
  exit 1
fi
echo "All checks passed."
