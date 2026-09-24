# frozen_string_literal: true

module HackerNews
  # A small fixed table of named options: the sections, the ways of sorting a
  # search, the periods one can be confined to.
  #
  # Every entry has a key and a label. The table is looked up by key when the
  # value comes from the preferences, and by index when it comes from a
  # segmented control or a popup button saying what was clicked -- so a class
  # that extends this differs from its siblings only in what it holds.
  module Choices
    def default
      self::ALL.first
    end

    def keys
      @keys ||= self::ALL.map(&:key).freeze
    end

    def labels
      @labels ||= self::ALL.map(&:label).freeze
    end

    # A key that is stale, or hand-edited in the preferences, falls back to
    # the first entry rather than raising.
    def [](key)
      self::ALL.find { |choice| choice.key == key.to_s.to_sym } || default
    end

    def at(index)
      self::ALL[index] || default
    end

    def index_of(key)
      keys.index(key.to_s.to_sym) || 0
    end
  end
end
