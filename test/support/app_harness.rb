# frozen_string_literal: true

module HackerNews
  # One App per test class, built lazily and shared by that class's tests.
  #
  # Building one per test would be slow, and worse: every App installs a menu
  # bar and a toolbar on the one shared NSApplication, so the last one built
  # is the one that answers. A class gets one and keeps it.
  #
  # Each comes with an API, a saved list and preferences of its own, so a test
  # run writes nothing to the copies the reader is actually using -- the real
  # NSUserDefaults is shared with the running app, and a screenshot script
  # once left it showing the wrong section at launch.
  module AppHarness
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def app
        @app ||= HackerNews::App.new(api: stub, favorites: favorites,
                                     settings: settings, history: history)
      end

      def stub
        @stub ||= HackerNews::StubAPI.new
      end

      def favorites
        @favorites ||= HackerNews::Favorites.new(store: HackerNews::MemoryText.new)
      end

      def settings
        @settings ||= HackerNews::Settings.new(HackerNews::MemoryDefaults.new)
      end

      def history_store
        @history_store ||= HackerNews::MemoryStore.new
      end

      def history
        @history ||= HackerNews::ReadingHistory.new(settings, store: history_store)
      end
    end

    def app
      self.class.app
    end

    def stub
      self.class.stub
    end

    def favorites
      self.class.favorites
    end

    # What the reading history actually wrote, which is what the next launch
    # would read back.
    def history_store
      self.class.history_store
    end

    def window
      app.main_window.window
    end

    # What most setups want: the preferences back to their defaults, the API
    # answering again, and nothing selected.
    def reset_app
      app.settings.reset
      stub.error   = nil
      stub.pages   = nil
      stub.tree    = { 'children' => [] }
      app.instance_variable_set(:@story, nil)
    end
  end
end
