# frozen_string_literal: true

module HackerNews
  # The lists Hacker News offers, described as queries.
  #
  # Holds what to ask for, not how to ask: API turns these into URLs, which
  # keeps the taxonomy in one readable table.
  class Section
    extend Choices

    DAY   = 24 * 60 * 60
    WEEK  = 7 * DAY

    attr_reader :key, :label, :endpoint, :tags, :window, :shortcut

    def initialize(key:, label:, endpoint: :search, tags: 'story',
                   window: nil, front_page_first: false, shortcut: nil)
      @key      = key
      @label    = label
      @endpoint = endpoint
      @tags     = tags
      @window   = window
      @front_page_first = front_page_first
      @shortcut = shortcut
      freeze
    end

    # Top starts with the real front page, then continues into the week's
    # ranked stories -- which is what Hacker News's own "More" link amounts to.
    def front_page_first?
      @front_page_first
    end

    ALL = [
      new(key: :top,  label: 'Top',  window: WEEK, front_page_first: true, shortcut: '1'),
      new(key: :new,  label: 'New',  endpoint: :search_by_date,            shortcut: '2'),
      new(key: :best, label: 'Best', window: DAY,                          shortcut: '3'),
      # Ranking Ask and Show across all time surfaces 2010's classics rather
      # than what is being discussed now, so both are windowed to the week.
      new(key: :ask,  label: 'Ask',  tags: 'ask_hn',  window: WEEK,        shortcut: '4'),
      new(key: :show, label: 'Show', tags: 'show_hn', window: WEEK,        shortcut: '5'),
      # Job posts are time-sensitive and rarely upvoted, so newest wins.
      new(key: :jobs, label: 'Jobs', tags: 'job', endpoint: :search_by_date, shortcut: '6')
    ].freeze
  end
end
