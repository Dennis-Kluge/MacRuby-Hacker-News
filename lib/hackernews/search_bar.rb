# frozen_string_literal: true

module HackerNews
  # The row of search options that appears under the toolbar while a search
  # is running: how to rank the results, and how far back to look.
  #
  # It is a titlebar accessory rather than part of the window's content, which
  # is what Safari's find bar and Finder's scope bar are. AppKit gives it the
  # full width, draws the separator under it, and animates it in and out, so
  # nothing below has to be rearranged when it appears.
  class SearchBar
    # What we ask for; AppKit pins a titlebar accessory to a height of its
    # own, so this is a starting size and never the one laid out against.
    HEIGHT = 28.0
    # Level with the table's own cell inset, so "Sort:" lines up with the
    # site icons in the list below it.
    MARGIN  = 16.0
    GAP     = 6.0
    SPACING = 20.0

    # +on_change+ is called with the sorting and the period after either.
    def initialize(width: 900.0, &on_change)
      @on_change = on_change
      @targets   = []

      build(width)
      build_controller
    end

    attr_reader :view, :controller, :sorting_control, :period_popup

    def sorting
      Sorting.at(@sorting_control.selectedSegment)
    end

    def period
      Period.at(@period_popup.indexOfSelectedItem)
    end

    # Show what the query actually holds, which is not always what was
    # clicked: starting a search adopts the section's own ranking.
    def show(query)
      @sorting_control.setSelectedSegment(Sorting.index_of(query.sorting.key))
      @period_popup.selectItemAtIndex(Period.index_of(query.period.key))
      # The bar is about to be seen, and by now it has its real height.
      layout
      @controller.setHidden(false)
    end

    def hide
      @controller.setHidden(true)
    end

    def visible?
      !@controller.isHidden
    end

    # The window draws it; until then there is nothing to attach it to, and
    # no final height to lay the row out against.
    def install(window)
      window.addTitlebarAccessoryViewController(@controller)
      @controller.setHidden(true)
      layout
      @controller
    end

    # Centre the tallest control, then put every baseline on its line.
    #
    # A text field, a segmented control and a popup button each pad their
    # text differently inside their frame, so centring the frames leaves the
    # text visibly out of step -- which is what "Sort:" riding low next to
    # "Relevance" was.
    def layout
      height = @view.frame.height
      return if height <= 0

      anchor   = @row.map(&:first).max_by { |control| control.frame.height }
      baseline = height - ((height - anchor.frame.height) / 2.0).round -
                 baseline_offset(anchor)

      x = MARGIN
      @row.each do |control, gap|
        frame = control.frame
        control.setFrameOrigin(
          [x.round, (baseline - (frame.height - baseline_offset(control))).round]
        )
        x += frame.width + gap
      end
      @view
    end

    private

    def build_controller
      @controller = Cocoa::NSTitlebarAccessoryViewController.alloc.init
      @controller.setView(@view)
      # Below the toolbar rather than beside it.
      @controller.setLayoutAttribute(Cocoa::NSLayoutAttributeBottom)
      @controller.setHidden(true)
    end

    def build(width)
      @view = Cocoa::NSView.alloc.initWithFrame([0, 0, width, HEIGHT])
      @view.setAutoresizingMask(Cocoa::NSViewWidthSizable)

      # Left to right, each with the gap that follows it. Four small controls
      # in a fixed-height strip do not need a stack view's machinery.
      @row = [
        [label('Sort:'),   GAP],
        [build_sorting,    SPACING],
        [label('From:'),   GAP],
        [build_period,     0.0]
      ]
      @row.each { |control, _gap| @view.addSubview(control) }
      layout
    end

    # Where a control draws its text, measured down from the top of its
    # frame. Every AppKit control answers this, which is what makes aligning
    # them by eye unnecessary.
    def baseline_offset(control)
      control.firstBaselineOffsetFromTop
    end

    def label(text)
      field = Cocoa::NSTextField.alloc.initWithFrame([0, 0, 10, 16])
      field.setEditable(false)
      field.setSelectable(false)
      field.setBezeled(false)
      field.setDrawsBackground(false)
      field.setStringValue(text)
      field.setFont(Cocoa::NSFont.systemFontOfSize(11))
      field.setTextColor(Cocoa::NSColor.secondaryLabelColor)
      field.sizeToFit
      field
    end

    def build_sorting
      control = Cocoa::NSSegmentedControl.alloc.init
      control.setSegmentCount(Sorting::ALL.size)
      control.setSegmentStyle(Cocoa::NSSegmentStyleRounded)
      control.setTrackingMode(Cocoa::NSSegmentSwitchTrackingSelectOne)
      control.setControlSize(1) # NSControlSizeSmall
      control.setFont(Cocoa::NSFont.systemFontOfSize(11))

      Sorting::ALL.each_with_index { |item, i| control.setLabel_forSegment(item.label, i) }
      control.setSelectedSegment(0)
      control.sizeToFit

      @sorting_control = control
      changes(control)
    end

    def build_period
      popup = Cocoa::NSPopUpButton.alloc.initWithFrame_pullsDown([0, 0, 140, 20], false)
      popup.setControlSize(1) # NSControlSizeSmall
      popup.setFont(Cocoa::NSFont.systemFontOfSize(11))
      popup.setBezelStyle(Cocoa::NSBezelStyleRounded)
      Period.labels.each { |label| popup.addItemWithTitle(label) }
      popup.selectItemAtIndex(0)
      popup.sizeToFit

      @period_popup = popup
      changes(popup)
    end

    def changes(control)
      target = Cocoa.action { |_sender| @on_change.call(sorting, period) }
      @targets << target # controls do not retain their target
      control.setTarget(target)
      control.setAction(Cocoa::ACTION_SELECTOR)
      control
    end
  end
end
