#!/usr/bin/env ruby
# frozen_string_literal: true
#
# A native Cocoa window driven entirely by Ruby blocks, on stock CRuby.
#
#   ruby -Ilib examples/hello_window.rb
#
# Set COCOA_DEMO_TIMEOUT=<seconds> to have the app close itself.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'cocoa'

Cocoa.framework 'AppKit'

app = Cocoa::NSApplication.sharedApplication
app.setActivationPolicy(Cocoa::NSApplicationActivationPolicyRegular)

style = Cocoa::NSWindowStyleMaskTitled |
        Cocoa::NSWindowStyleMaskClosable |
        Cocoa::NSWindowStyleMaskMiniaturizable |
        Cocoa::NSWindowStyleMaskResizable

window = Cocoa::NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
  [0, 0, 560, 340], style, Cocoa::NSBackingStoreBuffered, false
)
window.setTitle('Ruby + Cocoa')
window.center

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
# The block's signature comes from the metadata Apple ships with the framework.
words = Cocoa::NSArray.arrayWithArray(%w[blocks delegates target/action])
collected = []
words.enumerateObjectsUsingBlock { |word, index, _stop| collected << "#{index + 1}. #{word}" }

content.addSubview label([40, 178, 480, 22],
                         "NSArray enumerated by a Ruby block: #{collected.join('  ')}",
                         12, 0.6)

status = label([40, 128, 480, 24], 'The button below runs a Ruby block.', 14)
content.addSubview status

clicks = 0
button = Cocoa::NSButton.alloc.initWithFrame([40, 60, 160, 32])
button.setTitle('Click me')
button.setBezelStyle(Cocoa::NSBezelStyleRounded)
Cocoa.on_action(button) do |_sender|
  clicks += 1
  status.setStringValue("Clicked #{clicks} time#{'s' unless clicks == 1} - from Ruby.")
end
content.addSubview(button)

quit = Cocoa::NSButton.alloc.initWithFrame([210, 60, 160, 32])
quit.setTitle('Quit')
quit.setBezelStyle(Cocoa::NSBezelStyleRounded)
Cocoa.on_action(quit) { |_sender| app.terminate(nil) }
content.addSubview(quit)

window.makeKeyAndOrderFront(nil)
app.activateIgnoringOtherApps(true)

# Self-termination via NSTimer's block-based API.
if (timeout = ENV['COCOA_DEMO_TIMEOUT'])
  Cocoa::NSTimer.scheduledTimerWithTimeInterval_repeats_block(timeout.to_f, false) do |_timer|
    app.terminate(nil)
  end
  $stderr.puts "[demo] will quit in #{timeout}s"
end

# Lets the test suite capture this exact window by its CGWindowID.
if (path = ENV['COCOA_DEMO_WINDOWFILE'])
  File.write(path, window.windowNumber.to_s)
end

$stderr.puts "[demo] window visible: #{window.isVisible.inspect}"
app.run
