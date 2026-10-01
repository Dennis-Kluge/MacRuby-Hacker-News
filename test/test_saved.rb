# frozen_string_literal: true

# Saving articles, the section that shows them, and exporting.
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

class TestHackerNewsSaved < Minitest::Test
  include HackerNews::AppHarness

  def setup
    app.settings.reset
    stub.error = nil
    stub.pages = nil
    stub.search_results = {}
    stub.stories = [
      { id: '42', title: 'First story', author: 'alice', points: 9, comments: 3,
        url: 'https://example.com/a', domain: 'example.com' },
      { id: '43', title: 'Second story', author: 'bob', points: 4, comments: 1,
        url: 'https://example.com/b', domain: 'example.com' }
    ]
    stub.tree = { 'children' => [] }
    favorites.clear
    # The menu bar outlives each test, and the save item's title depends on
    # what is selected, so it is put back to a known wording.
    app.story_view.deselect
    app.menu_bar.refresh_titles
    app.search_delay = 0
    app.search('')
    app.show_section(:top)
    app.load_front_page
  end

  def teardown
    favorites.clear
    app.search('')
    app.show_section(:top)
    app.settings.reset
  end

  # ---- saving ------------------------------------------------------------

  def test_saving_the_selected_story
    app.select_story(0)
    assert_equal :added, app.toggle_saved

    assert_equal 1, app.saved_count
    assert favorites.include?('42')
    assert_match(/Saved/, app.status_text)
  end

  def test_saving_again_removes_it
    app.select_story(0)
    app.toggle_saved
    assert_equal :removed, app.toggle_saved

    assert_equal 0, app.saved_count
    assert_match(/Removed/, app.status_text)
  end

  def test_saving_with_nothing_selected
    app.story_view.deselect
    assert_nil app.toggle_saved
    assert_match(/Select a story first/, app.status_text)
  end

  # The whole story is kept, because the API will not necessarily still
  # answer for it when the export happens.
  def test_it_keeps_the_whole_story
    app.select_story(0)
    app.toggle_saved

    kept = favorites.stories.first
    assert_equal 'First story',            kept[:title]
    assert_equal 'https://example.com/a',  kept[:url]
    assert_equal 'alice',                  kept[:author]
    refute_nil kept[:saved_at]
  end

  # ---- the Saved section -------------------------------------------------

  def test_saved_is_a_section_of_its_own
    assert_includes HackerNews::Section.keys, :saved
    assert HackerNews::Section[:saved].local?
    assert_equal '7', HackerNews::Section[:saved].shortcut
  end

  def test_the_section_shows_what_was_saved
    app.select_story(0)
    app.toggle_saved
    app.show_section(:saved)

    assert app.list.local?
    assert_equal 1, app.list.size
    assert_equal '42', app.list[0][:id]
  end

  # Nothing is requested for it, which is the point of a local section.
  def test_the_section_asks_the_api_for_nothing
    app.select_story(0)
    app.toggle_saved
    before = stub.last_request
    app.show_section(:saved)

    assert_same before, stub.last_request
    refute app.list.more?, 'there is no second page of saved stories'
  end

  def test_saving_while_the_section_is_showing_updates_it
    app.show_section(:saved)
    assert_equal 0, app.list.size

    app.show_section(:top)
    app.select_story(1)
    app.toggle_saved
    app.show_section(:saved)
    assert_equal 1, app.list.size

    # And removing it takes the row away again.
    app.select_story(0)
    app.toggle_saved
    assert_equal 0, app.list.size
  end

  def test_the_search_field_filters_the_saved_list
    app.show_section(:top)
    app.select_story(0)
    app.toggle_saved
    app.select_story(1)
    app.toggle_saved
    app.show_section(:saved)
    assert_equal 2, app.list.size

    app.search('second')
    assert_equal 1, app.list.size
    assert_equal '43', app.list[0][:id]

    app.search('')
    assert_equal 2, app.list.size
  end

  # Sorting and windowing are questions for the API, so the bar has nothing
  # to say about a list held in hand.
  def test_the_filter_bar_stays_hidden_while_searching_saved
    app.show_section(:top)
    app.select_story(0)
    app.toggle_saved
    app.show_section(:saved)

    app.search('first')
    assert app.searching?
    refute app.search_bar.visible?
  end

  def test_an_empty_saved_section_says_so
    app.show_section(:saved)

    assert app.story_view.empty_visible?
    assert_match(/Nothing saved/, app.story_view.empty_text)
    assert_equal HackerNews::StoryListView::NO_SAVED_SYMBOL,
                 app.story_view.placeholder.symbol_name
    assert_match(/Nothing saved/, app.status_text)
  end

  # "2 days ago" beside a saved story reads as the story's age unless it says
  # which date it means.
  def test_a_saved_row_says_when_it_was_saved
    app.select_story(0)
    app.toggle_saved
    app.show_section(:saved)

    meta = app.story_view.cell(0).string.to_s.split("\n").last
    assert_includes meta, 'saved just now'
  end

  def test_a_story_row_shows_its_own_age
    meta = app.story_view.cell(0).string.to_s.split("\n").last
    refute_includes meta, 'saved '
  end

  # A star marks the saved ones where that distinguishes anything; in the
  # Saved section every story carries one, so it would say nothing.
  def test_a_star_marks_a_saved_story
    app.select_story(0)
    app.toggle_saved
    app.story_view.invalidate

    assert_includes app.story_view.cell(0).string.to_s, HackerNews::Typography::STAR
    refute_includes app.story_view.cell(1).string.to_s, HackerNews::Typography::STAR

    app.show_section(:saved)
    refute_includes app.story_view.cell(0).string.to_s, HackerNews::Typography::STAR
  end

  def test_the_status_counts_saved_stories
    app.select_story(0)
    app.toggle_saved
    app.show_section(:saved)

    assert_match(/1 saved story/, app.status_text)
    refute_match(/scroll for more/, app.status_text)
  end

  # ---- the context menu --------------------------------------------------

  def test_the_context_menu_words_itself_for_the_story
    app.story_view.select(0)
    app.story_view.prepare_context_menu
    item = context_item
    assert_equal 'Save Article', item.title.to_s

    app.toggle_saved
    app.story_view.prepare_context_menu
    assert_equal 'Remove from Saved', context_item.title.to_s
  end

  def context_item
    menu = app.story_view.context_menu
    (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i) }
                            .find { |i| ['Save Article', 'Remove from Saved'].include?(i.title.to_s) }
  end

  # ---- the menus ---------------------------------------------------------

  def test_the_file_menu_offers_saving_and_exporting
    # The save item's title depends on the selection, so it is settled first.
    app.story_view.deselect
    app.menu_bar.refresh_titles

    save = app.menu_bar.item_titled('File', 'Save Article')
    refute_nil save
    assert_equal 'd', save.keyEquivalent.to_s

    export = app.menu_bar.item_titled('File', 'Export Saved Articles')
    refute_nil export
    titles = (0...export.submenu.numberOfItems).map { |i| export.submenu.itemAtIndex(i).title.to_s }
    assert_equal HackerNews::Export.labels, titles
  end

  # ---- exporting ---------------------------------------------------------

  def with_export_to(path)
    app.save_panel_runner = ->(_format) { path }
    yield
  ensure
    app.save_panel_runner = nil
  end

  def test_exporting_writes_the_file
    app.select_story(0)
    app.toggle_saved

    Dir.mktmpdir('hn-export') do |dir|
      HackerNews::Export.keys.each do |key|
        path = File.join(dir, HackerNews::Export.filename(key))
        with_export_to(path) { assert_equal path, app.export_saved(key) }

        assert File.file?(path), "#{key} should have been written"
        assert_includes File.read(path), 'First story'
        assert_match(/Exported 1 story/, app.status_text)
      end
    end
  end

  def test_exporting_nothing_does_not_open_a_panel
    asked = false
    app.save_panel_runner = ->(_f) { asked = true }

    assert_nil app.export_saved(:markdown)
    refute asked, 'there is nothing to ask about'
    assert_match(/Nothing saved to export/, app.status_text)
  ensure
    app.save_panel_runner = nil
  end

  def test_a_dismissed_panel_writes_nothing
    app.select_story(0)
    app.toggle_saved

    with_export_to(nil) { assert_nil app.export_saved(:markdown) }
    assert_match(/cancelled/, app.status_text)
  end

  def test_a_path_that_cannot_be_written_is_reported
    app.select_story(0)
    app.toggle_saved

    with_export_to('/nowhere-at-all/hacker-news-favorites.md') do
      assert_nil app.export_saved(:markdown)
    end
    assert_match(/Could not write/, app.status_text)
  end

  # ---- importing ---------------------------------------------------------

  def with_import_from(path)
    app.open_panel_runner = -> { path }
    yield
  ensure
    app.open_panel_runner = nil
  end

  def exported_file(dir)
    app.select_story(0)
    app.toggle_saved
    path = File.join(dir, 'hacker-news-saved.json')
    with_export_to(path) { app.export_saved(:json) }
    favorites.clear
    path
  end

  def test_importing_an_export_brings_the_stories_back
    Dir.mktmpdir('hn-import') do |dir|
      path = exported_file(dir)
      assert_equal 0, app.saved_count

      with_import_from(path) { assert_equal 1, app.import_saved }
      assert_equal 1, app.saved_count
      assert favorites.include?('42')
      assert_match(/Imported 1 story/, app.status_text)
    end
  end

  # Importing the same file twice should do nothing the second time, and say
  # so rather than looking like it failed.
  def test_importing_twice_adds_nothing
    Dir.mktmpdir('hn-import') do |dir|
      path = exported_file(dir)
      with_import_from(path) { app.import_saved }
      with_import_from(path) { assert_equal 0, app.import_saved }

      assert_equal 1, app.saved_count
      assert_match(/Already had/, app.status_text)
    end
  end

  def test_a_dismissed_panel_imports_nothing
    with_import_from(nil) { assert_nil app.import_saved }
    assert_match(/cancelled/, app.status_text)
  end

  def test_a_file_that_is_not_ours_is_reported
    Dir.mktmpdir('hn-import') do |dir|
      path = File.join(dir, 'something-else.json')
      File.write(path, 'this is not an export')

      with_import_from(path) { assert_nil app.import_saved }
      assert_match(/not an export/, app.status_text)
    end
  end

  def test_a_file_that_cannot_be_read_is_reported
    with_import_from('/nowhere-at-all/saved.json') { assert_nil app.import_saved }
    assert_match(/Could not read/, app.status_text)
  end

  # The Saved section is a view of the store, so an import has to show up.
  def test_importing_while_the_section_is_showing_updates_it
    Dir.mktmpdir('hn-import') do |dir|
      path = exported_file(dir)
      app.show_section(:saved)
      assert_equal 0, app.list.size

      with_import_from(path) { app.import_saved }
      assert_equal 1, app.list.size
    end
  end

  # The right-click menu has reworded itself since it existed; the File menu
  # said "Save Article" over a story that was already saved.
  def test_the_file_menu_item_says_which_way_it_will_go
    app.select_story(0)
    app.menu_bar.refresh_titles
    item = app.menu_bar.item_titled('File', 'Save Article')
    refute_nil item, 'should read Save Article for an unsaved story'

    app.toggle_saved
    app.menu_bar.refresh_titles
    refute_nil app.menu_bar.item_titled('File', 'Remove from Saved')
    assert_nil app.menu_bar.item_titled('File', 'Save Article')

    # And the shortcut travels with it.
    assert_equal 'd', app.menu_bar.item_titled('File', 'Remove from Saved')
                                  .keyEquivalent.to_s
  end

  def test_the_file_menu_offers_it
    item = app.menu_bar.item_titled('File', 'Import Saved Articles…')
    refute_nil item
  end

  def test_clearing_from_the_preferences
    app.select_story(0)
    app.toggle_saved
    assert_equal 1, app.saved_count

    app.clear_saved
    assert_equal 0, app.saved_count
    assert_match(/cleared/, app.status_text)
  end
end

# The title bar carries controls; the list carries its own status line.
