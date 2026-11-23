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
# anything else instead of guessing. Above the first section, only the "Status:"
# and "Last reviewed against the code:" lines are published; links to other
# docs in them point at those docs on GitHub.

require "cgi"

ROOT = File.expand_path("..", __dir__)
SOURCE = File.join(ROOT, "docs", "privacy-policy.md")
TARGET = File.join(ROOT, "site", "privacy", "index.html")
DOCS_URL = "https://github.com/D-e-e-g/qbank/blob/main/docs/"

def refuse(number, line)
  abort "#{SOURCE}:#{number}: Markdown this renderer does not handle: #{line[0, 60]}"
end

def inline(text, number)
  refuse(number, text) if text.match?(/`|\[[^\]]*\]\(/)
  CGI.escapeHTML(text)
     .gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
     .gsub(%r{(https://[^\s<)]+[^\s<).,;])}, '<a href="\1">\1</a>')
     .gsub(/\b([\w.+-]+@[\w-]+\.[\w.]+[\w])/, '<a href="mailto:\1">\1</a>')
end

def preamble_line(lines, start, label)
  index = lines[0...start].index { |line| line.start_with?("#{label}: ") } or abort "#{SOURCE} has no \"#{label}:\" line before its first section"
  lines[index][(label.length + 2)..].split(/(\[[^\]]+\]\([\w-]+\.md\))/).map do |piece|
    if (link = piece.match(/\A\[([^\]]+)\]\(([\w-]+\.md)\)\z/))
      %(<a href="#{DOCS_URL}#{link[2]}">#{CGI.escapeHTML(link[1])}</a>)
    else
      inline(piece, index + 1)
    end
  end.join
end

def render_body(markdown)
  lines = markdown.lines.map(&:chomp)
  start = lines.index { |line| line.start_with?("## ") } or abort "#{SOURCE} has no ## section"
  html = [
    %(<p class="note"><strong>Status:</strong> #{preamble_line(lines, start, "Status")}</p>),
    %(<p><strong>Last updated</strong> (last reviewed against the code): #{preamble_line(lines, start, "Last reviewed against the code")}</p>)
  ]
  list = false
  lines[start..].each_with_index do |line, offset|
    number = start + offset + 1
    if line.start_with?("- ")
      html << "<ul>" unless list
      list = true
      html << "<li>#{inline(line[2..], number)}</li>"
      next
    end
    (html << "</ul>"; list = false) if list
    case line
    when "" then next
    when /\A### (.+)/ then html << "<h3>#{inline(Regexp.last_match(1), number)}</h3>"
    when /\A## (.+)/ then html << "<h2>#{inline(Regexp.last_match(1), number)}</h2>"
    when /\A[#>|\d]/, /\A\s/ then refuse(number, line)
    else html << "<p>#{inline(line, number)}</p>"
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
