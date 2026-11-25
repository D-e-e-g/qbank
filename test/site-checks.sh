#!/usr/bin/env bash
# Checks for site/ (the public privacy, support, and question-file-format pages)
# and the workflow that publishes it.
#
# Run by test/release-checks.sh. Credential-free and network-free: it reads
# tracked files, and renders the privacy page from the policy and the format page
# from the pinned contract.
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

SITE=site
CONTACT=dimitrygallego@gmail.com
PAGES=.github/workflows/pages.yml

# --- The pages and the custom domain -------------------------------------------

for page in "$SITE/index.html" "$SITE/privacy/index.html" "$SITE/support/index.html" "$SITE/format/index.html" "$SITE/404.html" "$SITE/style.css"; do
  if [ -f "$page" ]; then
    pass "$page exists"
  else
    fail "$page exists"
  fi
done

if [ -f "$SITE/CNAME" ] && [ "$(cat "$SITE/CNAME")" = "qbank-app.dimitrygallego.com" ]; then
  pass "$SITE/CNAME is qbank-app.dimitrygallego.com"
else
  fail "$SITE/CNAME is qbank-app.dimitrygallego.com on one line"
fi

for page in "$SITE/privacy/index.html" "$SITE/support/index.html" "$SITE/format/index.html"; do
  if grep -qF "mailto:$CONTACT" "$page" 2>/dev/null && grep -qF ">$CONTACT<" "$page"; then
    pass "$page shows the contact address $CONTACT"
  else
    fail "$page shows the contact address $CONTACT as text and as a mailto link"
  fi
done

if grep -rqF 'PRIVACY_CONTACT_EMAIL' "$SITE" docs/privacy-policy.md; then
  fail "no contact placeholder is left in the privacy policy or the site"
else
  pass "no contact placeholder is left in the privacy policy or the site"
fi

# --- Nothing from other hosts, no secrets ---------------------------------------

# A page may link to other sites with <a href>, but it loads nothing from them:
# no script at all, no frame, and no stylesheet, image, font, or media from
# another host (a src or a href on a non-anchor tag, or a CSS url or @import).
site_files="$(git ls-files "$SITE"; git ls-files --others --exclude-standard "$SITE")"
loaders="$(ruby -e '
  $stdin.each_line do |line|
    path = line.chomp
    next unless File.file?(path) && path =~ /\.(html|css)\z/
    text = File.read(path)
    text.scan(/<script\b|<iframe\b|<object\b|<embed\b/i) { puts "#{path}: loads a #{$&.delete("<")}" }
    text.scan(/<(?!a\b)[a-z0-9]+\b[^>]*\b(?:src|href|srcset|poster|data)\s*=\s*["\x27]?\s*(?:https?:)?\/\/[^\s"\x27>]*/i) { puts "#{path}: #{$&[0, 90]}" }
    text.scan(/@import\b|url\(\s*["\x27]?\s*(?:https?:)?\/\//i) { puts "#{path}: CSS loads from another host" }
  end
' <<<"$site_files")"
if [ -n "$loaders" ]; then
  fail "the site loads no script and nothing from another host: $loaders"
else
  pass "the site loads no script and nothing from another host"
fi

# Gitleaks is the real secret check (test/leak-check.sh). These patterns keep
# the commonest key shapes out of the site even where gitleaks is not run.
secrets="$(printf '%s\n' "$site_files" | xargs grep -nEi -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{20,}|\bAKIA[0-9A-Z]{16}\b|\bsk-[A-Za-z0-9]{20,}|(api[_-]?key|secret|token|password)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9+/_-]{16,}' || true)"
if [ -n "$secrets" ]; then
  fail "the site holds no secret: $secrets"
else
  pass "the site holds no secret"
fi

# --- The privacy page is the policy ---------------------------------------------

if ruby scripts/render-privacy-page.rb --check; then
  pass "site/privacy/index.html is docs/privacy-policy.md rendered"
else
  fail "site/privacy/index.html is docs/privacy-policy.md rendered (run scripts/render-privacy-page.rb)"
fi

# --- The format page is the contract's description -------------------------------

if ruby scripts/render-format-page.rb --check; then
  pass "site/format/index.html is the pinned contract's question file format rendered"
else
  fail "site/format/index.html is the pinned contract's question file format rendered (run scripts/render-format-page.rb)"
fi

# --- The Pages workflow ---------------------------------------------------------

if [ ! -f "$PAGES" ]; then
  fail "$PAGES exists"
else
  pass "$PAGES exists"
  if ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    on = wf[true] || wf["on"]
    abort "permissions must be exactly pages: write and id-token: write (got #{wf["permissions"].inspect})" unless wf["permissions"] == { "pages" => "write", "id-token" => "write" }
    abort "triggers must be push and workflow_dispatch (got #{on.keys.inspect})" unless on.keys.map(&:to_s).sort == %w[push workflow_dispatch]
    abort "push must be branches: [main] (got #{on["push"].inspect})" unless on["push"]["branches"] == ["main"]
    renderer = "scripts/render-format-page.rb"
    inputs = ["site/**", renderer, "scripts/site_page.rb", "Packages/QBankKit/Tests/QBankKitTests/Fixtures/openapi.json"]
    missed = inputs - Array(on["push"]["paths"])
    abort "a push that changes #{missed.inspect} must publish" unless missed.empty?
    jobs = wf["jobs"] || {}
    abort "no jobs" if jobs.empty?
    jobs.each do |name, job|
      abort "job #{name} must run on a hosted Linux machine (got #{job["runs-on"].inspect})" unless job["runs-on"].to_s.start_with?("ubuntu-")
      abort "job #{name} sets its own permissions" if job.key?("permissions")
    end
    steps = jobs.values.flat_map { |job| job["steps"] || [] }
    upload = steps.find { |step| step["uses"].to_s.start_with?("actions/upload-pages-artifact@") }
    abort "no step uploads site/" unless upload && upload.dig("with", "path") == "site"
    render = steps.index { |step| step["run"].to_s.strip == "ruby #{renderer}" }
    abort "no step runs ruby #{renderer} before site/ is uploaded" unless render && render < steps.index(upload)
    abort "no step deploys with actions/deploy-pages" unless steps.any? { |step| step["uses"].to_s.start_with?("actions/deploy-pages@") }
    strings = lambda do |node|
      case node
      when Hash then node.flat_map { |key, value| strings.(key) + strings.(value) }
      when Array then node.flat_map { |value| strings.(value) }
      when String then [node]
      else []
      end
    end
    used = strings.(wf).grep(/\$\{\{[^}]*\bsecrets\b/)
    abort "the workflow uses secrets: #{used.inspect}" unless used.empty?
  ' "$PAGES" 2>&1; then
    pass "$PAGES renders the format page and publishes site/ from main with pages: write and id-token: write on Linux, using no secrets"
  else
    fail "$PAGES renders the format page and publishes site/ from main with pages: write and id-token: write on Linux, using no secrets"
  fi
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES site check(s) failed." >&2
  exit 1
fi
