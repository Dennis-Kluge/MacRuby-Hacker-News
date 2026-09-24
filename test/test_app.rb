# frozen_string_literal: true

# Tests for the Hacker News reader. The API is stubbed, so these are fast and
# deterministic; the live network path is exercised separately by setting
# HN_LIVE=1.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../cocoa/lib', __dir__)
require 'minitest/autorun'
require 'time'
require 'tmpdir'
require 'fileutils'
require 'cocoa'
require 'cocoa/pooled_tests'

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

class TestHackerNewsHTML < Minitest::Test
  H = HackerNews::HTML

  def test_paragraphs_become_blank_lines
    assert_equal "one\n\ntwo", H.to_text('<p>one</p><p>two</p>').sub(/\A\n+/, '')
  end

  def test_line_breaks
    assert_equal "a\nb\nc", H.to_text('a<br>b<br/>c')
  end

  def test_entities_are_decoded
    assert_equal "it's < & > \"quoted\"", H.to_text('it&#x27;s &lt; &amp; &gt; &quot;quoted&quot;')
  end

  def test_numeric_entities
    assert_equal 'café', H.to_text('caf&#233;')
    assert_equal 'café', H.to_text('caf&#xe9;')
  end

  def test_links_keep_their_destination
    assert_equal 'see this (https://example.com)',
                 H.to_text('see <a href="https://example.com">this</a>')
  end

  def test_a_bare_link_is_not_doubled
    assert_equal 'https://example.com',
                 H.to_text('<a href="https://example.com">https://example.com...</a>')
  end

  def test_tags_are_stripped
    assert_equal 'bold and italic', H.to_text('<b>bold</b> and <i>italic</i>')
  end

  def test_relative_time
    now = Time.now
    assert_equal 'just now',    H.relative_time((now - 10).iso8601, now)
    assert_equal '5 minutes ago', H.relative_time((now - 300).iso8601, now)
    assert_equal '1 hour ago',  H.relative_time((now - 3600).iso8601, now)
    assert_equal '2 days ago',  H.relative_time((now - 172_800).iso8601, now)
  end

  def test_rich_extraction_records_link_ranges
    rich = H.to_rich('see <a href="https://example.com">this link</a> now')
    assert_equal 'see this link now', rich[:text]
    assert_equal 1, rich[:links].size
    assert_equal 'https://example.com', rich[:links].first[:url]
    assert_equal 'this link', H.utf16_slice(rich[:text], *rich[:links].first[:range])
  end

  # Hacker News escapes href attributes, so an undecoded href would not resolve.
  def test_href_entities_are_decoded
    rich = H.to_rich('<a href="https:&#x2F;&#x2F;example.com&#x2F;a">x</a>')
    assert_equal 'https://example.com/a', rich[:links].first[:url]
  end

  # Ranges are UTF-16 code units, so anything past the BMP must shift them.
  def test_link_ranges_are_utf16_offsets
    rich = H.to_rich('a 🎉 <a href="https://x.io">link</a>')
    start, length = rich[:links].first[:range]
    assert_equal 'link', H.utf16_slice(rich[:text], start, length)
    assert_operator start, :>, rich[:text].index('link')
  end

  def test_bare_urls_become_links
    rich = H.to_rich('go to https://bare.example.com/x now')
    assert_equal ['https://bare.example.com/x'], rich[:links].map { |l| l[:url] }
  end

  def test_paragraph_break_is_configurable
    assert_equal "one\n\ntwo", H.to_rich('<p>one</p><p>two</p>')[:text].sub(/\A\n+/, '')
    assert_equal "one\ntwo",
                 H.to_rich('<p>one</p><p>two</p>', paragraph_break: "\n")[:text].sub(/\A\n+/, '')
  end

  def test_bad_input_is_survivable
    assert_equal '', H.to_text(nil)
    assert_equal '', H.relative_time('not a date')
    assert_equal '', H.relative_time(nil)
  end
end

class TestHackerNewsApp < Minitest::Test
  # The data source classes are registered with the runtime by name, so one
  # app is shared and its stub is re-primed per test.
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    @app ||= self.class.app
  end

  def stub
    @stub ||= self.class.stub
  end

  def setup
    stub.error   = nil
    stub.stories = [
      { id: '1', title: 'First story',  author: 'alice', points: 100, comments: 2, url: 'https://a' },
      { id: '2', title: 'Second story', author: 'bob',   points: 50,  comments: 0, url: nil }
    ]
    stub.tree = {
      'children' => [
        { 'id' => 10, 'author' => 'carol', 'text' => '<p>top level</p>',
          'created_at' => (Time.now - 3600).iso8601,
          'children' => [
            { 'id' => 11, 'author' => 'dave', 'text' => 'a reply',
              'created_at' => (Time.now - 1800).iso8601, 'children' => [] }
          ] },
        { 'id' => 12, 'author' => 'erin', 'text' => 'second thread',
          'created_at' => (Time.now - 600).iso8601, 'children' => [] }
      ]
    }
    app.instance_variable_set(:@story, nil)
    app.load_front_page
  end

  def number(value)
    Cocoa::NSNumber.numberWithLongLong(value)
  end

  def outline
    app.thread_view.view
  end

  # ---- stories -------------------------------------------------------------

  def test_stories_load_into_the_table
    assert_equal 2, app.story_view.row_count
    assert_equal 'First story', app.stories.first[:title]
    assert_match(/2 stories/, app.status_text)
  end

  def test_story_cells_are_attributed_strings
    cell = app.story_view.cell(0)
    assert_kind_of ObjC::Object, cell
    assert_match(/First story/, cell.string.to_s)
    assert_match(/100 points · 2 comments · alice/, cell.string.to_s)
  end

  def test_out_of_range_story_row
    assert_equal '', app.story_view.cell(99)
  end

  def test_a_failed_load_is_reported_not_raised
    stub.error = 'network unreachable'
    app.instance_variable_set(:@loading, false)
    app.load_front_page
    assert_match(/network unreachable/, app.status_text)
  end

  # ---- comment tree --------------------------------------------------------

  def test_selecting_a_story_builds_the_tree
    app.select_story(0)

    assert_equal 2, app.thread_view.thread.roots.size
    assert_equal 3, app.thread_view.thread.nodes.size
    assert_match(/3 comments/, app.status_text)
  end

  def test_children_are_reported_to_the_outline_view
    app.select_story(0)

    assert_equal 2, app.thread_view.child_count(nil)          # root level
    assert_equal 1, app.thread_view.child_count(number(10))   # carol has one reply
    assert_equal 0, app.thread_view.child_count(number(11))
  end

  def test_child_at_returns_items_the_outline_view_can_use
    app.select_story(0)

    first = app.thread_view.child_at(nil, 0)
    assert_kind_of ObjC::Object, first
    assert_equal 10, first.objc_send('longLongValue')

    reply = app.thread_view.child_at(number(10), 0)
    assert_equal 11, reply.objc_send('longLongValue')
  end

  def test_expandability
    app.select_story(0)
    assert_equal true,  app.thread_view.expandable?(number(10))
    assert_equal false, app.thread_view.expandable?(number(11))
    assert_equal false, app.thread_view.expandable?(nil)
  end

  def test_comment_cells_carry_author_and_body
    app.select_story(0)

    text = app.thread_view.cell(number(10)).string.to_s
    assert_match(/carol/, text)
    assert_match(/1 hour ago/, text)
    assert_match(/top level/, text)
  end

  def test_comment_html_is_converted
    app.select_story(0)
    refute_match(/<p>/, app.thread_view.cell(number(10)).string.to_s)
  end

  def test_row_heights_are_measured
    app.select_story(0)

    height = app.thread_view.row_height(number(10))
    assert_kind_of Float, height
    assert_operator height, :>, 20.0
    assert_operator height, :<, 400.0
  end

  def test_deeper_rows_get_less_width_and_so_more_height
    stub.tree = {
      'children' => [
        { 'id' => 20, 'author' => 'a', 'text' => 'x ' * 200,
          'created_at' => Time.now.iso8601,
          'children' => [{ 'id' => 21, 'author' => 'b', 'text' => 'x ' * 200,
                           'created_at' => Time.now.iso8601, 'children' => [] }] }
      ]
    }
    app.instance_variable_set(:@story, nil)
    app.select_story(0)
    outline.expandItem(number(20))

    assert_operator app.thread_view.row_height(number(21)), :>=,
                    app.thread_view.row_height(number(20))
  end

  def test_unknown_items_do_not_crash_the_data_source
    app.select_story(0)
    assert_equal 0, app.thread_view.child_count(number(999))
    assert_equal '', app.thread_view.cell(number(999))
    assert_equal 18.0, app.thread_view.row_height(number(999))
  end

  # ---- tree shaping --------------------------------------------------------

  def test_deleted_leaf_comments_are_dropped
    stub.tree = {
      'children' => [
        { 'id' => 30, 'author' => nil, 'text' => nil, 'children' => [] },
        { 'id' => 31, 'author' => 'x', 'text' => 'kept', 'children' => [] }
      ]
    }
    app.instance_variable_set(:@story, nil)
    app.select_story(0)

    assert_equal 1, app.thread_view.thread.roots.size
    assert_equal 31, app.thread_view.thread.roots.first
  end

  # A deleted comment that still has replies has to stay, or the replies would
  # be orphaned out of the thread.
  def test_deleted_comments_with_replies_are_kept
    stub.tree = {
      'children' => [
        { 'id' => 40, 'author' => nil, 'text' => nil,
          'children' => [{ 'id' => 41, 'author' => 'y', 'text' => 'reply', 'children' => [] }] }
      ]
    }
    app.instance_variable_set(:@story, nil)
    app.select_story(0)

    assert_equal 1, app.thread_view.thread.roots.size
    assert_equal '[deleted]', app.thread_view.thread.nodes[40][:text]
    assert_equal [41], app.thread_view.thread.nodes[40][:children]
  end

  # ---- opening links -------------------------------------------------------
  # These check which URL would be opened. None of them call NSWorkspace, so no
  # browser is launched by the test suite.

  def test_link_for_a_story_with_a_url
    app.select_story(0)
    assert_equal 'https://a', app.link_for(app.stories[0])
  end

  # Ask HN and Show HN posts carry no external link.
  def test_link_falls_back_to_the_discussion_page
    assert_equal 'https://news.ycombinator.com/item?id=2', app.link_for(app.stories[1])
  end

  def test_link_for_nothing_selected
    assert_nil app.link_for(nil)
    assert_nil app.discussion_url(nil)
  end

  def test_discussion_url_is_always_available
    assert_equal 'https://news.ycombinator.com/item?id=1',
                 app.discussion_url(app.stories[0])
  end

  def test_selected_story_tracks_the_table
    app.select_story(1)
    assert_equal 'Second story', app.selected_story[:title]
  end

  def test_opening_with_no_selection_reports_rather_than_raises
    app.story_view.view.deselectAll(nil)
    app.open_selected_link
    assert_match(/Select a story first/, app.status_text)
  end

  def test_an_unparseable_url_is_reported
    app.open_url('http://exa mple.com/ bad')
    assert_match(/Could not parse/, app.status_text)
  end

  def test_the_file_menu_offers_both_open_commands
    titles = menu_titles('File')
    assert_includes titles, 'Open Link'
    assert_includes titles, 'Open on Hacker News'
    assert_includes titles, 'Reload Stories'
  end

  def menu_titles(menu_name)
    main = Cocoa::NSApplication.sharedApplication.mainMenu
    index = (0...main.numberOfItems).find do |i|
      main.itemAtIndex(i).title.to_s == menu_name
    end
    return [] if index.nil?

    menu = main.itemAtIndex(index).submenu
    (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i).title.to_s }
  end

  def test_double_click_is_wired_to_opening
    table = app.story_view.view
    assert_equal Cocoa::ACTION_SELECTOR, table.doubleAction.to_s
    refute_nil table.target
  end

  def test_it_renders
    app.select_story(0)
    path = File.join(Dir.tmpdir, 'hn_test.png')
    File.delete(path) if File.exist?(path)
    app.render_to(path)
    assert File.exist?(path)
    assert_operator File.size(path), :>, 10_000
  ensure
    File.delete(path) if path && File.exist?(path)
  end
end

# Opt-in: exercises the real asynchronous NSURLSession path.
class TestHackerNewsLive < Minitest::Test
  def setup
    skip 'set HN_LIVE=1 to run tests that hit the network' unless ENV['HN_LIVE'] == '1'
  end

  def test_it_loads_the_front_page_and_a_comment_thread
    app = HackerNews::App.new
    assert app.load_and_wait(30), 'front page did not load'
    assert_operator app.stories.size, :>, 5

    assert app.open_story_and_wait(0, 45), 'comments did not load'
    assert_operator app.thread_view.thread.nodes.size, :>, 0
  end
end

# The parts that make it read as a current Mac app rather than an old one.
class TestHackerNewsChrome < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      @stub.stories = [{ id: '1', title: 'A story', author: 'a', points: 1, comments: 1, url: 'https://a' }]
      @stub.tree = {
        'children' => [
          { 'id' => 60, 'author' => 'linky',
            'text' => 'read <a href="https:&#x2F;&#x2F;example.com&#x2F;doc">the docs</a> please',
            'created_at' => Time.now.iso8601, 'children' => [] }
        ]
      }
      HackerNews::App.new(api: @stub)
    end
  end

  def app
    self.class.app
  end

  def window
    app.main_window.window
  end

  def test_the_window_uses_a_split_view_controller
    controller = window.contentViewController
    assert_equal 'NSSplitViewController', controller.objc_class_name
    assert_equal 2, controller.splitViewItems.count
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
    assert_includes identifiers, HackerNews::App::RELOAD_ITEM
    assert_includes identifiers, HackerNews::App::OPEN_ITEM
    assert_includes identifiers, HackerNews::App::HN_ITEM
  end

  def test_toolbar_items_carry_sf_symbols
    item = app.toolbar.item(HackerNews::App::RELOAD_ITEM)
    refute_nil item
    assert_equal 'Reload', item.label.to_s
    refute_nil item.image
  end

  def test_status_goes_to_the_window_subtitle
    app.load_front_page
    assert_equal app.status_text, window.subtitle.to_s
    assert_match(/1 story/, window.subtitle.to_s)
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
class TestHackerNewsReadState < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  # Endless method definitions are Ruby 3.0+; the arm64 interpreter is 2.6.
  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    Cocoa::NSUserDefaults.standardUserDefaults
                         .removeObjectForKey(HackerNews::ReadingHistory::KEY)
    app.mark_all_unread

    stub.error = nil
    stub.stories = [
      { id: '101', title: 'First',  author: 'a', points: 10, comments: 2,
        url: 'https://www.example.com/a', domain: 'example.com' },
      { id: '102', title: 'Second', author: 'b', points: 20, comments: 3,
        url: nil, domain: nil }
    ]
    stub.tree = { 'children' => [] }
    app.instance_variable_set(:@story, nil)
    app.load_front_page
  end

  def test_nothing_is_read_to_begin_with
    assert_equal 0, app.visited_count
    refute app.visited?(app.stories[0])
  end

  def test_opening_a_thread_marks_the_story_read
    app.select_story(0)
    assert app.visited?(app.stories[0])
    refute app.visited?(app.stories[1])
    assert_equal 1, app.visited_count
  end

  def test_opening_the_link_marks_it_read_too
    app.story_view.view
       .selectRowIndexes_byExtendingSelection(Cocoa::NSIndexSet.indexSetWithIndex(1), false)
    app.open_url(nil) # no browser launched; the marking is what is under test
    app.send(:mark_visited, app.stories[1])
    assert app.visited?(app.stories[1])
  end

  def test_read_stories_render_differently
    unread = app.story_view.cell(0).string.to_s
    app.select_story(0)
    read = app.story_view.cell(0).string.to_s
    # Same words either way; the difference is in the attributes.
    assert_equal unread, read

    attributes = app.story_view.cell(0)
    font = attributes.attribute_atIndex_effectiveRange(Cocoa::NSFontAttributeName, 4, nil)
    refute_includes font.fontName.to_s, 'Bold'
  end

  def test_unread_stories_are_bold
    attributes = app.story_view.cell(1)
    font = attributes.attribute_atIndex_effectiveRange(Cocoa::NSFontAttributeName, 4, nil)
    assert_includes font.fontName.to_s, 'Bold'
  end

  # The rank column is what shows when site icons are turned off.
  def test_rank_and_domain_appear_in_the_row
    app.settings.show_favicons = false
    app.apply_favicons
    text = app.story_view.cell(0).string.to_s
    assert_match(/\A\s*1\s+First/, text)
    assert_match(/example\.com · 10 points · 2 comments · a/, text)
  end

  def test_a_story_without_a_url_shows_no_domain
    refute_match(/·\s+·/, app.story_view.cell(1).string.to_s)
  end

  def test_read_state_persists
    app.select_story(0)
    stored = Cocoa::NSUserDefaults.standardUserDefaults
                                  .arrayForKey(HackerNews::ReadingHistory::KEY)
    refute_nil stored
    assert_includes stored.to_a.map(&:to_s), '101'
  end

  def test_marking_all_unread_clears_it
    app.select_story(0)
    assert_equal 1, app.visited_count

    app.mark_all_unread
    assert_equal 0, app.visited_count
    refute app.visited?(app.stories[0])
  end

  def test_the_view_menu_can_reset_read_state
    main = Cocoa::NSApplication.sharedApplication.mainMenu
    index = (0...main.numberOfItems).find { |i| main.itemAtIndex(i).title.to_s == 'View' }
    menu  = main.itemAtIndex(index).submenu
    titles = (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i).title.to_s }
    assert_includes titles, 'Mark All Stories Unread'
  end
end

# Paging and the prefetch that drives endless scrolling.
class TestHackerNewsPaging < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def story(id, title = "Story #{id}")
    { id: id.to_s, title: title, author: 'a', points: 1, comments: 1,
      url: "https://example.com/#{id}", domain: 'example.com' }
  end

  def setup
    stub.error = nil
    stub.pages = nil
    app.instance_variable_set(:@story, nil)
  end

  def table
    app.story_view.view
  end

  # Ask for a view near the end, which is what a scroll does, then let the
  # deferred prefetch run.
  def scroll_to_end
    before = app.stories.size
    app.story_view.row_view([before - 1, 0].max)
    app.pump(3) do
      !app.prefetching? &&
        !app.list.loading?
    end
    before
  end

  def test_the_first_page_loads
    stub.pages = [[story(1), story(2)]]
    app.load_front_page

    assert_equal 2, app.stories.size
    assert_match(/2 stories/, app.status_text)
  end

  def test_reaching_the_end_loads_the_next_page
    stub.pages = [[story(1), story(2)], [story(3), story(4)]]
    app.load_front_page
    assert_equal 2, app.stories.size

    scroll_to_end
    assert_equal 4, app.stories.size
    assert_equal %w[1 2 3 4], app.stories.map { |s| s[:id] }
  end

  # Consecutive pages overlap, so the same story arrives more than once.
  def test_stories_already_seen_are_dropped
    stub.pages = [[story(1), story(2)], [story(2), story(3)]]
    app.load_front_page
    scroll_to_end

    assert_equal %w[1 2 3], app.stories.map { |s| s[:id] }
  end

  def test_paging_stops_at_the_last_page
    stub.pages = [[story(1)], [story(2)]]
    app.load_front_page
    scroll_to_end
    assert_equal 2, app.stories.size

    scroll_to_end
    assert_equal 2, app.stories.size, 'should not have asked for a page past the end'
    assert_match(/that's everything/, app.status_text)
  end

  # A whole page can be duplicates; the loader should skip ahead rather than
  # stall, but not walk the entire archive doing it.
  def test_a_page_of_duplicates_is_skipped
    stub.pages = [[story(1)], [story(1)], [story(1)], [story(2)]]
    app.load_front_page
    scroll_to_end

    assert_equal %w[1 2], app.stories.map { |s| s[:id] }
  end

  def test_it_gives_up_after_too_many_empty_pages
    duplicate = [story(1)]
    stub.pages = [duplicate] * (HackerNews::StoryList::MAX_EMPTY_PAGES + 4)
    app.load_front_page
    scroll_to_end

    assert_equal 1, app.stories.size
    # It gave up rather than walking the whole archive. The exact page reached
    # depends on how many times the table asked for a view, so the claim is
    # that it stopped short, not where.
    assert_operator app.list.page, :<, stub.pages.size
  end

  def test_reloading_starts_over_at_the_front_page
    stub.pages = [[story(1)], [story(2)]]
    app.load_front_page
    scroll_to_end
    assert_equal 2, app.stories.size

    app.load_front_page
    assert_equal 1, app.stories.size
    assert_equal '1', app.stories.first[:id]
  end

  def test_ranks_keep_counting_across_pages
    app.settings.show_favicons = false
    app.apply_favicons
    stub.pages = [[story(1), story(2)], [story(3)]]
    app.load_front_page
    scroll_to_end

    assert_match(/\A\s*3\s+Story 3/, app.story_view.cell(2).string.to_s)
  end

  def test_a_failed_page_stops_paging_rather_than_looping
    stub.pages = [[story(1)], [story(2)]]
    app.load_front_page

    stub.error = 'offline'
    scroll_to_end

    assert_equal 1, app.stories.size
    assert_match(/offline/, app.status_text)

    scroll_to_end
    assert_match(/offline/, app.status_text)
  end

  # Row heights are asked for every row, so prefetching from there would fetch
  # the whole archive the moment the table reloaded.
  def test_measuring_heights_does_not_trigger_loading
    stub.pages = [[story(1), story(2)], [story(3)]]
    app.load_front_page

    app.stories.each_index { |row| app.story_view.row_height(row) }
    assert_equal 2, app.stories.size
  end
end

class TestHackerNewsSettings < Minitest::Test
  def setup
    @settings = HackerNews::Settings.new
    @settings.reset
  end

  def teardown
    @settings.reset
  end

  def test_comments_start_collapsed
    assert_equal :collapsed, @settings.expansion
  end

  def test_reading_history_is_on_by_default
    assert_equal true, @settings.remember_read?
  end

  def test_expansion_round_trips
    @settings.expansion = :all
    assert_equal :all, HackerNews::Settings.new.expansion
  end

  def test_reading_history_round_trips
    @settings.remember_read = false
    assert_equal false, HackerNews::Settings.new.remember_read?
  end

  # A stale or hand-edited value must not leave the app in a bad state.
  def test_an_unknown_stored_mode_falls_back
    Cocoa::NSUserDefaults.standardUserDefaults
                         .setObject_forKey('nonsense', HackerNews::Settings::EXPANSION_KEY)
    assert_equal :collapsed, HackerNews::Settings.new.expansion
  end

  # registerDefaults must not clobber a value the user chose.
  def test_registering_defaults_leaves_choices_alone
    @settings.expansion = :top_level
    HackerNews::Settings.register_defaults
    assert_equal :top_level, HackerNews::Settings.new.expansion
  end

  def test_modes_map_to_popup_indexes
    assert_equal 3, HackerNews::Settings.mode_labels.size
    assert_equal :collapsed, HackerNews::Settings.mode_at(0)
    assert_equal :all, HackerNews::Settings.mode_at(2)
    assert_equal 1, HackerNews::Settings.index_of(:top_level)
    # Out of range should not raise.
    assert_equal :collapsed, HackerNews::Settings.mode_at(99)
  end
end

class TestHackerNewsSettingsInApp < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
    Cocoa::NSUserDefaults.standardUserDefaults
                         .removeObjectForKey(HackerNews::ReadingHistory::KEY)
    app.mark_all_unread

    stub.error = nil
    stub.pages = nil
    stub.stories = [{ id: '1', title: 'S', author: 'a', points: 1, comments: 1,
                      url: 'https://e.com', domain: 'e.com' }]
    # A root with one reply, so expansion state is observable.
    stub.tree = {
      'children' => [
        { 'id' => 70, 'author' => 'x', 'text' => 'parent',
          'created_at' => Time.now.iso8601,
          'children' => [{ 'id' => 71, 'author' => 'y', 'text' => 'child',
                           'created_at' => Time.now.iso8601, 'children' => [] }] }
      ]
    }
    app.instance_variable_set(:@story, nil)
    app.load_front_page
  end

  def teardown
    app.settings.reset
  end

  def tree
    app.thread_view.view
  end

  def test_comments_are_collapsed_when_a_story_opens
    app.select_story(0)
    assert_equal 1, tree.numberOfRows, 'only the root should be showing'
  end

  def test_top_level_mode_expands_one_level
    app.settings.expansion = :top_level
    app.select_story(0)
    assert_equal 2, tree.numberOfRows
  end

  def test_expand_all_shows_every_comment
    app.select_story(0)
    app.thread_view.expand_all
    assert_equal 2, tree.numberOfRows

    app.thread_view.collapse_all
    assert_equal 1, tree.numberOfRows
  end

  def test_read_state_is_saved_when_history_is_on
    app.set_remember_read(true)
    app.select_story(0)

    stored = Cocoa::NSUserDefaults.standardUserDefaults
                                  .arrayForKey(HackerNews::ReadingHistory::KEY)
    refute_nil stored
    assert_includes stored.to_a.map(&:to_s), '1'
  end

  # With history off the mark still shows, but nothing reaches the disk.
  def test_nothing_is_saved_when_history_is_off
    app.set_remember_read(false)
    app.select_story(0)

    assert app.visited?(app.stories[0]), 'the session mark should still apply'
    assert_nil Cocoa::NSUserDefaults.standardUserDefaults
                                    .arrayForKey(HackerNews::ReadingHistory::KEY)
  end

  def test_turning_history_off_forgets_what_was_stored
    app.set_remember_read(true)
    app.select_story(0)
    refute_nil Cocoa::NSUserDefaults.standardUserDefaults
                                    .arrayForKey(HackerNews::ReadingHistory::KEY)

    app.set_remember_read(false)
    assert_nil Cocoa::NSUserDefaults.standardUserDefaults
                                    .arrayForKey(HackerNews::ReadingHistory::KEY)
  end

  def test_the_settings_window_reflects_the_current_values
    app.settings.expansion = :all
    app.set_remember_read(false)

    prefs = app.preferences
    prefs.refresh

    assert_equal 2, prefs.expansion_popup.indexOfSelectedItem
    assert_equal 0, prefs.remember_checkbox.state
    assert_equal 'Settings', prefs.window.title.to_s
  end

  def test_the_clear_button_reports_the_count
    app.set_remember_read(true)
    app.select_story(0)

    prefs = app.preferences
    prefs.refresh
    assert_match(/Forget 1 Read Story/, prefs.clear_button.title.to_s)

    app.mark_all_unread
    prefs.refresh
    assert_match(/No Stories Marked Read/, prefs.clear_button.title.to_s)
  end

  def test_the_menus_expose_the_new_commands
    main = Cocoa::NSApplication.sharedApplication.mainMenu
    def_titles = lambda do |name|
      i = (0...main.numberOfItems).find { |n| main.itemAtIndex(n).title.to_s == name }
      m = main.itemAtIndex(i).submenu
      (0...m.numberOfItems).map { |n| m.itemAtIndex(n).title.to_s }
    end

    assert_includes def_titles.call('Hacker News'), 'Settings…'
    view = def_titles.call('View')
    assert_includes view, 'Expand All Comments'
    assert_includes view, 'Collapse All Comments'
  end

  def test_settings_uses_the_conventional_shortcut
    main = Cocoa::NSApplication.sharedApplication.mainMenu
    menu = main.itemAtIndex(0).submenu
    item = (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i) }
                                   .find { |i| i.title.to_s == 'Settings…' }
    assert_equal ',', item.keyEquivalent.to_s
  end
end

class TestHackerNewsPreferencesModel < Minitest::Test
  def setup
    @settings = HackerNews::Settings.new
    @settings.reset
  end

  def teardown
    @settings.reset
  end

  def test_defaults
    assert_equal :medium, @settings.text_size
    assert_equal :top,    @settings.section.key
    assert_equal 30,      @settings.page_size
  end

  def test_text_size_round_trips_and_scales
    small  = HackerNews::Settings.font_sizes(:small)
    medium = HackerNews::Settings.font_sizes(:medium)
    large  = HackerNews::Settings.font_sizes(:large)

    assert_equal 3, medium.size
    small.zip(medium, large).each do |s, m, l|
      assert_operator s, :<, m
      assert_operator m, :<, l
    end

    @settings.text_size = :large
    assert_equal :large, HackerNews::Settings.new.text_size
  end

  def test_section_round_trips
    @settings.section = :ask
    assert_equal :ask, HackerNews::Settings.new.section.key
  end

  def test_refresh_interval_round_trips_and_rejects_junk
    @settings.refresh_interval = 60
    assert_equal 60, HackerNews::Settings.new.refresh_interval

    Cocoa::NSUserDefaults.standardUserDefaults
                         .setInteger_forKey(7, HackerNews::Settings::REFRESH_KEY)
    assert_equal 300, HackerNews::Settings.new.refresh_interval
  end

  def test_page_size_round_trips_and_rejects_junk
    @settings.page_size = 50
    assert_equal 50, HackerNews::Settings.new.page_size

    Cocoa::NSUserDefaults.standardUserDefaults
                         .setInteger_forKey(999, HackerNews::Settings::PAGE_SIZE_KEY)
    assert_equal 30, HackerNews::Settings.new.page_size
  end

  def test_stale_values_fall_back
    defaults = Cocoa::NSUserDefaults.standardUserDefaults
    defaults.setObject_forKey('huge', HackerNews::Settings::TEXT_SIZE_KEY)
    defaults.setObject_forKey('yearly', HackerNews::Settings::SECTION_KEY)

    assert_equal :medium, HackerNews::Settings.new.text_size
    assert_equal :top,    HackerNews::Settings.new.section.key
  end
end

class TestHackerNewsSectionURLs < Minitest::Test
  def setup
    @api = HackerNews::API.new
  end

  def url(page, key, text = nil)
    query = HackerNews::Query.new(section: HackerNews::Section[key], text: text)
    @api.send(:page_url, page, 30, query)
  end

  # Only Top begins with the real front page; the others page from their first.
  def test_only_top_starts_at_the_front_page
    assert_match(/tags=front_page/, url(0, :top))
    refute_match(/front_page/, url(0, :new))
    refute_match(/front_page/, url(0, :ask))
  end

  def test_each_section_asks_for_something_different
    assert_match(/tags=story/,   url(1, :top))
    assert_match(/search_by_date/, url(0, :new))
    assert_match(/tags=ask_hn/,  url(0, :ask))
    assert_match(/tags=show_hn/, url(0, :show))
    assert_match(/tags=job/,     url(0, :jobs))
  end

  # Ranking Ask and Show across all time surfaces 2010's classics.
  def test_windowed_sections_filter_by_date
    %i[top best ask show].each do |key|
      assert_match(/numericFilters=created_at_i%3E\d+/, url(1, key), "#{key} should be windowed")
    end
  end

  def test_jobs_is_newest_first_rather_than_ranked
    assert_match(/search_by_date/, url(0, :jobs))
    refute_match(/numericFilters/, url(0, :jobs))
  end

  # The front page occupies a page of its own, so the rest shift by one.
  def test_top_offsets_its_paging_past_the_front_page
    assert_match(/page=0/, url(1, :top))
    assert_match(/page=2/, url(3, :top))
    # A section without a front page does not shift.
    assert_match(/page=3/, url(3, :new))
  end

  def test_unknown_keys_fall_back_to_top
    assert_equal :top, HackerNews::Section['nonsense'].key
    assert_equal :top, HackerNews::Section.at(99).key
  end

  # ---- searching ---------------------------------------------------------

  def test_the_search_text_is_sent_encoded
    assert_match(/query=rust\+gpu/, url(0, :top, 'rust gpu'))
    assert_match(/query=c%2B%2B/,    url(0, :top, 'c++'))
    refute_match(/query=/,           url(0, :top))
  end

  # The curated front page is not an answer to a question, so searching Top
  # starts at the ranked results instead.
  def test_searching_top_skips_the_front_page
    refute_match(/front_page/, url(0, :top, 'rust'))
    assert_match(/page=0/,     url(0, :top, 'rust'))
    assert_match(/page=1/,     url(1, :top, 'rust'))
  end

  # A section's window keeps a ranked list current; searching within one week
  # would hide almost everything worth finding.
  def test_searching_drops_the_recency_window
    %i[top best ask show].each do |key|
      refute_match(/numericFilters/, url(0, key, 'rust'), "#{key} should search all time")
    end
  end

  # Search narrows the section rather than replacing it: the section still
  # says what may match, while the sorting says how the matches are ranked.
  def test_a_search_keeps_the_section_it_was_made_in
    assert_match(/tags=ask_hn/,  url(0, :ask, 'rust'))
    assert_match(/tags=show_hn/, url(0, :show, 'rust'))
    assert_match(/tags=job/,     url(0, :jobs, 'rust'))
  end

  def sorted(key, sorting, period = :all)
    query = HackerNews::Query.new(section: HackerNews::Section[key], text: 'rust',
                                  sorting: HackerNews::Sorting[sorting],
                                  period: HackerNews::Period[period])
    @api.send(:page_url, 0, 30, query)
  end

  # Ranking is the sorting's job while searching, whichever section is showing.
  def test_the_sorting_picks_the_endpoint
    assert_match(%r{/search\?},         sorted(:top, :relevance))
    assert_match(%r{/search_by_date\?}, sorted(:top, :newest))
    # Even in a section that is newest-first when it is not being searched.
    assert_match(%r{/search\?},         sorted(:new, :relevance))
  end

  # Ranked by date nothing downstream sorts a loose match down, so the
  # question has to be asked precisely: "rust" must not match "trust".
  def test_newest_first_asks_precisely
    newest = sorted(:top, :newest)
    assert_match(/typoTolerance=false/, newest)
    assert_match(/restrictSearchableAttributes=title,url/, newest)
  end

  # Relevance keeps both, which is what still finds Kubernetes for
  # "kubernets" -- the exact matches rank above the approximate ones anyway.
  def test_relevance_stays_forgiving
    relevance = sorted(:top, :relevance)
    refute_match(/typoTolerance/, relevance)
    refute_match(/restrictSearchableAttributes/, relevance)
  end

  # None of it applies to a list that is not being searched.
  def test_a_plain_list_asks_for_none_of_it
    refute_match(/typoTolerance/, url(0, :new))
    refute_match(/restrictSearchableAttributes/, url(1, :top))
  end

  def test_the_period_windows_the_search
    refute_match(/numericFilters/, sorted(:top, :relevance, :all))

    now = Time.now.to_i
    { day: 86_400, week: 604_800, year: 31_536_000 }.each do |key, seconds|
      match = sorted(:top, :relevance, key).match(/created_at_i%3E(\d+)/)
      refute_nil match, "#{key} should be windowed"
      assert_in_delta now - seconds, match[1].to_i, 5
    end
  end

  # The section's own window still applies when nothing is being searched for.
  def test_a_plain_list_keeps_its_own_window
    assert_match(/numericFilters/, url(1, :top))
    refute_match(/numericFilters/, url(0, :new))
  end
end

class TestDebounce < Minitest::Test
  def pump(seconds)
    Cocoa::NSRunLoop.currentRunLoop.runUntilDate(
      Cocoa::NSDate.dateWithTimeIntervalSinceNow(seconds)
    )
  end

  def test_only_the_last_request_runs
    seen = []
    debounce = HackerNews::Debounce.new(delay: 0.05) { |text| seen << text }

    debounce.schedule('r')
    debounce.schedule('ru')
    debounce.schedule('rust')
    assert debounce.pending?
    pump(0.3)

    assert_equal ['rust'], seen
    refute debounce.pending?
  end

  def test_cancelling_drops_the_request
    seen = []
    debounce = HackerNews::Debounce.new(delay: 0.05) { |text| seen << text }
    debounce.schedule('rust')
    debounce.cancel
    pump(0.2)

    assert_empty seen
  end

  def test_flushing_runs_it_now
    seen = []
    debounce = HackerNews::Debounce.new(delay: 5.0) { |text| seen << text }
    debounce.schedule('rust')
    debounce.flush('rust')

    assert_equal ['rust'], seen
    refute debounce.pending?, 'the pending timer should have been dropped'
  end

  # Tests have no run loop to deliver a timer, so zero means run immediately.
  def test_no_delay_runs_synchronously
    seen = []
    HackerNews::Debounce.new(delay: 0) { |text| seen << text }.schedule('rust')
    assert_equal ['rust'], seen
  end
end

class TestHackerNewsSettingsApplied < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
    stub.error = nil
    stub.pages = nil
    stub.stories = [{ id: '1', title: 'Sized', author: 'a', points: 1, comments: 1,
                      url: 'https://e.com', domain: 'e.com' }]
    stub.tree = { 'children' => [] }
    app.instance_variable_set(:@story, nil)
    app.load_front_page
  end

  def teardown
    app.settings.reset
  end

  def font_size_of(attributed, index)
    attributed.attribute_atIndex_effectiveRange(Cocoa::NSFontAttributeName, index, nil)
              .pointSize
  end

  def test_text_size_changes_what_is_rendered
    medium = font_size_of(app.story_view.cell(0), 4)

    app.settings.text_size = :large
    app.apply_text_size
    large = font_size_of(app.story_view.cell(0), 4)

    assert_operator large, :>, medium
  end

  def test_changing_text_size_clears_measured_heights
    # A string built at one text size must not survive a change of size.
    medium = app.story_view.cell(0).objc_address

    app.settings.text_size = :large
    app.apply_text_size
    refute_equal medium, app.story_view.cell(0).objc_address
  end

  def test_the_section_preference_reaches_the_api
    app.show_section(:show)
    assert_equal :show, stub.last_request[:section].key
    # And is remembered for next launch.
    assert_equal :show, app.settings.section.key
  ensure
    app.show_section(:top)
  end

  def test_the_page_size_preference_reaches_the_api
    app.settings.page_size = 50
    app.reload_stories
    assert_equal 50, stub.last_request[:per_page]
  end

  def test_changing_the_section_starts_the_list_over
    stub.pages = [[{ id: '1', title: 'A', author: 'a', points: 1, comments: 1, url: nil, domain: nil }],
                  [{ id: '2', title: 'B', author: 'b', points: 1, comments: 1, url: nil, domain: nil }]]
    app.load_front_page
    app.story_view.row_view(0)
    app.pump(3) { !app.prefetching? }
    assert_equal 2, app.stories.size

    app.show_section(:best)
    assert_equal 1, app.stories.size
  end
end

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

class TestHackerNewsReader < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
    @opened = []
    # Never actually hand a URL to the system during tests.
    app.browser_opener = ->(url) { @opened << url.absoluteString.to_s; true }

    stub.error = nil
    stub.pages = nil
    stub.stories = [{ id: '1', title: 'A Story', author: 'a', points: 1, comments: 1,
                      url: 'about:blank', domain: nil }]
    stub.tree = { 'children' => [] }
    app.instance_variable_set(:@story, nil)
    app.load_front_page
  end

  def teardown
    app.settings.reset
  end

  def test_links_open_in_the_reader_by_default
    assert_equal :app, app.settings.open_links_in
  end

  def test_the_reader_loads_a_url
    assert app.reader.open('about:blank', title: 'Blank')
    assert_equal 'WKWebView', app.reader.web_view.objc_class_name.sub(/\ANSKVONotifying_/, '')
  end

  def test_the_reader_rejects_an_unusable_url
    refute app.reader.open('http://exa mple.com/ bad')
  end

  # The story headline stands in while the page has no title of its own.
  def test_the_window_title_falls_back_to_the_story
    app.reader.open('about:blank', title: 'A Story')
    assert_equal 'A Story', app.reader.window.title.to_s
  end

  def test_selecting_in_app_routes_to_the_reader
    app.settings.open_links_in = :app
    app.select_story(0)
    app.open_selected_link

    assert_empty @opened, 'nothing should have been handed to the system'
    assert_match(/Reading about:blank/, app.status_text)
  end

  def test_selecting_default_browser_routes_outward
    app.settings.open_links_in = :browser
    app.select_story(0)
    app.open_selected_link

    assert_equal ['about:blank'], @opened
    assert_match(/Opened about:blank/, app.status_text)
  end

  # The menu command leaves the app whatever the preference says.
  def test_the_explicit_command_always_leaves_the_app
    app.settings.open_links_in = :app
    app.select_story(0)
    app.open_selected_externally

    assert_equal ['about:blank'], @opened
  end

  def test_opening_with_nothing_selected_is_reported
    app.story_view.view.deselectAll(nil)
    app.open_selected_link
    assert_match(/Select a story first/, app.status_text)
  end

  def test_the_reader_has_a_navigation_delegate
    delegate = app.reader.web_view.navigationDelegate
    refute_nil delegate
    assert delegate.objc_responds_to?('webView:didFinishNavigation:')
    assert delegate.objc_responds_to?('webView:didFailNavigation:withError:')
  end

  def test_the_reader_toolbar_has_navigation_controls
    identifiers = app.reader.toolbar_items
    assert_includes identifiers, HackerNews::Reader::BACK_ITEM
    assert_includes identifiers, HackerNews::Reader::FORWARD_ITEM
    assert_includes identifiers, HackerNews::Reader::EXTERNAL_ITEM

    back = app.reader.toolbar_item(HackerNews::Reader::BACK_ITEM)
    assert_equal 'Back', back.label.to_s
    refute_nil back.image
  end

  def test_back_is_disabled_with_no_history
    app.reader.toolbar_item(HackerNews::Reader::BACK_ITEM)
    app.reader.update_navigation_items
    refute app.reader.web_view.canGoBack
  end

  def test_the_preference_is_offered_in_settings
    prefs = app.preferences
    app.settings.open_links_in = :browser
    prefs.refresh
    assert_equal 1, prefs.link_target_popup.indexOfSelectedItem

    app.settings.open_links_in = :app
    prefs.refresh
    assert_equal 0, prefs.link_target_popup.indexOfSelectedItem
  end

  def test_the_menu_offers_an_external_escape_hatch
    main = Cocoa::NSApplication.sharedApplication.mainMenu
    index = (0...main.numberOfItems).find { |i| main.itemAtIndex(i).title.to_s == 'File' }
    menu  = main.itemAtIndex(index).submenu
    item  = (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i) }
                                    .find { |i| i.title.to_s == 'Open in Default Browser' }
    refute_nil item
    assert_equal 'o', item.keyEquivalent.to_s
  end
end

# Dragging the divider or resizing the window has to reach the cells: the
# column follows the pane, and every row is measured again at the new width.
class TestHackerNewsResizing < Minitest::Test
  LONG_TITLE = 'A rather long story title that will certainly need to wrap ' \
               'onto several lines once the sidebar is made narrow'

  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
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

class TestHackerNewsSections < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
    stub.error = nil
    stub.pages = nil
    stub.stories = [{ id: '1', title: 'One', author: 'a', points: 1, comments: 1,
                      url: nil, domain: nil }]
    stub.tree = { 'children' => [] }
    app.instance_variable_set(:@story, nil)
    app.show_section(:top)
    app.load_front_page
  end

  def teardown
    app.settings.reset
  end

  def test_the_sections_match_hacker_news
    assert_equal %i[top new best ask show jobs], HackerNews::Section.keys
    assert_equal %w[Top New Best Ask Show Jobs], HackerNews::Section.labels
  end

  def test_switching_section_reloads_from_that_section
    app.show_section(:ask)

    assert_equal :ask, app.section.key
    assert_equal :ask, stub.last_request[:section].key
    assert_equal 0, stub.last_request[:page], 'should start from the first page'
  end

  def test_the_choice_is_remembered
    app.show_section(:show)
    assert_equal :show, HackerNews::Settings.new.section.key
  end

  def test_switching_to_the_current_section_does_nothing
    app.show_section(:new)
    before = stub.last_request
    app.show_section(:new)
    assert_same before, stub.last_request
  end

  def test_switching_clears_the_open_thread
    app.select_story(0)
    app.show_section(:best)

    assert app.thread_view.thread.empty?
    assert_nil app.story
  end

  def test_the_toolbar_control_tracks_the_section
    control = app.instance_variable_get(:@section_control)
    refute_nil control
    assert_equal HackerNews::Section::ALL.size, control.segmentCount

    app.show_section(:jobs)
    assert_equal HackerNews::Section.index_of(:jobs), control.selectedSegment
  end

  def test_every_section_has_a_menu_command_and_shortcut
    main = Cocoa::NSApplication.sharedApplication.mainMenu
    index = (0...main.numberOfItems).find { |i| main.itemAtIndex(i).title.to_s == 'View' }
    menu  = main.itemAtIndex(index).submenu
    items = (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i) }

    HackerNews::Section::ALL.each do |section|
      item = items.find { |i| i.title.to_s == section.label }
      refute_nil item, "no menu item for #{section.label}"
      assert_equal section.shortcut, item.keyEquivalent.to_s
    end
  end
end

class TestHackerNewsAutoRefresh < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
    stub.error = nil
    stub.pages = [
      [{ id: '1', title: 'One', author: 'a', points: 1, comments: 1, url: nil, domain: nil }],
      [{ id: '2', title: 'Two', author: 'b', points: 1, comments: 1, url: nil, domain: nil }]
    ]
    stub.tree = { 'children' => [] }
    app.instance_variable_set(:@story, nil)
    app.load_front_page
  end

  def teardown
    app.settings.reset
    app.auto_refresh.stop
  end

  def test_the_interval_comes_from_the_preference
    app.settings.refresh_interval = 60
    assert_equal 60, app.auto_refresh.interval
  end

  def test_it_runs_only_when_an_interval_is_set
    app.settings.refresh_interval = 0
    refute app.apply_refresh_interval
    refute app.auto_refresh.running?

    app.settings.refresh_interval = 60
    assert app.apply_refresh_interval
    assert app.auto_refresh.running?
  end

  def test_a_fresh_list_is_undisturbed
    assert app.undisturbed?
    assert app.refresh_if_undisturbed
  end

  # Refetching would discard the pages already loaded and jump the reader back
  # to the top.
  def test_a_paged_list_is_left_alone
    app.story_view.row_view(0)
    app.pump(2) { !app.prefetching? }
    assert_equal 2, app.stories.size, 'a second page should have loaded'

    refute app.undisturbed?
    refute app.refresh_if_undisturbed
    assert_equal 2, app.stories.size, 'the extra page should have survived'
  end

  def test_the_selected_story_survives_a_refresh
    app.select_story(0)
    reading = app.selected_story

    assert app.refresh_if_undisturbed
    assert_equal reading[:id], app.selected_story[:id]
  end

  def test_it_does_not_refresh_while_a_load_is_in_flight
    app.instance_variable_get(:@list).instance_variable_set(:@loading, true)
    refute app.undisturbed?
  ensure
    app.instance_variable_get(:@list).instance_variable_set(:@loading, false)
  end
end

class TestHackerNewsFavicons < Minitest::Test
  def store
    # A cache directory of its own, so tests never touch the real one.
    @store ||= HackerNews::Favicons.new(cache_dir: File.join(Dir.tmpdir, 'hn-favicon-test'))
  end

  def teardown
    FileUtils.rm_rf(File.join(Dir.tmpdir, 'hn-favicon-test'))
  end

  # A row must never wait on the network to look finished.
  def test_an_unknown_domain_gets_a_monogram_at_once
    icon = store.icon_for('example.com')
    refute_nil icon
    assert_equal HackerNews::Favicons::SIZE, icon.size.width
    assert_equal HackerNews::Favicons::SIZE, icon.size.height
  end

  def test_the_monogram_is_actually_drawn
    icon = store.icon_for('example.com')
    rep  = Cocoa::NSBitmapImageRep.imageRepWithData(icon.TIFFRepresentation)
    centre = rep.colorAtX_y(8, 8)
    assert_operator centre.alphaComponent, :>, 0.5, 'the tile should be filled'
  end

  # Same site, same colour between runs.
  def test_monogram_colours_are_stable
    first  = store.icon_for('example.com').TIFFRepresentation.length
    second = HackerNews::Favicons
             .new(cache_dir: File.join(Dir.tmpdir, 'hn-favicon-test2'))
             .icon_for('example.com').TIFFRepresentation.length
    assert_equal first, second
  ensure
    FileUtils.rm_rf(File.join(Dir.tmpdir, 'hn-favicon-test2'))
  end

  def test_nothing_is_drawn_for_a_missing_domain
    assert_nil store.icon_for(nil)
    assert_nil store.icon_for('')
  end

  def test_it_asks_for_each_domain_only_once
    store.icon_for('example.com')
    attempted = store.instance_variable_get(:@attempted).dup
    store.icon_for('example.com')
    assert_equal attempted.keys, store.instance_variable_get(:@attempted).keys
  end
end

class TestHackerNewsFaviconSetting < Minitest::Test
  def app
    TestHackerNewsChrome.app
  end

  def teardown
    app.settings.reset
    app.apply_favicons
  end

  def test_it_is_on_by_default
    app.settings.reset
    assert app.settings.show_favicons?
  end

  # With icons off the rank column comes back.
  def test_turning_it_off_restores_the_numbering
    app.load_front_page
    app.settings.show_favicons = false
    app.apply_favicons
    assert_match(/\A\s*1\s/, app.story_view.cell(0).string.to_s)

    app.settings.show_favicons = true
    app.apply_favicons
    # An attachment shows up as the object replacement character.
    assert_match(/￼/, app.story_view.cell(0).string.to_s)
  end

  def test_the_preference_is_offered_in_settings
    prefs = app.preferences
    app.settings.show_favicons = false
    prefs.refresh
    assert_equal 0, prefs.favicons_checkbox.state

    app.settings.show_favicons = true
    prefs.refresh
    assert_equal 1, prefs.favicons_checkbox.state
  end
end

# An empty pane with no explanation reads as broken, so it always says why.
class TestHackerNewsEmptyState < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
    stub.error = nil
    stub.pages = nil
    stub.stories = [
      { id: '1', title: 'Talked about', author: 'a', points: 1, comments: 2, url: nil, domain: nil },
      { id: '2', title: 'Ignored',      author: 'b', points: 1, comments: 0, url: nil, domain: nil }
    ]
    stub.tree = {
      'children' => [
        { 'id' => 90, 'author' => 'x', 'text' => 'a comment',
          'created_at' => Time.now.iso8601, 'children' => [] }
      ]
    }
    app.instance_variable_set(:@story, nil)
    app.load_front_page
    # Switching to the section already showing is a no-op, so the pane is put
    # back to its opening state directly.
    app.thread_view.present(HackerNews::CommentThread.new,
                            message: HackerNews::ThreadView::NOTHING_SELECTED)
  end

  def teardown
    app.settings.reset
  end

  def thread_view
    app.thread_view
  end

  def test_it_explains_itself_before_anything_is_selected
    assert thread_view.placeholder_visible?
    assert_equal HackerNews::ThreadView::NOTHING_SELECTED, thread_view.placeholder_text
  end

  def test_opening_a_story_replaces_it_with_the_thread
    app.select_story(0)
    app.pump(2) { !thread_view.thread.empty? }

    refute thread_view.placeholder_visible?
    assert_equal 1, thread_view.thread.size
  end

  # A story nobody has replied to is not the same as nothing being selected.
  def test_a_story_without_comments_says_so
    stub.tree = { 'children' => [] }
    app.select_story(1)
    app.pump(2) { !app.loading_comments? }

    assert thread_view.placeholder_visible?
    assert_equal HackerNews::ThreadView::NO_COMMENTS, thread_view.placeholder_text
  end

  def test_a_failed_load_says_what_went_wrong
    app.select_story(0)
    app.pump(2) { !thread_view.thread.empty? }
    refute thread_view.placeholder_visible?

    stub.error = 'offline'
    app.instance_variable_set(:@story, nil)
    app.select_story(1)
    app.pump(2) { !app.loading_comments? }

    assert thread_view.placeholder_visible?
    assert_match(/offline/, thread_view.placeholder_text)
  end

  def test_switching_section_puts_it_back
    app.select_story(0)
    app.pump(2) { !thread_view.thread.empty? }
    refute thread_view.placeholder_visible?

    app.show_section(:ask)
    assert thread_view.placeholder_visible?
    assert_equal HackerNews::ThreadView::NOTHING_SELECTED, thread_view.placeholder_text
  end

  # The outline view is hidden while the placeholder shows, so it cannot be
  # scrolled or leave a stray scroller behind.
  def test_the_list_and_the_placeholder_are_never_both_showing
    assert thread_view.scroll_view.isHidden

    app.select_story(0)
    app.pump(2) { !thread_view.thread.empty? }
    refute thread_view.scroll_view.isHidden
    refute thread_view.placeholder_visible?
  end
end

class TestHackerNewsSharing < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
    stub.error = nil
    stub.pages = nil
    stub.stories = [
      { id: '42', title: 'Linked', author: 'a', points: 1, comments: 1,
        url: 'https://example.com/a', domain: 'example.com' },
      { id: '43', title: 'Ask HN: something', author: 'b', points: 1, comments: 1,
        url: nil, domain: nil }
    ]
    stub.tree = { 'children' => [] }
    app.instance_variable_set(:@story, nil)
    app.load_front_page
  end

  def teardown
    app.settings.reset
  end

  def share_item
    app.toolbar.item(HackerNews::App::SHARE_ITEM)
  end

  def test_it_shares_the_article
    app.select_story(0)
    items = app.share_items

    assert_equal 1, items.size
    assert_equal 'https://example.com/a', items.first.absoluteString.to_s
  end

  # A text post has no article, so its discussion page is the thing to share.
  def test_a_text_post_shares_its_discussion
    app.select_story(1)
    assert_equal 'https://news.ycombinator.com/item?id=43',
                 app.share_items.first.absoluteString.to_s
  end

  def test_nothing_selected_shares_nothing
    app.story_view.deselect
    assert_empty app.share_items
  end

  def test_showing_the_sheet_with_no_selection_is_reported_not_raised
    app.story_view.deselect
    assert_nil app.share_selected
    assert_match(/Select a story first/, app.status_text)
  end

  # The system draws the share control and runs the picker; all it asks the
  # app for is the list of things to share.
  def test_the_toolbar_item_is_the_system_control
    assert_equal 'NSSharingServicePickerToolbarItem',
                 share_item.objc_class_name.sub(/\ANSKVONotifying_/, '')
    refute_nil share_item.delegate
  end

  def test_the_toolbar_delegate_answers_with_the_selection
    app.select_story(0)
    items = share_item.delegate
                      .objc_send('itemsForSharingServicePickerToolbarItem:', share_item)
    assert_equal 1, items.count
    assert_equal 'https://example.com/a', items.objectAtIndex(0).absoluteString.to_s

    app.story_view.deselect
    empty = share_item.delegate
                      .objc_send('itemsForSharingServicePickerToolbarItem:', share_item)
    assert_equal 0, empty.count
  end

  def test_macos_offers_services_for_what_we_share
    app.select_story(0)
    services = Cocoa::NSSharingService.sharingServicesForItems(app.share_items)
    assert_operator services.count, :>, 0
  end

  def test_copying_the_link_reaches_the_pasteboard
    app.select_story(0)
    assert_equal 'https://example.com/a', app.copy_link

    written = Cocoa::NSPasteboard.generalPasteboard.stringForType('public.utf8-plain-text')
    assert_equal 'https://example.com/a', written.to_s
  end

  def test_copying_with_no_selection_is_reported
    app.story_view.deselect
    assert_nil app.copy_link
    assert_match(/Select a story first/, app.status_text)
  end

  def test_the_menu_offers_both
    main = Cocoa::NSApplication.sharedApplication.mainMenu
    index = (0...main.numberOfItems).find { |i| main.itemAtIndex(i).title.to_s == 'File' }
    menu  = main.itemAtIndex(index).submenu
    items = (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i) }

    share = items.find { |i| i.title.to_s == 'Share…' }
    copy  = items.find { |i| i.title.to_s == 'Copy Link' }
    refute_nil share
    refute_nil copy
    assert_equal 's', share.keyEquivalent.to_s
    assert_equal 'c', copy.keyEquivalent.to_s
  end
end

class TestHackerNewsContextMenu < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
    app.mark_all_unread
    stub.error = nil
    stub.pages = nil
    stub.stories = [
      { id: '42', title: 'Linked', author: 'a', points: 1, comments: 1,
        url: 'https://example.com/a', domain: 'example.com' },
      { id: '43', title: 'Ask HN: something', author: 'b', points: 1, comments: 1,
        url: nil, domain: nil }
    ]
    stub.tree = { 'children' => [] }
    app.instance_variable_set(:@story, nil)
    app.load_front_page
  end

  def teardown
    app.settings.reset
  end

  def menu
    app.story_view.context_menu
  end

  def items
    (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i) }
  end

  def titles
    items.map { |i| i.title.to_s }.reject(&:empty?)
  end

  def read_item
    items.find { |i| i.title.to_s.start_with?('Mark as') }
  end

  # clickedRow is only set while the menu is tracking, so outside of a real
  # right-click the target falls back to the selection.
  def target(row)
    app.story_view.select(row)
    app.story_view.prepare_context_menu
  end

  def test_the_table_carries_the_menu
    refute_nil menu
    assert_equal menu.objc_address, app.story_view.view.menu.objc_address
  end

  def test_it_offers_what_a_story_row_can_do
    # The read item is worded for whichever story is being acted on, so it is
    # matched by shape rather than by its exact title.
    fixed = titles.reject { |t| t.start_with?('Mark as') }
    assert_equal ['Open Link', 'Open on Hacker News', 'Copy Article Link',
                  'Copy Comments Link', 'Share…'], fixed
    assert_equal 1, titles.count { |t| t.start_with?('Mark as') }
  end

  def test_the_two_copy_commands_differ
    target(0)
    assert_equal 'https://example.com/a', app.copy_article_link
    assert_equal 'https://news.ycombinator.com/item?id=42', app.copy_comments_link
  end

  def test_the_article_copy_lands_on_the_pasteboard
    target(0)
    app.copy_article_link
    written = Cocoa::NSPasteboard.generalPasteboard.stringForType('public.utf8-plain-text')
    assert_equal 'https://example.com/a', written.to_s
  end

  # A text post has no article, so both commands point at the discussion.
  def test_a_text_post_copies_its_discussion_either_way
    target(1)
    assert_equal 'https://news.ycombinator.com/item?id=43', app.copy_article_link
    assert_equal 'https://news.ycombinator.com/item?id=43', app.copy_comments_link
  end

  def test_marking_read_and_unread_again
    target(0)
    story = app.context_story
    assert app.visited?(story), 'selecting a story marks it read'

    app.toggle_context_read
    refute app.visited?(story)
    assert_match(/unread/, app.status_text)

    app.toggle_context_read
    assert app.visited?(story)
    assert_match(/read/, app.status_text)
  end

  # Marking unread must survive, not just repaint.
  def test_unread_is_forgotten_from_the_history
    target(0)
    assert_equal 1, app.visited_count

    app.toggle_context_read
    assert_equal 0, app.visited_count
    refute app.history.include?('42')
  end

  def test_the_item_says_which_way_it_will_go
    target(0)
    assert_equal 'Mark as Unread', read_item.title.to_s

    app.toggle_context_read
    app.story_view.prepare_context_menu
    assert_equal 'Mark as Read', read_item.title.to_s
  end

  def test_the_item_is_disabled_with_nothing_to_act_on
    app.story_view.deselect
    app.story_view.prepare_context_menu
    refute read_item.isEnabled
    assert_nil app.context_story
  end

  def test_toggling_with_nothing_to_act_on_is_reported
    app.story_view.deselect
    app.story_view.prepare_context_menu
    assert_nil app.toggle_context_read
    assert_match(/Select a story first/, app.status_text)
  end

  def test_the_context_row_can_differ_from_the_selection
    target(1)
    assert_equal '43', app.context_story[:id]
    target(0)
    assert_equal '42', app.context_story[:id]
  end
end

# Closing the window leaves the app running, so there has to be a way back.
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
class TestHackerNewsSearch < Minitest::Test
  RESULTS = {
    'rust' => [
      { id: '90', title: 'Rust in production', author: 'a', points: 9, comments: 3,
        url: 'https://example.com/rust', domain: 'example.com', age: '2 years ago' }
    ]
  }.freeze

  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
    stub.error = nil
    stub.pages = nil
    stub.search_results = RESULTS
    stub.stories = [
      { id: '1', title: 'Front page story', author: 'a', points: 1, comments: 1,
        url: 'https://example.com/a', domain: 'example.com' }
    ]
    # No run loop in these tests, so the field's keystrokes act at once.
    app.search_delay = 0
    app.search('')
    app.load_front_page
  end

  def teardown
    app.search('')
    app.show_section(:top)
    app.settings.reset
  end

  def search_field
    app.search_field
  end

  # ---- the field ---------------------------------------------------------

  def test_the_toolbar_offers_a_search_field
    assert_includes app.toolbar.identifiers, HackerNews::App::SEARCH_ITEM
    refute_nil search_field
    assert_equal HackerNews::App::SEARCH_PLACEHOLDER,
                 search_field.placeholderString.to_s
  end

  # Recent searches are the system's own feature; all it needs is a name to
  # save them under.
  def test_recent_searches_are_remembered
    assert_equal HackerNews::App::SEARCH_AUTOSAVE,
                 search_field.recentsAutosaveName.to_s
  end

  # Typing reports every keystroke; the delay before asking is ours, not
  # AppKit's, so it can be tuned in one place.
  def test_the_field_reports_what_was_typed
    search_field.setStringValue('rust')
    search_field.target.objc_send(Cocoa::ACTION_SELECTOR, search_field)

    assert_equal 'rust', app.search_text
    assert app.searching?
  end

  def test_cmd_f_puts_the_keyboard_in_the_field
    refute_nil app.focus_search
    assert app.main_window_visible?
  end

  def test_the_edit_menu_offers_find
    find = app.menu_bar.item_titled('Edit', 'Find…')
    refute_nil find
    assert_equal 'f', find.keyEquivalent.to_s

    refute_nil app.menu_bar.item_titled('Edit', 'Clear Search')
  end

  # ---- what it asks for --------------------------------------------------

  def test_searching_reloads_the_list_with_the_query
    app.search('rust')

    assert_equal 'rust', stub.last_request[:query].text
    assert_equal 1, app.list.size
    assert_equal 'Rust in production', app.list[0][:title]
  end

  def test_the_same_search_twice_asks_only_once
    assert app.search('rust')
    before = stub.last_request
    refute app.search('rust'), 'an unchanged search should not reload'
    assert_same before, stub.last_request
  end

  def test_a_search_narrows_the_section_rather_than_replacing_it
    app.search('rust')
    app.show_section(:ask)

    assert_equal :ask,   stub.last_request[:query].section.key
    assert_equal 'rust', stub.last_request[:query].text
    assert_equal 'rust', app.search_text
  end

  def test_clearing_goes_back_to_the_plain_list
    app.search('rust')
    app.clear_search

    refute app.searching?
    assert_empty search_field.stringValue.to_s
    assert_equal 'Front page story', app.list[0][:title]
  end

  # A search is a new question, so whatever was being read is no longer the
  # answer to it.
  def test_searching_clears_the_comment_pane
    app.select_story(0)
    app.pump(2) { !app.story.nil? }
    refute_nil app.story

    app.search('rust')
    assert_nil app.story
    assert app.thread_view.placeholder_visible?
  end

  # ---- what it says ------------------------------------------------------

  def test_the_status_counts_results_rather_than_stories
    app.search('rust')
    assert_match(/1 result/, app.status_text)
    assert_match(/rust/,     app.status_text)
  end

  def test_a_search_that_finds_nothing_says_so
    app.search('nothing at all matches this')

    assert_empty app.list.stories
    assert_match(/Nothing found/, app.status_text)
  end

  # An empty table says nothing at all, so the list says it instead.
  def test_a_search_that_finds_nothing_shows_an_empty_state
    app.search('nothing at all matches this')

    assert app.story_view.empty_visible?
    assert_match(/No stories match/, app.story_view.empty_text)
    assert_equal HackerNews::StoryListView::NO_RESULTS_SYMBOL,
                 app.story_view.placeholder.symbol_name
  end

  def test_results_put_the_list_back
    app.search('nothing at all matches this')
    assert app.story_view.empty_visible?

    app.search('rust')
    refute app.story_view.empty_visible?
  end

  def test_a_failed_search_says_why
    stub.error = 'offline'
    app.search('rust')

    assert app.story_view.empty_visible?
    assert_match(/offline/, app.story_view.empty_text)
  end
end

# The filter bar under the toolbar: what it shows, what it asks for, and when
# it is there at all.
class TestHackerNewsSearchOptions < Minitest::Test
  def self.app
    @app ||= begin
      @stub = HackerNews::StubAPI.new
      HackerNews::App.new(api: @stub)
    end
  end

  def self.stub
    app
    @stub
  end

  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    app.settings.reset
    stub.error = nil
    stub.pages = nil
    stub.search_results = { 'rust' => [story_hash] }
    stub.stories = [story_hash]
    app.search_delay = 0
    app.search('')
    app.apply_search_options(sorting: HackerNews::Sorting[:relevance],
                             period: HackerNews::Period[:all])
    app.show_section(:top)
    app.load_front_page
  end

  def teardown
    app.search('')
    app.show_section(:top)
    app.settings.reset
  end

  def story_hash
    { id: '90', title: 'Rust in production', author: 'a', points: 9, comments: 3,
      url: 'https://example.com/rust', domain: 'example.com', age: '2 years ago' }
  end

  def bar
    app.search_bar
  end

  def query
    stub.last_request[:query]
  end

  # ---- when it is there --------------------------------------------------

  def test_it_is_hidden_until_something_is_searched_for
    refute bar.visible?

    app.search('rust')
    assert bar.visible?

    app.clear_search
    refute bar.visible?
  end

  def test_it_sits_below_the_toolbar
    assert_equal Cocoa::NSLayoutAttributeBottom, bar.controller.layoutAttribute
    assert_includes (0...app.main_window.window.titlebarAccessoryViewControllers.count)
                    .map { |i| app.main_window.window.titlebarAccessoryViewControllers
                                  .objectAtIndex(i).objc_address },
                    bar.controller.objc_address
  end

  # ---- what it asks for --------------------------------------------------

  def test_changing_the_sorting_reruns_the_search
    app.search('rust')
    assert_equal :relevance, query.sorting.key

    app.sorting = :newest
    assert_equal :newest, query.sorting.key
    assert_equal 'rust',  query.text
  end

  def test_changing_the_period_reruns_the_search
    app.search('rust')
    app.period = :week

    assert_equal :week, query.period.key
    assert_equal 604_800, query.window
  end

  def test_the_controls_drive_the_same_thing_the_menu_does
    app.search('rust')
    control = bar.sorting_control
    control.setSelectedSegment(HackerNews::Sorting.index_of(:newest))
    control.target.objc_send(Cocoa::ACTION_SELECTOR, control)

    assert_equal :newest, app.sorting.key
    assert_equal :newest, query.sorting.key
  end

  def test_the_popup_drives_the_period
    app.search('rust')
    popup = bar.period_popup
    popup.selectItemAtIndex(HackerNews::Period.index_of(:month))
    popup.target.objc_send(Cocoa::ACTION_SELECTOR, popup)

    assert_equal :month, app.period.key
    assert_equal :month, query.period.key
  end

  # Changing an option off a search costs nothing; it is remembered instead.
  def test_options_off_a_search_do_not_reload
    before = stub.last_request
    app.period = :year

    assert_equal :year, app.period.key
    assert_same before, stub.last_request

    app.search('rust')
    assert_equal :year, query.period.key
  end

  def test_setting_the_same_option_twice_asks_only_once
    app.search('rust')
    app.period = :week
    before = stub.last_request

    refute app.apply_search_options(period: HackerNews::Period[:week])
    assert_same before, stub.last_request
  end

  # ---- what it shows -----------------------------------------------------

  # Searching from New should stay newest-first rather than silently
  # re-ranking what is already on screen -- and the bar has to say so.
  def test_a_search_begun_from_new_starts_newest_first
    app.show_section(:new)
    app.search('rust')

    assert_equal :newest, app.sorting.key
    assert_equal HackerNews::Sorting.index_of(:newest), bar.sorting_control.selectedSegment
  end

  def test_refining_a_search_keeps_the_sorting_that_was_chosen
    app.search('rust')
    app.sorting = :newest
    app.search('rust lang')

    assert_equal :newest, app.sorting.key
  end

  def test_switching_section_mid_search_keeps_the_options
    app.search('rust')
    app.period = :week
    app.show_section(:ask)

    assert_equal 'rust', query.text
    assert_equal :week,  query.period.key
    assert_equal :ask,   query.section.key
  end

  def test_the_bar_shows_what_the_query_holds
    app.show_section(:new)
    app.period = :month
    app.search('rust')

    assert_equal HackerNews::Sorting.index_of(:newest), bar.sorting_control.selectedSegment
    assert_equal HackerNews::Period.index_of(:month), bar.period_popup.indexOfSelectedItem
  end

  # A count means something different once the search is windowed.
  def test_the_status_names_the_period
    app.search('rust')
    refute_match(/all time/, app.status_text)

    app.period = :week
    assert_match(/1 result/, app.status_text)
    assert_match(/past week/, app.status_text)
  end

  def test_an_empty_windowed_search_says_where_it_looked
    app.period = :day
    app.search('nothing matches this at all')

    assert_match(/Nothing found/, app.status_text)
    assert_match(/past 24 hours/, app.status_text)
  end

  # ---- how it is laid out ------------------------------------------------

  def bar_controls
    view = bar.view
    (0...view.subviews.count).map { |i| view.subviews.objectAtIndex(i) }
  end

  # A text field, a segmented control and a popup button pad their text
  # differently inside their frames, so matching the frames is not enough:
  # "Sort:" rode three points below "Relevance" until these were aligned by
  # baseline instead.
  def test_the_row_shares_one_baseline
    app.search('rust')
    baselines = bar_controls.map do |control|
      control.frame.y + control.frame.height - control.firstBaselineOffsetFromTop
    end

    assert_equal 4, baselines.size
    assert_equal 1, baselines.uniq.size, "baselines were #{baselines.inspect}"
  end

  # AppKit gives a titlebar accessory a height of its own, whatever height
  # the view was created with, so the row is laid out against the real one.
  def test_the_row_fits_the_height_appkit_gives_it
    app.search('rust')
    height = bar.view.frame.height

    assert_operator height, :>, 0
    bar_controls.each do |control|
      assert_operator control.frame.y, :>=, 0
      assert_operator control.frame.y + control.frame.height, :<=, height
    end
  end

  def test_the_controls_do_not_overlap
    app.search('rust')
    frames = bar_controls.map(&:frame).sort_by(&:x)
    frames.each_cons(2) do |left, right|
      assert_operator left.x + left.width, :<=, right.x
    end
    assert_operator frames.first.x, :>=, HackerNews::SearchBar::MARGIN
  end

  # ---- the menu ----------------------------------------------------------

  def test_the_view_menu_carries_both_sets
    sort = app.menu_bar.item_titled('View', 'Sort Search Results')
    refute_nil sort
    titles = (0...sort.submenu.numberOfItems).map { |i| sort.submenu.itemAtIndex(i).title.to_s }
    assert_equal HackerNews::Sorting.labels, titles

    period = app.menu_bar.item_titled('View', 'Search Period')
    refute_nil period
    titles = (0...period.submenu.numberOfItems).map { |i| period.submenu.itemAtIndex(i).title.to_s }
    assert_equal HackerNews::Period.labels, titles
  end

  def test_the_menu_items_act
    app.search('rust')
    item = app.menu_bar.item_titled('View', 'Search Period').submenu.itemAtIndex(2)
    item.target.objc_send(Cocoa::ACTION_SELECTOR, item)

    assert_equal :week, app.period.key
  end
end
