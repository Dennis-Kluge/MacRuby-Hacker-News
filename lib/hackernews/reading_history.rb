# frozen_string_literal: true

require 'set'

module HackerNews
  # Which stories have been read, and whether that is remembered between
  # launches.
  #
  # The backing store is injected so this can be exercised without touching
  # the user's actual preferences.
  class ReadingHistory
    KEY = 'HNVisitedStoryIDs'
    CAP = 800

    # Wraps NSUserDefaults in the two operations this needs.
    class DefaultsStore
      def initialize(defaults = Cocoa::NSUserDefaults.standardUserDefaults)
        @defaults = defaults
      end

      def read(key)
        stored = @defaults.arrayForKey(key)
        stored.nil? ? nil : stored.to_a.map(&:to_s)
      rescue ObjC::Exception
        nil
      end

      def write(key, values)
        @defaults.setObject_forKey(values, key)
      rescue ObjC::Exception
        nil
      end

      def delete(key)
        @defaults.removeObjectForKey(key)
      rescue ObjC::Exception
        nil
      end
    end

    def initialize(settings, store: DefaultsStore.new)
      @settings = settings
      @store    = store
      load
    end

    def include?(id)
      @ids.include?(id.to_s)
    end

    def size
      @ids.size
    end

    def empty?
      @ids.empty?
    end

    # Returns true when this is the first time the story has been seen.
    def add(id)
      key = id.to_s
      return false if @ids.include?(key)

      @ids << key
      @order << key
      trim
      persist
      true
    end

    # Returns true when the story had been marked.
    def remove(id)
      key = id.to_s
      return false unless @ids.delete?(key)

      @order.delete(key)
      persist
      true
    end

    def clear
      @ids   = Set.new
      @order = []
      @store.delete(KEY)
    end

    # Turning remembering off forgets what is on disk but keeps the marks made
    # in this session, so the list does not visibly reset under the reader.
    def remembering=(enabled)
      @settings.remember_read = enabled
      enabled ? persist : @store.delete(KEY)
    end

    def remembering?
      @settings.remember_read?
    end

    private

    def load
      stored = remembering? ? @store.read(KEY) : nil
      @order = stored || []
      @ids   = Set.new(@order)
    end

    def trim
      return if @order.size <= CAP

      dropped = @order.shift(@order.size - CAP)
      dropped.each { |id| @ids.delete(id) }
    end

    def persist
      @store.write(KEY, @order) if remembering?
    end
  end
end
