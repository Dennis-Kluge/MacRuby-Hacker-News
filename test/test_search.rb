# frozen_string_literal: true

# Searching: what is asked of the API, and the filter bar.
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

class TestHackerNewsSearch < Minitest::Test
  RESULTS = {
    'rust' => [
      { id: '90', title: 'Rust in production', author: 'a', points: 9, comments: 3,
        url: 'https://example.com/rust', domain: 'example.com', age: '2 years ago' }
    ]
  }.freeze

  include HackerNews::AppHarness

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
  include HackerNews::AppHarness

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

# Saving articles, the section that shows them, and writing them out.
