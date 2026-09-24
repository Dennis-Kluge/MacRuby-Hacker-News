#!/usr/bin/env ruby
# frozen_string_literal: true
#
# A Cocoa class browser, written in Ruby, browsing the Objective-C runtime it
# is itself running on.
#
#   ruby -Ilib examples/class_browser.rb
#
# Exercises the parts of the bridge a real application needs: NSTableView data
# sources and delegates implemented as Ruby blocks, target/action, menus,
# autoresizing, and live filtering across ~20,000 classes.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'cocoa'

Cocoa.framework 'AppKit'

class ClassBrowser
  WIDTH  = 940
  HEIGHT = 580
  MARGIN = 16

  # Autoresizing masks (AppKit constants, resolved from BridgeSupport).
  WIDTH_SIZABLE  = Cocoa::NSViewWidthSizable
  HEIGHT_SIZABLE = Cocoa::NSViewHeightSizable
  MIN_Y_MARGIN   = Cocoa::NSViewMinYMargin
  MAX_Y_MARGIN   = Cocoa::NSViewMaxYMargin
  MAX_X_MARGIN   = Cocoa::NSViewMaxXMargin

  def initialize
    @all_classes  = ObjC.class_names.sort
    @classes      = @all_classes
    @methods       = []
    @all_methods   = []
    @filter        = ''
    @method_filter = ''

    @app = Cocoa::NSApplication.sharedApplication
    @app.setActivationPolicy(Cocoa::NSApplicationActivationPolicyRegular)

    build_menu
    build_window
    build_views
    install_data_source

    reload
  end

  def run
    @window.makeKeyAndOrderFront(nil)
    @app.activateIgnoringOtherApps(true)

    # Ruby processes signals between VM instructions, and inside [NSApp run]
    # the VM never gets a turn, so Ctrl-C and SIGTERM cannot stop the app.
    # Cmd-Q works; this timer exists so scripted runs can exit too.
    if (seconds = ENV['CLASS_BROWSER_TIMEOUT'])
      Cocoa::NSTimer.scheduledTimerWithTimeInterval_repeats_block(seconds.to_f, false) do |_t|
        @app.terminate(nil)
      end
    end

    @app.run
  end

  # Render the window's content to a PNG without entering the event loop, so
  # the layout can be checked headlessly.
  def render_to(path)
    view = @window.contentView
    # Without an event loop nothing has laid out or drawn yet, so the header
    # views of scrolled tables would capture stale content.
    view.layoutSubtreeIfNeeded
    # Scrolling a table offscreen leaves its header view stale, so force a
    # full redraw rather than only the parts marked dirty.
    [@class_scroll, @method_scroll].each do |scroll|
      # Re-tile so the header view follows the clip view's scrolled origin,
      # which a real event loop would otherwise have done for us.
      scroll.reflectScrolledClipView(scroll.contentView)
      scroll.tile
    end
    [@class_table, @method_table].each do |t|
      t.setNeedsDisplay(true)
      t.headerView&.setNeedsDisplay(true)
    end
    @window.display
    bounds = view.bounds
    rep    = view.bitmapImageRepForCachingDisplayInRect(bounds)
    view.cacheDisplayInRect_toBitmapImageRep(bounds, rep)
    data = rep.representationUsingType_properties(Cocoa::NSBitmapImageFileTypePNG, {})
    data.writeToFile_atomically(path, true)
  end

  private

  # ---- construction --------------------------------------------------------

  def build_menu
    menubar  = Cocoa::NSMenu.alloc.init
    app_item = Cocoa::NSMenuItem.alloc.init
    menubar.addItem(app_item)

    app_menu = Cocoa::NSMenu.alloc.init
    app_menu.addItem(
      Cocoa::NSMenuItem.alloc.initWithTitle_action_keyEquivalent('Quit', 'terminate:', 'q')
    )
    app_item.setSubmenu(app_menu)

    @app.setMainMenu(menubar)
  end

  def build_window
    style = Cocoa::NSWindowStyleMaskTitled |
            Cocoa::NSWindowStyleMaskClosable |
            Cocoa::NSWindowStyleMaskMiniaturizable |
            Cocoa::NSWindowStyleMaskResizable

    @window = Cocoa::NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
      [0, 0, WIDTH, HEIGHT], style, Cocoa::NSBackingStoreBuffered, false
    )
    @window.setTitle('Objective-C Class Browser')
    @window.setMinSize([640, 400])
    @window.center
  end

  def build_views
    content = @window.contentView

    search_h  = 24
    detail_h  = 96
    tables_y  = MARGIN + detail_h + MARGIN
    tables_h  = HEIGHT - tables_y - search_h - (MARGIN * 2)
    left_w    = 320
    right_x   = MARGIN + left_w + 12
    right_w   = WIDTH - right_x - MARGIN

    search_y = HEIGHT - MARGIN - search_h

    @search = Cocoa::NSSearchField.alloc.initWithFrame([MARGIN, search_y, left_w, search_h])
    @search.setPlaceholderString('Filter classes')
    @search.setAutoresizingMask(MIN_Y_MARGIN | MAX_X_MARGIN)
    Cocoa.on_action(@search) { |field| apply_filter(field.stringValue.to_s) }
    content.addSubview(@search)

    @method_search = Cocoa::NSSearchField.alloc.initWithFrame(
      [right_x, search_y, right_w, search_h]
    )
    @method_search.setPlaceholderString('Filter methods')
    @method_search.setAutoresizingMask(WIDTH_SIZABLE | MIN_Y_MARGIN)
    Cocoa.on_action(@method_search) { |field| apply_method_filter(field.stringValue.to_s) }
    content.addSubview(@method_search)

    @class_scroll, @class_table =
      table([MARGIN, tables_y, left_w, tables_h], 'Class',
            HEIGHT_SIZABLE | MAX_X_MARGIN)
    content.addSubview(@class_scroll)

    @method_scroll, @method_table =
      table([right_x, tables_y, right_w, tables_h], 'Method',
            WIDTH_SIZABLE | HEIGHT_SIZABLE)
    content.addSubview(@method_scroll)

    @detail = Cocoa::NSTextField.alloc.initWithFrame(
      [MARGIN, MARGIN, WIDTH - (MARGIN * 2), detail_h]
    )
    @detail.setEditable(false)
    @detail.setBezeled(true)
    @detail.setDrawsBackground(true)
    @detail.setFont(Cocoa::NSFont.userFixedPitchFontOfSize(11))
    @detail.cell.setWraps(true)
    @detail.setUsesSingleLineMode(false)
    @detail.setAutoresizingMask(WIDTH_SIZABLE | MAX_Y_MARGIN)
    @detail.setStringValue("#{@all_classes.size} classes registered in this process.")
    content.addSubview(@detail)
  end

  def table(frame, title, mask)
    scroll = Cocoa::NSScrollView.alloc.initWithFrame(frame)
    scroll.setHasVerticalScroller(true)
    scroll.setBorderType(Cocoa::NSBezelBorder)
    scroll.setAutoresizingMask(mask)

    view = Cocoa::NSTableView.alloc.initWithFrame(frame)
    view.setUsesAlternatingRowBackgroundColors(true)
    view.setRowHeight(17)

    column = Cocoa::NSTableColumn.alloc.initWithIdentifier('value')
    column.setWidth(frame[2] - 24)
    column.headerCell.setStringValue(title)
    view.addTableColumn(column)

    scroll.setDocumentView(view)
    [scroll, view]
  end

  # ---- the data source, implemented in Ruby --------------------------------

  def install_data_source
    browser = self

    klass = Cocoa.define_class(
      'CBTableSource', 'NSObject',
      protocols: %w[NSTableViewDataSource NSTableViewDelegate]
    ) do |c|
      c.define('numberOfRowsInTableView:', 'q@:@') do |_self, table|
        browser.row_count(table)
      end

      c.define('tableView:objectValueForTableColumn:row:', '@@:@@q') do |_self, table, _col, row|
        browser.value_at(table, row)
      end

      c.define('tableViewSelectionDidChange:', 'v@:@') do |_self, notification|
        browser.selection_changed(notification.object)
      end
    end

    # Tables hold their data source weakly, so this must stay reachable.
    @source = klass.alloc.init

    [@class_table, @method_table].each do |view|
      view.setDataSource(@source)
      view.setDelegate(@source)
    end
  end

  # ---- callbacks (public: invoked from the data source blocks) -------------

  public

  # Drive the UI programmatically, so the browser can be exercised (and
  # screenshotted) without a running event loop.
  def select_class(name)
    index = @classes.index(name)
    return false unless index

    @class_table.selectRowIndexes_byExtendingSelection(
      Cocoa::NSIndexSet.indexSetWithIndex(index), false
    )
    selection_changed(@class_table)
    true
  end

  def select_method(matching)
    # Prefer an exact selector match; NSWindow has private methods whose names
    # merely contain the one being asked for.
    index = @methods.index { |m| m[1..] == matching } ||
            @methods.index { |m| m.include?(matching) }
    return false unless index

    @method_table.selectRowIndexes_byExtendingSelection(
      Cocoa::NSIndexSet.indexSetWithIndex(index), false
    )
    selection_changed(@method_table)
    true
  end

  def filter(text)
    @search.setStringValue(text)
    apply_filter(text)
  end

  def filter_methods(text)
    @method_search.setStringValue(text)
    apply_method_filter(text)
  end

  attr_reader :classes, :methods

  def detail_text
    @detail.stringValue.to_s
  end

  def row_count(table)
    same?(table, @class_table) ? @classes.size : @methods.size
  end

  def value_at(table, row)
    list = same?(table, @class_table) ? @classes : @methods
    list[row] || ''
  end

  def selection_changed(table)
    if same?(table, @class_table)
      row = @class_table.selectedRow
      @selected     = row >= 0 ? @classes[row] : nil
      @all_methods  = @selected ? methods_for(@selected) : []
      @methods      = filtered_methods
      @method_table.reloadData
      @method_table.deselectAll(nil)
      describe_class
    else
      describe_method
    end
  end

  private

  def same?(table, other)
    !table.nil? && table.objc_address == other.objc_address
  end

  def methods_for(class_name)
    klass = ObjC.class_named(class_name)
    return [] unless klass

    instance = ObjC.method_names(klass, false).map { |m| "-#{m}" }
    klass_m  = ObjC.method_names(klass, true).map  { |m| "+#{m}" }
    (klass_m.sort + instance.sort)
  end

  def describe_class
    return @detail.setStringValue('') unless @selected

    klass = ObjC.class_named(@selected)
    chain = []
    probe = klass
    while probe
      chain << probe.name
      probe = probe.superclass_name ? ObjC.class_named(probe.superclass_name) : nil
    end

    @detail.setStringValue(
      "#{@selected}\n" \
      "#{@all_methods.size} methods\n" \
      "#{chain.join(' -> ')}"
    )
  end

  def describe_method
    row = @method_table.selectedRow
    return if row.negative? || @selected.nil?

    entry     = @methods[row]
    class_sel = entry[0]
    selector  = entry[1..]
    klass     = ObjC.class_named(@selected)
    encoding  = ObjC.method_encoding(klass, selector, class_sel == '+')

    @detail.setStringValue(
      "#{entry}\n" \
      "encoding: #{encoding || '(unavailable)'}\n" \
      "#{encoding ? Cocoa.describe_encoding(encoding) : ''}"
    )
  end

  def filtered_methods
    return @all_methods.to_a if @method_filter.to_s.empty?

    @all_methods.to_a.select { |m| m.downcase.include?(@method_filter) }
  end

  def apply_method_filter(text)
    @method_filter = text.strip.downcase
    @methods = filtered_methods
    @method_table.reloadData
    @method_table.deselectAll(nil)
  end

  def apply_filter(text)
    @filter  = text.strip.downcase
    @classes = if @filter.empty?
                 @all_classes
               else
                 @all_classes.select { |n| n.downcase.include?(@filter) }
               end
    reload
  end

  def reload
    @class_table.reloadData
    @detail.setStringValue("#{@classes.size} of #{@all_classes.size} classes")
  end
end

return if defined?(CLASS_BROWSER_NO_MAIN)

browser = ClassBrowser.new

if (out = ENV['CLASS_BROWSER_RENDER'])
  browser.filter(ENV['CLASS_BROWSER_FILTER']) if ENV['CLASS_BROWSER_FILTER']
  browser.select_class(ENV['CLASS_BROWSER_SELECT']) if ENV['CLASS_BROWSER_SELECT']
  browser.filter_methods(ENV['CLASS_BROWSER_MFILTER']) if ENV['CLASS_BROWSER_MFILTER']
  browser.select_method(ENV['CLASS_BROWSER_METHOD']) if ENV['CLASS_BROWSER_METHOD']
  browser.render_to(out)
  puts "rendered #{out}"
else
  browser.run
end
