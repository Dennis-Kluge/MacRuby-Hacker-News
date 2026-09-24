#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Build the demo UI and render it to a PNG using AppKit's own drawing, without
# entering the event loop. Exercises the whole bridge -- struct returns, object
# arguments, blocks, Ruby Hash -> NSDictionary, NSData -> file -- and produces
# visual proof that the view hierarchy is real.
#
#   ruby -Ilib examples/render_to_png.rb /tmp/out.png

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'cocoa'

Cocoa.framework 'AppKit'

out = ARGV[0] || '/tmp/cocoa_render.png'

app = Cocoa::NSApplication.sharedApplication
app.setActivationPolicy(Cocoa::NSApplicationActivationPolicyAccessory)

style = Cocoa::NSWindowStyleMaskTitled | Cocoa::NSWindowStyleMaskClosable
window = Cocoa::NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
  [0, 0, 560, 340], style, Cocoa::NSBackingStoreBuffered, false
)
window.setTitle('Ruby + Cocoa')

content = window.contentView

def label(frame, text, size, alpha = 1.0)
  field = Cocoa::NSTextField.alloc.initWithFrame(frame)
  field.setStringValue(text)
  field.setEditable(false)
  field.setSelectable(false)
  field.setBezeled(false)
  field.setDrawsBackground(false)
  field.setFont(Cocoa::NSFont.systemFontOfSize(size))
  field.setTextColor(Cocoa::NSColor.labelColor.colorWithAlphaComponent(alpha))
  field
end

content.addSubview label([40, 250, 480, 44], 'Hello from Ruby', 34)
content.addSubview label([40, 221, 480, 22],
                         "CRuby #{RUBY_VERSION} - libffi - #{RUBY_PLATFORM}", 13, 0.6)

# Foundation enumerating an NSArray, calling a Ruby block for each element.
words = Cocoa::NSArray.arrayWithArray(%w[blocks delegates target/action])
collected = []
words.enumerateObjectsUsingBlock { |word, index, _stop| collected << "#{index + 1}. #{word}" }

content.addSubview label([40, 178, 480, 22],
                         "NSArray enumerated by a Ruby block: #{collected.join('  ')}",
                         12, 0.6)

content.addSubview label([40, 128, 480, 24],
                         'The button below runs a Ruby block.', 14)

button = Cocoa::NSButton.alloc.initWithFrame([40, 60, 160, 32])
button.setTitle('Click me')
button.setBezelStyle(Cocoa::NSBezelStyleRounded)
Cocoa.on_action(button) { |_sender| }
content.addSubview(button)

quit = Cocoa::NSButton.alloc.initWithFrame([210, 60, 160, 32])
quit.setTitle('Quit')
quit.setBezelStyle(Cocoa::NSBezelStyleRounded)
Cocoa.on_action(quit) { |_sender| }
content.addSubview(quit)

# Draw the live view hierarchy into a bitmap, then encode it as PNG.
bounds = content.bounds
rep = content.bitmapImageRepForCachingDisplayInRect(bounds)
content.cacheDisplayInRect_toBitmapImageRep(bounds, rep)

png = rep.representationUsingType_properties(Cocoa::NSBitmapImageFileTypePNG, {})
ok  = png.writeToFile_atomically(out, true)

puts "bounds     : #{bounds.inspect}"
puts "bitmap rep : #{rep.pixelsWide}x#{rep.pixelsHigh}"
puts "png bytes  : #{png.length}"
puts "wrote #{out}: #{ok.inspect}"
