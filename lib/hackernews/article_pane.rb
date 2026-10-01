# frozen_string_literal: true

module HackerNews
  # The article itself, beside its comments.
  #
  # A WKWebView with no window of its own, so it can be a third column. The
  # Reader keeps its own window for reading something properly; this is for
  # seeing what a story actually links to without leaving the list.
  #
  # One Objective-C delegate class serves every pane -- classes are registered
  # globally by name, so a class defined per instance would have its methods
  # replaced by the next one and then answer for the wrong pane.
  class ArticlePane
    NOTHING_SELECTED = 'Select a story to see what it links to'
    NO_ARTICLE       = 'This story is its own discussion — there is no link to follow'
    SYMBOL           = 'doc.richtext'

    def self.owners
      @owners ||= {}
    end

    def self.owner_of(receiver)
      owners[receiver.objc_address]
    end

    def self.delegate_class
      @delegate_class ||= Cocoa.define_class(
        'HNArticlePaneDelegate', 'NSObject', protocols: %w[WKNavigationDelegate]
      ) do |c|
        c.define('webView:didStartProvisionalNavigation:', 'v@:@@') do |receiver, _v, _n|
          owner_of(receiver)&.navigation_started
        end
        c.define('webView:didFinishNavigation:', 'v@:@@') do |receiver, _v, _n|
          owner_of(receiver)&.navigation_finished
        end
        c.define('webView:didFailNavigation:withError:', 'v@:@@@') do |receiver, _v, _n, error|
          owner_of(receiver)&.navigation_failed(error&.localizedDescription.to_s)
        end
        c.define('webView:didFailProvisionalNavigation:withError:', 'v@:@@@') do |receiver, _v, _n, error|
          owner_of(receiver)&.navigation_failed(error&.localizedDescription.to_s)
        end
      end
    end

    def initialize(width:, height:, on_change: nil)
      @on_change = on_change
      build_web_view(width, height)
      @placeholder = Placeholder.new(over: @web_view, width: width, height: height,
                                     symbol: SYMBOL, description: 'Article')
      show_placeholder(NOTHING_SELECTED)
    end

    attr_reader :web_view, :placeholder

    # The placeholder's container: the page, or the reason there is none.
    def pane
      @placeholder.container
    end

    # Show what this story links to. A story that is its own discussion has
    # nothing to show, and says so rather than loading the thread twice.
    def show(story, url)
      return clear(NOTHING_SELECTED) if story.nil?
      return clear(NO_ARTICLE) if url.to_s.empty?
      return if url.to_s == @requested

      target = Cocoa::NSURL.URLWithString(url.to_s)
      return clear("Could not parse that link — #{url}") if target.nil?

      @requested = url.to_s
      @failure   = nil
      @placeholder.hide
      @web_view.loadRequest(Cocoa::NSURLRequest.requestWithURL(target))
      @requested
    end

    # Back to the placeholder, and stop whatever was loading for the story
    # that is no longer selected.
    def clear(message = NOTHING_SELECTED)
      @web_view.stopLoading if loading?
      # about:blank rather than leaving the last article up behind the
      # message: the placeholder covers the view, it does not empty it.
      @web_view.loadHTMLString_baseURL('', nil)
      @requested = nil
      show_placeholder(message)
      nil
    end

    def url
      @web_view.URL&.absoluteString&.to_s || @requested
    end

    def requested
      @requested
    end

    def loading?
      @web_view.isLoading
    end

    def failure
      @failure
    end

    def title
      @web_view.title.to_s
    end

    def showing_placeholder?
      @placeholder.visible?
    end

    def placeholder_text
      @placeholder.text
    end

    # ---- the navigation delegate ---------------------------------------------

    def navigation_started
      @on_change&.call(:started)
    end

    def navigation_finished
      @failure = nil
      @on_change&.call(:finished)
    end

    # A page that will not load should say so where the page would have been,
    # rather than leaving an empty rectangle.
    def navigation_failed(message)
      # Cancelling a load to start another one is not a failure worth saying.
      return if message.to_s.include?('cancelled') || @requested.nil?

      @failure = message.to_s
      show_placeholder("Could not load this page — #{message}")
      @on_change&.call(:failed)
    end

    private

    def show_placeholder(message)
      @placeholder.show(message, symbol: SYMBOL)
    end

    def build_web_view(width, height)
      configuration = Cocoa::WKWebViewConfiguration.alloc.init
      @web_view = Cocoa::WKWebView.alloc.initWithFrame_configuration(
        [0, 0, width, height], configuration
      )
      @web_view.setAutoresizingMask(
        Cocoa::NSViewWidthSizable | Cocoa::NSViewHeightSizable
      )

      delegate = self.class.delegate_class.alloc.init
      self.class.owners[delegate.objc_address] = self
      @delegate = delegate # the web view holds its delegate weakly
      @web_view.setNavigationDelegate(delegate)
    end
  end
end
