# frozen_string_literal: true

module HackerNews
  # Draws the application icon.
  #
  # A bare SF Symbol reads as a glyph rather than an app, so it is set on the
  # rounded, tinted plate macOS icons use. Drawn rather than shipped as a file,
  # which keeps the example a single directory of Ruby.
  class AppIcon
    SYMBOL = 'newspaper.fill'

    # Hacker News orange, top to bottom.
    TOP_COLOUR    = [1.00, 0.46, 0.13].freeze
    BOTTOM_COLOUR = [0.91, 0.29, 0.02].freeze

    # macOS rounds app icons at just under a quarter of their side, and leaves
    # the outer edge of the canvas clear.
    CORNER_RATIO = 0.2237
    CANVAS_INSET = 0.085
    GLYPH_RATIO  = 0.30

    class << self
      def image(size = 512.0)
        canvas = Cocoa::NSImage.alloc.initWithSize([size, size])
        canvas.lockFocus
        draw_plate(size)
        draw_glyph(size)
        canvas.unlockFocus
        canvas
      rescue ObjC::Exception
        nil
      end

      def write_png(path, size = 1024.0)
        rendered = image(size)
        return false if rendered.nil?

        rep = Cocoa::NSBitmapImageRep.imageRepWithData(rendered.TIFFRepresentation)
        data = rep.representationUsingType_properties(Cocoa::NSBitmapImageFileTypePNG, {})
        data.writeToFile_atomically(path, true)
      end

      private

      def draw_plate(size)
        inset  = size * CANVAS_INSET
        side   = size - (inset * 2)
        radius = side * CORNER_RATIO

        plate = Cocoa::NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
          [inset, inset, side, side], radius, radius
        )
        gradient = Cocoa::NSGradient.alloc.initWithStartingColor_endingColor(
          colour(TOP_COLOUR), colour(BOTTOM_COLOUR)
        )
        # -90 degrees runs the gradient from the top edge downwards.
        gradient.drawInBezierPath_angle(plate, -90.0)
      end

      def draw_glyph(size)
        glyph = white_symbol(size * GLYPH_RATIO)
        return if glyph.nil?

        drawn = glyph.size
        origin_x = (size - drawn.width) / 2.0
        origin_y = (size - drawn.height) / 2.0

        glyph.drawInRect_fromRect_operation_fraction(
          [origin_x, origin_y, drawn.width, drawn.height],
          [0, 0, 0, 0], Cocoa::NSCompositingOperationSourceOver, 1.0
        )
      end

      def white_symbol(point_size)
        symbol = Cocoa::NSImage.imageWithSystemSymbolName_accessibilityDescription(
          SYMBOL, 'Hacker News'
        )
        return nil if symbol.nil?

        sizing = Cocoa::NSImageSymbolConfiguration
                 .configurationWithPointSize_weight_scale(point_size, 0.4, 3)
        tinted = Cocoa::NSImageSymbolConfiguration
                 .configurationWithHierarchicalColor(Cocoa::NSColor.whiteColor)

        symbol.imageWithSymbolConfiguration(sizing.configurationByApplyingConfiguration(tinted))
      end

      def colour(components)
        red, green, blue = components
        Cocoa::NSColor.colorWithSRGBRed_green_blue_alpha(red, green, blue, 1.0)
      end
    end
  end
end
