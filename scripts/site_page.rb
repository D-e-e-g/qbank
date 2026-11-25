# frozen_string_literal: true

# What the scripts that render a page of site/ share: the frame around the page,
# and writing the page or checking the committed one against it.

require "cgi"

module SitePage
  ROOT = File.expand_path("..", __dir__)
  PAGES = { "privacy" => "Privacy", "support" => "Support", "format" => "Question file format" }.freeze
  CONTACT = "dimitrygallego@gmail.com"

  # The whole of site/<slug>/index.html around `main`, the page's own HTML.
  def self.html(slug:, title:, description:, main:)
    links = PAGES.map do |page, name|
      current = page == slug ? ' aria-current="page"' : ""
      %(<li><a href="../#{page}/"#{current}>#{name}</a></li>)
    end
    <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{CGI.escapeHTML(title)}</title>
      <meta name="description" content="#{CGI.escapeHTML(description)}">
      <link rel="stylesheet" href="../style.css">
      </head>
      <body>
      <header>
      <a class="brand" href="../">QBank</a>
      <nav aria-label="Pages"><ul>
      #{links.join("\n")}
      </ul></nav>
      </header>
      <main>
      #{main}
      </main>
      <footer>
      <p>Questions: <a href="mailto:#{CONTACT}">#{CONTACT}</a></p>
      </footer>
      </body>
      </html>
    HTML
  end

  # With no argument writes site/<slug>/index.html. With --check, exits 1 when the
  # committed file differs from `output`.
  def self.publish(slug, output, script:, arguments:)
    relative = "site/#{slug}/index.html"
    target = File.join(ROOT, relative)
    case arguments
    when []
      File.write(target, output)
    when ["--check"]
      return if File.exist?(target) && File.read(target, encoding: "UTF-8") == output

      warn "#{relative} is out of date; run #{script}"
      exit 1
    else
      abort "usage: #{script} [--check]"
    end
  end
end
