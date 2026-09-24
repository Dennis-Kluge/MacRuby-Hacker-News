# frozen_string_literal: true

# The models carry no AppKit, so they can be exercised on their own -- no
# window, no run loop, no network.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../cocoa/lib', __dir__)
require 'minitest/autorun'
require 'time'
require 'cocoa'
require 'cocoa/pooled_tests'

require 'hackernews'

module HackerNews
  # Stands in for NSUserDefaults.
  class MemoryStore
    def initialize
      @data = {}
    end
    def read(key)
      @data[key]
    end
    def write(key, values)
      @data[key] = values.dup
    end
    def delete(key)
      @data.delete(key)
    end
    def [](key)
      @data[key]
    end
  end

  # Answers immediately from canned pages.
  class FakeAPI
    attr_reader :requests

    def initialize(pages: [], error: nil)
      @pages    = pages
      @error    = error
      @requests = []
    end

    attr_writer :pages, :error

    def stories(page = 0, per_page = 30, query: HackerNews::Query.new, &block)
      @requests << { page: page, per_page: per_page, query: query, section: query.section }
      return block.call(nil, false, @error) if @error

      block.call(@pages[page] || [], page < @pages.size - 1, nil)
    end
  end

  # Holds its replies until the test releases them, which is how a reply that
  # arrives after a reload can be arranged deliberately.
  class DeferredAPI
    def initialize
      @pending = []
    end

    def stories(page = 0, per_page = 30, query: HackerNews::Query.new, &block)
      @pending << { page: page, per_page: per_page, query: query, block: block }
    end

    def pending
      @pending.size
    end

    # Answer the oldest outstanding request.
    def answer(stories, more: false, error: nil)
      request = @pending.shift
      request[:block].call(stories, more, error)
      request
    end
  end

  # Just enough of Settings to drive the models.
  class FakeSettings
    attr_accessor :page_size, :section, :remember_read

    def initialize(remember: true)
      @page_size     = 30
      @section       = Section.default
      @remember_read = remember
    end

    def remember_read?
      @remember_read
    end

  end
end

def story(id, title = "Story #{id}")
  { id: id.to_s, title: title, author: 'a', points: 1, comments: 1,
    url: "https://example.com/#{id}", domain: 'example.com' }
end

class TestReadingHistory < Minitest::Test
  def setup
    @store    = HackerNews::MemoryStore.new
    @settings = HackerNews::FakeSettings.new
    @history  = HackerNews::ReadingHistory.new(@settings, store: @store)
  end

  def test_it_starts_empty
    assert @history.empty?
    refute @history.include?('1')
  end

  def test_adding_reports_whether_it_was_new
    assert_equal true,  @history.add('1')
    assert_equal false, @history.add('1')
    assert_equal 1, @history.size
  end

  def test_it_persists_when_remembering
    @history.add('7')
    assert_equal ['7'], @store[HackerNews::ReadingHistory::KEY]
  end

  def test_it_reloads_what_was_stored
    @history.add('7')
    revived = HackerNews::ReadingHistory.new(@settings, store: @store)
    assert revived.include?('7')
  end

  def test_nothing_is_written_when_not_remembering
    @settings.remember_read = false
    history = HackerNews::ReadingHistory.new(@settings, store: @store)
    history.add('9')

    assert history.include?('9'), 'the session mark should still apply'
    assert_nil @store[HackerNews::ReadingHistory::KEY]
  end

  # Turning it off forgets the disk but keeps the session, so the list does not
  # visibly reset under the reader.
  def test_turning_it_off_forgets_the_disk_but_not_the_session
    @history.add('4')
    @history.remembering = false

    assert @history.include?('4')
    assert_nil @store[HackerNews::ReadingHistory::KEY]
  end

  def test_clearing_empties_both
    @history.add('4')
    @history.clear
    assert @history.empty?
    assert_nil @store[HackerNews::ReadingHistory::KEY]
  end

  def test_it_forgets_the_oldest_beyond_the_cap
    cap = HackerNews::ReadingHistory::CAP
    (1..(cap + 10)).each { |i| @history.add(i) }

    assert_equal cap, @history.size
    refute @history.include?('1'),   'the oldest should have been dropped'
    assert @history.include?((cap + 10).to_s)
  end
end

class TestCommentThread < Minitest::Test
  def node(id, text: "text #{id}", author: 'a', children: [])
    { 'id' => id, 'author' => author, 'text' => text,
      'created_at' => Time.now.iso8601, 'children' => children }
  end

  def test_an_empty_thread
    thread = HackerNews::CommentThread.from('children' => [])
    assert thread.empty?
    assert_equal 0, thread.size
    assert_equal [], thread.children(nil)
  end

  def test_it_flattens_a_tree
    thread = HackerNews::CommentThread.from(
      'children' => [node(1, children: [node(2), node(3, children: [node(4)])])]
    )

    assert_equal [1], thread.roots
    assert_equal 4, thread.size
    assert_equal [2, 3], thread.children(1)
    assert_equal [4], thread.children(3)
    assert_equal [], thread.children(2)
  end

  def test_expandability_follows_the_children
    thread = HackerNews::CommentThread.from('children' => [node(1, children: [node(2)])])
    assert thread.expandable?(1)
    refute thread.expandable?(2)
    refute thread.expandable?(999)
  end

  def test_html_is_converted_and_links_recorded
    thread = HackerNews::CommentThread.from(
      'children' => [node(1, text: '<p>see <a href="https://x.io">this</a></p>')]
    )
    comment = thread.node(1)

    assert_equal 'see this', comment[:text]
    assert_equal ['https://x.io'], comment[:links].map { |l| l[:url] }
  end

  def test_deleted_leaves_are_dropped
    thread = HackerNews::CommentThread.from(
      'children' => [node(1, text: nil, author: nil), node(2)]
    )
    assert_equal [2], thread.roots
  end

  # A deleted comment with replies stays, or the replies leave the thread.
  def test_deleted_comments_with_replies_are_kept
    thread = HackerNews::CommentThread.from(
      'children' => [node(1, text: nil, author: nil, children: [node(2)])]
    )

    assert_equal [1], thread.roots
    assert_equal '[deleted]', thread.node(1)[:author]
    assert_equal '[deleted]', thread.node(1)[:text]
    assert_equal [2], thread.children(1)
  end

  def test_unknown_ids_answer_safely
    thread = HackerNews::CommentThread.from('children' => [node(1)])
    assert_nil thread.node(999)
    assert_equal [], thread.children(999)
  end
end

class TestStoryList < Minitest::Test
  def build(pages: [], remember: true)
    @settings = HackerNews::FakeSettings.new(remember: remember)
    @api      = HackerNews::FakeAPI.new(pages: pages)
    @history  = HackerNews::ReadingHistory.new(@settings, store: HackerNews::MemoryStore.new)
    HackerNews::StoryList.new(api: @api, history: @history, settings: @settings)
  end

  def events(list, &block)
    seen = []
    block.call(->(event, payload) { seen << [event, payload] })
    seen
  end

  def test_it_loads_the_first_page
    list = build(pages: [[story(1), story(2)]])
    list.reload

    assert_equal 2, list.size
    assert_equal %w[1 2], list.stories.map { |s| s[:id] }
    refute list.more?
  end

  def test_it_reports_what_happened
    list = build(pages: [[story(1)], [story(2)]])
    seen = events(list) { |cb| list.reload(&cb) }

    assert_equal %i[reset loading loaded], seen.map(&:first)
    assert_equal 1, seen.last.last, 'one story was added'
  end

  def test_paging_appends
    list = build(pages: [[story(1)], [story(2)]])
    list.reload
    assert list.more?

    list.load_next
    assert_equal %w[1 2], list.stories.map { |s| s[:id] }
    refute list.more?
  end

  # Consecutive pages overlap, so the same story arrives more than once.
  def test_duplicates_are_dropped
    list = build(pages: [[story(1), story(2)], [story(2), story(3)]])
    list.reload
    list.load_next

    assert_equal %w[1 2 3], list.stories.map { |s| s[:id] }
  end

  def test_a_page_of_duplicates_is_skipped
    list = build(pages: [[story(1)], [story(1)], [story(2)]])
    list.reload
    list.load_next

    assert_equal %w[1 2], list.stories.map { |s| s[:id] }
  end

  def test_it_gives_up_after_too_many_empty_pages
    pages = [[story(1)]] * (HackerNews::StoryList::MAX_EMPTY_PAGES + 4)
    list  = build(pages: pages)
    list.reload
    list.load_next

    assert_equal 1, list.size
    assert_operator list.page, :<=, HackerNews::StoryList::MAX_EMPTY_PAGES + 2
  end

  def test_an_error_stops_paging
    list = build(pages: [[story(1)], [story(2)]])
    list.reload
    @api.error = 'offline'

    seen = events(list) { |cb| list.load_next(&cb) }
    assert_equal :error, seen.last.first
    assert_equal 'offline', seen.last.last
    refute list.more?
  end

  def test_reload_starts_over
    list = build(pages: [[story(1)], [story(2)]])
    list.reload
    list.load_next
    assert_equal 2, list.size

    list.reload
    assert_equal 1, list.size
  end

  def test_it_passes_the_preferences_to_the_api
    list = build(pages: [[story(1)]])
    list.ask(list.query.with_section(HackerNews::Section[:show]))
    @settings.page_size = 50
    list.reload

    assert_equal :show, @api.requests.last[:section].key
    assert_equal 50,    @api.requests.last[:per_page]
  end

  def test_read_state
    list = build(pages: [[story(1), story(2)]])
    list.reload

    refute list.read?(list[0])
    assert list.mark_read(list[0])
    assert list.read?(list[0])
    refute list.read?(list[1])
    refute list.mark_read(list[0]), 'marking twice reports no change'
  end

  def test_bounds
    list = build(pages: [[story(1)]])
    list.reload

    assert_nil list[-1]
    assert_nil list[99]
    assert_equal 0, list.index_of(list[0])
  end
end

class TestQuery < Minitest::Test
  Q = HackerNews::Query
  S = HackerNews::Section

  def test_no_text_is_not_a_search
    refute Q.new.search?
    refute Q.new(text: '').search?
    refute Q.new(text: "  \t ").search?
  end

  def test_text_is_stripped
    assert_equal 'rust', Q.new(text: '  rust  ').text
    assert Q.new(text: ' rust ').search?
  end

  def test_it_defaults_to_the_default_section
    assert_equal S.default.key, Q.new.section.key
  end

  def test_narrowing_keeps_the_section
    query = Q.new(section: S[:show]).with_text('pi')
    assert_equal :show, query.section.key
    assert_equal 'pi', query.text
  end

  def test_changing_section_keeps_the_search
    query = Q.new(text: 'pi').with_section(S[:ask])
    assert_equal :ask, query.section.key
    assert_equal 'pi', query.text
  end

  # Value equality is what lets the list ignore a keystroke that changed
  # nothing -- a typed and then deleted space, say.
  def test_two_queries_asking_the_same_thing_are_equal
    assert_equal Q.new(text: 'pi'), Q.new(text: ' pi ')
    assert_equal Q.new(text: 'pi').hash, Q.new(text: 'pi').hash
    refute_equal Q.new(text: 'pi'), Q.new(text: 'pie')
    refute_equal Q.new(text: 'pi'), Q.new(section: S[:ask], text: 'pi')
    refute_equal Q.new, 'not a query'
  end

  def test_it_cannot_change_under_a_request_in_flight
    query = Q.new(text: 'pi')
    assert query.frozen?
    refute_same query, query.with_text('pie')
  end

  def test_it_describes_itself
    assert_equal 'Top', Q.new.to_s
    assert_match(/Top/, Q.new(text: 'pi').to_s)
    assert_match(/pi/,  Q.new(text: 'pi').to_s)
  end
end

class TestStoryListSearching < Minitest::Test
  def setup
    @api      = HackerNews::FakeAPI.new
    @settings = HackerNews::FakeSettings.new
    @history  = HackerNews::ReadingHistory.new(@settings, store: HackerNews::MemoryStore.new)
  end

  def build(pages: [])
    @api.pages = pages
    HackerNews::StoryList.new(api: @api, history: @history, settings: @settings)
  end

  def test_it_starts_from_the_section_the_preferences_name
    @settings.section = HackerNews::Section[:ask]
    assert_equal :ask, build.query.section.key
    refute build.searching?
  end

  def test_asking_the_same_question_changes_nothing
    list = build
    refute list.ask(list.query), 'an unchanged query should not ask for a reload'
    assert list.ask(list.query.with_text('rust'))
    refute list.ask(list.query.with_text('  rust  ')), 'stripping makes these the same'
  end

  def test_the_query_reaches_the_api
    list = build(pages: [[story(1)]])
    list.ask(list.query.with_text('rust'))
    list.reload

    assert_equal 'rust', @api.requests.last[:query].text
    assert list.searching?
  end

  def test_an_empty_search_is_the_way_back
    list = build(pages: [[story(1)]])
    list.ask(list.query.with_text('rust'))
    assert list.ask(list.query.with_text(''))
    refute list.searching?
  end

  # Typing "ru" then "rust" leaves the first request in flight. Its answer is
  # to a question nobody is asking any more, and must not reach the list.
  def test_a_reload_orphans_the_reply_still_in_flight
    api  = HackerNews::DeferredAPI.new
    list = HackerNews::StoryList.new(api: api, history: @history, settings: @settings)

    list.reload
    assert_equal 1, api.pending

    list.ask(list.query.with_text('rust'))
    list.reload
    assert_equal 2, api.pending

    api.answer([story(1), story(2)]) # the stale one
    assert_equal 0, list.size, 'a stale reply must not reach the list'

    api.answer([story(3)])
    assert_equal 1, list.size
  end

  def test_an_orphaned_reply_does_not_unset_loading
    api  = HackerNews::DeferredAPI.new
    list = HackerNews::StoryList.new(api: api, history: @history, settings: @settings)

    list.reload
    list.reload # orphans the first
    api.answer([story(1)])

    assert list.loading?, 'the second request is still outstanding'
  end
end

class TestChoices < Minitest::Test
  TABLES = [HackerNews::Section, HackerNews::Sorting, HackerNews::Period].freeze

  def test_every_table_answers_the_same_questions
    TABLES.each do |table|
      assert_equal table::ALL.first, table.default, table.name
      assert_equal table::ALL.map(&:key), table.keys, table.name
      assert_equal table::ALL.map(&:label), table.labels, table.name
      assert_equal table::ALL[1], table.at(1), table.name
    end
  end

  # Keys arrive from the preferences and from menus, so a stale or hand-edited
  # one has to fall back rather than raise.
  def test_an_unknown_key_falls_back
    TABLES.each do |table|
      assert_equal table.default, table['nonsense'], table.name
      assert_equal table.default, table.at(99), table.name
      assert_equal 0, table.index_of(:nonsense), table.name
    end
  end

  def test_keys_can_be_strings_or_symbols
    TABLES.each do |table|
      key = table.keys.last
      assert_equal table[key], table[key.to_s], table.name
      assert_equal table.keys.size - 1, table.index_of(key.to_s), table.name
    end
  end

  def test_the_entries_are_frozen
    TABLES.each { |table| table::ALL.each { |entry| assert entry.frozen?, table.name } }
  end
end

class TestSearchOptions < Minitest::Test
  S = HackerNews::Section

  # The API offers two rankings and no more; there is no sort by points.
  def test_there_are_two_sortings
    assert_equal %i[relevance newest], HackerNews::Sorting.keys
    assert_equal :search,         HackerNews::Sorting[:relevance].endpoint
    assert_equal :search_by_date, HackerNews::Sorting[:newest].endpoint
  end

  # A section already implies a ranking, which is what a search begun from it
  # should start out with.
  def test_a_section_implies_a_sorting
    assert_equal :newest,    HackerNews::Sorting.for_section(S[:new]).key
    assert_equal :newest,    HackerNews::Sorting.for_section(S[:jobs]).key
    assert_equal :relevance, HackerNews::Sorting.for_section(S[:top]).key
    assert_equal :relevance, HackerNews::Sorting.for_section(S[:ask]).key
  end

  def test_only_the_unranked_sorting_asks_precisely
    assert HackerNews::Sorting[:relevance].ranked?
    assert_empty HackerNews::Sorting[:relevance].parameters

    refute HackerNews::Sorting[:newest].ranked?
    assert_includes HackerNews::Sorting[:newest].parameters, 'typoTolerance=false'
  end

  # The extra parameters belong to the search, not to the plain list.
  def test_parameters_only_apply_to_a_search
    newest = HackerNews::Sorting[:newest]
    assert_empty HackerNews::Query.new(sorting: newest).parameters
    refute_empty HackerNews::Query.new(sorting: newest, text: 'rust').parameters
  end

  def test_all_time_has_no_window
    assert HackerNews::Period[:all].all_time?
    assert_nil HackerNews::Period[:all].seconds
    assert_nil HackerNews::Period[:all].since
  end

  def test_a_period_counts_back_from_now
    now = Time.now
    assert_equal now.to_i - 604_800, HackerNews::Period[:week].since(now)
    refute HackerNews::Period[:week].all_time?
  end

  def test_the_periods_grow
    seconds = HackerNews::Period::ALL.drop(1).map(&:seconds)
    assert_equal seconds.sort, seconds
  end
end

class TestQuerySearchOptions < Minitest::Test
  Q = HackerNews::Query
  S = HackerNews::Section

  def test_it_defaults_to_relevance_over_all_time
    assert_equal :relevance, Q.new.sorting.key
    assert_equal :all,       Q.new.period.key
  end

  # Without a search the section's own endpoint and window apply, which is
  # what keeps the plain lists current.
  def test_an_unsearched_query_defers_to_its_section
    plain = Q.new(section: S[:new], sorting: HackerNews::Sorting[:relevance])
    assert_equal :search_by_date, plain.endpoint
    assert_equal S[:best].window, Q.new(section: S[:best]).window
  end

  def test_a_search_is_ranked_by_its_sorting
    query = Q.new(section: S[:new], text: 'rust')
    assert_equal :search, query.endpoint, 'the sorting decides, not the section'
    assert_equal :search_by_date, query.with_sorting(HackerNews::Sorting[:newest]).endpoint
  end

  def test_a_search_is_windowed_by_its_period
    query = Q.new(section: S[:top], text: 'rust')
    assert_nil query.window, 'a search reaches back to 2007 unless asked not to'
    assert_equal 604_800, query.with_period(HackerNews::Period[:week]).window
  end

  # Starting a search from New should stay newest-first rather than silently
  # re-ranking what is already on screen.
  def test_starting_a_search_adopts_the_sections_ranking
    assert_equal :newest,    Q.new(section: S[:new]).starting_search('rust').sorting.key
    assert_equal :relevance, Q.new(section: S[:top]).starting_search('rust').sorting.key
  end

  def test_starting_a_search_keeps_a_period_already_chosen
    started = Q.new(period: HackerNews::Period[:week]).starting_search('rust')
    assert_equal :week, started.period.key
  end

  def test_the_options_take_part_in_equality
    query = Q.new(text: 'rust')
    refute_equal query, query.with_sorting(HackerNews::Sorting[:newest])
    refute_equal query, query.with_period(HackerNews::Period[:week])
    assert_equal query, query.with_sorting(HackerNews::Sorting[:relevance])
    refute_equal query.hash, query.with_period(HackerNews::Period[:day]).hash
  end

  def test_it_describes_what_it_is_asking_for
    assert_equal 'Top', Q.new.to_s
    described = Q.new(text: 'rust', period: HackerNews::Period[:week]).to_s
    assert_match(/rust/,      described)
    assert_match(/Relevance/, described)
    assert_match(/Past Week/, described)
    # All Time is the absence of a period, not a fact worth stating.
    refute_match(/All Time/, Q.new(text: 'rust').to_s)
  end
end
