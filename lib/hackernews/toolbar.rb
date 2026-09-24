# frozen_string_literal: true

module HackerNews
  # A unified toolbar built from a list of items.
  #
  # One Objective-C delegate class serves every toolbar; each instance finds
  # its owner here, so the main window and the reader can both have one.
  class Toolbar
    SPACE = :flexible_space

    SEARCH_WIDTH = 220.0

    Button = Struct.new(:identifier, :label, :symbol, :action, keyword_init: true)
    Custom = Struct.new(:identifier, :view, keyword_init: true)
    # The system's own share button; +items+ is asked for what to share.
    Share  = Struct.new(:identifier, :label, :items, keyword_init: true)
    # The system's own search field, which collapses to a magnifier when the
    # window gets narrow. +on_search+ is called with the text as it is typed.
    Search = Struct.new(:identifier, :label, :placeholder, :autosave, :on_search,
                        keyword_init: true)

    def self.owners
      @owners ||= {}
    end

    def self.owner_of(receiver)
      owners[receiver.objc_address]
    end

    # One delegate class for every share item, each finding its own spec.
    def self.share_owners
      @share_owners ||= {}
    end

    def self.share_delegate_class
      @share_delegate_class ||= Cocoa.define_class(
        'HNShareDelegate', 'NSObject',
        protocols: %w[NSSharingServicePickerToolbarItemDelegate]
      ) do |c|
        c.define('itemsForSharingServicePickerToolbarItem:', '@@:@') do |receiver, _item|
          Toolbar.share_owners[receiver.objc_address]&.call || []
        end
      end
    end

    def self.delegate_class
      @delegate_class ||= Cocoa.define_class(
        'HNToolbarDelegate', 'NSObject', protocols: %w[NSToolbarDelegate]
      ) do |c|
        c.define('toolbarAllowedItemIdentifiers:', '@@:@') do |receiver, _t|
          owner_of(receiver).identifiers
        end
        c.define('toolbarDefaultItemIdentifiers:', '@@:@') do |receiver, _t|
          owner_of(receiver).identifiers
        end
        c.define('toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:', '@@:@@B') do |receiver, _t, id, _f|
          owner_of(receiver).item(id.to_s)
        end
      end
    end

    def initialize(identifier:, items:)
      @identifier = identifier
      @items      = items
      @built      = {}
      @targets    = []
    end

    def identifiers
      @items.map do |item|
        item == SPACE ? Cocoa::NSToolbarFlexibleSpaceItemIdentifier : item.identifier
      end
    end

    def install(window)
      delegate = self.class.delegate_class.alloc.init
      # The toolbar holds its delegate weakly.
      @delegate = self.class.owners[delegate.objc_address] = self
      @delegate_object = delegate

      toolbar = Cocoa::NSToolbar.alloc.initWithIdentifier(@identifier)
      toolbar.setDelegate(delegate)
      toolbar.setDisplayMode(2) # icon only
      toolbar.setAllowsUserCustomization(false)

      window.setToolbar(toolbar)
      window.setToolbarStyle(Cocoa::NSWindowToolbarStyleUnified)
      toolbar
    end

    def item(identifier)
      @built[identifier] ||= build(@items.find { |i| i != SPACE && i.identifier == identifier })
    end

    # Put the keyboard in a search item's field. The toolbar builds its items
    # lazily, so asking for it is what makes it exist.
    def begin_search(identifier)
      search = item(identifier)
      search&.beginSearchInteraction
      search
    end

    def enable(identifier, flag)
      @built[identifier]&.setEnabled(flag)
    end

    private

    # NSSharingServicePickerToolbarItem draws the standard share control and
    # runs the picker itself; all it wants is the list of things to share.
    def build_share(spec)
      item = Cocoa::NSSharingServicePickerToolbarItem.alloc
                                                     .initWithItemIdentifier(spec.identifier)
      item.setLabel(spec.label)
      item.setToolTip(spec.label)

      delegate = self.class.share_delegate_class.alloc.init
      self.class.share_owners[delegate.objc_address] = spec.items
      @targets << delegate # the item holds its delegate weakly

      item.setDelegate(delegate)
      item
    end

    # NSSearchToolbarItem owns the field, its cancel button and its recents
    # menu; all it needs from us is where to send what was typed.
    #
    # Reporting every keystroke, with no delay of AppKit's own, leaves the
    # decision of when to actually search to the caller -- which is where the
    # cost of asking is known.
    def build_search(spec)
      item = Cocoa::NSSearchToolbarItem.alloc.initWithItemIdentifier(spec.identifier)
      item.setLabel(spec.label)
      item.setToolTip(spec.label)
      item.setPreferredWidthForSearchField(SEARCH_WIDTH)
      # Escape should clear the field and give the list the keyboard back.
      item.setResignsFirstResponderWithCancel(true)

      field = item.searchField
      field.setPlaceholderString(spec.placeholder)
      field.setSendsWholeSearchString(false)
      field.setSendsSearchStringImmediately(true)
      # Recent searches, remembered across launches, for free.
      field.setRecentsAutosaveName(spec.autosave) if spec.autosave

      target = Cocoa.action { |sender| spec.on_search.call(sender.stringValue.to_s) }
      @targets << target # controls do not retain their target
      field.setTarget(target)
      field.setAction(Cocoa::ACTION_SELECTOR)
      item
    end

    def build(spec)
      return nil if spec.nil?
      return build_share(spec) if spec.is_a?(Share)
      return build_search(spec) if spec.is_a?(Search)

      item = Cocoa::NSToolbarItem.alloc.initWithItemIdentifier(spec.identifier)

      if spec.is_a?(Custom)
        item.setView(spec.view)
        return item
      end

      target = Cocoa.action { |_sender| spec.action.call }
      @targets << target # controls do not retain their target

      item.setLabel(spec.label)
      item.setToolTip(spec.label)
      item.setImage(
        Cocoa::NSImage.imageWithSystemSymbolName_accessibilityDescription(spec.symbol, spec.label)
      )
      item.setBordered(true)
      item.setTarget(target)
      item.setAction(Cocoa::ACTION_SELECTOR)
      item
    end
  end
end
