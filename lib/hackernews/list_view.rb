# frozen_string_literal: true

module HackerNews
  # Shared behaviour for the two lists: a scroll view wrapping a view-based
  # table, cached row heights, and a bridge to a Ruby-implemented data source.
  #
  # Objective-C classes are registered globally by name, so defining one per
  # instance would silently replace the previous instance's methods. Each
  # subclass defines its class once and every delegate instance is looked up
  # here, which keeps more than one view working at a time.
  class ListView
    TEXT_INSET = 10
    # Leaves room for the scroller rather than letting the column sit flush.
    COLUMN_INSET = 6
    MIN_COLUMN   = 80.0

    # Observer instances, keyed by address, so one Objective-C class can serve
    # every list.
    RESIZE_OBSERVERS = {}

    def self.resize_observer_class
      @resize_observer_class ||= Cocoa.define_class('HNListResizeObserver', 'NSObject') do |c|
        c.define('viewDidResize:', 'v@:@') do |receiver, _note|
          ListView::RESIZE_OBSERVERS[receiver.objc_address]&.layout_changed
        end
      end
    end

    def self.owners
      @owners ||= {}
    end

    def self.owner_of(receiver)
      owners[receiver.objc_address]
    end

    def self.adopt(delegate, owner)
      owners[delegate.objc_address] = owner
      delegate
    end

    attr_reader :scroll_view, :view

    # The view that goes into the window. A subclass that wraps its scroll
    # view in something larger overrides this.
    def pane
      @scroll_view
    end

    def initialize(typography)
      @typography = typography
      @heights    = {}
      @rendered   = {}
    end

    # The table's own column autoresizing does not fire for a frame change
    # driven by the split view, so the column is sized here instead. Watching
    # the frame rather than the column is what makes a divider drag reach the
    # cells at all.
    def observe_resizing
      @view.setPostsFrameChangedNotifications(true)

      observer = ListView.resize_observer_class.alloc.init
      RESIZE_OBSERVERS[observer.objc_address] = self
      @resize_observer = observer # the notification centre does not retain it

      Cocoa::NSNotificationCenter.defaultCenter.addObserver_selector_name_object(
        observer, 'viewDidResize:', Cocoa::NSViewFrameDidChangeNotification, @view
      )
    end

    def layout_changed
      fit_column
      width_changed
    end

    # Give the single column the width the clip view offers, then take back
    # whatever the table style adds around it.
    #
    # The inset and source-list styles pad their rows horizontally, so a column
    # set to the clip's width leaves the table wider than the clip -- which is
    # what makes the list scroll sideways and clip the rank column.
    def fit_column
      clip = @view.enclosingScrollView&.contentView
      return if clip.nil?

      available = clip.bounds.width
      column    = @view.tableColumns.objectAtIndex(0)

      # The document view keeps whatever width it was last given, so it has to
      # be clamped explicitly: a table wider than its clip view is exactly what
      # lets the list scroll sideways.
      if (@view.frame.width - available).abs > 0.5
        @view.setFrameSize([available, @view.frame.height])
      end

      # The inset and source-list styles lay their cell out at an offset from
      # the row's leading edge, so a column as wide as the row runs off the
      # end. Leave room for that inset on both sides.
      margins = (cell_inset * 2) + COLUMN_INSET
      column.setWidth([available - margins, MIN_COLUMN].max)

      # Nothing should be able to scroll sideways once it fits.
      clip.scrollToPoint([0.0, clip.bounds.y]) if clip.bounds.x.abs > 0.5
    end

    # How far the table style indents a cell from the row's leading edge.
    # Measured from a real row, since it varies by style, then remembered.
    def cell_inset
      return @cell_inset if @cell_inset
      return 0.0 if @view.numberOfRows.zero?

      @cell_inset = @view.frameOfCellAtColumn_row(0, 0).x
    end

    # A row's height depends on the width it was measured at, so a resize
    # invalidates every one of them. The table caches what it was told, and
    # only re-asks when it is told to.
    def width_changed
      width = usable_width.to_i
      return if width == @measured_width

      @measured_width = width
      @heights = {}
      relayout
    end

    # Row views already on screen keep the frame they were given, so telling
    # the table only that heights changed leaves their text wrapped to the old
    # width. Reloading re-creates them at the new one.
    #
    # Deferred because doing either while the table is asking a delegate
    # question is reentrant, which AppKit warns will become an assert.
    def relayout
      return if @relayout_pending

      @relayout_pending = true
      Cocoa::NSOperationQueue.mainQueue.addOperationWithBlock do
        @relayout_pending = false
        next if @view.numberOfRows.zero?

        @rendered = {}
        @view.reloadData
        @view.noteHeightOfRowsWithIndexesChanged(
          Cocoa::NSIndexSet.indexSetWithIndexesInRange([0, @view.numberOfRows])
        )
      end
    end

    alias note_heights_changed relayout

    # Text metrics changed, so every cached string and height is stale.
    def invalidate
      @heights  = {}
      @rendered = {}
      @measured_width = nil
      reload
      note_heights_changed
    end

    # Cached strings are only valid for the rows they were built for, and a
    # reload can renumber every one of them.
    def reload
      @rendered = {}
      @view.reloadData
    end

    private

    # No bezel, no border: modern lists sit flush against their container.
    def build_scroll_view(width, height)
      scroll = Cocoa::NSScrollView.alloc.initWithFrame([0, 0, width, height])
      scroll.setHasVerticalScroller(true)
      scroll.setBorderType(0) # NSNoBorder
      scroll.setAutohidesScrollers(true)
      scroll
    end

    def build_column(identifier, width)
      column = Cocoa::NSTableColumn.alloc.initWithIdentifier(identifier)
      column.setWidth(width)
      column.setResizingMask(1) # NSTableColumnAutoresizingMask
      column
    end

    # Reuse a text field if the table has a spare, otherwise make one.
    #
    # Selectable plus editable attributes is what makes an NSTextField honour
    # NSLinkAttributeName: the link becomes clickable and the text copyable.
    def text_field(identifier, selectable:)
      field = @view.makeViewWithIdentifier_owner(identifier, nil)
      return field unless field.nil?

      field = Cocoa::NSTextField.alloc.initWithFrame([0, 0, 200, 20])
      field.setIdentifier(identifier)
      field.setEditable(false)
      field.setBezeled(false)
      field.setDrawsBackground(false)
      field.setLineBreakMode(0)
      field.setMaximumNumberOfLines(0)
      field.cell.setWraps(true)
      field.setSelectable(selectable)
      field.setAllowsEditingTextAttributes(selectable)
      field.setAutoresizingMask(
        Cocoa::NSViewWidthSizable | Cocoa::NSViewHeightSizable
      )
      field
    end

    # The width a row view actually receives. The column is authoritative once
    # laid out; the clip view is the better guess before that.
    def usable_width
      column = @view.tableColumns.objectAtIndex(0)
      clip   = @view.enclosingScrollView&.contentView
      width  = column ? column.width : 0.0
      width  = clip.bounds.width if clip && (width <= 0 || width > clip.bounds.width)
      [width - 8.0, 120.0].max
    end

    # Heights are cached per width, because a resize changes every one of them.
    def cached_height(key, width, minimum:, padding:)
      @heights[[key, width.to_i]] ||= begin
        measured = yield
        [measured.ceil + padding, minimum].max.to_f
      end
    end
  end
end
