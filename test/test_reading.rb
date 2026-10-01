# frozen_string_literal: true

# Reading stories: the list, its state, and how it pages.
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

class TestHackerNewsApp < Minitest::Test
  # The data source classes are registered with the runtime by name, so one
  # app is shared and its stub is re-primed per test.
  include HackerNews::AppHarness

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

class TestHackerNewsReadState < Minitest::Test
  include HackerNews::AppHarness

  # Endless method definitions are Ruby 3.0+; the arm64 interpreter is 2.6.
  def app
    self.class.app
  end

  def stub
    self.class.stub
  end

  def setup
    history_store.delete(HackerNews::ReadingHistory::KEY)
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
    stored = history_store.read(HackerNews::ReadingHistory::KEY)
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
  include HackerNews::AppHarness

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

class TestHackerNewsEmptyState < Minitest::Test
  include HackerNews::AppHarness

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

class TestHackerNewsSections < Minitest::Test
  include HackerNews::AppHarness

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

  # The sections that stand for something on Hacker News are exactly Hacker
  # News's own. Saved is ours, and is answered from disk.
  def test_the_sections_match_hacker_news
    remote = HackerNews::Section::ALL.reject(&:local?)
    assert_equal %i[top new best ask show jobs], remote.map(&:key)
    assert_equal %w[Top New Best Ask Show Jobs], remote.map(&:label)
  end

  def test_saved_is_the_only_local_section
    local = HackerNews::Section::ALL.select(&:local?)
    assert_equal [:saved], local.map(&:key)
  end

  def test_switching_section_reloads_from_that_section
    app.show_section(:ask)

    assert_equal :ask, app.section.key
    assert_equal :ask, stub.last_request[:section].key
    assert_equal 0, stub.last_request[:page], 'should start from the first page'
  end

  # A fresh Settings over the same store, which is what the next launch gets
  # -- not a fresh Settings over the reader's real one.
  def test_the_choice_is_remembered
    app.show_section(:show)
    reopened = HackerNews::Settings.new(app.settings.defaults)
    assert_equal :show, reopened.section.key
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
  include HackerNews::AppHarness

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
  include HackerNews::AppHarness

  def self.stub
    @stub ||= HackerNews::StubAPI.new.tap do |api|
      api.stories = [{ id: '1', title: 'A story', author: 'a', points: 1,
                       comments: 1, url: 'https://a', domain: 'a' }]
    end
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
