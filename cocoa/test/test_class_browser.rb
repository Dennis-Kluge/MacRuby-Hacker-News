# frozen_string_literal: true

# Drive the class browser example without an event loop, to check that a real
# application's moving parts work: an NSTableView data source and delegate
# implemented in Ruby, target/action filtering, and menu construction.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'tmpdir'
require 'cocoa'
require 'cocoa/pooled_tests'

CLASS_BROWSER_NO_MAIN = true
require_relative '../examples/class_browser'

class TestClassBrowser < Minitest::Test
  # The data source class is registered with the Objective-C runtime by name,
  # so all tests share one browser rather than redefining its methods.
  def self.browser
    @browser ||= ClassBrowser.new
  end

  def browser
    self.class.browser
  end

  def setup
    browser.filter('')
    browser.filter_methods('')
  end

  def test_it_builds_without_an_event_loop
    refute_nil browser
    assert_operator browser.classes.size, :>, 1_000
  end

  # AppKit asking a Ruby object how many rows to draw.
  def test_table_view_asks_ruby_for_its_row_count
    source = browser.instance_variable_get(:@source)
    table  = browser.instance_variable_get(:@class_table)

    rows = source.objc_send('numberOfRowsInTableView:', table)
    assert_equal browser.classes.size, rows
  end

  # AppKit asking a Ruby object for a cell value.
  def test_table_view_asks_ruby_for_cell_values
    source = browser.instance_variable_get(:@source)
    table  = browser.instance_variable_get(:@class_table)

    value = source.objc_send('tableView:objectValueForTableColumn:row:', table, nil, 0)
    assert_equal browser.classes.first, value.to_s
  end

  def test_out_of_range_rows_do_not_crash
    source = browser.instance_variable_get(:@source)
    table  = browser.instance_variable_get(:@method_table)

    value = source.objc_send('tableView:objectValueForTableColumn:row:', table, nil, 99_999)
    assert_equal '', value.to_s
  end

  def test_filtering_narrows_the_class_list
    all = browser.classes.size
    browser.filter('nswindow')

    assert_operator browser.classes.size, :<, all
    assert_includes browser.classes, 'NSWindow'
    assert(browser.classes.all? { |c| c.downcase.include?('nswindow') })
  end

  def test_selecting_a_class_populates_its_methods
    browser.filter('nswindow')
    assert browser.select_class('NSWindow')

    assert_operator browser.methods.size, :>, 100
    assert_includes browser.methods, '-setTitle:'
    assert(browser.methods.any? { |m| m.start_with?('+') }, 'expected class methods too')
  end

  def test_method_filter_narrows_the_method_list
    browser.filter('nswindow')
    browser.select_class('NSWindow')
    all = browser.methods.size

    browser.filter_methods('settitle')
    assert_operator browser.methods.size, :<, all
    assert_includes browser.methods, '-setTitle:'
  end

  def test_selecting_a_method_decodes_its_encoding
    browser.filter('nswindow')
    browser.select_class('NSWindow')
    browser.filter_methods('settitle')
    assert browser.select_method('setTitle:')

    detail = browser.detail_text
    assert_match(/-setTitle:/, detail)
    assert_match(/v24@0:8@16/, detail)
    assert_match(/void method\(id self, SEL _cmd, id\)/, detail)
  end

  def test_class_detail_shows_the_superclass_chain
    browser.filter('nsbutton')
    browser.select_class('NSButton')

    detail = browser.detail_text
    assert_match(/NSButton/, detail)
    assert_match(/NSControl -> NSView/, detail)
    assert_match(/NSObject/, detail)
  end

  def test_a_class_with_a_struct_returning_method_decodes
    browser.filter('nsview')
    browser.select_class('NSView')
    browser.filter_methods('frame')
    assert browser.select_method('frame')

    assert_match(/CGRect method/, browser.detail_text)
  end

  def test_the_data_source_conforms_to_the_protocols_it_claims
    source = browser.instance_variable_get(:@source)
    klass  = ObjC.class_named('CBTableSource')

    assert ObjC.conforms?(klass, 'NSTableViewDataSource')
    assert ObjC.conforms?(klass, 'NSTableViewDelegate')
    assert source.objc_responds_to?('numberOfRowsInTableView:')
    assert source.objc_responds_to?('tableViewSelectionDidChange:')
  end

  def test_the_menu_was_built
    app  = Cocoa::NSApplication.sharedApplication
    menu = app.mainMenu
    refute_nil menu
    assert_operator menu.numberOfItems, :>, 0

    quit = menu.itemAtIndex(0).submenu.itemAtIndex(0)
    assert_equal 'Quit', quit.title.to_s
  end

  def test_it_renders_to_a_png
    path = File.join(Dir.tmpdir, 'cocoa_browser_test.png')
    File.delete(path) if File.exist?(path)

    browser.filter('nswindow')
    browser.select_class('NSWindow')
    browser.render_to(path)

    assert File.exist?(path)
    assert_operator File.size(path), :>, 10_000
  ensure
    File.delete(path) if path && File.exist?(path)
  end
end
