# frozen_string_literal: true

module HackerNews
  # How search results are ranked.
  #
  # There are exactly two, because the API offers exactly two: one endpoint
  # blends relevance with points and age, the other is strictly newest first.
  # There is no sort by points -- which is why the filter bar offers two
  # choices rather than the three one might expect.
  class Sorting
    extend Choices

    # What a ranking with no relevance ordering has to ask for.
    #
    # Algolia allows one typo in a four-letter word, so a search for "rust"
    # also matches "trust", "restart" and "runtime", and it searches a post's
    # body as well as its title. Ranked by relevance none of that shows: the
    # exact title matches sort above the approximate ones, and the tolerance
    # is a free safety net that finds Kubernetes when you type "kubernets".
    #
    # Ranked by date there is no such ordering. Every loose match floats
    # straight to the top, and the newest results come back full of stories
    # with nothing to do with the search. So this ranking asks the question
    # precisely instead, because nothing downstream will rank a bad match
    # down.
    PRECISE = %w[typoTolerance=false restrictSearchableAttributes=title,url].freeze

    attr_reader :key, :label, :endpoint, :parameters

    def initialize(key:, label:, endpoint:, parameters: [])
      @key        = key
      @label      = label
      @endpoint   = endpoint
      @parameters = parameters
      freeze
    end

    # Whether Algolia is ordering these by how well they match.
    def ranked?
      @parameters.empty?
    end

    ALL = [
      new(key: :relevance, label: 'Relevance', endpoint: :search),
      new(key: :newest,    label: 'Newest',    endpoint: :search_by_date,
          parameters: PRECISE)
    ].freeze

    # The sorting a section already implies. Searching from New should stay
    # newest-first rather than silently re-ranking what is on screen.
    def self.for_section(section)
      ALL.find { |sorting| sorting.endpoint == section.endpoint } || default
    end
  end

  # How far back a search looks.
  #
  # Newest-first over all time returns whatever was posted in the last few
  # minutes, so the two controls are most useful together.
  class Period
    extend Choices

    DAY = 24 * 60 * 60

    attr_reader :key, :label, :seconds

    def initialize(key:, label:, seconds:)
      @key     = key
      @label   = label
      @seconds = seconds
      freeze
    end

    def all_time?
      @seconds.nil?
    end

    # The oldest timestamp still inside this period, or nil for all of time.
    def since(now = Time.now)
      @seconds && (now.to_i - @seconds)
    end

    ALL = [
      new(key: :all,   label: 'All Time',      seconds: nil),
      new(key: :day,   label: 'Past 24 Hours', seconds: DAY),
      new(key: :week,  label: 'Past Week',     seconds: 7 * DAY),
      new(key: :month, label: 'Past Month',    seconds: 30 * DAY),
      new(key: :year,  label: 'Past Year',     seconds: 365 * DAY)
    ].freeze
  end
end
