#!/usr/bin/env bash
# Checks for site/ (the public privacy, support, and question-file-format pages)
# and the workflow that publishes it.
#
# Run by test/release-checks.sh. Credential-free and network-free: it reads
# tracked files and renders the privacy page from the policy.
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

for page in "$SITE/privacy/index.html" "$SITE/support/index.html"; do
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

# --- The format page describes the API's import check -----------------------------

FORMAT="$SITE/format/index.html"
OPENAPI=Packages/QBankKit/Tests/QBankKitTests/Fixtures/openapi.json

# The oracle for the types is the server's published API (the pinned OpenAPI
# fixture): the type enum of DraftQuestion, a question as the importer stores it.
# The oracle for the limits is the server's import check
# (packages/questions/src/media.ts in the private server repository): at most 4
# images per question, each at most 300 KB after decoding.
format_check="$(ruby -rjson -rcgi -e '
  html, api = File.read(ARGV[0]), JSON.parse(File.read(ARGV[1]))
  types = api.dig("components", "schemas", "DraftQuestion", "properties", "type", "enum") or abort "#{ARGV[1]}: no DraftQuestion type enum"
  section = lambda do |title|
    html[%r{<h2>#{Regexp.escape(title)}</h2>(.*?)(?=<h2>|</main>)}m, 1] or abort "no #{title.inspect} section"
  end
  rows = section.("The nine question formats").scan(%r{<tr><td><code>([^<]+)</code></td>}).flatten
  abort "the format table lists #{rows.inspect}, the API #{types.inspect}" unless rows.sort == types.sort && rows.uniq == rows
  type_row = section.("Every question")[%r{<tr><td><code>type</code></td><td>(.*?)</td></tr>}m, 1] or abort "no type row under Every question"
  listed = type_row.scan(%r{<code>([^<]+)</code>}).flatten
  abort "the type row lists #{listed.inspect}, the API #{types.inspect}" unless listed.sort == types.sort && listed.uniq == listed
  media = CGI.unescapeHTML(section.("Tables and pictures").gsub(/<[^>]+>/, ""))
  count = media[/images is a list of at most (\d+) pictures per question/, 1]
  abort "the picture count limit is #{count.inspect}, the importer 4" unless count == "4"
  size = media[/An image may be at most (\d+) KB after decoding/, 1]
  abort "the image size limit is #{size.inspect} KB, the importer 300" unless size == "300"
' "$FORMAT" "$OPENAPI" 2>&1)"
# shellcheck disable=SC2181 # the program's output is the failure message
if [ $? -eq 0 ]; then
  pass "the format page lists the API's nine types and the importer's image limits"
else
  fail "the format page lists the API's nine types and the importer's image limits: $format_check"
fi

ruby_example="$(ruby -rjson -rcgi -e '
  html = File.read(ARGV[0])
  block = html[%r{<pre><code>(.*?)</code></pre>}m, 1] or abort "no example"
  data = JSON.parse(CGI.unescapeHTML(block))
  abort "no questions" unless data["questions"].is_a?(Array) && !data["questions"].empty?
  data["questions"].each { |q| abort "#{q["id"]}: no ask" unless q["ask"].is_a?(String) && !q["ask"].strip.empty? }
' "$FORMAT" 2>&1)"
# shellcheck disable=SC2181 # the program's output is the failure message
if [ $? -eq 0 ]; then
  pass "the format page's example is JSON whose questions each have an ask"
else
  fail "the format page's example is JSON whose questions each have an ask: $ruby_example"
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
    jobs = wf["jobs"] || {}
    abort "no jobs" if jobs.empty?
    jobs.each do |name, job|
      abort "job #{name} must run on a hosted Linux machine (got #{job["runs-on"].inspect})" unless job["runs-on"].to_s.start_with?("ubuntu-")
      abort "job #{name} sets its own permissions" if job.key?("permissions")
    end
    steps = jobs.values.flat_map { |job| job["steps"] || [] }
    upload = steps.find { |step| step["uses"].to_s.start_with?("actions/upload-pages-artifact@") }
    abort "no step uploads site/" unless upload && upload.dig("with", "path") == "site"
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
    pass "$PAGES publishes site/ from main with pages: write and id-token: write on Linux, using no secrets"
  else
    fail "$PAGES publishes site/ from main with pages: write and id-token: write on Linux, using no secrets"
  fi
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES site check(s) failed." >&2
  exit 1
fi
