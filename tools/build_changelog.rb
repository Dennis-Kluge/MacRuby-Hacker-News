#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Render CHANGELOG.md into docs/changelog.html.
#
#   rake site
#
# So that the notes have one source. The alternative was writing them twice
# and keeping the copies in step by remembering to, which nobody does.
#
# This understands only the Markdown the changelog actually uses, and raises
# on anything else rather than quietly dropping it -- a converter that fails
# loudly on a heading it has never seen is worth more here than one that
# handles all of Markdown.

require 'cgi'

module HackerNews
  class ChangelogPage
    TITLE = 'Hacker News — release notes'
    REPO  = 'https://github.com/Dennis-Kluge/MacRuby-Hacker-News'

    def initialize(markdown)
      @markdown = markdown
    end

    def self.render(markdown)
      new(markdown).to_html
    end

    def to_html
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{TITLE}</title>
        <meta name="description" content="What changed in each release of Hacker News, a Mac app written in Ruby.">
        <link rel="icon" href="img/icon-64.png" sizes="64x64">
        <link rel="apple-touch-icon" href="img/icon-180.png">
        <link rel="stylesheet" href="style.css">
        </head>
        <body>
        <div class="wrap page">
        <a class="back" href="./">← Hacker News</a>
        <h1>Release notes</h1>
        #{body}
        <footer>
          <p>MIT licensed · <a href="#{REPO}">Source on GitHub</a> ·
             <a href="#{REPO}/releases">Releases</a></p>
        </footer>
        </div>
        </body>
        </html>
      HTML
    end

    private

    # Each "## 1.1" starts a release; everything until the next one is its
    # notes.
    def body
      sections.map { |version, lines| release(version, lines) }.join("\n")
    end

    def sections
      found = []
      @markdown.each_line do |line|
        case line
        when /\A# /          then next          # the file's own title
        when /\A## (.+)\n?\z/ then found << [Regexp.last_match(1).strip, []]
        else
          raise "text before the first release: #{line.inspect}" if found.empty? && line.strip != ''

          found.last[1] << line unless found.empty?
        end
      end
      found
    end

    def release(version, lines)
      [%(<section class="release">), %(<h2>#{CGI.escapeHTML(version)}</h2>),
       blocks(lines), '</section>'].join("\n")
    end

    # Paragraphs and bullet lists, which is all the changelog has in it.
    def blocks(lines)
      out = []
      list = []

      lines.chunk_while { |a, b| !(a.strip.empty? || b.strip.empty?) }.each do |chunk|
        text = chunk.map(&:rstrip).reject(&:empty?)
        next if text.empty?

        if text.first.start_with?('- ')
          out << bullets(text)
        else
          out << "<p>#{inline(text.join(' ').sub(/\A- /, ''))}</p>"
        end
      end
      out.join("\n")
    end

    def bullets(lines)
      items = []
      lines.each do |line|
        if line.start_with?('- ')
          items << line.sub(/\A- /, '')
        else
          raise "a bullet list ran into #{line.inspect}" if items.empty?

          items[-1] = "#{items.last} #{line.strip}" # a wrapped bullet
        end
      end
      "<ul>\n#{items.map { |i| "  <li>#{inline(i)}</li>" }.join("\n")}\n</ul>"
    end

    # Bold, inline code, and nothing else. Anything that looks like other
    # Markdown is a sign the changelog grew a construct this does not know.
    def inline(text)
      escaped = CGI.escapeHTML(text)
      escaped = escaped.gsub(/`([^`]+)`/) { "<code>#{Regexp.last_match(1)}</code>" }
      escaped = escaped.gsub(/\*\*([^*]+)\*\*/) { "<strong>#{Regexp.last_match(1)}</strong>" }

      raise "unhandled markdown in #{text.inspect}" if escaped.match?(/\[.+\]\(.+\)|^\s*#|\*\w/)

      escaped
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root   = File.expand_path('..', __dir__)
  source = File.join(root, 'CHANGELOG.md')
  target = File.join(root, 'docs', 'changelog.html')

  # Spelled out: the changelog has ⌘ and — in it, and the default external
  # encoding is whatever the locale says, which is not always UTF-8.
  markdown = File.read(source, encoding: 'UTF-8')
  File.write(target, HackerNews::ChangelogPage.render(markdown), encoding: 'UTF-8')
  puts "wrote #{target} from #{File.basename(source)}"
end
