# frozen_string_literal: true

module HackerNews
  # The main window: a sidebar of stories beside the comment thread.
  class MainWindow
    WIDTH           = 1080
    HEIGHT          = 720
    SIDEBAR_MIN     = 220
    SIDEBAR_MAX     = 620
    SIDEBAR_DEFAULT = 330

    AUTOSAVE_NAME = 'HackerNewsMainWindow'

    # +accessory+ is an optional strip below the toolbar -- the search filter
    # bar -- which AppKit shows and hides for itself.
    def initialize(title:, sidebar:, content:, toolbar:, accessory: nil)
      build_split(sidebar, content)
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

    def subtitle=(text)
      @window.setSubtitle(text)
    end

    # Restore the saved size and position, falling back to the default. Only
    # used when actually running, so tests get a deterministic window.
    def restore_frame
      @window.setFrameAutosaveName(AUTOSAVE_NAME)
      return if @window.setFrameUsingName(AUTOSAVE_NAME)

      default_frame
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

    def build_split(sidebar, content)
      @sidebar_controller = controller_for(sidebar)
      @content_controller = controller_for(content)

      item = Cocoa::NSSplitViewItem.sidebarWithViewController(@sidebar_controller)
      item.setMinimumThickness(SIDEBAR_MIN)
      item.setMaximumThickness(SIDEBAR_MAX)
      item.setCanCollapse(true)

      @split = Cocoa::NSSplitViewController.alloc.init
      @split.addSplitViewItem(item)
      @split.addSplitViewItem(
        Cocoa::NSSplitViewItem.splitViewItemWithViewController(@content_controller)
      )
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
      @window.setTitle(title)
      @window.setMinSize([720, 460])
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

    def default_frame
      @window.setFrame_display([0, 0, WIDTH, HEIGHT], false)
      @window.center
    end
  end
end
