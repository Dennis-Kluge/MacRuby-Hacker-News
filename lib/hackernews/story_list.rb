# frozen_string_literal: true

require 'set'

module HackerNews
  # The paged list of stories, and which of them have been read.
  #
  # Knows nothing about tables or windows: it reports what changed through a
  # callback and lets the view decide what to redraw.
  class StoryList
    # A page can be entirely stories already shown; give up after this many in
    # a row rather than walking the whole archive.
    MAX_EMPTY_PAGES = 5

    def initialize(api:, history:, settings:)
      @api        = api
      @history    = history
      @settings   = settings
      @generation = 0
      @query      = Query.new(section: settings.section)
      reset
    end

    attr_reader :stories, :history, :page, :query

    def size
      @stories.size
    end

    def empty?
      @stories.empty?
    end

    def [](index)
      return nil if index.negative? || index >= @stories.size

      @stories[index]
    end

    def index_of(story)
      @stories.index { |candidate| candidate[:id] == story[:id] }
    end

    def loading?
      @loading
    end

    def more?
      @more
    end

    def searching?
      @query.search?
    end

    # Ask a different question. Returns true when it really is a different
    # one, which is the caller's cue to start the list again -- and false for
    # the keystroke that changed nothing.
    def ask(query)
      return false if query == @query

      @query = query
      true
    end

    def read?(story)
      story && @history.include?(story[:id])
    end

    # Returns true when the story had not been marked before.
    def mark_read(story)
      story && @history.add(story[:id])
    end

    # Returns true when the story had been marked.
    def mark_unread(story)
      story && @history.remove(story[:id])
    end

    # Start again from the front page.
    def reload(&on_event)
      reset
      notify(on_event, :reset)
      load_next(&on_event)
    end

    # Append the next page, if there is one and nothing is already in flight.
    def load_next(&on_event)
      return if @loading || !@more

      @loading = true
      notify(on_event, :loading)

      requested  = @page
      generation = @generation
      @api.stories(requested, @settings.page_size,
                   query: @query) do |stories, more, error|
        # A reload while this was in flight -- a new search, another section --
        # means this is the answer to a question nobody is asking any more.
        next if generation != @generation

        @loading = false

        if error
          @more = false
          notify(on_event, :error, error)
          next
        end

        @page = requested + 1
        @more = more
        added = append(stories)

        if added.zero? && @more && @empty_pages < MAX_EMPTY_PAGES
          @empty_pages += 1
          load_next(&on_event)
        else
          @empty_pages = 0 if added.positive?
          notify(on_event, :loaded, added)
        end
      end
    end

    private

    # Bumping the generation is what orphans any request still in flight.
    def reset
      @stories     = []
      @seen        = Set.new
      @page        = 0
      @more        = true
      @loading     = false
      @empty_pages = 0
      @generation += 1
    end

    # Consecutive pages overlap, so identifiers already shown are dropped.
    def append(stories)
      fresh = (stories || []).reject { |story| @seen.include?(story[:id].to_s) }
      fresh.each { |story| @seen << story[:id].to_s }
      @stories.concat(fresh)
      fresh.size
    end

    def notify(callback, event, payload = nil)
      callback&.call(event, payload)
    end
  end
end
