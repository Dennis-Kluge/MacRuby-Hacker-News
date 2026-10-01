# frozen_string_literal: true

# Preferences: what is stored, and what applying one does.
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

class TestHackerNewsSettings < Minitest::Test
  def setup
    # Preferences of its own: the real store is shared with the running app.
    @settings = HackerNews::Settings.new(HackerNews::MemoryDefaults.new)
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
    assert_equal :all, HackerNews::Settings.new(@settings.defaults).expansion
  end

  def test_reading_history_round_trips
    @settings.remember_read = false
    assert_equal false, HackerNews::Settings.new(@settings.defaults).remember_read?
  end

  # A stale or hand-edited value must not leave the app in a bad state.
  def test_an_unknown_stored_mode_falls_back
    @settings.defaults.setObject_forKey('nonsense', HackerNews::Settings::EXPANSION_KEY)
    assert_equal :collapsed, HackerNews::Settings.new(@settings.defaults).expansion
  end

  # registerDefaults must not clobber a value the user chose.
  def test_registering_defaults_leaves_choices_alone
    @settings.expansion = :top_level
    HackerNews::Settings.register_defaults(@settings.defaults)
    assert_equal :top_level, HackerNews::Settings.new(@settings.defaults).expansion
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
  include HackerNews::AppHarness

  def setup
    app.settings.reset
    history_store.delete(HackerNews::ReadingHistory::KEY)
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

    stored = history_store.read(HackerNews::ReadingHistory::KEY)
    refute_nil stored
    assert_includes stored.to_a.map(&:to_s), '1'
  end

  # With history off the mark still shows, but nothing reaches the disk.
  def test_nothing_is_saved_when_history_is_off
    app.set_remember_read(false)
    app.select_story(0)

    assert app.visited?(app.stories[0]), 'the session mark should still apply'
    assert_nil history_store.read(HackerNews::ReadingHistory::KEY)
  end

  def test_turning_history_off_forgets_what_was_stored
    app.set_remember_read(true)
    app.select_story(0)
    refute_nil history_store.read(HackerNews::ReadingHistory::KEY)

    app.set_remember_read(false)
    assert_nil history_store.read(HackerNews::ReadingHistory::KEY)
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
    # Preferences of its own: the real store is shared with the running app.
    @settings = HackerNews::Settings.new(HackerNews::MemoryDefaults.new)
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
    assert_equal :large, HackerNews::Settings.new(@settings.defaults).text_size
  end

  def test_section_round_trips
    @settings.section = :ask
    assert_equal :ask, HackerNews::Settings.new(@settings.defaults).section.key
  end

  def test_refresh_interval_round_trips_and_rejects_junk
    @settings.refresh_interval = 60
    assert_equal 60, HackerNews::Settings.new(@settings.defaults).refresh_interval

    @settings.defaults.setInteger_forKey(7, HackerNews::Settings::REFRESH_KEY)
    assert_equal 300, HackerNews::Settings.new(@settings.defaults).refresh_interval
  end

  def test_page_size_round_trips_and_rejects_junk
    @settings.page_size = 50
    assert_equal 50, HackerNews::Settings.new(@settings.defaults).page_size

    @settings.defaults.setInteger_forKey(999, HackerNews::Settings::PAGE_SIZE_KEY)
    assert_equal 30, HackerNews::Settings.new(@settings.defaults).page_size
  end

  def test_stale_values_fall_back
    defaults = @settings.defaults
    defaults.setObject_forKey('huge', HackerNews::Settings::TEXT_SIZE_KEY)
    defaults.setObject_forKey('yearly', HackerNews::Settings::SECTION_KEY)

    assert_equal :medium, HackerNews::Settings.new(@settings.defaults).text_size
    assert_equal :top,    HackerNews::Settings.new(@settings.defaults).section.key
  end
end

class TestHackerNewsSettingsApplied < Minitest::Test
  include HackerNews::AppHarness

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

# The preferences window is laid out top-down and then resized to fit.
class TestHackerNewsPreferencesWindow < Minitest::Test
  include HackerNews::AppHarness

  def prefs
    app.preferences
  end

  def content
    prefs.window.contentView
  end

  def subviews
    (0...content.subviews.count).map { |i| content.subviews.objectAtIndex(i) }
  end

  # It used to only ever shrink, so adding two rows pushed the last of them
  # off the bottom and nothing said so.
  def test_every_row_is_inside_the_window
    height = content.frame.height

    subviews.each do |view|
      frame = view.frame
      assert_operator frame.y, :>=, -0.5,
                      "a row starts below the window at y=#{frame.y.round}"
      assert_operator frame.y + frame.height, :<=, height + 0.5,
                      "a row runs past the top of the window"
    end
  end

  def test_the_window_grew_to_fit_its_rows
    assert_operator content.frame.height, :>, HackerNews::Preferences::HEIGHT,
                    'the rows need more than the starting height'
  end

  def test_the_rows_that_should_be_there_are
    titles = subviews.map { |v| v.stringValue.to_s rescue '' }.reject(&:empty?)

    ['Reading', 'Stories', 'Links', 'History', 'Saved Articles'].each do |section|
      assert_includes titles, section
    end
  end
end
