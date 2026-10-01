# frozen_string_literal: true

module HackerNews
  # The article itself, beside its comments.
  #
  # A page with no window of its own, so it can be a third column. The Reader
  # keeps its window for reading something properly; this is for seeing what a
  # story actually links to without leaving the list.
  class ArticlePane
    NOTHING_SELECTED = 'Select a story to see what it links to'
    NO_ARTICLE       = 'This story is its own discussion — there is no link to follow'
    SYMBOL           = 'doc.richtext'

    def initialize(width:, height:)
      @web = WebView.new(width: width, height: height) do |event, message|
        page_changed(event, message)
      end

      @placeholder = Placeholder.new(over: @web.view, width: width, height: height,
                                     symbol: SYMBOL, description: 'Article')
      show_placeholder(NOTHING_SELECTED)
    end

    attr_reader :placeholder

    def web_view
      @web.view
    end

    # The placeholder's container: the page, or the reason there is none.
    def pane
      @placeholder.container
    end

    # Show what this story links to. A story that is its own discussion has
    # nothing to show, and says so rather than loading the thread twice.
    def show(story, url)
      return clear(NOTHING_SELECTED) if story.nil?
      return clear(NO_ARTICLE) if url.to_s.empty?
      return if url.to_s == @web.requested

      return clear("Could not parse that link — #{url}") if @web.load(url).nil?

      @placeholder.hide
      @web.requested
    end

    # Back to the placeholder, and stop whatever was loading for the story
    # that is no longer selected.
    def clear(message = NOTHING_SELECTED)
      @web.blank
      show_placeholder(message)
      nil
    end

    def url
      @web.url
    end

    def requested
      @web.requested
    end

    def loading?
      @web.loading?
    end

    def failure
      @web.failure
    end

    def title
      @web.title
    end

    def showing_placeholder?
      @placeholder.visible?
    end

    def placeholder_text
      @placeholder.text
    end

    # Kept so a test can report a failure without a network.
    def navigation_failed(message)
      @web.navigation_failed(message)
    end

    private

    # A page that will not load should say so where the page would have been,
    # rather than leaving an empty rectangle.
    def page_changed(event, message)
      return unless event == :failed
      # Nothing was asked for, so nothing failed; this is a stale report.
      return if @web.requested.nil?

      show_placeholder("Could not load this page — #{message}")
    end

    def show_placeholder(message)
      @placeholder.show(message, symbol: SYMBOL)
    end
  end
end
