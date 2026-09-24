# frozen_string_literal: true

module HackerNews
  # Hacker News comments arrive as a small, predictable subset of HTML.
  # Converting it in Ruby is both faster and more controllable than handing it
  # to NSAttributedString's HTML importer, which would have to run on the main
  # thread for every one of several hundred comments.
  module HTML
    ENTITIES = {
      '&amp;'  => '&',  '&lt;'   => '<',  '&gt;'  => '>',
      '&quot;' => '"',  '&#x27;' => "'",  '&#39;' => "'",
      '&#x2F;' => '/',  '&#47;'  => '/',  '&nbsp;' => ' ',
      '&hellip;' => '…', '&mdash;' => '—', '&ndash;' => '–'
    }.freeze

    # Markers that survive tag stripping and entity decoding, so link
    # positions can be recovered after the rest of the conversion has run.
    LINK_START = "\u0002"
    LINK_SPLIT = "\u0003"
    LINK_END   = "\u0004"

    BARE_URL = %r{https?://[^\s<>"'\u0002\u0003\u0004)\]]+}

    module_function

    # Convert one comment's HTML into text plus the ranges that should be
    # links. Ranges are in UTF-16 code units, which is what NSAttributedString
    # expects -- character offsets would be wrong the moment a comment contains
    # an emoji.
    def to_rich(html, paragraph_break: "\n\n")
      return { text: '', links: [] } if html.nil?

      hrefs = []
      text  = html.dup

      text.gsub!(%r{<p>}i, paragraph_break)
      text.gsub!(%r{</p>}i, '')
      text.gsub!(%r{<br\s*/?>}i, "\n")
      text.gsub!(%r{<li>}i, "\n  • ")

      text.gsub!(%r{<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>}im) do
        # Hacker News escapes href attributes too, so "https:&#x2F;&#x2F;..."
        # has to be decoded here or the link will not resolve.
        href  = decode_entities(Regexp.last_match(1))
        label = Regexp.last_match(2).gsub(%r{<[^>]+>}, '').strip
        # Anchor text is often elided ("example.com/very/long..."), in which
        # case the href itself reads better.
        label = href if label.empty? || label.include?('...')
        hrefs << href
        "#{LINK_START}#{hrefs.size - 1}#{LINK_SPLIT}#{label}#{LINK_END}"
      end

      text.gsub!(%r{<[^>]+>}, '')
      text = decode_entities(text)
      limit = paragraph_break.count("\n") + 1
      text.gsub!(/\n{#{limit + 1},}/, paragraph_break)
      text.strip!

      extract_links(text.to_s, hrefs)
    end

    # Rebuild the plain string, recording where each link landed.
    def extract_links(marked, hrefs)
      out    = +''
      links  = []
      cursor = 0

      marked.scan(/#{LINK_START}(\d+)#{LINK_SPLIT}(.*?)#{LINK_END}/m) do
        match = Regexp.last_match
        out << marked[cursor...match.begin(0)]

        label = match[2]
        links << { range: [utf16_length(out), utf16_length(label)],
                   url: hrefs[match[1].to_i] }
        out << label
        cursor = match.end(0)
      end
      out << marked[cursor..].to_s

      { text: out, links: links + bare_urls(out, links) }
    end

    # Plain URLs typed into a comment are links too.
    def bare_urls(text, existing)
      taken = existing.map { |l| l[:range] }
      found = []

      text.to_enum(:scan, BARE_URL).each do
        match  = Regexp.last_match
        start  = utf16_length(text[0...match.begin(0)])
        length = utf16_length(match[0])
        next if taken.any? { |s, l| start >= s && start < s + l }

        found << { range: [start, length], url: match[0] }
      end
      found
    end

    # NSAttributedString counts in UTF-16 code units, so a character offset is
    # wrong for anything outside the basic multilingual plane.
    def utf16_length(string)
      string.to_s.encode(::Encoding::UTF_16LE).bytesize / 2
    end

    # Plain text, with link destinations spelled out for contexts that cannot
    # render a real link.
    def to_text(html)
      rich = to_rich(html)
      text = rich[:text].dup

      # Walk backwards so earlier offsets stay valid as text is inserted.
      rich[:links].sort_by { |link| -link[:range][0] }.each do |link|
        start, length = link[:range]
        label = utf16_slice(text, start, length)
        next if label == link[:url]

        insert_at = utf16_offset_to_char(text, start + length)
        text.insert(insert_at, " (#{link[:url]})")
      end
      text
    end

    def utf16_slice(string, start, length)
      units = string.encode(::Encoding::UTF_16LE)
      units.byteslice(start * 2, length * 2).force_encoding(::Encoding::UTF_16LE)
           .encode(::Encoding::UTF_8)
    end

    def utf16_offset_to_char(string, offset)
      prefix = string.encode(::Encoding::UTF_16LE).byteslice(0, offset * 2)
      prefix.force_encoding(::Encoding::UTF_16LE).encode(::Encoding::UTF_8).length
    end

    def decode_entities(text)
      ENTITIES.each { |entity, char| text = text.gsub(entity, char) }
      text.gsub(/&#(\d+);/) { [Regexp.last_match(1).to_i].pack('U') }
          .gsub(/&#x([0-9a-fA-F]+);/) { [Regexp.last_match(1).to_i(16)].pack('U') }
    end

    # "3 hours ago" from an ISO 8601 timestamp.
    def relative_time(iso8601, now = Time.now)
      return '' if iso8601.nil?

      seconds = (now - Time.parse(iso8601)).to_i
      return 'just now' if seconds < 60

      # Years and months are here for search results, which reach back to
      # 2007; "4,800 days ago" is technically true and of no use to anyone.
      [[31_536_000, 'year'], [2_592_000, 'month'], [86_400, 'day'],
       [3_600, 'hour'], [60, 'minute']].each do |size, name|
        next if seconds < size

        count = seconds / size
        return "#{count} #{name}#{'s' unless count == 1} ago"
      end
      'just now'
    rescue ArgumentError, TypeError
      ''
    end
  end
end
