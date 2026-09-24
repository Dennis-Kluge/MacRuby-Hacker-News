#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Wrap the reader in a real .app bundle.
#
#   rake app                              (or)
#   ruby tools/build_app.rb [output directory]
#
# The bundle's executable is a launcher that execs Ruby. That leaves
# NSBundle.mainBundle pointing at Ruby's own directory -- but LaunchServices
# still identifies the process by the bundle it was launched from, which is
# what the Dock reads for the name and icon. The launcher exports the bundle
# path so the app can find its own resources regardless.

require 'fileutils'

$LOAD_PATH.unshift File.expand_path('../cocoa/lib', __dir__)
require 'cocoa'
Cocoa.framework 'AppKit'

require_relative '../lib/hackernews/app_icon'

module HackerNews
  class BundleBuilder
    APP_NAME   = 'Hacker News'
    IDENTIFIER = 'org.example.hackernews'
    VERSION    = '1.0'

    # The sizes macOS wants in an iconset, as [file suffix, pixel size].
    ICON_SIZES = [
      ['16x16', 16], ['16x16@2x', 32],
      ['32x32', 32], ['32x32@2x', 64],
      ['128x128', 128], ['128x128@2x', 256],
      ['256x256', 256], ['256x256@2x', 512],
      ['512x512', 512], ['512x512@2x', 1024]
    ].freeze

    def initialize(root:, output:)
      @root   = root
      @bundle = File.join(output, "#{APP_NAME}.app")
    end

    attr_reader :bundle

    def build
      FileUtils.rm_rf(@bundle)
      %w[Contents/MacOS Contents/Resources].each do |path|
        FileUtils.mkdir_p(File.join(@bundle, path))
      end

      write_info_plist
      copy_sources
      write_icon
      write_launcher
      @bundle
    end

    private

    def contents(*parts)
      File.join(@bundle, 'Contents', *parts)
    end

    def write_info_plist
      File.write(contents('Info.plist'), <<~PLIST)
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleName</key><string>#{APP_NAME}</string>
          <key>CFBundleDisplayName</key><string>#{APP_NAME}</string>
          <key>CFBundleIdentifier</key><string>#{IDENTIFIER}</string>
          <key>CFBundleExecutable</key><string>#{APP_NAME}</string>
          <key>CFBundleIconFile</key><string>AppIcon</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>#{VERSION}</string>
          <key>CFBundleVersion</key><string>#{VERSION}</string>
          <key>LSMinimumSystemVersion</key><string>12.0</string>
          <key>NSHighResolutionCapable</key><true/>
          <key>NSHumanReadableCopyright</key><string>A Hacker News reader built on the Cocoa bridge.</string>
        </dict>
        </plist>
      PLIST
    end

    # A self-contained copy, so the bundle keeps working if the checkout
    # moves.
    #
    # The application and the bridge it is built on are separate subtrees in
    # the repository; in the bundle they are installed side by side on one
    # load path, which is all the launcher then has to know about either.
    def copy_sources
      lib = contents('Resources', 'lib')
      FileUtils.mkdir_p(lib)
      FileUtils.cp_r(Dir[File.join(@root, 'lib', '*')], lib)
      FileUtils.cp_r(Dir[File.join(@root, 'cocoa', 'lib', '*')], lib)

      FileUtils.mkdir_p(contents('Resources', 'bin'))
      FileUtils.cp(File.join(@root, 'bin', 'hackernews'), contents('Resources', 'bin'))
    end

    # Render the icon at every size macOS asks for, then let iconutil pack it.
    def write_icon
      iconset = contents('Resources', 'AppIcon.iconset')
      FileUtils.mkdir_p(iconset)

      ICON_SIZES.each do |suffix, pixels|
        AppIcon.write_png(File.join(iconset, "icon_#{suffix}.png"), pixels.to_f)
      end

      ok = system('iconutil', '-c', 'icns', iconset,
                  '-o', contents('Resources', 'AppIcon.icns'))
      raise 'iconutil failed' unless ok

      FileUtils.rm_rf(iconset)
    end

    def write_launcher
      launcher = contents('MacOS', APP_NAME)
      File.write(launcher, <<~SH)
        #!/bin/sh
        # Resolve the bundle from this script's location, then hand over to Ruby.
        BUNDLE="$(cd "$(dirname "$0")/../.." && pwd)"
        RESOURCES="$BUNDLE/Contents/Resources"

        # NSBundle.mainBundle will point at Ruby after the exec, so the app is
        # told where its own bundle is.
        export HN_BUNDLE_PATH="$BUNDLE"

        exec "#{RbConfig.ruby}" -I"$RESOURCES/lib" "$RESOURCES/bin/hackernews"
      SH
      FileUtils.chmod(0o755, launcher)
    end
  end
end

# Only build when run directly: the tests load this file for the class alone.
if $PROGRAM_NAME == __FILE__
  root   = File.expand_path('..', __dir__)
  output = ARGV[0] || File.join(root, 'build')
  FileUtils.mkdir_p(output)

  bundle = HackerNews::BundleBuilder.new(root: root, output: output).build
  puts "built #{bundle}"
  puts "  ruby: #{RbConfig.ruby}"
end
