# frozen_string_literal: true

module HackerNews
  # What one story request asks for: a section, optionally narrowed by text,
  # and -- when it is narrowed -- how those results are ranked and how far
  # back they reach.
  #
  # A search is not a section of its own; it narrows whichever section is
  # showing, so "Show HN" plus "raspberry pi" is a perfectly sensible
  # question. Immutable, because a request in flight must not change under its
  # own reply.
  class Query
    attr_reader :section, :text, :sorting, :period

    def initialize(section: Section.default, text: nil,
                   sorting: Sorting.default, period: Period.default)
      @section = section
      # Leading and trailing space is never meant, and would otherwise make
      # two identical searches look different.
      @text    = text.to_s.strip
      @sorting = sorting
      @period  = period
      freeze
    end

    def search?
      !@text.empty?
    end

    def with_text(text)
      copy(text: text)
    end

    def with_section(section)
      copy(section: section)
    end

    def with_sorting(sorting)
      copy(sorting: sorting)
    end

    def with_period(period)
      copy(period: period)
    end

    # A section already implies a ranking -- New is newest-first -- so a
    # search begun from one starts out sorted the way the list already was.
    def starting_search(text)
      copy(text: text, sorting: Sorting.for_section(@section))
    end

    # Which endpoint answers this, and how far back it looks. Sorting and
    # period belong to the search; without one the section's own ranking and
    # window apply, which is what keeps the plain lists current.
    def endpoint
      search? ? @sorting.endpoint : @section.endpoint
    end

    def window
      search? ? @period.seconds : @section.window
    end

    # What this ranking needs asked of it beyond the text itself.
    def parameters
      search? ? @sorting.parameters : []
    end

    # Value equality: two queries asking the same thing are the same query,
    # which is what lets the list ignore a keystroke that changed nothing.
    def ==(other)
      other.is_a?(Query) && other.identity == identity
    end
    alias eql? ==

    def hash
      identity.hash
    end

    protected

    def identity
      [@section.key, @text, @sorting.key, @period.key]
    end

    public

    def to_s
      return @section.label unless search?

      parts = [@section.label, "“#{@text}”", @sorting.label]
      parts << @period.label unless @period.all_time?
      parts.join(' · ')
    end

    private

    def copy(section: @section, text: @text, sorting: @sorting, period: @period)
      Query.new(section: section, text: text, sorting: sorting, period: period)
    end
  end
end
