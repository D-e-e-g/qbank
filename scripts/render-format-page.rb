#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders site/format/index.html from the question file format the QBank API
# publishes: the Markdown under "x-question-format" in the pinned contract,
# which the server generates from the table its import check reads. The page
# holds no rule of its own. Run this after re-pinning the contract and commit the
# page with it; test/site-checks.sh runs it with --check and fails when the
# committed page differs from the contract. The Pages workflow only uploads the
# committed site/.
#
#   scripts/render-format-page.rb          write site/format/index.html
#   scripts/render-format-page.rb --check  exit 1 if that file is out of date
#
# The generated Markdown uses a small subset: "#", "##" and "###" headings, "-"
# bullets, tables, paragraphs, `code`, and a comment on a line of its own. The
# renderer refuses anything else instead of guessing.

require "json"
require_relative "site_page"

SOURCE = "Packages/QBankKit/Tests/QBankKitTests/Fixtures/openapi.json"
SCRIPT = "scripts/render-format-page.rb"
LEDE = "QBank imports a set of questions from one JSON file. You can write the file by hand or ask an AI chat to write it."

def refuse(number, line)
  abort "#{SOURCE}: x-question-format.markdown line #{number}: Markdown this renderer does not handle: #{line[0, 60]}"
end

def inline(text, number)
  pieces = text.split("`", -1)
  refuse(number, text) if pieces.length.even?
  pieces.each_with_index.map do |piece, index|
    next "<code>#{CGI.escapeHTML(piece)}</code>" if index.odd?

    refuse(number, text) if piece.match?(/\*\*|__|\]\(|\\|https?:/)
    CGI.escapeHTML(piece)
  end.join
end

def kind(line)
  case line
  when "" then :blank
  when /\A<!--.*-->\z/ then :comment
  when /\A\#{1,3} \S/ then :heading
  when /\A- \S/ then :bullet
  when /\A\|.*\|\z/ then :row
  when /\A(?:\s|[#>|<*+]|-{3}|```|\d+[.)] )/ then :unknown
  else :text
  end
end

def table(lines)
  number = lines.first.last
  rows = lines.map { |line, _| line[1...-1].split("|", -1).map(&:strip) }
  width = rows.first.length
  ruled = rows.length > 2 && rows[1].all? { |cell| cell.match?(/\A-{3,}\z/) }
  refuse(number, lines.first.first) unless ruled && rows.all? { |row| row.length == width }
  row = lambda do |cells, tag, at|
    html = cells.map { |cell| inline(cell, at) }
    # A long name in the first column may break after an underscore.
    html[0] = html[0].gsub("_", "_<wbr>")
    "<tr>#{html.map { |cell| "<#{tag}>#{cell}</#{tag}>" }.join}</tr>"
  end
  [
    %(<div class="table-wrap">),
    "<table>",
    "<thead>#{row.call(rows.first, "th", number)}</thead>",
    "<tbody>",
    *rows.drop(2).each_with_index.map { |cells, offset| row.call(cells, "td", number + offset + 2) },
    "</tbody>",
    "</table>",
    "</div>"
  ]
end

def render(markdown)
  numbered = markdown.lines.map(&:chomp).each_with_index.map { |line, index| [line, index + 1] }
  blocks = numbered.chunk_while { |(a, _), (b, _)| kind(a) == kind(b) && %i[bullet row text].include?(kind(a)) }
  html = blocks.flat_map do |lines|
    line, number = lines.first
    case kind(line)
    when :blank, :comment then []
    when :heading
      marks, text = line.split(" ", 2)
      heading = "<h#{marks.length}>#{inline(text, number)}</h#{marks.length}>"
      marks.length == 1 ? [heading, %(<p class="lede">#{LEDE}</p>)] : [heading]
    when :bullet then ["<ul>", *lines.map { |item, at| "<li>#{inline(item[2..-1], at)}</li>" }, "</ul>"]
    when :row then table(lines)
    when :text then ["<p>#{lines.map { |text, at| inline(text, at) }.join(" ")}</p>"]
    else refuse(number, line)
    end
  end
  titles = html.grep(/\A<h1>/)
  abort "#{SOURCE}: x-question-format.markdown needs exactly one # title, first" unless titles.length == 1 && html.first == titles.first

  html.join("\n")
end

contract = JSON.parse(File.read(File.join(SitePage::ROOT, SOURCE), encoding: "UTF-8"))
markdown = contract.dig("x-question-format", "markdown") or abort "#{SOURCE} has no x-question-format.markdown"
output = SitePage.html(
  slug: "format",
  title: "QBank question file format",
  description: "The JSON file format QBank imports, with the rules a file must meet.",
  main: render(markdown)
)
SitePage.publish("format", output, script: SCRIPT, arguments: ARGV)
