# frozen_string_literal: true

module HackerNews
  # A WKWebView, and the delegate that says what it is doing.
  #
  # The reader window and the article column both need a page, whether it is
  # still loading, and a history to go back through. Neither needs its own
  # copy of this, and until this existed they each had one.
  #
  # One Objective-C delegate class serves every instance. Classes are
  # registered globally by name, so a class defined per instance has its
  # methods replaced by the next one and then answers for the wrong view --
  # harmless while there was only ever one reader, and not a thing to leave
  # lying about now that there are two web views.
  class WebView
    def self.owners
      @owners ||= {}
    end

    def self.owner_of(receiver)
      owners[receiver.objc_address]
    end

    def self.delegate_class
      @delegate_class ||= Cocoa.define_class(
        'HNWebViewDelegate', 'NSObject', protocols: %w[WKNavigationDelegate]
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

    # +on_event+ is called with :started, :finished or :failed, and the
    # message in the failing case. What to do about it is the caller's: the
    # reader puts it in a subtitle, the column puts it where the page would
    # have been.
    def initialize(width:, height:, &on_event)
      @on_event = on_event
      build(width, height)
    end

    attr_reader :view, :requested, :failure

    # Returns the URL asked for, or nil when it could not be parsed.
    def load(url_string)
      target = Cocoa::NSURL.URLWithString(url_string.to_s)
      return nil if target.nil?

      @requested = url_string.to_s
      @failure   = nil
      @view.loadRequest(Cocoa::NSURLRequest.requestWithURL(target))
      @requested
    end

    # An empty page, for when there is nothing to show. The last article must
    # not be left sitting behind whatever stands in for it.
    def blank
      stop
      @view.loadHTMLString_baseURL('', nil)
      @requested = nil
      @failure   = nil
    end

    def url
      @view.URL&.absoluteString&.to_s || @requested
    end

    def title
      @view.title.to_s
    end

    def loading?
      @view.isLoading
    end

    def stop
      @view.stopLoading if loading?
    end

    # The one button that is two: stop while it is still coming, reload once
    # it has arrived.
    def reload
      loading? ? stop : @view.reload
    end

    def can_go_back?
      @view.canGoBack
    end

    def can_go_forward?
      @view.canGoForward
    end

    def back
      @view.goBack
    end

    def forward
      @view.goForward
    end

    # ---- what the delegate reports -------------------------------------------

    def navigation_started
      @on_event&.call(:started, nil)
    end

    def navigation_finished
      @failure = nil
      @on_event&.call(:finished, nil)
    end

    # Starting one load cancels the last, and that is not a failure worth
    # reporting to anyone.
    def navigation_failed(message)
      return if self.class.cancelled?(message)

      @failure = message.to_s
      @on_event&.call(:failed, @failure)
    end

    def self.cancelled?(message)
      message.to_s.downcase.include?('cancel')
    end

    private

    def build(width, height)
      configuration = Cocoa::WKWebViewConfiguration.alloc.init
      @view = Cocoa::WKWebView.alloc.initWithFrame_configuration(
        [0, 0, width, height], configuration
      )
      @view.setAutoresizingMask(
        Cocoa::NSViewWidthSizable | Cocoa::NSViewHeightSizable
      )

      delegate = self.class.delegate_class.alloc.init
      self.class.owners[delegate.objc_address] = self
      @delegate = delegate # the web view holds its delegate weakly
      @view.setNavigationDelegate(delegate)
    end
  end
end
