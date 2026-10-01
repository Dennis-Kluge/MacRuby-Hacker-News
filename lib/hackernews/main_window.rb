# frozen_string_literal: true

module HackerNews
  # The main window: a sidebar of stories beside the comment thread.
  class MainWindow
    WIDTH           = 1080
    # Three columns need room the two never did; the window opens wider when
    # the article is showing and narrower when it is not.
    WIDE            = 1440
    HEIGHT          = 720
    SIDEBAR_MIN     = 220
    SIDEBAR_MAX     = 620
    SIDEBAR_DEFAULT = 330
    CONTENT_MIN     = 360
    ARTICLE_MIN     = 420
    ARTICLE_DEFAULT = 560

    # Two columns fit in a small window. Three need room for all three, or
    # the one in the middle is squeezed to nothing between the minimums of
    # the two either side.
    MIN_SIZE      = [720, 460].freeze
    MIN_SIZE_WIDE = [SIDEBAR_MIN + CONTENT_MIN + ARTICLE_MIN, 460].freeze

    AUTOSAVE_NAME = 'HackerNewsMainWindow'

    # +accessory+ is an optional strip below the toolbar -- the search filter
    # bar -- which AppKit shows and hides for itself.
    # +article+ is the optional third column: the page a story links to,
    # beside its comments.
    def initialize(title:, sidebar:, content:, toolbar:, accessory: nil, article: nil)
      build_split(sidebar, content, article)
      build_window(title)
      toolbar.install(@window)
      accessory&.install(@window)
    end

    attr_reader :window

    def show
      @window.makeKeyAndOrderFront(nil)
    end

    # Move the divider, which is what a drag does.
    def sidebar_width=(points)
      @split.splitView.setPosition_ofDividerAtIndex(points.to_f, 0)
      @window.contentView.layoutSubtreeIfNeeded
    end

    def sidebar_width
      @split.splitViewItems.objectAtIndex(0).viewController.view.frame.width
    end

    # Restore the saved size and position, falling back to the default. Only
    # used when actually running, so tests get a deterministic window.
    def restore_frame
      @window.setFrameAutosaveName(AUTOSAVE_NAME)
      return if @window.setFrameUsingName(AUTOSAVE_NAME)

      default_frame
    end

    # ---- the third column ----------------------------------------------------

    def article_column?
      !@article_item.nil?
    end

    def article_visible?
      article_column? && !@article_item.isCollapsed
    end

    # Collapsing rather than removing: the split view animates it, and the
    # divider goes back where it was when it comes again.
    def article_visible=(showing)
      return false unless article_column?

      @article_item.setCollapsed(!showing)
      @window&.setMinSize(showing ? MIN_SIZE_WIDE : MIN_SIZE)
      resize_for_article(showing)
      showing
    end

    def article_width
      return 0.0 unless article_visible?

      @article_controller.view.frame.width
    end

    def render_to(path, chrome: true)
      # contentView excludes the titlebar; its superview is the frame view,
      # which is where the toolbar lives.
      view = chrome ? @window.contentView.superview : @window.contentView
      view.layoutSubtreeIfNeeded
      @window.display

      rep = view.bitmapImageRepForCachingDisplayInRect(view.bounds)
      view.cacheDisplayInRect_toBitmapImageRep(view.bounds, rep)
      rep.representationUsingType_properties(Cocoa::NSBitmapImageFileTypePNG, {})
         .writeToFile_atomically(path, true)
    end

    private

    def build_split(sidebar, content, article)
      @sidebar_controller = controller_for(sidebar)
      @content_controller = controller_for(content)

      item = Cocoa::NSSplitViewItem.sidebarWithViewController(@sidebar_controller)
      item.setMinimumThickness(SIDEBAR_MIN)
      item.setMaximumThickness(SIDEBAR_MAX)
      item.setCanCollapse(true)

      @split = Cocoa::NSSplitViewController.alloc.init
      @split.addSplitViewItem(item)

      content_item = Cocoa::NSSplitViewItem.splitViewItemWithViewController(
        @content_controller
      )
      # The comments are the point of the window; they do not give way to the
      # columns on either side of them.
      content_item.setMinimumThickness(CONTENT_MIN)
      @split.addSplitViewItem(content_item)

      return if article.nil?

      @article_controller = controller_for(article)
      @article_item = Cocoa::NSSplitViewItem.splitViewItemWithViewController(
        @article_controller
      )
      @article_item.setMinimumThickness(ARTICLE_MIN)
      @article_item.setCanCollapse(true)
      @split.addSplitViewItem(@article_item)
    end

    # Assigning the view up front keeps NSViewController from looking for a nib.
    def controller_for(view)
      controller = Cocoa::NSViewController.alloc.init
      controller.setView(view)
      controller
    end

    def build_window(title)
      style = Cocoa::NSWindowStyleMaskTitled | Cocoa::NSWindowStyleMaskClosable |
              Cocoa::NSWindowStyleMaskMiniaturizable | Cocoa::NSWindowStyleMaskResizable

      @window = Cocoa::NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
        [0, 0, WIDTH, HEIGHT], style, Cocoa::NSBackingStoreBuffered, false
      )
      # Assigning a content view controller resizes the window to that view's
      # fitting size, so the frame has to be set afterwards, not before.
      @window.setContentViewController(@split)
      # Still named, for the Window menu and Mission Control, but not drawn:
      # in a unified toolbar the title sits beside the controls rather than
      # above them, and it was the widest thing in the row.
      @window.setTitle(title)
      @window.setTitleVisibility(Cocoa::NSWindowTitleHidden)
      @window.setMinSize(MIN_SIZE)
      # Closing must not destroy it: the app stays running and the window is
      # reopened from the Dock or the Window menu.
      @window.setReleasedWhenClosed(false)
      default_frame

      # Lay out now so the lists have their real widths before any row is
      # measured; otherwise every cached height is computed against the
      # construction-time width.
      @split.splitView.setPosition_ofDividerAtIndex(SIDEBAR_DEFAULT, 0)
      @window.contentView.layoutSubtreeIfNeeded
    end

    def default_frame(width = WIDTH)
      @window.setFrame_display([0, 0, width, HEIGHT], false)
      @window.center
    end

    # Three columns in a window sized for two would squeeze the comments to
    # nothing, so the window grows with the column -- but only if the reader
    # has not already made it big enough.
    def resize_for_article(showing)
      wanted = showing ? SIDEBAR_DEFAULT + ARTICLE_MIN + ARTICLE_DEFAULT : WIDTH
      return if @window.frame.width >= wanted

      frame = @window.frame
      @window.setFrame_display([frame.x, frame.y, wanted, frame.height], true)
    end
  end
end
