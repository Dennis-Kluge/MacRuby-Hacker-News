# frozen_string_literal: true

module HackerNews
  # An article window backed by WKWebView, so a story can be read without
  # leaving the app. One window is reused for every article; it keeps its own
  # back/forward history.
  class Reader
    WIDTH  = 1000
    HEIGHT = 780

    TOOLBAR_ID   = 'hn.reader.toolbar'
    BACK_ITEM    = 'hn.reader.back'
    FORWARD_ITEM = 'hn.reader.forward'
    RELOAD_ITEM  = 'hn.reader.reload'
    SPINNER_ITEM = 'hn.reader.spinner'
    EXTERNAL_ITEM = 'hn.reader.external'

    # +on_external+ is handed the current URL when the reader is asked to
    # hand the page over to a real browser.
    def initialize(on_external:)
      @on_external = on_external
      @items = {}
      build_window
      build_web_view
      build_toolbar
    end

    attr_reader :window, :web_view

    # Load a URL, bringing the window forward.
    def open(url_string, title: nil)
      url = Cocoa::NSURL.URLWithString(url_string.to_s)
      return false if url.nil?

      @current_url = url_string.to_s
      # Kept as the fallback: WKWebView clears its title mid-navigation, and
      # the story's own headline reads better than "Reader".
      @fallback_title = title.to_s
      @window.setTitle(display_title(''))
      @window.setSubtitle(url.host.to_s)

      @web_view.loadRequest(Cocoa::NSURLRequest.requestWithURL(url))
      @window.makeKeyAndOrderFront(nil)
      Cocoa::NSApplication.sharedApplication.activateIgnoringOtherApps(true)
      true
    end

    def current_url
      @web_view.URL&.absoluteString&.to_s || @current_url
    end

    def loading?
      @web_view.isLoading
    end

    # Called by the navigation delegate as the page moves along.
    def navigation_started
      @spinner&.startAnimation(nil)
      update_navigation_items
    end

    def navigation_finished
      @spinner&.stopAnimation(nil)
      @window.setTitle(display_title(@web_view.title.to_s))
      @window.setSubtitle(@web_view.URL&.host.to_s)
      update_navigation_items
    end

    def navigation_failed(message)
      @spinner&.stopAnimation(nil)
      @window.setSubtitle("Could not load — #{message}")
      update_navigation_items
    end

    def display_title(page_title)
      return page_title unless page_title.strip.empty?
      return @fallback_title unless @fallback_title.to_s.strip.empty?

      'Reader'
    end

    def update_navigation_items
      @items[BACK_ITEM]&.setEnabled(@web_view.canGoBack)
      @items[FORWARD_ITEM]&.setEnabled(@web_view.canGoForward)
    end

    def open_externally
      @on_external.call(current_url)
    end

    private

    def build_window
      style = Cocoa::NSWindowStyleMaskTitled | Cocoa::NSWindowStyleMaskClosable |
              Cocoa::NSWindowStyleMaskMiniaturizable | Cocoa::NSWindowStyleMaskResizable

      @window = Cocoa::NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
        [0, 0, WIDTH, HEIGHT], style, Cocoa::NSBackingStoreBuffered, false
      )
      @window.setTitle('Reader')
      @window.setMinSize([520, 400])
      @window.setReleasedWhenClosed(false)
      @window.center
      @window.setFrameAutosaveName('HackerNewsReaderWindow')
    end

    def build_web_view
      configuration = Cocoa::WKWebViewConfiguration.alloc.init
      bounds = @window.contentView.bounds

      @web_view = Cocoa::WKWebView.alloc.initWithFrame_configuration(
        [0, 0, bounds.width, bounds.height], configuration
      )
      @web_view.setAutoresizingMask(
        Cocoa::NSViewWidthSizable | Cocoa::NSViewHeightSizable
      )

      reader = self
      delegate_class = Cocoa.define_class(
        'HNReaderNavigationDelegate', 'NSObject', protocols: %w[WKNavigationDelegate]
      ) do |c|
        c.define('webView:didStartProvisionalNavigation:', 'v@:@@') do |_s, _v, _n|
          reader.navigation_started
        end
        c.define('webView:didFinishNavigation:', 'v@:@@') do |_s, _v, _n|
          reader.navigation_finished
        end
        c.define('webView:didFailNavigation:withError:', 'v@:@@@') do |_s, _v, _n, error|
          reader.navigation_failed(error&.localizedDescription.to_s)
        end
        c.define('webView:didFailProvisionalNavigation:withError:', 'v@:@@@') do |_s, _v, _n, error|
          reader.navigation_failed(error&.localizedDescription.to_s)
        end
      end

      # The web view holds its delegate weakly.
      @navigation_delegate = delegate_class.alloc.init
      @web_view.setNavigationDelegate(@navigation_delegate)

      @window.contentView.addSubview(@web_view)
    end

    def build_toolbar
      @spinner = Cocoa::NSProgressIndicator.alloc.initWithFrame([0, 0, 18, 18])
      @spinner.setStyle(Cocoa::NSProgressIndicatorStyleSpinning)
      @spinner.setControlSize(2)
      @spinner.setDisplayedWhenStopped(false)

      @back_target    = Cocoa.action { |_s| @web_view.goBack }
      @forward_target = Cocoa.action { |_s| @web_view.goForward }
      @reload_target  = Cocoa.action { |_s| loading? ? @web_view.stopLoading : @web_view.reload }
      @external_target = Cocoa.action { |_s| open_externally }

      reader = self
      delegate_class = Cocoa.define_class(
        'HNReaderToolbarDelegate', 'NSObject', protocols: %w[NSToolbarDelegate]
      ) do |c|
        c.define('toolbarAllowedItemIdentifiers:', '@@:@') { |_s, _t| reader.toolbar_items }
        c.define('toolbarDefaultItemIdentifiers:', '@@:@') { |_s, _t| reader.toolbar_items }
        c.define('toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:', '@@:@@B') do |_s, _t, id, _f|
          reader.toolbar_item(id.to_s)
        end
      end

      @toolbar_delegate = delegate_class.alloc.init

      toolbar = Cocoa::NSToolbar.alloc.initWithIdentifier(TOOLBAR_ID)
      toolbar.setDelegate(@toolbar_delegate)
      toolbar.setDisplayMode(2)
      toolbar.setAllowsUserCustomization(false)

      @window.setToolbar(toolbar)
      @window.setToolbarStyle(Cocoa::NSWindowToolbarStyleUnified)
    end

    public

    def toolbar_items
      [BACK_ITEM, FORWARD_ITEM, RELOAD_ITEM,
       Cocoa::NSToolbarFlexibleSpaceItemIdentifier, SPINNER_ITEM, EXTERNAL_ITEM]
    end

    def toolbar_item(identifier)
      item = case identifier
             when BACK_ITEM
               button_item(identifier, 'Back', 'chevron.left', @back_target)
             when FORWARD_ITEM
               button_item(identifier, 'Forward', 'chevron.right', @forward_target)
             when RELOAD_ITEM
               button_item(identifier, 'Reload', 'arrow.clockwise', @reload_target)
             when EXTERNAL_ITEM
               button_item(identifier, 'Open in Browser', 'safari', @external_target)
             when SPINNER_ITEM
               spinner = Cocoa::NSToolbarItem.alloc.initWithItemIdentifier(identifier)
               spinner.setView(@spinner)
               spinner
             end

      @items[identifier] = item if item
      update_navigation_items
      item
    end

    private

    def button_item(identifier, label, symbol, target)
      item = Cocoa::NSToolbarItem.alloc.initWithItemIdentifier(identifier)
      item.setLabel(label)
      item.setToolTip(label)
      item.setImage(
        Cocoa::NSImage.imageWithSystemSymbolName_accessibilityDescription(symbol, label)
      )
      item.setBordered(true)
      item.setTarget(target)
      item.setAction(Cocoa::ACTION_SELECTOR)
      item
    end
  end
end
