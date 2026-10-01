# frozen_string_literal: true

require 'json'
require 'time'

module HackerNews
  # Turns saved stories into a file someone else can read.
  #
  # Plain Ruby in and a String out: no panels, no windows, no file system, so
  # every format can be checked without any of that. Whoever calls this
  # decides where the bytes go.
  module Export
    HEADING   = 'Saved from Hacker News'
    GENERATOR = 'Hacker News for macOS'

    Format = Struct.new(:key, :label, :extension, :uti, keyword_init: true)

    ALL = [
      Format.new(key: :markdown,  label: 'Markdown',          extension: 'md',
                 uti: 'net.daringfireball.markdown'),
      Format.new(key: :json,      label: 'JSON',              extension: 'json',
                 uti: 'public.json'),
      Format.new(key: :opml,      label: 'OPML',              extension: 'opml',
                 uti: 'public.xml'),
      Format.new(key: :bookmarks, label: 'Browser Bookmarks', extension: 'html',
                 uti: 'public.html')
    ].freeze

    # Looked up by key from a menu, or by index from a popup, like every other
    # table of options in the app.
    extend Choices

    # Render +stories+ in the named format.
    def self.render(key, stories, now: Time.now)
      case self[key].key
      when :json      then json(stories, now)
      when :opml      then opml(stories, now)
      when :bookmarks then bookmarks(stories)
      else                 markdown(stories, now)
      end
    end

    # The default file name, which the save panel starts with.
    def self.filename(key)
      "hacker-news-saved.#{self[key].extension}"
    end

    # ---- reading one back ----------------------------------------------------

    # JSON is the only one of the four that round-trips: the others drop
    # fields on the way out, by design, because a bookmarks file is not a
    # place to keep a comment count.
    IMPORTABLE = %w[json].freeze

    # Returns the stories in +text+, or nil when it is not a file we wrote.
    #
    # Nothing here raises: this is handed a file somebody chose, and the
    # answer to the wrong file is to say so, not to fall over.
    def self.parse(text)
      parsed = JSON.parse(text.to_s, symbolize_names: true)
      stories = parsed.is_a?(Hash) ? parsed[:stories] : parsed
      return nil unless stories.is_a?(Array)

      kept = stories.select { |story| story.is_a?(Hash) && !story[:id].nil? }
      kept.map { |story| restore(story) }
    rescue JSON::ParserError
      nil
    end

    # Only the fields a saved story is made of, so an export someone has
    # edited cannot introduce whatever it likes into the store.
    def self.restore(story)
      record = Favorites::FIELDS.each_with_object({}) do |field, kept|
        kept[field] = story[field]
      end
      record[:id] = record[:id].to_s
      record[:saved_at] = story[:saved_at] if story[:saved_at]
      record
    end

    # ---- the formats ---------------------------------------------------------

    # Readable first: this is the one that gets pasted into a notebook.
    def self.markdown(stories, now = Time.now)
      lines = ["# #{HEADING}", '', "_#{stories.size} #{stories.size == 1 ? 'story' : 'stories'}, " \
                                   "exported #{now.strftime('%-d %B %Y')}_", '']

      stories.each do |story|
        lines << "## [#{story[:title]}](#{link_for(story)})"
        lines << ''
        lines << meta_line(story)
        lines << ''
        lines << "Discussion: #{discussion_for(story)}"
        lines << ''
      end

      lines.join("\n")
    end

    # Everything kept, so another tool -- or a later version of this one --
    # can read it back.
    def self.json(stories, now = Time.now)
      JSON.pretty_generate(
        generator:   GENERATOR,
        exported_at: now.utc.iso8601,
        count:       stories.size,
        stories:     stories.map { |story| json_record(story) }
      )
    end

    # An outline of links, which is what OPML is for once you look past feeds.
    def self.opml(stories, now = Time.now)
      outlines = stories.map do |story|
        attributes = {
          'text'    => story[:title].to_s,
          'type'    => 'link',
          'url'     => link_for(story),
          'htmlUrl' => discussion_for(story)
        }
        attributes['created'] = story[:saved_at] if story[:saved_at]

        "    <outline #{attributes.map { |k, v| %(#{k}="#{xml_escape(v)}") }.join(' ')}/>"
      end

      <<~OPML
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>#{xml_escape(HEADING)}</title>
            <dateCreated>#{now.utc.strftime('%a, %d %b %Y %H:%M:%S %z')}</dateCreated>
          </head>
          <body>
        #{outlines.join("\n")}
          </body>
        </opml>
      OPML
    end

    # The Netscape bookmark format, which Safari, Chrome and Firefox all
    # import. It is not valid HTML and never was -- the unclosed <DT> is part
    # of the format, and importers expect it.
    def self.bookmarks(stories)
      entries = stories.map do |story|
        added = epoch_of(story)
        date  = added ? %( ADD_DATE="#{added}") : ''
        %(    <DT><A HREF="#{xml_escape(link_for(story))}"#{date}>#{xml_escape(story[:title].to_s)}</A>)
      end

      <<~HTML
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file. It will be read and overwritten. -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3>#{xml_escape(HEADING)}</H3>
            <DL><p>
        #{entries.join("\n")}
            </DL><p>
        </DL><p>
      HTML
    end

    # ---- shared --------------------------------------------------------------

    # A text post has no article of its own, so its discussion page stands in.
    def self.link_for(story)
      url = story[:url].to_s
      url.empty? ? discussion_for(story) : url
    end

    def self.discussion_for(story)
      "https://news.ycombinator.com/item?id=#{story[:id]}"
    end

    def self.json_record(story)
      {
        id:        story[:id],
        title:     story[:title],
        url:       story[:url],
        domain:    story[:domain],
        author:    story[:author],
        points:    story[:points],
        comments:  story[:comments],
        saved_at:  story[:saved_at],
        discussion: discussion_for(story)
      }
    end

    def self.meta_line(story)
      parts = []
      parts << story[:domain] if story[:domain]
      parts << pluralize(story[:points], 'point') if story[:points]
      parts << pluralize(story[:comments], 'comment') if story[:comments]
      parts << "by #{story[:author]}" if story[:author]
      parts << "saved #{story[:saved_at][0, 10]}" if story[:saved_at]
      parts.join(' · ')
    end

    def self.pluralize(count, singular)
      "#{count} #{count == 1 ? singular : "#{singular}s"}"
    end

    def self.epoch_of(story)
      Time.parse(story[:saved_at].to_s).to_i
    rescue ArgumentError, TypeError
      nil
    end

    def self.xml_escape(value)
      value.to_s
           .gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
           .gsub('"', '&quot;').gsub("'", '&#39;')
    end
  end
end
