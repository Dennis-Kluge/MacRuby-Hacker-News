# frozen_string_literal: true

module HackerNews
  # The line under the story list saying what the list is showing.
  #
  # It used to be the window's subtitle. In a unified toolbar the title is not
  # above the controls but beside them, competing for the same row -- and at a
  # narrow width it was the status, the one thing there carrying information
  # rather than affording an action, that got truncated.
  #
  # Down here it has the width of the sidebar to itself and sits against the
  # list it describes, which is where Finder, Mail and Xcode keep theirs.
  class StatusBar
    HEIGHT = 28.0
    INSET  = 12.0

    # +over+ is the view this sits beneath; the container it returns is what
    # goes into the window in its place.
    def initialize(over:, width:, height:)
      @content = over

      build_container(width, height)
      build_separator(width)
      build_label(width)
      layout
    end

    attr_reader :container, :label

    def text=(value)
      @label.setStringValue(value.to_s)
    end

    def text
      @label.stringValue.to_s
    end

    private

    def build_container(width, height)
      @container = Cocoa::NSView.alloc.initWithFrame([0, 0, width, height])

      @content.setAutoresizingMask(
        Cocoa::NSViewWidthSizable | Cocoa::NSViewHeightSizable
      )
      @container.addSubview(@content)

      @bar = Cocoa::NSView.alloc.initWithFrame([0, 0, width, HEIGHT])
      @bar.setAutoresizingMask(Cocoa::NSViewWidthSizable | Cocoa::NSViewMaxYMargin)
      @container.addSubview(@bar)
    end

    # A hairline, so the bar reads as its own strip rather than as a gap the
    # list happens to stop short of.
    #
    # A layer-backed view rather than an NSBox: a separator box has a minimum
    # thickness of its own and re-centres itself inside whatever frame it is
    # given, which puts the line somewhere other than the edge.
    def build_separator(width)
      @separator = Cocoa::NSView.alloc.initWithFrame([0, HEIGHT - 1, width, 1])
      @separator.setAutoresizingMask(Cocoa::NSViewWidthSizable)
      @separator.setWantsLayer(true)
      @separator.layer.setBackgroundColor(Cocoa::NSColor.separatorColor.CGColor)
      @bar.addSubview(@separator)
    end

    def build_label(width)
      @label = Cocoa::NSTextField.alloc.initWithFrame(
        [INSET, 0, width - (INSET * 2), 16]
      )
      @label.setEditable(false)
      @label.setSelectable(false)
      @label.setBezeled(false)
      @label.setDrawsBackground(false)
      @label.setFont(Cocoa::NSFont.systemFontOfSize(11))
      @label.setTextColor(Cocoa::NSColor.secondaryLabelColor)
      @label.setAutoresizingMask(Cocoa::NSViewWidthSizable)
      # Long enough to need it only in a very narrow window, but then it must
      # lose its end rather than its beginning.
      @label.cell.setLineBreakMode(4) # NSLineBreakByTruncatingTail
      @bar.addSubview(@label)
    end

    def layout
      height = @container.frame.height
      width  = @container.frame.width

      @content.setFrame([0, HEIGHT, width, [height - HEIGHT, 0].max])
      @bar.setFrame([0, 0, width, HEIGHT])
      @separator.setFrame([0, HEIGHT - 1, width, 1])
      @label.setFrameOrigin([INSET, ((HEIGHT - @label.frame.height) / 2.0).round])
    end
  end
end
