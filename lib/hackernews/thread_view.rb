# frozen_string_literal: true

module HackerNews
  # The comment thread, as an outline view with per-row measured heights.
  class ThreadView < ListView
    def self.delegate_class
      @delegate_class ||= Cocoa.define_class(
        'HNCommentSource', 'NSObject',
        protocols: %w[NSOutlineViewDataSource NSOutlineViewDelegate]
      ) do |c|
        c.define('outlineView:numberOfChildrenOfItem:', 'q@:@@') do |receiver, _v, item|
          owner_of(receiver).child_count(item)
        end
        c.define('outlineView:child:ofItem:', '@@:@q@') do |receiver, _v, index, item|
          owner_of(receiver).child_at(item, index)
        end
        c.define('outlineView:isItemExpandable:', 'B@:@@') do |receiver, _v, item|
          owner_of(receiver).expandable?(item)
        end
        c.define('outlineView:objectValueForTableColumn:byItem:', '@@:@@@') do |receiver, _v, _c, item|
          owner_of(receiver).cell(item)
        end
        c.define('outlineView:viewForTableColumn:item:', '@@:@@@') do |receiver, _v, _c, item|
          owner_of(receiver).row_view(item)
        end
        c.define('outlineView:heightOfRowByItem:', 'd@:@@') do |receiver, _v, item|
          owner_of(receiver).row_height(item)
        end
        c.define('outlineViewColumnDidResize:', 'v@:@') do |receiver, _note|
          owner_of(receiver).width_changed
        end
      end
    end

    NOTHING_SELECTED = 'Select a story to read its comments'
    NO_COMMENTS      = 'No comments yet'

    SYMBOL = 'bubble.left.and.bubble.right'

    def initialize(typography:, width:, height:)
      super(typography)
      @thread = CommentThread.new
      build(width, height)
      @placeholder = Placeholder.new(over: @scroll_view, width: width, height: height,
                                     symbol: SYMBOL, description: 'Comments')
      show_placeholder(NOTHING_SELECTED)
    end

    attr_reader :thread, :placeholder

    # The placeholder's container, so the message can sit over the scroll view.
    def pane
      @placeholder.container
    end

    def show_placeholder(message)
      @placeholder.show(message)
    end

    def hide_placeholder
      @placeholder.hide
    end

    def placeholder_visible?
      @placeholder.visible?
    end

    def placeholder_text
      @placeholder.text
    end

    def thread=(thread)
      @thread   = thread
      @heights  = {}
      @rendered = {}
      reload
    end

    # Show the thread, or say why there is nothing to show.
    def present(thread, message: NO_COMMENTS)
      self.thread = thread
      thread.empty? ? show_placeholder(message) : hide_placeholder
    end

    def rows
      @view.numberOfRows
    end

    # Comments start collapsed unless the preference says otherwise.
    def apply_expansion(mode)
      case mode
      when :all       then expand_all
      when :top_level then @thread.roots.each { |id| @view.expandItem(item_for(id)) }
      else                 collapse_all
      end
    end

    def expand_all
      @view.expandItem_expandChildren(nil, true)
    end

    def collapse_all
      @view.collapseItem_collapseChildren(nil, true)
    end

    def expand(id)
      @view.expandItem(item_for(id))
    end

    # ---- data source ---------------------------------------------------------

    def child_count(item)
      @thread.children(node_id(item)).size
    end

    def child_at(item, index)
      id = @thread.children(node_id(item))[index]
      id.nil? ? nil : item_for(id)
    end

    def expandable?(item)
      @thread.expandable?(node_id(item))
    end

    def cell(item)
      node = node_for(item)
      return '' if node.nil?

      @rendered[node[:id]] ||= @typography.comment(node)
    end

    def row_view(item)
      field = text_field('comment', selectable: true)
      field.setAttributedStringValue(cell(item))
      field
    end

    def row_height(item)
      node = node_for(item)
      return 18.0 if node.nil?

      width = text_width(item)
      cached_height(node[:id], width, minimum: 20, padding: 6) do
        @typography.measure(cell(item), width)
      end
    end

    def node_for(item)
      item.nil? ? nil : @thread.node(node_id(item))
    end

    private

    # Items cross into Objective-C as numbers, which the outline view is happy
    # to hold and hand back.
    def item_for(id)
      Cocoa::NSNumber.numberWithLongLong(id)
    end

    def node_id(item)
      item.nil? ? nil : item.objc_send('longLongValue')
    end

    # Usable text width at this row's indentation level.
    def text_width(item)
      level = @view.levelForItem(item)
      width = usable_width - (level * @view.indentationPerLevel) - (TEXT_INSET * 2)
      [width, 80.0].max
    end

    def build(width, height)
      @scroll_view = build_scroll_view(width, height)

      @view = Cocoa::NSOutlineView.alloc.initWithFrame([0, 0, width, height])
      @view.setStyle(Cocoa::NSTableViewStyleInset)
      @view.setHeaderView(nil)
      @view.setIndentationPerLevel(20)
      @view.setIntercellSpacing([0, 12])
      @view.setAutosaveExpandedItems(false)
      @view.setColumnAutoresizingStyle(1)
      @view.setAutoresizingMask(Cocoa::NSViewWidthSizable)

      column = build_column('comment', width - 24)
      @view.addTableColumn(column)
      @view.setOutlineTableColumn(column)

      @delegate = self.class.adopt(self.class.delegate_class.alloc.init, self)
      @view.setDataSource(@delegate)
      @view.setDelegate(@delegate)

      @scroll_view.setDocumentView(@view)
      observe_resizing
    end
  end
end
