# frozen_string_literal: true

module HackerNews
  # Preferences, stored in NSUserDefaults.
  #
  # Defaults are registered rather than written, so a fresh install gets
  # sensible values without anything being persisted until the user actually
  # changes something.
  class Settings
    EXPANSION_KEY = 'HNCommentExpansion'
    REMEMBER_KEY  = 'HNRememberReadStories'
    TEXT_SIZE_KEY = 'HNTextSize'
    SECTION_KEY   = 'HNSection'
    REFRESH_KEY   = 'HNRefreshInterval'
    PAGE_SIZE_KEY = 'HNStoriesPerPage'
    LINK_TARGET_KEY = 'HNOpenLinksIn'
    FAVICONS_KEY  = 'HNShowFavicons'

    # Ordered, because the index is what the popup button reports back.
    EXPANSION_MODES = [
      [:collapsed, 'Keep all comments collapsed'],
      [:top_level, 'Expand top-level comments'],
      [:all,       'Expand every comment']
    ].freeze

    # Point sizes for the comment header, comment body, and story title.
    TEXT_SIZES = [
      [:small,  'Small',  [10.5, 11.5, 12.0]],
      [:medium, 'Medium', [11.0, 12.5, 13.0]],
      [:large,  'Large',  [12.0, 14.0, 14.5]]
    ].freeze

    # How often the story list refetches itself, in seconds.
    REFRESH_INTERVALS = [
      [0,   'Never'],
      [60,  'Every minute'],
      [300, 'Every 5 minutes'],
      [900, 'Every 15 minutes']
    ].freeze

    PAGE_SIZES = [20, 30, 50].freeze

    # Where a story's link opens.
    LINK_TARGETS = [
      [:app,     'The built-in reader'],
      [:browser, 'My default browser']
    ].freeze

    DEFAULT_EXPANSION = :collapsed
    DEFAULT_REMEMBER  = true
    DEFAULT_TEXT_SIZE = :medium
    DEFAULT_SECTION   = :top
    DEFAULT_REFRESH   = 300
    DEFAULT_PAGE_SIZE = 30
    DEFAULT_LINK_TARGET = :app
    DEFAULT_FAVICONS    = true

    def self.register_defaults
      defaults.registerDefaults(
        EXPANSION_KEY => DEFAULT_EXPANSION.to_s,
        REMEMBER_KEY  => DEFAULT_REMEMBER,
        TEXT_SIZE_KEY => DEFAULT_TEXT_SIZE.to_s,
        SECTION_KEY   => DEFAULT_SECTION.to_s,
        REFRESH_KEY   => DEFAULT_REFRESH,
        PAGE_SIZE_KEY => DEFAULT_PAGE_SIZE,
        LINK_TARGET_KEY => DEFAULT_LINK_TARGET.to_s,
        FAVICONS_KEY  => DEFAULT_FAVICONS
      )
    end

    # Look up a symbol setting, falling back when the stored value is stale or
    # hand-edited.
    def self.symbol_from(table, stored, fallback)
      candidate = stored.to_s.to_sym
      table.map(&:first).include?(candidate) ? candidate : fallback
    end

    def self.text_size_labels
      TEXT_SIZES.map { |_, label, _| label }
    end

    def self.text_size_at(index)
      (TEXT_SIZES[index] || TEXT_SIZES[1]).first
    end

    def self.index_of_text_size(size)
      TEXT_SIZES.index { |key, _, _| key == size } || 1
    end

    def self.font_sizes(size)
      entry = TEXT_SIZES.find { |key, _, _| key == size } || TEXT_SIZES[1]
      entry.last
    end

    def self.link_target_labels
      LINK_TARGETS.map(&:last)
    end

    def self.link_target_at(index)
      (LINK_TARGETS[index] || LINK_TARGETS.first).first
    end

    def self.index_of_link_target(target)
      LINK_TARGETS.index { |key, _| key == target } || 0
    end

    def self.refresh_labels
      REFRESH_INTERVALS.map(&:last)
    end

    def self.refresh_at(index)
      (REFRESH_INTERVALS[index] || REFRESH_INTERVALS.first).first
    end

    def self.index_of_refresh(seconds)
      REFRESH_INTERVALS.index { |value, _| value == seconds } || 0
    end

    def self.page_size_labels
      PAGE_SIZES.map { |n| "#{n} stories" }
    end

    def self.defaults
      Cocoa::NSUserDefaults.standardUserDefaults
    end

    def self.mode_labels
      EXPANSION_MODES.map(&:last)
    end

    def self.mode_at(index)
      (EXPANSION_MODES[index] || EXPANSION_MODES.first).first
    end

    def self.index_of(mode)
      EXPANSION_MODES.index { |key, _| key == mode } || 0
    end

    def expansion
      self.class.symbol_from(EXPANSION_MODES,
                             self.class.defaults.stringForKey(EXPANSION_KEY),
                             DEFAULT_EXPANSION)
    end

    def expansion=(mode)
      self.class.defaults.setObject_forKey(mode.to_s, EXPANSION_KEY)
    end

    def text_size
      self.class.symbol_from(TEXT_SIZES,
                             self.class.defaults.stringForKey(TEXT_SIZE_KEY),
                             DEFAULT_TEXT_SIZE)
    end

    def text_size=(size)
      self.class.defaults.setObject_forKey(size.to_s, TEXT_SIZE_KEY)
    end

    def font_sizes
      self.class.font_sizes(text_size)
    end

    def section
      Section[self.class.defaults.stringForKey(SECTION_KEY)]
    end

    def section=(key)
      self.class.defaults.setObject_forKey(key.to_s, SECTION_KEY)
    end

    def refresh_interval
      stored = self.class.defaults.integerForKey(REFRESH_KEY)
      REFRESH_INTERVALS.map(&:first).include?(stored) ? stored : DEFAULT_REFRESH
    end

    def refresh_interval=(seconds)
      self.class.defaults.setInteger_forKey(seconds, REFRESH_KEY)
    end

    def page_size
      stored = self.class.defaults.integerForKey(PAGE_SIZE_KEY)
      PAGE_SIZES.include?(stored) ? stored : DEFAULT_PAGE_SIZE
    end

    def page_size=(size)
      self.class.defaults.setInteger_forKey(size, PAGE_SIZE_KEY)
    end

    def open_links_in
      self.class.symbol_from(LINK_TARGETS,
                             self.class.defaults.stringForKey(LINK_TARGET_KEY),
                             DEFAULT_LINK_TARGET)
    end

    def open_links_in=(target)
      self.class.defaults.setObject_forKey(target.to_s, LINK_TARGET_KEY)
    end

    def show_favicons?
      self.class.defaults.boolForKey(FAVICONS_KEY)
    end

    def show_favicons=(flag)
      self.class.defaults.setBool_forKey(flag ? true : false, FAVICONS_KEY)
    end

    def remember_read?
      self.class.defaults.boolForKey(REMEMBER_KEY)
    end

    def remember_read=(flag)
      self.class.defaults.setBool_forKey(flag ? true : false, REMEMBER_KEY)
    end

    # Used by tests and by the "restore defaults" path.
    def reset
      [EXPANSION_KEY, REMEMBER_KEY, TEXT_SIZE_KEY, SECTION_KEY, REFRESH_KEY,
       PAGE_SIZE_KEY, LINK_TARGET_KEY, FAVICONS_KEY].each do |key|
        self.class.defaults.removeObjectForKey(key)
      end
      self.class.register_defaults
    end
  end
end
