# frozen_string_literal: true

# Acting on a story: sharing, copying, the context menu.
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

class TestHackerNewsSharing < Minitest::Test
  include HackerNews::AppHarness

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
  include HackerNews::AppHarness

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
    fixed = titles.reject { |t| t.start_with?('Mark as') || saved_item?(t) }
    assert_equal ['Open Link', 'Open on Hacker News', 'Copy Article Link',
                  'Copy Comments Link', 'Share…'], fixed
    assert_equal 1, titles.count { |t| t.start_with?('Mark as') }
    assert_equal 1, titles.count { |t| saved_item?(t) }
  end

  # Worded for whichever story is being acted on, like the read item.
  def saved_item?(title)
    ['Save Article', 'Remove from Saved'].include?(title)
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
