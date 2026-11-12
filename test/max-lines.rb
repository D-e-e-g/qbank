#!/usr/bin/env ruby
# frozen_string_literal: true

# Fails when a hand-written source file goes over the code-line limit.
#
# A code line is a line that is not blank and not only a comment. Blank lines
# and comment-only lines are skipped the same way in every QBank repository.
# test/max-lines.conf names what this repository counts, what it leaves out
# (each exclusion has a reason), and every file already over the limit with
# its code-line count for reference. A listed file is exempt until it is
# split: growing, or a stale entry, prints a warning and does not fail.
# docs/ci.md says how to update it.
#
# Usage, from the repository root:
#   ruby test/max-lines.rb
#   ruby test/max-lines.rb --dump
#   ruby test/max-lines.rb --self-test

module MaxLines
  ROOT = File.expand_path("..", __dir__)
  CONFIG = File.join(ROOT, "test/max-lines.conf")
  METACHAR = " \t|&;()<>`"

  SwiftCode = Struct.new(:interp)
  SwiftString = Struct.new(:hashes, :quotes)
  Block = Struct.new(:depth)
  ShellCode = Struct.new(:closer, :paren, :word)
  Single = Struct.new(:unused)
  Double = Struct.new(:unused)
  Ansi = Struct.new(:unused)
  Arithmetic = Struct.new(:depth)
  Heredoc = Struct.new(:delim, :quoted, :strip)
  Config = Struct.new(:limit, :includes, :excludes, :allows)

  module_function

  def code_lines(text, language)
    flags(text, language).count(:code)
  end

  def flags(text, language)
    text = text.b.force_encoding(Encoding::UTF_8)
    text = text.scrub unless text.valid_encoding?
    case language
    when :swift then swift_flags(text)
    when :shell then shell_flags(text)
    else raise "unknown language #{language}"
    end
  end

  def language_for(path)
    case File.extname(path)
    when ".swift" then :swift
    when ".sh" then :shell
    end
  end

  # --- Shared line walk ------------------------------------------------------

  def scan_lines(text)
    flags = []
    index = 0
    line = fresh_line
    length = text.length
    while index < length
      if text[index] == "\r"
        index += 1
        next
      end
      if text[index] == "\n"
        flags << classify(line)
        on_newline
        line = fresh_line
        index += 1
        next
      end
      nxt = yield(line, index)
      raise "scanner did not advance at #{index}" unless nxt > index
      line[:start] = false
      index = nxt
    end
    flags << classify(line) if !text.empty? && !text.end_with?("\n")
    flags
  end

  def fresh_line
    { code: false, marked: false, start: true }
  end

  def classify(line)
    return :code if line[:code]
    return :comment if line[:marked]
    :blank
  end

  def blank_char?(char)
    char == " " || char == "\t" || char == "\f" || char == "\v"
  end

  def on_newline
    case @mode
    when :swift
      pop_single_line_strings!
    when :shell
      top = @stack.last
      if top.is_a?(ShellCode)
        # A newline ends a word, so a "#" on the next line can start a comment.
        # A trailing unquoted backslash joins the lines and the word continues.
        top.word = false unless @join_word
        @join_word = false
        @stack << @pending.shift unless @pending.empty?
      end
    end
  end

  # --- Swift -----------------------------------------------------------------

  def swift_flags(text)
    @mode = :swift
    @stack = [SwiftCode.new(nil)]
    @pending = nil
    flags = scan_lines(text) { |line, index| swift_step(text, index, line) }
    @stack = nil
    @mode = nil
    flags
  end

  def swift_step(text, index, line)
    char = text[index]
    top = @stack.last
    if top.is_a?(Block)
      line[:marked] = true unless blank_char?(char)
      if text[index, 2] == "/*"
        top.depth += 1
        return index + 2
      end
      if text[index, 2] == "*/"
        top.depth -= 1
        @stack.pop if top.depth.zero?
        return index + 2
      end
      return index + 1
    end
    if top.is_a?(SwiftString)
      if text[index, top.hashes + 2] == "\\" + ("#" * top.hashes) + "("
        line[:code] = true
        @stack.push(SwiftCode.new(1))
        return index + top.hashes + 2
      end
      if string_ends_at?(text, index, top)
        line[:code] = true
        @stack.pop
        return index + top.quotes + top.hashes
      end
      line[:code] = true unless blank_char?(char)
      return index + 1
    end
    return index + 1 if blank_char?(char)
    if text[index, 2] == "//"
      line[:marked] = true
      index += 1 while index < text.length && text[index] != "\n"
      return index
    end
    if text[index, 2] == "/*"
      line[:marked] = true
      @stack.push(Block.new(1))
      return index + 2
    end
    opened = opening_string(text, index)
    if opened
      line[:code] = true
      @stack.push(SwiftString.new(opened[0], opened[1]))
      return index + opened[2]
    end
    if top.interp && char == ")"
      line[:code] = true
      if top.interp == 1
        @stack.pop
      else
        top.interp -= 1
      end
      return index + 1
    end
    if top.interp && char == "("
      line[:code] = true
      top.interp += 1
      return index + 1
    end
    line[:code] = true
    index + 1
  end

  def opening_string(text, index)
    hashes = 0
    hashes += 1 while text[index + hashes] == "#"
    return nil unless text[index + hashes] == '"'
    quotes = text[index + hashes, 3] == '"""' ? 3 : 1
    [hashes, quotes, hashes + quotes]
  end

  def string_ends_at?(text, index, string)
    delim = ('"' * string.quotes) + ("#" * string.hashes)
    text[index, delim.length] == delim && !delimiter_escaped?(text, index, string.hashes)
  end

  def delimiter_escaped?(text, index, hashes)
    intro = "\\" + ("#" * hashes)
    count = 0
    pos = index
    while pos >= intro.length && text[pos - intro.length, intro.length] == intro
      count += 1
      pos -= intro.length
    end
    count.odd?
  end

  # A single-line string cannot cross a newline. Drop it, and anything opened
  # inside it, so the next line is not swallowed. Multiline strings stay open.
  def pop_single_line_strings!
    index = @stack.rindex { |frame| frame.is_a?(SwiftString) && frame.quotes == 1 }
    @stack.slice!(index..) if index
  end

  # --- Shell -----------------------------------------------------------------

  def shell_flags(text)
    @mode = :shell
    @stack = [ShellCode.new(nil, 0, false)]
    @pending = []
    @join_word = false
    flags = scan_lines(text) { |line, index| shell_step(text, index, line) }
    @stack = nil
    @pending = nil
    @mode = nil
    flags
  end

  def shell_step(text, index, line)
    if line[:start] && @stack.last.is_a?(Heredoc) && heredoc_boundary(text, index, line)
      return text.index("\n", index) || text.length
    end
    top = @stack.last
    return heredoc_step(text, index, line) if top.is_a?(Heredoc)
    return quoted_step(text, index, line) if top.is_a?(Single) || top.is_a?(Double) || top.is_a?(Ansi)
    return arithmetic_step(text, index, line) if top.is_a?(Arithmetic)
    shell_code_step(text, index, line)
  end

  def heredoc_boundary(text, index, line)
    heredoc = @stack.last
    finish = text.index("\n", index) || text.length
    raw = text[index...finish]
    comparable = heredoc.strip ? raw.sub(/\A\t+/, "") : raw
    if comparable == heredoc.delim
      line[:code] = true
      @stack.pop
      return true
    end
    return false unless heredoc.quoted
    line[:code] = true if raw.match?(/\S/)
    true
  end

  def heredoc_step(text, index, line)
    char = text[index]
    if char == "\\"
      line[:code] = true
      return index + (text[index + 1] && text[index + 1] != "\n" ? 2 : 1)
    end
    expansion = begin_expansion(text, index, line)
    return expansion if expansion
    if char == "`"
      line[:code] = true
      @stack.push(ShellCode.new(:backtick, 0, false))
      return index + 1
    end
    line[:code] = true unless blank_char?(char)
    index + 1
  end

  def quoted_step(text, index, line)
    top = @stack.last
    char = text[index]
    if (top.is_a?(Double) || top.is_a?(Ansi)) && char == "\\"
      line[:code] = true
      return index + (text[index + 1] && text[index + 1] != "\n" ? 2 : 1)
    end
    if top.is_a?(Double)
      expansion = begin_expansion(text, index, line)
      return expansion if expansion
      if char == "`"
        line[:code] = true
        @stack.push(ShellCode.new(:backtick, 0, false))
        return index + 1
      end
    end
    line[:code] = true unless blank_char?(char)
    @stack.pop if char == closing_quote(top)
    index + 1
  end

  def closing_quote(frame)
    return "'" if frame.is_a?(Single) || frame.is_a?(Ansi)
    '"' if frame.is_a?(Double)
  end

  def arithmetic_step(text, index, line)
    char = text[index]
    top = @stack.last
    top.depth += 1 if char == "("
    if char == ")"
      top.depth -= 1
      @stack.pop if top.depth.zero?
    end
    line[:code] = true unless blank_char?(char)
    index + 1
  end

  def shell_code_step(text, index, line)
    top = @stack.last
    char = text[index]
    if blank_char?(char)
      top.word = false
      return index + 1
    end
    if char == "\\" && (text[index + 1].nil? || text[index + 1] == "\n")
      line[:code] = true
      @join_word = true
      return index + 1
    end
    if char == "#" && !top.word
      line[:marked] = true
      index += 1 while index < text.length && text[index] != "\n"
      return index
    end
    if text[index, 3] == "<<<"
      line[:code] = true
      top.word = false
      return index + 3
    end
    if text[index, 2] == "<<" && text[index, 3] != "<<<"
      parsed = parse_heredoc(text, index)
      if parsed
        line[:code] = true
        top.word = false
        @pending << parsed[1]
        return parsed[0]
      end
    end
    if text[index, 2] == "$'"
      line[:code] = true
      top.word = true
      @stack.push(Ansi.new(nil))
      return index + 2
    end
    expansion = begin_expansion(text, index, line)
    return expansion if expansion
    if char == "'"
      line[:code] = true
      top.word = true
      @stack.push(Single.new(nil))
      return index + 1
    end
    if char == '"'
      line[:code] = true
      top.word = true
      @stack.push(Double.new(nil))
      return index + 1
    end
    if char == "`"
      line[:code] = true
      top.word = false
      @stack.push(ShellCode.new(:backtick, 0, false))
      return index + 1
    end
    if (char == "{" || char == "}") && !top.word
      nxt = text[index + 1]
      if nxt.nil? || blank_char?(nxt) || nxt == "\n" || METACHAR.include?(nxt)
        line[:code] = true
        return index + 1
      end
    end
    if top.closer == :backtick && char == "`"
      line[:code] = true
      @stack.pop
      return index + 1
    end
    if ";|&()<>".include?(char)
      line[:code] = true
      top.word = false
      if top.closer == :paren && char == "("
        top.paren += 1
      elsif top.closer == :paren && char == ")"
        top.paren -= 1
        @stack.pop if top.paren.zero?
      end
      return index + 1
    end
    line[:code] = true
    top.word = true
    index + 1
  end

  def begin_expansion(text, index, line)
    if text[index, 3] == "$(("
      line[:code] = true
      @stack.last.word = false if @stack.last.is_a?(ShellCode)
      @stack.push(Arithmetic.new(2))
      return index + 3
    end
    return nil unless text[index, 2] == "$("
    line[:code] = true
    @stack.last.word = false if @stack.last.is_a?(ShellCode)
    @stack.push(ShellCode.new(:paren, 1, false))
    index + 2
  end

  def parse_heredoc(text, index)
    cursor = index + 2
    strip = false
    if text[cursor] == "-"
      strip = true
      cursor += 1
    end
    cursor += 1 while text[cursor] == " " || text[cursor] == "\t"
    quoted = false
    if text[cursor] == "'" || text[cursor] == '"'
      quote = text[cursor]
      finish = text.index(quote, cursor + 1)
      return nil unless finish
      word = text[(cursor + 1)...finish]
      quoted = true
      cursor = finish + 1
    elsif text[cursor] == "\\"
      quoted = true
      cursor += 1
      start = cursor
      cursor += 1 while cursor < text.length && text[cursor] != "\n" && !METACHAR.include?(text[cursor])
      word = text[start...cursor]
    else
      start = cursor
      cursor += 1 while cursor < text.length && text[cursor] != "\n" && !METACHAR.include?(text[cursor])
      word = text[start...cursor]
      return nil if word.nil? || word.empty?
    end
    [cursor, Heredoc.new(word, quoted, strip)]
  end

  # --- Config and repository check ------------------------------------------

  def parse_config(text)
    config = Config.new(nil, [], [], {})
    text.lines.each_with_index do |raw, number|
      line = raw.strip
      next if line.empty? || line.start_with?("#")
      key, rest = line.split(/\s+/, 2)
      where = "test/max-lines.conf:#{number + 1}"
      case key
      when "limit"
        raise "#{where}: limit is already set" if config.limit
        raise "#{where}: limit needs a number" unless rest&.match?(/\A[0-9]+\z/)
        config.limit = Integer(rest, 10)
      when "include"
        raise "#{where}: include needs one pattern" if rest.nil? || rest.empty? || rest.match?(/\s/)
        config.includes << rest
      when "exclude"
        pattern, reason = rest&.split(/\s+/, 2)
        raise "#{where}: exclude needs a pattern and a reason" if pattern.nil? || reason.nil? || reason.strip.empty?
        config.excludes << [pattern, reason.strip]
      when "allow"
        path, count = rest&.split(/\s+/, 2)
        raise "#{where}: allow needs a path and a count" if path.nil? || count.nil? || count.match?(/\s/)
        raise "#{where}: #{path} is listed twice" if config.allows.key?(path)
        raise "#{where}: allowance needs a number" unless count.match?(/\A[0-9]+\z/)
        config.allows[path] = Integer(count, 10)
      else
        raise "#{where}: unknown setting #{key}"
      end
    end
    raise "test/max-lines.conf sets no limit" unless config.limit
    raise "test/max-lines.conf lists nothing to count" if config.includes.empty?
    config
  end

  def categorize(path, config)
    return :exclude if config.excludes.any? { |pattern, _reason| match_pattern?(pattern, path) }
    return :include if config.includes.any? { |pattern| match_pattern?(pattern, path) }
    :unknown
  end

  def match_pattern?(pattern, path)
    if pattern.end_with?("/")
      path == pattern.chomp("/") || path.start_with?(pattern)
    elsif pattern.start_with?("*.")
      File.fnmatch?(pattern, File.basename(path), File::FNM_DOTMATCH)
    else
      path == pattern
    end
  end

  def evaluate(config, files)
    errors = []
    warnings = []
    counts = {}
    files.keys.sort.each do |path|
      case categorize(path, config)
      when :unknown
        errors << "uncategorized: #{path} (add an include, or an exclude with a reason)"
      when :include
        language = language_for(path)
        if language.nil?
          errors << "included file has no counter: #{path}"
        else
          counts[path] = code_lines(files.fetch(path), language)
        end
      end
    end
    # Listed files are exempt until they are split. A change in size, or a
    # stale entry, is a warning so another in-flight change is not blocked.
    config.allows.keys.sort.each do |path|
      count = counts[path]
      recorded = config.allows.fetch(path)
      if count.nil?
        warnings << "warning: #{path} is gone or no longer counted; its recorded count is #{recorded}"
      elsif count <= config.limit
        warnings << "warning: #{path} has #{count} code lines, at or under #{config.limit}; its recorded count is #{recorded}"
      elsif count > recorded
        warnings << "warning: #{path} has #{count} code lines, over its recorded count of #{recorded}"
      elsif count < recorded
        warnings << "warning: #{path} has #{count} code lines; its recorded count is #{recorded}"
      end
    end
    counts.keys.sort.each do |path|
      count = counts.fetch(path)
      next if count <= config.limit || config.allows.key?(path)
      errors << "over: #{path} has #{count} code lines"
    end
    [errors, warnings, counts]
  end

  def repository_files
    output = IO.popen(["git", "-C", ROOT, "ls-files", "-z", "--cached", "--others", "--exclude-standard"], &:read)
    raise "git ls-files failed" unless $?.success?
    output.split("\0").reject(&:empty?).to_h do |path|
      raise "refusing to read #{path}" if path.include?("..") || path.start_with?("/")
      [path, File.binread(File.join(ROOT, path))]
    end
  end

  def check(dump: false)
    config = parse_config(File.read(CONFIG))
    errors, warnings, counts = evaluate(config, repository_files)
    if dump
      counts.keys.sort_by { |path| [-counts.fetch(path), path] }.each do |path|
        puts "#{counts.fetch(path)}\t#{path}"
      end
    end
    warnings.each { |warning| warn warning }
    errors.each { |error| warn error }
    errors.empty?
  end

  def self_test
    check_count = lambda do |language, text, expected|
      got = code_lines(text, language)
      raise "#{language} expected #{expected} got #{got}: #{text.inspect}" unless got == expected
    end

    check_count.call(:swift, "let a = 1\n", 1)
    check_count.call(:swift, "let a = 1\n\n// note\n\nlet b = 2\n", 2)
    check_count.call(:swift, "/// doc\n/* block\n still */\nlet a = 1 // tail\n", 1)
    check_count.call(:swift, "/* outer /* inner */ still\n*/\nlet a = 1\n", 1)
    check_count.call(:swift, "let a = \"/* not // a comment */\"\nlet b = 1\n", 2)
    check_count.call(:swift, "let a = #\"raw // not\"#\n", 1)
    check_count.call(:swift, "let a = #\"a\\#\"b\"#\nlet b = 1 // c\n", 2)
    check_count.call(:swift, "let a = \"a\\\"b\" // c\n// only\n", 1)
    check_count.call(:swift, "let s = #\"\"\"\na\\#\"b\n// inside\n\"\"\"#\n", 4)
    check_count.call(:swift, "let e = \"\"\"\nhello \\(\n  1 // comment\n  + 2)\n\"\"\"\n", 5)
    check_count.call(:swift, "let g = \"ok \\(1 /* c */ + 2)\"\n", 1)
    check_count.call(:swift, "css.range(of: \"/*\")\nlet a = 1\n", 2)
    check_count.call(:swift, "let a = \"unterminated\nlet b = 1 // real\n", 2)
    check_count.call(:swift, "let a = 1\n" * 1000, 1000)
    check_count.call(:swift, "let a = 1\n" * 1001, 1001)

    check_count.call(:shell, "echo hi # tail\n\n# only\necho there\n", 2)
    check_count.call(:shell, "echo '# not a comment'\necho \"# neither\"\n# yes\n", 2)
    check_count.call(:shell, "ruby -e '\n# ruby comment inside the quotes\necho hi\n'\n# shell comment\necho done\n", 5)
    check_count.call(:shell, "if [ ${#preferred[@]} -eq 0 ]; then\necho \"hello\"\n# comment\nfi\n", 3)
    check_count.call(:shell, "echo ${#foo}\"\n# inside string\n\"\n", 3)
    check_count.call(:shell, "[ $# -gt 0 ]\ntries=$((tries + 1))\n", 2)
    check_count.call(:shell, "cat <<'EOF'\n# not a shell comment\necho hi\nEOF\necho after\n", 5)
    check_count.call(:shell, "cat <<EOF\n# literal\n$(\n# real comment\necho hi\n)\nEOF\necho after\n", 7)
    check_count.call(:shell, "done <<EOF_ORPHANS\n$(python3 -c '\n# python, inside quotes\nprint(1)\n')\nEOF_ORPHANS\n", 6)
    check_count.call(:shell, "cat <<-EOF\n\t# kept\n\tEOF\necho after\n", 4)
    check_count.call(:shell, "echo foo#bar\n{#notacomment}\n{ # comment\necho hi\n", 4)

    config = parse_config(<<~CONF)
      limit 1000
      include *.swift
      exclude *.md Documentation.
      exclude build/ Local build output.
      allow Old.swift 1002
    CONF
    errors, warnings, counts = evaluate(config, {
      "Old.swift" => "let a = 1\n" * 1002,
      "New.swift" => "let a = 1\n" * 1000,
      "Fat.swift" => "let a = 1\n" * 1001,
      "README.md" => "hello\n"
    })
    unless counts == { "Old.swift" => 1002, "New.swift" => 1000, "Fat.swift" => 1001 } && errors == ["over: Fat.swift has 1001 code lines"] && warnings.empty?
      raise "sample check failed: #{errors} #{warnings} #{counts}"
    end
    errors, warnings, = evaluate(config, { "Old.swift" => "let a = 1\n" * 1005, "New.swift" => "let a = 1\n" })
    raise "growth: #{errors} #{warnings}" unless errors.empty? && warnings == ["warning: Old.swift has 1005 code lines, over its recorded count of 1002"]
    errors, warnings, = evaluate(config, { "Old.swift" => "let a = 1\n" * 1001, "New.swift" => "let a = 1\n" })
    raise "shrink: #{warnings.inspect} #{errors.inspect}" unless errors.empty? && warnings == ["warning: Old.swift has 1001 code lines; its recorded count is 1002"]
    errors, warnings, = evaluate(config, { "Old.swift" => "let a = 1\n" * 1000, "New.swift" => "let a = 1\n" })
    raise "stale under: #{errors} #{warnings}" unless errors.empty? && warnings.any? { |warning| warning.include?("Old.swift") && warning.include?("1000") }
    errors, warnings, = evaluate(config, { "New.swift" => "let a = 1\n" })
    raise "stale gone: #{errors} #{warnings}" unless errors.empty? && warnings.any? { |warning| warning.include?("Old.swift") && warning.include?("gone") }
    errors, = evaluate(config, { "New.swift" => "let a = 1\n", "notes.txt" => "x\n" })
    raise "uncategorized: #{errors}" unless errors.any? { |error| error.include?("uncategorized: notes.txt") }

    live = parse_config(File.read(CONFIG))
    raise "the configured limit is #{live.limit}, expected 1000" unless live.limit == 1000
    raise "an exclusion is missing its reason" if live.excludes.any? { |_pattern, reason| reason.empty? }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    MaxLines.self_test
  rescue StandardError => error
    warn "self-test failed: #{error.message}"
    exit 1
  end
  if ARGV == ["--self-test"]
    puts "ok: max-lines self-test"
    exit 0
  end
  if ARGV != [] && ARGV != ["--dump"]
    warn "usage: ruby test/max-lines.rb [--dump|--self-test]"
    exit 2
  end
  exit MaxLines.check(dump: ARGV == ["--dump"]) ? 0 : 1
end
