#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders docs/privacy-policy.md as site/privacy/index.html, so the public page
# and the policy file cannot drift. test/release-checks.sh runs this with
# --check and fails when the committed page differs from what the policy says.
#
#   scripts/render-privacy-page.rb          write site/privacy/index.html
#   scripts/render-privacy-page.rb --check  exit 1 if that file is out of date
#
# The policy uses a small Markdown subset: "##" and "###" headings, "-" bullets,
# paragraphs, **bold**, and plain URLs and email addresses. The renderer refuses
# anything else instead of guessing.

require "cgi"

ROOT = File.expand_path("..", __dir__)
SOURCE = File.join(ROOT, "docs", "privacy-policy.md")
TARGET = File.join(ROOT, "site", "privacy", "index.html")

def inline(text)
  CGI.escapeHTML(text)
     .gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
     .gsub(%r{(https://[^\s<)]+[^\s<).,;])}, '<a href="\1">\1</a>')
     .gsub(/\b([\w.+-]+@[\w-]+\.[\w.]+[\w])/, '<a href="mailto:\1">\1</a>')
end

def render_body(markdown)
  lines = markdown.lines.map(&:chomp)
  start = lines.index { |line| line.start_with?("## ") } or abort "#{SOURCE} has no ## section"
  html = []
  list = false
  lines[start..].each_with_index do |line, offset|
    if line.start_with?("- ")
      html << "<ul>" unless list
      list = true
      html << "<li>#{inline(line[2..])}</li>"
      next
    end
    (html << "</ul>"; list = false) if list
    case line
    when "" then next
    when /\A### (.+)/ then html << "<h3>#{inline(Regexp.last_match(1))}</h3>"
    when /\A## (.+)/ then html << "<h2>#{inline(Regexp.last_match(1))}</h2>"
    when /\A[#>|`\d]/, /\A\s/, /\[[^\]]*\]\(/
      abort "#{SOURCE}:#{start + offset + 1}: Markdown this renderer does not handle: #{line[0, 60]}"
    else html << "<p>#{inline(line)}</p>"
    end
  end
  html << "</ul>" if list
  html.join("\n")
end

def page(body)
  <<~HTML
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>QBank privacy policy</title>
    <meta name="description" content="What the QBank app and its server keep, why, and how to delete your data.">
    <link rel="stylesheet" href="../style.css">
    </head>
    <body>
    <header>
    <a class="brand" href="../">QBank</a>
    <nav aria-label="Pages"><ul>
    <li><a href="../privacy/" aria-current="page">Privacy</a></li>
    <li><a href="../support/">Support</a></li>
    <li><a href="../format/">Question file format</a></li>
    </ul></nav>
    </header>
    <main>
    <h1>QBank privacy policy</h1>
    #{body}
    </main>
    <footer>
    <p>Questions: <a href="mailto:dimitrygallego@gmail.com">dimitrygallego@gmail.com</a></p>
    </footer>
    </body>
    </html>
  HTML
end

output = page(render_body(File.read(SOURCE)))
if ARGV == ["--check"]
  if File.exist?(TARGET) && File.read(TARGET) == output
    exit 0
  end
  warn "site/privacy/index.html is out of date; run scripts/render-privacy-page.rb"
  exit 1
elsif ARGV.empty?
  File.write(TARGET, output)
else
  abort "usage: scripts/render-privacy-page.rb [--check]"
end
