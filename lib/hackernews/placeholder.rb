# frozen_string_literal: true

module HackerNews
  # The centred symbol and line of text a list shows when it has nothing to
  # show: no story selected yet, or a search that found nothing.
  #
  # It wraps the scroll view rather than sitting inside it, so showing the
  # message is a matter of swapping which of the two is hidden. Both lists use
  # one, which is why it is here rather than in either of them.
  class Placeholder
    BOX_WIDTH  = 340.0
    BOX_HEIGHT = 120.0
    SYMBOL_BOX = 60.0

    # +over+ is the scroll view this stands in front of; the container it
    # returns is what goes into the window.
    def initialize(over:, width:, height:, symbol:, description: '')
      @scroll_view = over
      @symbol_name = symbol

      build_container(width, height)
      build_box(symbol, description)
      @container.addSubview(@box)
    end

    attr_reader :container, :box

    def show(message, symbol: nil)
      @label.setStringValue(message)
      apply_symbol(symbol) if symbol && symbol != @symbol_name
      @box.setHidden(false)
      @scroll_view.setHidden(true)
    end

    def hide
      @box.setHidden(true)
      @scroll_view.setHidden(false)
    end

    def visible?
      !@box.isHidden
    end

    def text
      @label.stringValue.to_s
    end

    def symbol_name
      @symbol_name
    end

    private

    def build_container(width, height)
      @container = Cocoa::NSView.alloc.initWithFrame([0, 0, width, height])
      @scroll_view.setFrame([0, 0, width, height])
      @scroll_view.setAutoresizingMask(
        Cocoa::NSViewWidthSizable | Cocoa::NSViewHeightSizable
      )
      @container.addSubview(@scroll_view)
    end

    def build_box(symbol, description)
      width  = @container.frame.width
      height = @container.frame.height

      @box = Cocoa::NSView.alloc.initWithFrame(
        [(width - BOX_WIDTH) / 2.0, (height - BOX_HEIGHT) / 2.0, BOX_WIDTH, BOX_HEIGHT]
      )
      # Flexible margins on every side keep it in the middle as the pane is
      # resized.
      @box.setAutoresizingMask(
        Cocoa::NSViewMinXMargin | Cocoa::NSViewMaxXMargin |
        Cocoa::NSViewMinYMargin | Cocoa::NSViewMaxYMargin
      )

      build_image(symbol, description)
      build_label
    end

    def build_image(symbol, description)
      @image_view = Cocoa::NSImageView.alloc.initWithFrame(
        [(BOX_WIDTH - SYMBOL_BOX) / 2.0, 48, SYMBOL_BOX, 56]
      )
      @image_view.setContentTintColor(Cocoa::NSColor.tertiaryLabelColor)
      @description = description
      @box.addSubview(@image_view)
      apply_symbol(symbol)
    end

    # A missing symbol leaves an empty image view rather than an empty space
    # the label has to be laid out around.
    def apply_symbol(name)
      image = Cocoa::NSImage.imageWithSystemSymbolName_accessibilityDescription(
        name, @description
      )
      @symbol_name = name
      return @image_view.setImage(nil) if image.nil?

      configuration = Cocoa::NSImageSymbolConfiguration
                      .configurationWithPointSize_weight_scale(44.0, 0.2, 3)
      @image_view.setImage(image.imageWithSymbolConfiguration(configuration))
    end

    def build_label
      @label = Cocoa::NSTextField.alloc.initWithFrame([0, 8, BOX_WIDTH, 34])
      @label.setEditable(false)
      @label.setSelectable(false)
      @label.setBezeled(false)
      @label.setDrawsBackground(false)
      @label.setAlignment(Cocoa::NSTextAlignmentCenter)
      @label.setFont(Cocoa::NSFont.systemFontOfSize(13))
      @label.setTextColor(Cocoa::NSColor.secondaryLabelColor)
      @label.cell.setWraps(true)
      @box.addSubview(@label)
    end
  end
end
