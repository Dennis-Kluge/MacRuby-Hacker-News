# frozen_string_literal: true

module HackerNews
  # The sidebar list of stories.
  class StoryListView < ListView
    PREFETCH = 8

    # What the empty state shows, depending on why the list is empty.
    NO_RESULTS_SYMBOL = 'magnifyingglass'
    NO_STORIES_SYMBOL = 'newspaper'

    # One menu delegate for every story list, each finding its own owner.
    def self.menu_owners
      @menu_owners ||= {}
    end

    def self.menu_delegate_class
      @menu_delegate_class ||= Cocoa.define_class(
        'HNStoryMenuDelegate', 'NSObject', protocols: %w[NSMenuDelegate]
      ) do |c|
        c.define('menuNeedsUpdate:', 'v@:@') do |receiver, _menu|
          StoryListView.menu_owners[receiver.objc_address]&.prepare_context_menu
        end
      end
    end

    def self.delegate_class
      @delegate_class ||= Cocoa.define_class(
        'HNStorySource', 'NSObject',
        protocols: %w[NSTableViewDataSource NSTableViewDelegate]
      ) do |c|
        c.define('numberOfRowsInTableView:', 'q@:@') do |receiver, _table|
          owner_of(receiver).row_count
        end
        c.define('tableView:objectValueForTableColumn:row:', '@@:@@q') do |receiver, _t, _col, row|
          owner_of(receiver).cell(row)
        end
        c.define('tableView:viewForTableColumn:row:', '@@:@@q') do |receiver, _t, _col, row|
          owner_of(receiver).row_view(row)
        end
        c.define('tableView:heightOfRow:', 'd@:@q') do |receiver, _t, row|
          owner_of(receiver).row_height(row)
        end
        c.define('tableViewSelectionDidChange:', 'v@:@') do |receiver, _note|
          owner_of(receiver).selection_changed
        end
        c.define('tableViewColumnDidResize:', 'v@:@') do |receiver, _note|
          owner_of(receiver).width_changed
        end
      end
    end

    # +on_select+ fires when the highlighted row changes, +on_activate+ on a
    # double click, and +on_prefetch+ when the end of the list comes into view.
    def initialize(list:, typography:, width:, height:, favicons: nil,
                   context: {}, on_select:, on_activate:, on_prefetch:)
      super(typography)
      @list        = list
      @favicons    = favicons
      @context     = context
      @on_select   = on_select
      @on_activate = on_activate
      @on_prefetch = on_prefetch
      @context_row = -1

      build(width, height)
      build_context_menu
      @placeholder = Placeholder.new(over: @scroll_view, width: width, height: height,
                                     symbol: NO_STORIES_SYMBOL, description: 'Stories')
      # The table is what the list normally shows; the message is the exception.
      @placeholder.hide
    end

    # The placeholder's container, so a message can stand in for the table.
    def pane
      @placeholder.container
    end

    attr_reader :placeholder

    # Say why the list is empty, or get out of the way now that it is not.
    def show_empty(message, symbol: NO_STORIES_SYMBOL)
      @placeholder.show(message, symbol: symbol)
    end

    def hide_empty
      @placeholder.hide
    end

    def empty_visible?
      @placeholder.visible?
    end

    def empty_text
      @placeholder.text
    end

    # The row a context menu is acting on: the one right-clicked, or the
    # selection when the click landed outside any row.
    attr_reader :context_row

    def context_menu
      @context_menu
    end

    # Turning site icons off falls back to the rank column.
    def favicons=(store)
      @favicons = store
      invalidate
    end

    def note_rows_changed
      @view.noteNumberOfRowsChanged
    end

    def select(index)
      @view.selectRowIndexes_byExtendingSelection(
        Cocoa::NSIndexSet.indexSetWithIndex(index), false
      )
      selection_changed
    end

    def deselect
      @view.deselectAll(nil)
    end

    def selected_row
      @view.selectedRow
    end

    # Redraw one row rather than the whole table, so scroll position and
    # selection survive.
    def refresh_row(index)
      return if index.nil?

      # The cell is drawn from the read state, which has just changed.
      @rendered.delete(index)

      @view.reloadDataForRowIndexes_columnIndexes(
        Cocoa::NSIndexSet.indexSetWithIndex(index),
        Cocoa::NSIndexSet.indexSetWithIndex(0)
      )
    end

    # ---- data source ---------------------------------------------------------

    def row_count
      @list.size
    end

    def cell(row)
      story = @list[row]
      return '' if story.nil?

      @rendered[row] ||= @typography.story(
        story, rank: row + 1, read: @list.read?(story), icon: icon_for(story)
      )
    end

    # Redraw the rows showing a site whose icon has just arrived.
    def refresh_domain(domain)
      @list.stories.each_with_index do |story, row|
        next unless story[:domain] == domain

        @rendered.delete(row)
        refresh_row(row)
      end
    end

    def row_view(row)
      # Only visible rows are asked for a view, which makes this the right place
      # to notice that the end of the list is approaching. Row heights are asked
      # for every row, so prefetching there would fetch the whole archive.
      @on_prefetch.call if row >= @list.size - PREFETCH

      field = text_field('story', selectable: false)
      field.setAttributedStringValue(cell(row))
      field
    end

    def row_height(row)
      return 20.0 if @list[row].nil?

      width = [usable_width - TEXT_INSET, 120.0].max
      cached_height(row, width, minimum: 32, padding: 12) do
        @typography.measure(cell(row), width)
      end
    end

    def selection_changed
      @on_select.call(selected_row)
    end

    # Called just before the menu opens: remember which row was clicked and
    # word the read/unread item for that story.
    def prepare_context_menu
      clicked = @view.clickedRow
      @context_row = clicked.negative? ? @view.selectedRow : clicked

      return if @read_item.nil?

      read = @context.fetch(:read?, -> { false }).call
      @read_item.setTitle(read ? 'Mark as Unread' : 'Mark as Read')
      @read_item.setEnabled(!@context_row.negative?)
    end

    def icon_for(story)
      return nil if @favicons.nil?

      @favicons.icon_for(story[:domain] || 'news.ycombinator.com')
    end

    private

    # A cell is only valid for the read state it was drawn with, so the string
    # cache is dropped alongside the heights.
    def build(width, height)
      @scroll_view = build_scroll_view(width, height)
      # A sidebar list does not draw its own background: the split view item's
      # material shows through instead.
      @scroll_view.setDrawsBackground(false)

      @view = Cocoa::NSTableView.alloc.initWithFrame([0, 0, width, height])
      @view.setStyle(Cocoa::NSTableViewStyleSourceList)
      @view.setHeaderView(nil)
      @view.setBackgroundColor(Cocoa::NSColor.clearColor)
      @view.setSelectionHighlightStyle(1)
      @view.setColumnAutoresizingStyle(1)
      @view.setAutoresizingMask(Cocoa::NSViewWidthSizable)
      @view.setIntercellSpacing([0, 6])
      @view.setGridStyleMask(Cocoa::NSTableViewSolidHorizontalGridLineMask)
      @view.setGridColor(Cocoa::NSColor.separatorColor)
      @view.addTableColumn(build_column('story', width - 24))

      @delegate = self.class.adopt(self.class.delegate_class.alloc.init, self)
      @view.setDataSource(@delegate)
      @view.setDelegate(@delegate)

      @activate_target = Cocoa.action { |_sender| @on_activate.call }
      @view.setTarget(@activate_target)
      @view.setDoubleAction(Cocoa::ACTION_SELECTOR)

      @scroll_view.setDocumentView(@view)
      observe_resizing
    end

    # Right-clicking a row acts on that row, which is not necessarily the
    # selected one -- hence clickedRow rather than selectedRow.
    def build_context_menu
      return if @context.empty?

      @context_menu = Cocoa::NSMenu.alloc.init
      @context_targets = []

      add_context_item('Open Link', :open)
      add_context_item('Open on Hacker News', :discussion)
      @context_menu.addItem(Cocoa::NSMenuItem.separatorItem)
      add_context_item('Copy Article Link', :copy_article)
      add_context_item('Copy Comments Link', :copy_comments)
      @context_menu.addItem(Cocoa::NSMenuItem.separatorItem)
      @read_item = add_context_item('Mark as Read', :toggle_read)
      @context_menu.addItem(Cocoa::NSMenuItem.separatorItem)
      add_context_item('Share…', :share)

      delegate = self.class.menu_delegate_class.alloc.init
      self.class.menu_owners[delegate.objc_address] = self
      @menu_delegate = delegate # the menu holds its delegate weakly
      @context_menu.setDelegate(delegate)

      @view.setMenu(@context_menu)
    end

    def add_context_item(title, command)
      handler = @context[command]
      return nil if handler.nil?

      target = Cocoa.action { |_sender| handler.call }
      @context_targets << target # menu items do not retain their target

      item = Cocoa::NSMenuItem.alloc.initWithTitle_action_keyEquivalent(title, nil, '')
      item.setTarget(target)
      item.setAction(Cocoa::ACTION_SELECTOR)
      @context_menu.addItem(item)
      item
    end
  end
end
