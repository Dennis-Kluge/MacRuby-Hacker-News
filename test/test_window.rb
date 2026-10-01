# frozen_string_literal: true

# The window, its chrome, and how both behave when resized.
#
# The API is stubbed, so these are fast and deterministic; the live network
# path is exercised separately by setting HN_LIVE=1.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../cocoa/lib', __dir__)
require 'minitest/autorun'
require 'time'
require 'tmpdir'
require 'fileutils'
require 'cocoa'
require 'cocoa/pooled_tests'
require_relative 'support/stores'
require_relative 'support/app_harness'

require 'hackernews'
require_relative 'support/test_support'

module HackerNews
  # Stands in for API, answering immediately from canned data.
  class StubAPI
    attr_accessor :stories, :tree, :error

    def initialize
      @stories = []
      @tree    = { 'children' => [] }
      @error   = nil
    end

    # Pages of canned stories; by default a single page with no more after it.
    attr_accessor :pages

    def front_page(_limit = 30, &block)
      block.call(@error ? nil : @stories, @error)
    end

    # Records what it was asked for, so paging preferences can be asserted.
    attr_reader :last_request

    # Canned answers to searches, keyed by the text searched for; anything not
    # listed finds nothing, which is what makes the empty state testable.
    attr_accessor :search_results

    def stories(page = 0, per_page = 30, query: HackerNews::Query.new, &block)
      @last_request = { page: page, per_page: per_page, query: query, section: query.section }
      return block.call(nil, false, @error) if @error
      return block.call(results_for(query), false, nil) if query.search?

      list = @pages ? (@pages[page] || []) : (page.zero? ? @stories : [])
      more = @pages ? page < @pages.size - 1 : false
      block.call(list, more, nil)
    end

    def results_for(query)
      (@search_results || {})[query.text] || []
    end

    def item(_id, &block)
      block.call(@error ? nil : @tree, @error)
    end
  end
end

class TestHackerNewsChrome < Minitest::Test
  include HackerNews::AppHarness

  # Several classes below read this app rather than building another, so its
  # stub carries a story and a comment with a link in it.
  def self.stub
    @stub ||= HackerNews::StubAPI.new.tap do |api|
      api.stories = [{ id: '1', title: 'A story', author: 'a', points: 1,
                       comments: 1, url: 'https://a' }]
      api.tree = {
        'children' => [
          { 'id' => 60, 'author' => 'linky',
            'text' => 'read <a href="https:&#x2F;&#x2F;example.com&#x2F;doc">the docs</a> please',
            'created_at' => Time.now.iso8601, 'children' => [] }
        ]
      }
    end
  end

  def test_the_window_uses_a_split_view_controller
    controller = window.contentViewController
    assert_equal 'NSSplitViewController', controller.objc_class_name
    # Stories, their comments, and the page a story links to.
    assert_equal 3, controller.splitViewItems.count
  end

  # The comments are the point of the window; they do not give way to the
  # columns on either side of them.
  # Stories, then the page they link to, then the comments.
  def test_the_comments_column_cannot_be_squeezed_away
    content = window.contentViewController.splitViewItems.objectAtIndex(2)
    assert_equal HackerNews::MainWindow::CONTENT_MIN, content.minimumThickness
  end

  def test_the_columns_are_in_reading_order
    items = window.contentViewController.splitViewItems
    panes = (0...items.count).map { |i| items.objectAtIndex(i).viewController.view.objc_address }

    assert_equal [app.story_view.pane.objc_address,
                  app.article_pane.pane.objc_address,
                  app.thread_view.pane.objc_address], panes
  end

  def test_the_first_item_is_a_real_sidebar
    sidebar = window.contentViewController.splitViewItems.objectAtIndex(0)
    assert_equal true, sidebar.canCollapse
    # NSSplitViewItemBehaviorSidebar == 1
    assert_equal 1, sidebar.behavior
  end

  def test_there_is_a_unified_toolbar
    toolbar = window.toolbar
    refute_nil toolbar
    assert_equal Cocoa::NSWindowToolbarStyleUnified, window.toolbarStyle

    identifiers = app.toolbar.identifiers
    assert_includes identifiers, HackerNews::App::SECTION_ITEM
    assert_includes identifiers, HackerNews::App::SEARCH_ITEM
    assert_includes identifiers, HackerNews::App::HN_ITEM
    assert_includes identifiers, HackerNews::App::SHARE_ITEM

    # Each of these had a button that said what a shortcut, a double-click or
    # the status line already said.
    refute_includes identifiers, 'hn.open'
    refute_includes identifiers, 'hn.spinner'
    refute_includes identifiers, 'hn.reload'
  end

  def test_toolbar_items_carry_sf_symbols
    item = app.toolbar.item(HackerNews::App::HN_ITEM)
    refute_nil item
    assert_equal 'Discussion', item.label.to_s
    refute_nil item.image
  end

  # The status line lives under the story list now: in a unified toolbar the
  # subtitle sat beside the controls and was truncated by them.
  def test_status_goes_under_the_story_list
    app.load_front_page
    assert_equal app.status_text, app.story_view.status
    assert_match(/1 story/, app.story_view.status)
  end

  def test_lists_use_the_modern_table_styles
    stories  = app.story_view.view
    comments = app.thread_view.view

    assert_equal Cocoa::NSTableViewStyleSourceList, stories.style
    assert_equal Cocoa::NSTableViewStyleInset, comments.style
    # NSNoBorder == 0
    assert_equal 0, stories.enclosingScrollView.borderType
    assert_equal 0, comments.enclosingScrollView.borderType
  end

  # View-based rows are what make text selectable and links clickable.
  def test_rows_are_real_text_fields
    app.load_front_page
    table = app.story_view.view
    view  = app.story_view.row_view(0)

    assert_equal 'NSTextField', view.objc_class_name
    assert_match(/A story/, view.attributedStringValue.string.to_s)
  end

  def test_comment_rows_are_selectable_but_story_rows_are_not
    app.load_front_page
    app.select_story(0)

    story   = app.story_view.row_view(0)
    comment = app.thread_view.row_view(Cocoa::NSNumber.numberWithLongLong(60))

    assert_equal false, story.isSelectable
    assert_equal true,  comment.isSelectable
    assert_equal true,  comment.allowsEditingTextAttributes
  end

  def test_links_are_applied_to_comment_text
    app.load_front_page
    app.select_story(0)

    attributed = app.thread_view.cell(Cocoa::NSNumber.numberWithLongLong(60))
    urls = (0...attributed.length).map do |i|
      attributed.attribute_atIndex_effectiveRange(Cocoa::NSLinkAttributeName, i, nil)&.to_s
    end.compact.uniq

    assert_equal ['https://example.com/doc'], urls
  end
end

# A native app has a full menu bar, not one nameless menu.

class TestHackerNewsMenus < Minitest::Test
  def setup
    HackerNews::App.claim_app_identity
    @app ||= TestHackerNewsChrome.app
  end

  def main_menu
    Cocoa::NSApplication.sharedApplication.mainMenu
  end

  def titles_of(menu_name)
    index = (0...main_menu.numberOfItems).find do |i|
      main_menu.itemAtIndex(i).title.to_s == menu_name
    end
    return [] if index.nil?

    menu = main_menu.itemAtIndex(index).submenu
    (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i).title.to_s }
  end

  def test_the_standard_menus_are_present
    top = (0...main_menu.numberOfItems).map { |i| main_menu.itemAtIndex(i).title.to_s }
    assert_equal ['Hacker News', 'File', 'Edit', 'View', 'Window', 'Help'], top
  end

  def test_the_application_menu_follows_the_convention
    titles = titles_of('Hacker News')
    assert_includes titles, 'About Hacker News'
    assert_includes titles, 'Services'
    assert_includes titles, 'Hide Hacker News'
    assert_includes titles, 'Hide Others'
    assert_includes titles, 'Quit Hacker News'
  end

  # Comment text is selectable, so Copy and Select All have real work to do.
  # A nil target is what lets them travel the responder chain.
  def test_edit_menu_items_use_the_responder_chain
    index = (0...main_menu.numberOfItems).find { |i| main_menu.itemAtIndex(i).title.to_s == 'Edit' }
    menu  = main_menu.itemAtIndex(index).submenu

    copy = (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i) }
                                   .find { |i| i.title.to_s == 'Copy' }
    refute_nil copy
    assert_nil copy.target
    assert_equal 'copy:', copy.action.to_s
    assert_equal 'c', copy.keyEquivalent.to_s
  end

  def test_view_menu_can_toggle_the_sidebar
    assert_includes titles_of('View'), 'Toggle Sidebar'
  end

  def test_window_and_help_menus_are_registered_with_the_app
    app = Cocoa::NSApplication.sharedApplication
    refute_nil app.windowsMenu
    refute_nil app.helpMenu
    refute_nil app.servicesMenu
    assert_includes titles_of('Window'), 'Minimize'
  end

  # Without this the menu bar shows the process name, which is "ruby".
  def test_the_app_claims_a_name
    info = Cocoa::NSBundle.mainBundle.infoDictionary
    assert_equal 'Hacker News', info.objectForKey('CFBundleName').to_s
    assert_equal 'org.example.hackernews', info.objectForKey('CFBundleIdentifier').to_s
    # This is the one AppKit actually titles the menu with.
    assert_equal 'Hacker News', Cocoa::NSProcessInfo.processInfo.processName.to_s
  end
end

# Stories already read are shown differently, and that survives a relaunch.

class TestHackerNewsToolbarLayout < Minitest::Test
  include HackerNews::AppHarness

  def self.stub
    @stub ||= HackerNews::StubAPI.new.tap do |api|
      api.stories = [{ id: '1', title: 'Only story', author: 'a', points: 1,
                       comments: 1, url: 'https://example.com/a',
                       domain: 'example.com' }]
    end
  end

  def setup
    app.settings.reset
    app.search_delay = 0
    app.search('')
    app.show_section(:top)
    app.load_front_page
  end

  # ---- the title bar -----------------------------------------------------

  # Named for the Window menu and Mission Control, but not drawn: in a
  # unified toolbar the title sits beside the controls, not above them.
  def test_the_window_is_named_but_the_title_is_not_drawn
    assert_equal HackerNews::App::APP_NAME, window.title.to_s
    assert_equal Cocoa::NSWindowTitleHidden, window.titleVisibility
  end

  def test_the_toolbar_carries_only_what_has_no_other_route
    identifiers = app.toolbar.identifiers

    assert_equal [HackerNews::App::SECTION_ITEM,
                  Cocoa::NSToolbarFlexibleSpaceItemIdentifier.to_s,
                  HackerNews::App::SEARCH_ITEM,
                  HackerNews::App::HN_ITEM,
                  HackerNews::App::ARTICLE_ITEM,
                  HackerNews::App::SHARE_ITEM],
                 identifiers.map(&:to_s)
  end

  # Reload is ⌘R and a File menu entry, and the list refetches on a timer.
  def test_reload_kept_its_command_after_losing_its_button
    refute_includes app.toolbar.identifiers.map(&:to_s), 'hn.reload'

    item = app.menu_bar.item_titled('File', 'Reload Stories')
    refute_nil item
    assert_equal 'r', item.keyEquivalent.to_s
    assert app.commands.key?(:reload)
  end

  # ---- rearranging -------------------------------------------------------

  def test_the_toolbar_can_be_rearranged_and_remembers_it
    toolbar = window.toolbar
    assert toolbar.allowsUserCustomization
    assert toolbar.autosavesConfiguration
  end

  # Without the spacers there is no way to push things apart again.
  def test_the_palette_offers_the_spacers
    allowed = app.toolbar.allowed_identifiers.map(&:to_s)

    assert_includes allowed, Cocoa::NSToolbarFlexibleSpaceItemIdentifier.to_s
    assert_includes allowed, Cocoa::NSToolbarSpaceItemIdentifier.to_s
    app.toolbar.identifiers.each { |id| assert_includes allowed, id.to_s }
  end

  def test_the_view_menu_opens_the_palette
    item = app.menu_bar.item_titled('View', 'Customise Toolbar…')
    refute_nil item
    assert_equal 'runToolbarCustomizationPalette:', item.action.to_s
  end

  # ---- the status line ---------------------------------------------------

  def test_it_says_what_the_list_is_showing
    assert_match(/1 story/, app.story_view.status)

    app.search('nothing at all matches this')
    assert_match(/Nothing found/, app.story_view.status)
  ensure
    app.search('')
  end

  def test_it_sits_under_the_list_rather_than_over_it
    bar   = app.story_view.status_bar
    pane  = app.story_view.pane

    assert_equal pane.objc_address, bar.container.objc_address
    # The list is above the bar, and the two do not overlap.
    content = pane.subviews.objectAtIndex(0)
    assert_operator content.frame.y, :>=, HackerNews::StatusBar::HEIGHT - 0.5
    assert_operator content.frame.height, :>, 0
  end

  # A CGColor resolves a dynamic colour once and keeps that value, which left
  # the hairline black against a dark window. The box holds the NSColor.
  def test_the_hairline_still_answers_to_the_appearance
    separator = app.story_view.status_bar.instance_variable_get(:@separator)

    assert_equal 4, separator.boxType, 'a separator box would resize itself'
    assert_equal 0.0, separator.borderWidth
    assert_equal 1.0, separator.frame.height, 'a hairline is one point'
    # The dynamic colour itself, not a snapshot of what it resolved to.
    assert_equal Cocoa::NSColor.separatorColor.description.to_s,
                 separator.fillColor.description.to_s
  end

  # A long status must lose its end, not its beginning -- the count is what
  # the eye goes to first.
  def test_a_long_status_truncates_at_the_tail
    assert_equal 4, app.story_view.status_bar.label.cell.lineBreakMode
  end

  def test_the_bar_keeps_its_height_as_the_window_resizes
    bar = app.story_view.status_bar
    before = bar.container.frame.height

    window.setContentSize([820, 500])
    window.contentView.layoutSubtreeIfNeeded
    app.pump(0.3) { false }

    refute_equal before, bar.container.frame.height, 'the pane should have resized'
    assert_match(/story/, bar.text)
  end
end

# The third column: the page a story links to, beside its comments.

class TestHackerNewsResizing < Minitest::Test
  LONG_TITLE = 'A rather long story title that will certainly need to wrap ' \
               'onto several lines once the sidebar is made narrow'

  include HackerNews::AppHarness

  def setup
    app.settings.reset
    # Two columns: these measure how the sidebar and the comments share the
    # window, and a third column with a minimum of its own only narrows the
    # range they can be driven over.
    app.showing_article = false
    stub.error = nil
    stub.pages = nil
    stub.stories = [{ id: '1', title: LONG_TITLE, author: 'a', points: 1,
                      comments: 1, url: nil, domain: nil }]
    stub.tree = {
      'children' => [
        { 'id' => 80, 'author' => 'x', 'text' => ('a comment that needs to wrap ' * 8),
          'created_at' => Time.now.iso8601, 'children' => [] }
      ]
    }
    app.instance_variable_set(:@story, nil)
    app.load_front_page
  end

  def teardown
    app.settings.reset
  end

  def settle
    app.pump(1.5) { false }
  end

  # Other tests in here drive the window to 800 and 1400 and leave it there,
  # and how wide the sidebar can get depends on how much window is left after
  # the comments take their minimum. Each test starts from a known width.
  def window_width(width)
    window = app.main_window.window
    window.setFrame_display([window.frame.x, window.frame.y, width,
                             window.frame.height], true)
    settle
  end

  def story_table
    app.story_view.view
  end

  def comment_table
    app.thread_view.view
  end

  def column_width(table)
    table.tableColumns.objectAtIndex(0).width
  end

  def test_the_story_column_follows_the_sidebar
    window_width(1280)
    app.main_window.sidebar_width = 560
    settle
    wide = column_width(story_table)

    app.main_window.sidebar_width = 260
    settle
    narrow = column_width(story_table)

    assert_operator wide, :>, narrow + 200

    # The column is deliberately inset from the pane, so the meaningful check
    # is that the cell fills most of it rather than sitting at some fixed
    # construction width.
    cell = story_table.frameOfCellAtColumn_row(0, 0)
    assert_operator cell.x + cell.width, :>, 260 * 0.8
    assert_operator cell.x + cell.width, :<=, story_table.frame.width + 0.5
  end

  def test_story_rows_are_measured_again_at_the_new_width
    window_width(1280)
    app.main_window.sidebar_width = 600
    settle
    wide = story_table.rectOfRow(0).height

    app.main_window.sidebar_width = 240
    settle
    narrow = story_table.rectOfRow(0).height

    assert_operator narrow, :>, wide, 'a narrower column needs more lines'
  end

  def test_the_comment_column_follows_the_window
    app.select_story(0)
    app.pump(2) { app.thread_view.thread.size.positive? }

    window = app.main_window.window
    window.setFrame_display([window.frame.x, window.frame.y, 1300, window.frame.height], true)
    settle
    wide = column_width(comment_table)

    window.setFrame_display([window.frame.x, window.frame.y, 820, window.frame.height], true)
    settle
    narrow = column_width(comment_table)

    assert_operator wide, :>, narrow + 300
  end

  def test_comment_rows_are_measured_again_at_the_new_width
    app.select_story(0)
    app.pump(2) { app.thread_view.thread.size.positive? }

    window = app.main_window.window
    window.setFrame_display([window.frame.x, window.frame.y, 1400, window.frame.height], true)
    settle
    wide = comment_table.rectOfRow(0).height

    window.setFrame_display([window.frame.x, window.frame.y, 800, window.frame.height], true)
    settle
    narrow = comment_table.rectOfRow(0).height

    assert_operator narrow, :>, wide
  end

  # Nothing may scroll sideways: a table wider than its clip view is what makes
  # the list scroll horizontally and cut the rank column off.
  def test_neither_list_ever_exceeds_its_clip_view
    app.select_story(0)
    app.pump(2) { !app.thread_view.thread.empty? }

    [560, 260, 620, 380].each do |width|
      app.main_window.sidebar_width = width
      settle

      [app.story_view.view, comment_table].each do |table|
        clip = table.enclosingScrollView.contentView
        assert_operator table.frame.width, :<=, clip.bounds.width + 0.5,
                        "#{table.objc_class_name} overflows its clip view at #{width}pt"
      end
    end
  end

  # The inset and source-list styles lay the cell out at an offset from the
  # row's leading edge, so a column as wide as the row runs off the end.
  def test_cells_fit_inside_their_rows
    app.select_story(0)
    app.pump(2) { !app.thread_view.thread.empty? }

    [520, 300, 240].each do |width|
      app.main_window.sidebar_width = width
      settle

      [app.story_view.view, comment_table].each do |table|
        next if table.numberOfRows.zero?

        cell = table.frameOfCellAtColumn_row(0, 0)
        assert_operator cell.x + cell.width, :<=, table.frame.width + 0.5,
                        "cell runs past the row at #{width}pt"
      end
    end
  end

  # Row views already on screen keep the frame they were given, so a resize has
  # to re-create them or their text stays wrapped to the old width.
  def test_rows_are_rebuilt_at_the_new_width
    window_width(1280)
    app.main_window.sidebar_width = 600
    settle
    wide = app.story_view.cell(0).objc_address

    app.main_window.sidebar_width = 260
    settle
    refute_equal wide, app.story_view.cell(0).objc_address
  end

  # Re-measuring on every notification would rebuild the world during a drag.
  def test_an_unchanged_width_does_not_discard_the_measurements
    app.main_window.sidebar_width = 420
    settle
    before = app.story_view.row_height(0)

    app.story_view.layout_changed
    assert_equal before, app.story_view.row_height(0)
  end
end

class TestHackerNewsWindowReopening < Minitest::Test
  def app
    TestHackerNewsChrome.app
  end

  def window
    app.main_window.window
  end

  def setup
    window.makeKeyAndOrderFront(nil)
    app.pump(0.3) { false }
  end

  def teardown
    window.makeKeyAndOrderFront(nil)
  end

  # A window released on close would leave the app holding a dangling pointer.
  def test_the_window_survives_being_closed
    refute window.isReleasedWhenClosed
  end

  def test_closing_hides_it
    window.performClose(nil)
    app.pump(0.3) { false }
    refute app.main_window_visible?
  end

  # This is what the Dock asks when its icon is clicked.
  def test_the_dock_can_bring_it_back
    window.performClose(nil)
    app.pump(0.3) { false }
    refute app.main_window_visible?

    # Several apps exist across the suite and they share one NSApplication, so
    # this asks this app's own delegate rather than whichever was installed last.
    delegate = app.instance_variable_get(:@delegate)
    refute_nil delegate
    assert delegate.objc_responds_to?('applicationShouldHandleReopen:hasVisibleWindows:')

    handled = delegate.objc_send('applicationShouldHandleReopen:hasVisibleWindows:',
                                 Cocoa::NSApplication.sharedApplication, false)
    app.pump(0.3) { false }
    assert_equal true, handled
    assert app.main_window_visible?
  end

  def test_the_menu_can_bring_it_back
    window.performClose(nil)
    app.pump(0.3) { false }

    app.show_main_window
    app.pump(0.3) { false }
    assert app.main_window_visible?
  end

  # The Window menu's automatic list only shows windows that are open, so a
  # closed one needs an entry of its own.
  #
  # Asked of the menu bar this app built, not of NSApplication: everything in
  # the process shares one main menu, and the class browser example replaces
  # it with its own.
  def test_the_window_menu_lists_it
    item = app.menu_bar.item_titled('Window', 'Hacker News')

    refute_nil item
    assert_equal '0', item.keyEquivalent.to_s
  end
end

# Searching: the toolbar field, what it asks the API for, and what the window
# says while it has nothing to show.

class TestHackerNewsAboutPanel < Minitest::Test
  def app
    TestHackerNewsChrome.app
  end

  def test_an_icon_is_available
    refute_nil HackerNews::App.app_icon
  end

  # A script has no bundle resources, so the standard panel is given its
  # contents explicitly rather than left to find them.
  def test_the_panel_is_given_real_contents
    options = app.about_options

    assert_equal 'Hacker News', options[Cocoa::NSAboutPanelOptionApplicationName]
    assert_equal HackerNews::App::APP_VERSION,
                 options[Cocoa::NSAboutPanelOptionApplicationVersion]
    refute_nil options[Cocoa::NSAboutPanelOptionApplicationIcon]

    credits = options[Cocoa::NSAboutPanelOptionCredits]
    assert_match(/libffi/, credits.string.to_s)
    assert_match(/#{RUBY_VERSION}/, credits.string.to_s)
  end

  def test_credits_are_centred
    credits = app.about_options[Cocoa::NSAboutPanelOptionCredits]
    style = credits.attribute_atIndex_effectiveRange(
      Cocoa::NSParagraphStyleAttributeName, 0, nil
    )
    assert_equal Cocoa::NSTextAlignmentCenter, style.alignment
  end

  def test_opening_it_does_not_raise
    app.show_about_panel
    assert true
  end
end

class TestHackerNewsAppIcon < Minitest::Test
  def icon(size = 256.0)
    HackerNews::AppIcon.image(size)
  end

  def pixels(image)
    Cocoa::NSBitmapImageRep.imageRepWithData(image.TIFFRepresentation)
  end

  def test_it_draws_at_the_size_asked_for
    drawn = icon(256.0)
    refute_nil drawn
    assert_equal 256, drawn.size.width.to_i
    assert_equal 256, drawn.size.height.to_i
  end

  # A blank canvas would also have the right size, so check it was painted.
  def test_the_plate_is_orange
    rep = pixels(icon(256.0))
    # Left of centre: inside the plate, clear of the glyph.
    colour = rep.colorAtX_y((256 * 0.18).to_i, 128)

    assert_operator colour.redComponent, :>, 0.8
    assert_operator colour.greenComponent, :<, 0.6
    assert_operator colour.blueComponent, :<, 0.3
  end

  # macOS icons leave the outer edge of the canvas clear.
  def test_the_corners_are_transparent
    rep = pixels(icon(256.0))
    assert_operator rep.colorAtX_y(1, 1).alphaComponent, :<, 0.1
  end

  # Sampling one coordinate would pin the test to the glyph's exact shape, so
  # count how much of the plate is white instead.
  def test_the_glyph_is_drawn_in_white
    rep   = pixels(icon(256.0))
    white = 0
    total = 0

    (40...216).step(8) do |x|
      (40...216).step(8) do |y|
        colour = rep.colorAtX_y(x, y)
        total += 1
        white += 1 if colour.redComponent > 0.9 &&
                      colour.greenComponent > 0.9 &&
                      colour.blueComponent > 0.9
      end
    end

    assert_operator white, :>, 0, 'no white pixels: the glyph did not draw'
    assert_operator white.to_f / total, :<, 0.9, 'the plate should still show'
  end

  def test_it_writes_a_png
    path = File.join(Dir.tmpdir, 'hn_icon_test.png')
    File.delete(path) if File.exist?(path)

    assert HackerNews::AppIcon.write_png(path, 128.0)
    assert_operator File.size(path), :>, 1_000
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_the_app_uses_it
    assert_equal HackerNews::App.app_icon.objc_address,
                 HackerNews::App.app_icon.objc_address, 'should be built once'
    refute_nil HackerNews::App.app_icon
  end

  def test_the_about_panel_gets_it
    refute_nil TestHackerNewsChrome.app.about_options[Cocoa::NSAboutPanelOptionApplicationIcon]
  end
end
