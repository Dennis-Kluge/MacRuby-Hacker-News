# frozen_string_literal: true

# The .app bundle: what LaunchServices reads to give the app a Dock identity.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../cocoa/lib', __dir__)
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'cocoa'
require 'cocoa/pooled_tests'

Cocoa.framework 'AppKit'
require_relative '../lib/hackernews/app_icon'
load File.expand_path('../tools/build_app.rb', __dir__) unless defined?(HackerNews::BundleBuilder)

class TestAppBundle < Minitest::Test
  def self.bundle
    @bundle ||= begin
      @dir = Dir.mktmpdir('hn-bundle')
      HackerNews::BundleBuilder.new(
        root: File.expand_path('..', __dir__), output: @dir
      ).build
    end
  end

  def self.cleanup
    FileUtils.rm_rf(@dir) if @dir
  end

  Minitest.after_run { cleanup }

  def bundle
    self.class.bundle
  end

  def plist
    File.read(File.join(bundle, 'Contents', 'Info.plist'))
  end

  def test_it_builds_the_expected_shape
    assert File.directory?(bundle)
    assert File.file?(File.join(bundle, 'Contents', 'Info.plist'))
    assert File.file?(File.join(bundle, 'Contents', 'MacOS', 'Hacker News'))
    assert File.file?(File.join(bundle, 'Contents', 'Resources', 'AppIcon.icns'))
  end

  # These are the keys LaunchServices reads for the name and the icon.
  def test_the_plist_identifies_the_app
    assert_match(%r{<key>CFBundleName</key><string>Hacker News</string>}, plist)
    assert_match(%r{<key>CFBundleIdentifier</key><string>org\.example\.hackernews</string>}, plist)
    assert_match(%r{<key>CFBundleExecutable</key><string>Hacker News</string>}, plist)
    assert_match(%r{<key>CFBundleIconFile</key><string>AppIcon</string>}, plist)
    assert_match(%r{<key>NSHighResolutionCapable</key><true/>}, plist)
  end

  def test_the_plist_is_valid
    assert system('plutil', '-lint', File.join(bundle, 'Contents', 'Info.plist'),
                  out: File::NULL), 'Info.plist did not lint'
  end

  def test_the_launcher_is_executable_and_hands_over_to_ruby
    launcher = File.join(bundle, 'Contents', 'MacOS', 'Hacker News')
    assert File.executable?(launcher)

    script = File.read(launcher)
    assert_match(/exec /, script)
    assert_match(%r{bin/hackernews}, script)
    # NSBundle.mainBundle points at Ruby after the exec, so the app is told
    # where its own bundle is.
    assert_match(/HN_BUNDLE_PATH/, script)
  end

  def test_the_icon_carries_every_size_macos_asks_for
    icns = File.join(bundle, 'Contents', 'Resources', 'AppIcon.icns')
    assert_operator File.size(icns), :>, 50_000

    image = Cocoa::NSImage.alloc.initWithContentsOfFile(icns)
    refute_nil image
    assert_operator image.representations.count, :>=, 5
  end

  # The bundle carries its own copy, so moving the checkout does not break it.
  def test_it_is_self_contained
    resources = File.join(bundle, 'Contents', 'Resources')
    assert File.file?(File.join(resources, 'bin', 'hackernews'))
    # The application and the bridge land on one load path inside the bundle.
    assert File.file?(File.join(resources, 'lib', 'hackernews.rb'))
    assert File.file?(File.join(resources, 'lib', 'hackernews', 'app.rb'))
    assert File.file?(File.join(resources, 'lib', 'cocoa.rb'))
    assert File.file?(File.join(resources, 'lib', 'cocoa', 'objc_ext.bundle'))
  end
end
