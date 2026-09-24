# frozen_string_literal: true

module HackerNews
  # Builds the attributed strings the two lists draw, and measures them.
  #
  # Font sizes come from the preferences, so everything that decides how tall a
  # row needs to be lives in one place.
  class Typography
    # Wrapped lines align under the first one rather than falling back to the
    # left margin, past the rank column.
    RANK_WIDTH = 26.0

    def initialize(settings)
      @settings = settings
    end

    def story(story, rank:, read:, icon: nil)
      meta_size, _body, title_size = @settings.font_sizes

      compose do |out|
        out << if icon
                 site_icon(icon)
               else
                 attributed(format('%2d  ', rank),
                            font: Cocoa::NSFont.monospacedDigitSystemFontOfSize_weight(meta_size, 0.0),
                            color: Cocoa::NSColor.tertiaryLabelColor,
                            head_indent: RANK_WIDTH)
               end

        # Read stories dim and lose their weight, the way a visited link does.
        out << attributed(story[:title],
                          font: read ? Cocoa::NSFont.systemFontOfSize(title_size)
                                     : Cocoa::NSFont.boldSystemFontOfSize(title_size),
                          color: read ? Cocoa::NSColor.secondaryLabelColor
                                      : Cocoa::NSColor.labelColor,
                          head_indent: RANK_WIDTH)

        out << attributed("\n#{meta_line(story)}",
                          font: Cocoa::NSFont.systemFontOfSize(meta_size),
                          color: read ? Cocoa::NSColor.tertiaryLabelColor
                                      : Cocoa::NSColor.secondaryLabelColor,
                          head_indent: RANK_WIDTH, first_line_indent: RANK_WIDTH)
      end
    end

    def comment(node)
      header_size, body_size, = @settings.font_sizes

      compose do |out|
        out << attributed("#{node[:author]}  ·  #{node[:age]}\n",
                          font: Cocoa::NSFont.boldSystemFontOfSize(header_size),
                          color: Cocoa::NSColor.secondaryLabelColor)

        body = Cocoa::NSMutableAttributedString.alloc.initWithAttributedString(
          attributed(node[:text],
                     font: Cocoa::NSFont.systemFontOfSize(body_size),
                     color: Cocoa::NSColor.labelColor,
                     paragraph_spacing: 6.0)
        )
        apply_links(body, node[:links])
        out << body
      end
    end

    # Height needed to lay this string out in the given width.
    def measure(attributed_string, width)
      attributed_string.boundingRectWithSize_options(
        [width, 100_000], 1 # NSStringDrawingUsesLineFragmentOrigin
      ).height
    end

    def attributed(string, font:, color:, paragraph_spacing: 0.0,
                   head_indent: 0.0, first_line_indent: 0.0)
      paragraph = Cocoa::NSMutableParagraphStyle.alloc.init
      paragraph.setLineBreakMode(0) # NSLineBreakByWordWrapping
      paragraph.setLineSpacing(1.0)
      paragraph.setParagraphSpacing(paragraph_spacing)
      paragraph.setHeadIndent(head_indent)
      paragraph.setFirstLineHeadIndent(first_line_indent)

      Cocoa::NSAttributedString.alloc.initWithString_attributes(
        string,
        Cocoa::NSFontAttributeName            => font,
        Cocoa::NSForegroundColorAttributeName => color,
        Cocoa::NSParagraphStyleAttributeName  => paragraph
      )
    end

    # The site's icon, inline with the title. An attachment keeps the row a
    # single attributed string rather than a view hierarchy.
    def site_icon(image)
      attachment = Cocoa::NSTextAttachment.alloc.init
      attachment.setImage(image)
      # Nudged down so it sits on the text's baseline rather than above it.
      attachment.setBounds([0, -3, Favicons::SIZE, Favicons::SIZE])

      piece = Cocoa::NSMutableAttributedString.alloc.initWithAttributedString(
        Cocoa::NSAttributedString.attributedStringWithAttachment(attachment)
      )
      piece.appendAttributedString(
        attributed('  ', font: Cocoa::NSFont.systemFontOfSize(12),
                         color: Cocoa::NSColor.labelColor, head_indent: RANK_WIDTH)
      )
      # The paragraph style has to cover the attachment too, or the indent
      # applies to only part of the line.
      piece.addAttribute_value_range(
        Cocoa::NSParagraphStyleAttributeName, indented_paragraph, [0, piece.length]
      )
      piece
    end

    def indented_paragraph
      paragraph = Cocoa::NSMutableParagraphStyle.alloc.init
      paragraph.setLineBreakMode(0)
      paragraph.setLineSpacing(1.0)
      paragraph.setHeadIndent(RANK_WIDTH)
      paragraph
    end

    private

    # Collect the pieces of a cell, then join them into one attributed string.
    def compose
      pieces = []
      yield pieces
      pieces.each_with_object(Cocoa::NSMutableAttributedString.alloc.init) do |piece, combined|
        combined.appendAttributedString(piece)
      end
    end

    # Hacker News's own order, roughly: where it is from, how it did, who
    # posted it, and when. The age matters most in search results, which reach
    # back years, but it belongs on every row for the same reason it does on
    # the site itself.
    def meta_line(story)
      parts = []
      parts << story[:domain] if story[:domain]
      parts << pluralize(story[:points], 'point')
      parts << pluralize(story[:comments], 'comment')
      parts << story[:author]
      parts << story[:age] unless story[:age].to_s.empty?
      parts.join(' · ')
    end

    def pluralize(count, singular, plural = "#{singular}s")
      "#{count} #{count == 1 ? singular : plural}"
    end

    # Ranges recorded during HTML conversion become real links.
    def apply_links(body, links)
      return if links.nil? || links.empty?

      length = body.length
      links.each do |link|
        start, span = link[:range]
        next if start + span > length

        body.addAttribute_value_range(Cocoa::NSLinkAttributeName, link[:url], [start, span])
      end
    end
  end
end
