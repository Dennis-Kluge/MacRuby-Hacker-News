# frozen_string_literal: true

# The article: the reader window and the third column.
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

class TestHackerNewsReader < Minitest::Test
  include HackerNews::AppHarness

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

class TestHackerNewsArticleColumn < Minitest::Test
  LINKED = { id: '1', title: 'Linked story', author: 'a', points: 9, comments: 2,
             url: 'https://example.com/article', domain: 'example.com' }.freeze
  TEXT_POST = { id: '2', title: 'Ask HN: something', author: 'b', points: 3,
                comments: 1, url: nil, domain: nil }.freeze

  include HackerNews::AppHarness

  def pane
    app.article_pane
  end

  def setup
    app.settings.reset
    stub.error = nil
    stub.pages = nil
    stub.stories = [LINKED.dup, TEXT_POST.dup]
    stub.tree = { 'children' => [] }
    # No waiting about: these check what is asked for, not what comes back.
    app.article_delay = 0
    app.showing_article = true
    app.instance_variable_set(:@story, nil)
    # The pane outlives each test, so what the last one asked for has to go.
    app.article_debounce.cancel
    app.article_pane.clear
    app.load_front_page
  end

  def teardown
    app.showing_article = true
    app.settings.reset
  end

  # ---- the column --------------------------------------------------------

  def test_it_is_a_third_split_item
    items = app.main_window.window.contentViewController.splitViewItems
    assert_equal 3, items.count
    assert app.main_window.article_column?
    assert app.main_window.article_visible?
  end

  def test_it_can_be_put_away_and_brought_back
    app.toggle_article
    refute app.showing_article?
    refute app.main_window.article_visible?

    app.toggle_article
    assert app.showing_article?
    assert app.main_window.article_visible?
  end

  def test_whether_it_is_showing_is_remembered
    app.showing_article = false
    refute app.settings.show_article?

    app.showing_article = true
    assert app.settings.show_article?
  end

  def test_the_view_menu_toggles_it
    item = app.menu_bar.item_titled('View', 'Show Linked Page')
    refute_nil item
    assert_equal '3', item.keyEquivalent.to_s
  end

  # The window is never stopped from shrinking. Three columns need room for
  # three, and when there is not enough the article is what gives way: the
  # stories and their comments are what the window is for.
  def test_the_window_can_always_shrink
    app.showing_article = true
    assert_equal HackerNews::MainWindow::MIN_SIZE[0],
                 app.main_window.window.minSize.width
  end

  def test_a_narrow_window_puts_the_article_away_and_keeps_the_rest
    app.showing_article = true
    assert app.article_on_screen?

    resize(HackerNews::MainWindow::ROOM_FOR_THREE - 120)
    refute app.article_on_screen?, 'the article should have given way'
    assert app.showing_article?, 'but it is still what the reader asked for'

    assert_operator app.story_view.view.frame.width, :>, 0
    assert_operator app.thread_view.view.frame.width, :>,
                    HackerNews::MainWindow::CONTENT_MIN - 80
  end

  def test_widening_the_window_brings_it_back
    app.showing_article = true
    resize(HackerNews::MainWindow::ROOM_FOR_THREE - 120)
    refute app.article_on_screen?

    resize(HackerNews::MainWindow::ROOM_FOR_THREE + 300)
    assert app.article_on_screen?
  end

  # A window that grows past the threshold must not bring back a column the
  # reader put away.
  def test_widening_does_not_override_the_choice
    app.showing_article = false
    resize(HackerNews::MainWindow::ROOM_FOR_THREE + 300)

    refute app.article_on_screen?
    refute app.showing_article?
  end

  # Nothing is asked of any site while the column is not on screen, however
  # it came to be off screen.
  def test_a_squeezed_column_fetches_nothing
    app.showing_article = true
    resize(HackerNews::MainWindow::ROOM_FOR_THREE - 120)
    app.instance_variable_set(:@story, nil)
    app.select_story(0)

    assert_nil pane.requested
  end

  def resize(width)
    window = app.main_window.window
    window.setFrame_display([window.frame.x, window.frame.y, width,
                             window.frame.height], true)
    window.contentView.layoutSubtreeIfNeeded
    app.pump(0.5) { false }
  end

  # ---- what it shows -----------------------------------------------------

  def test_nothing_selected_means_nothing_to_show
    assert pane.showing_placeholder?
    assert_match(/Select a story/, pane.placeholder_text)
  end

  def test_selecting_a_story_asks_for_its_link
    app.select_story(0)

    assert_equal 'https://example.com/article', pane.requested
    refute pane.showing_placeholder?
  end

  # A story that is its own discussion has no page to show, and says so
  # rather than loading the thread a second time.
  def test_a_text_post_has_no_page_to_show
    app.select_story(1)

    assert_nil pane.requested
    assert pane.showing_placeholder?
    assert_match(/its own discussion/, pane.placeholder_text)
  end

  def test_selecting_the_same_story_again_does_not_reload
    app.select_story(0)
    first = pane.requested
    app.select_story(0)

    assert_equal first, pane.requested
  end

  def test_clearing_the_selection_clears_the_column
    app.select_story(0)
    refute pane.showing_placeholder?

    app.search('something that finds nothing')
    assert pane.showing_placeholder?
    assert_nil pane.requested
  ensure
    app.search('')
  end

  # ---- not a crawler -----------------------------------------------------

  # Moving down the list with the arrow keys would otherwise ask every site
  # in turn for a page nobody waited to see.
  def test_the_request_waits_for_the_selection_to_settle
    app.article_delay = 5.0
    app.select_story(0)

    assert_nil pane.requested, 'it should not have asked yet'
    assert app.article_debounce.pending?
  ensure
    app.article_delay = 0
  end

  def test_nothing_is_fetched_while_the_column_is_hidden
    app.showing_article = false
    app.select_story(0)

    assert_nil pane.requested
    refute app.article_debounce.pending?
  end

  # ---- failures ----------------------------------------------------------

  def test_a_page_that_will_not_load_says_so_where_the_page_would_be
    app.select_story(0)
    pane.navigation_failed('The network connection was lost.')

    assert pane.showing_placeholder?
    assert_match(/Could not load/, pane.placeholder_text)
    assert_match(/network connection/, pane.failure)
  end

  # Starting one load cancels the last; that is not a failure worth saying.
  def test_a_cancelled_load_is_not_a_failure
    app.select_story(0)
    pane.navigation_failed('The operation was cancelled.')

    refute pane.showing_placeholder?
    assert_nil pane.failure
  end
end

# The page itself, which the reader window and the article column share.
class TestWebView < Minitest::Test
  def build(&block)
    HackerNews::WebView.new(width: 400, height: 300, &block)
  end

  def test_it_wraps_a_real_web_view
    web = build
    assert_equal 'WKWebView', web.view.objc_class_name.sub(/\ANSKVONotifying_/, '')
    refute_nil web.view.navigationDelegate
  end

  def test_an_unparseable_url_is_not_loaded
    web = build
    assert_nil web.load('http://exa mple.com/ bad')
    assert_nil web.requested
  end

  def test_loading_remembers_what_was_asked_for
    web = build
    assert_equal 'about:blank', web.load('about:blank')
    assert_equal 'about:blank', web.requested
  end

  def test_blanking_forgets_it
    web = build
    web.load('about:blank')
    web.blank
    assert_nil web.requested
  end

  # Starting one load cancels the last; that is not a failure worth telling
  # anybody about, and the reader used to put it in its subtitle.
  def test_a_cancelled_load_is_not_a_failure
    seen = []
    web = build { |event, message| seen << [event, message] }

    web.navigation_failed('The operation was cancelled.')
    assert_empty seen
    assert_nil web.failure

    assert HackerNews::WebView.cancelled?('Error: canceled')
    refute HackerNews::WebView.cancelled?('The network connection was lost.')
  end

  def test_a_real_failure_is_reported_once
    seen = []
    web = build { |event, message| seen << [event, message] }
    web.navigation_failed('The network connection was lost.')

    assert_equal [[:failed, 'The network connection was lost.']], seen
    assert_equal 'The network connection was lost.', web.failure
  end

  def test_finishing_clears_the_failure
    web = build
    web.navigation_failed('The network connection was lost.')
    refute_nil web.failure

    web.navigation_finished
    assert_nil web.failure
  end

  # One Objective-C delegate class serves every instance, so each has to find
  # its own owner -- a class defined per instance would have its methods
  # replaced by the next one and then answer for the wrong view.
  def test_two_of_them_do_not_answer_for_each_other
    first  = []
    second = []
    one = build { |event, _m| first << event }
    two = build { |event, _m| second << event }

    refute_equal one.view.navigationDelegate.objc_address,
                 two.view.navigationDelegate.objc_address

    HackerNews::WebView.owner_of(two.view.navigationDelegate).navigation_started
    assert_empty first
    assert_equal [:started], second
  end
end
