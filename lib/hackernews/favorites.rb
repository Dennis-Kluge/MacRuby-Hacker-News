# frozen_string_literal: true

require 'json'
require 'time'

module HackerNews
  # The stories that have been saved to come back to.
  #
  # Unlike the reading history, which needs only an identifier, this keeps the
  # whole story as it was at the moment it was saved -- title, link, author,
  # score. An export has to stand on its own months later, and the API will
  # not necessarily still answer for a story by then.
  #
  # The backing store is injected so this can be exercised without touching
  # the user's actual preferences.
  class Favorites
    KEY = 'HNSavedStories'

    # The fields worth keeping. A story hash carries view state too -- the
    # rendered age, for one -- which has no business being persisted.
    FIELDS = %i[id title url domain author points comments].freeze

    # Stored as one JSON string rather than an array of dictionaries.
    #
    # NSUserDefaults would take the nested structure, but it would come back
    # as Foundation objects needing conversion at every level, and the shape
    # is ours to version rather than the property list's.
    class DefaultsStore
      def initialize(defaults = Cocoa::NSUserDefaults.standardUserDefaults)
        @defaults = defaults
      end

      def read(key)
        value = @defaults.stringForKey(key)
        value&.to_s
      rescue ObjC::Exception
        nil
      end

      def write(key, string)
        @defaults.setObject_forKey(string, key)
      rescue ObjC::Exception
        nil
      end

      def delete(key)
        @defaults.removeObjectForKey(key)
      rescue ObjC::Exception
        nil
      end
    end

    def initialize(store: DefaultsStore.new, clock: -> { Time.now })
      @store = store
      @clock = clock
      load
    end

    def size
      @records.size
    end

    def empty?
      @records.empty?
    end

    def include?(id)
      return false if id.nil?

      @index.key?(id.to_s)
    end

    def saved?(story)
      story && include?(story[:id])
    end

    # Most recently saved first: that is the order you want to find them in.
    def stories
      @records.map { |record| present(record) }
    end

    # Returns true when the story was not already saved.
    def add(story)
      return false if story.nil? || story[:id].nil? || include?(story[:id])

      record = FIELDS.each_with_object({}) { |field, kept| kept[field] = story[field] }
      record[:saved_at] = @clock.call.utc.iso8601

      @records.unshift(record)
      @index[record[:id].to_s] = record
      persist
      true
    end

    # Returns true when the story had been saved.
    def remove(id)
      key = id.to_s
      return false unless @index.delete(key)

      @records.reject! { |record| record[:id].to_s == key }
      persist
      true
    end

    # Returns :added or :removed, so the caller can say which it was.
    def toggle(story)
      return nil if story.nil? || story[:id].nil?

      if include?(story[:id])
        remove(story[:id])
        :removed
      else
        add(story)
        :added
      end
    end

    def clear
      @records = []
      @index   = {}
      @store.delete(KEY)
    end

    # Saved stories the given text matches, so the search field keeps working
    # in a section the API knows nothing about.
    def matching(text)
      needle = text.to_s.strip.downcase
      return stories if needle.empty?

      stories.select do |story|
        %i[title domain author].any? { |field| story[field].to_s.downcase.include?(needle) }
      end
    end

    private

    # What the rest of the app sees: the saved record, plus how long ago that
    # was, which is what the list shows in place of the story's own age.
    def present(record)
      story = record.dup
      story[:age]       = HTML.relative_time(record[:saved_at], @clock.call)
      story[:saved_age] = story[:age]
      story
    end

    def load
      @records = decode(@store.read(KEY))
      @index   = @records.each_with_object({}) { |record, index| index[record[:id].to_s] = record }
    end

    # A hand-edited or half-written value must not take the app down with it.
    def decode(string)
      return [] if string.nil? || string.empty?

      parsed = JSON.parse(string, symbolize_names: true)
      return [] unless parsed.is_a?(Array)

      parsed.select { |record| record.is_a?(Hash) && record[:id] }
    rescue JSON::ParserError
      []
    end

    def persist
      @store.write(KEY, JSON.generate(@records))
    end
  end
end
