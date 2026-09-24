# frozen_string_literal: true

module HackerNews
  # The application's menus.
  #
  # Every entry is either a standard selector sent up the responder chain --
  # which is how Copy and Select All reach whichever text field has focus --
  # or a named command supplied by the caller.
  class MenuBar
    COMMAND  = Cocoa::ACTION_SELECTOR
    CMD      = Cocoa::NSEventModifierFlagCommand
    SHIFT    = Cocoa::NSEventModifierFlagShift
    OPTION   = Cocoa::NSEventModifierFlagOption
    CONTROL  = Cocoa::NSEventModifierFlagControl

    def initialize(app_name:, commands:)
      @app_name = app_name
      @commands = commands
      @targets  = {}
    end

    # The main menu this installed. NSApplication has only one, and anything
    # else in the process is free to replace it, so what we built is kept
    # here rather than read back from the application.
    attr_reader :menu

    # The submenu behind a top-level title, or nil if there is no such menu.
    def submenu_named(title)
      return nil if @menu.nil?

      index = (0...@menu.numberOfItems).find { |i| @menu.itemAtIndex(i).title.to_s == title }
      index && @menu.itemAtIndex(index).submenu
    end

    def items_in(title)
      menu = submenu_named(title)
      return [] if menu.nil?

      (0...menu.numberOfItems).map { |i| menu.itemAtIndex(i) }
    end

    def item_titled(menu_title, item_title)
      items_in(menu_title).find { |item| item.title.to_s == item_title }
    end

    def install(nsapp)
      main = Cocoa::NSMenu.alloc.init
      main.addItem(submenu(@app_name, application_menu(nsapp)))
      main.addItem(submenu('File', file_menu))
      main.addItem(submenu('Edit', edit_menu))
      main.addItem(submenu('View', view_menu))

      windows = window_menu
      main.addItem(submenu('Window', windows))
      help = help_menu
      main.addItem(submenu('Help', help))

      @menu = main
      nsapp.setMainMenu(main)
      # Handing these to NSApplication is what makes the system inject its own
      # entries: the window list, the services list, and Help search.
      nsapp.setWindowsMenu(windows)
      nsapp.setHelpMenu(help)
      main
    end

    private

    def application_menu(nsapp)
      menu = Cocoa::NSMenu.alloc.init
      command(menu, "About #{@app_name}", :about)
      separator(menu)
      command(menu, 'Settings…', :settings, key: ',')
      separator(menu)

      services = Cocoa::NSMenu.alloc.init
      standard(menu, 'Services', nil).setSubmenu(services)
      nsapp.setServicesMenu(services)
      separator(menu)

      standard(menu, "Hide #{@app_name}", 'hide:', key: 'h')
      standard(menu, 'Hide Others', 'hideOtherApplications:', key: 'h', modifiers: CMD | OPTION)
      standard(menu, 'Show All', 'unhideAllApplications:')
      separator(menu)
      standard(menu, "Quit #{@app_name}", 'terminate:', key: 'q')
      menu
    end

    def file_menu
      menu = Cocoa::NSMenu.alloc.init
      command(menu, 'Reload Stories', :reload, key: 'r')
      separator(menu)
      command(menu, 'Open Link', :open_link, key: 'o')
      command(menu, 'Open on Hacker News', :open_discussion, key: 'o', modifiers: CMD | SHIFT)
      command(menu, 'Open in Default Browser', :open_externally, key: 'o', modifiers: CMD | OPTION)
      separator(menu)
      command(menu, 'Share…', :share, key: 's', modifiers: CMD | SHIFT)
      command(menu, 'Copy Link', :copy_link, key: 'c', modifiers: CMD | SHIFT)
      separator(menu)
      standard(menu, 'Close Window', 'performClose:', key: 'w')
      menu
    end

    # Comment text is selectable, so these have real work to do.
    def edit_menu
      menu = Cocoa::NSMenu.alloc.init
      standard(menu, 'Undo', 'undo:', key: 'z')
      standard(menu, 'Redo', 'redo:', key: 'z', modifiers: CMD | SHIFT)
      separator(menu)
      standard(menu, 'Cut', 'cut:', key: 'x')
      standard(menu, 'Copy', 'copy:', key: 'c')
      standard(menu, 'Paste', 'paste:', key: 'v')
      standard(menu, 'Select All', 'selectAll:', key: 'a')
      separator(menu)
      # Find belongs in Edit, where every Mac application puts it.
      command(menu, 'Find…', :find, key: 'f')
      command(menu, 'Clear Search', :clear_search, key: 'f', modifiers: CMD | OPTION)
      menu
    end

    def view_menu
      menu = Cocoa::NSMenu.alloc.init
      Section::ALL.each do |section|
        command(menu, section.label, :"section_#{section.key}", key: section.shortcut)
      end
      separator(menu)
      # The filter bar has no keyboard of its own, so its two controls are
      # here as well.
      nest(menu, 'Sort Search Results',
           Sorting::ALL.map { |item| [item.label, :"sort_#{item.key}"] })
      nest(menu, 'Search Period',
           Period::ALL.map { |item| [item.label, :"period_#{item.key}"] })
      separator(menu)
      command(menu, 'Expand All Comments', :expand_all, key: ']', modifiers: CMD | SHIFT)
      command(menu, 'Collapse All Comments', :collapse_all, key: '[', modifiers: CMD | SHIFT)
      separator(menu)
      command(menu, 'Mark All Stories Unread', :mark_all_unread)
      separator(menu)
      # NSSplitViewController implements toggleSidebar:, reached via the chain.
      standard(menu, 'Toggle Sidebar', 'toggleSidebar:', key: 's', modifiers: CMD | CONTROL)
      standard(menu, 'Enter Full Screen', 'toggleFullScreen:', key: 'f', modifiers: CMD | CONTROL)
      menu
    end

    def window_menu
      menu = Cocoa::NSMenu.alloc.init
      standard(menu, 'Minimize', 'performMiniaturize:', key: 'm')
      standard(menu, 'Zoom', 'performZoom:')
      separator(menu)
      standard(menu, 'Bring All to Front', 'arrangeInFront:')
      separator(menu)
      # The window list below only shows windows that are open, so a closed
      # main window needs an entry of its own.
      command(menu, @app_name, :show_window, key: '0')
      menu
    end

    def help_menu
      menu = Cocoa::NSMenu.alloc.init
      command(menu, 'Hacker News Guidelines', :guidelines)
      menu
    end

    # ---- building blocks -----------------------------------------------------

    def submenu(title, menu)
      item = Cocoa::NSMenuItem.alloc.init
      item.setTitle(title)
      menu.setTitle(title)
      item.setSubmenu(menu)
      item
    end

    # A submenu of commands, each a plain entry with no shortcut of its own.
    def nest(menu, title, entries)
      inner = Cocoa::NSMenu.alloc.init
      entries.each { |entry_title, name| command(inner, entry_title, name) }
      item = standard(menu, title, nil)
      item.setSubmenu(inner)
      inner.setTitle(title)
      item
    end

    # A nil target lets the item travel the responder chain.
    def standard(menu, title, action, key: '', modifiers: nil)
      item = Cocoa::NSMenuItem.alloc.initWithTitle_action_keyEquivalent(title, action, key)
      item.setKeyEquivalentModifierMask(modifiers) if modifiers
      menu.addItem(item)
      item
    end

    def command(menu, title, name, key: '', modifiers: nil)
      handler = @commands.fetch(name)
      target  = Cocoa.action { |_sender| handler.call }
      @targets[name] = target # menu items do not retain their target

      item = standard(menu, title, nil, key: key, modifiers: modifiers)
      item.setTarget(target)
      item.setAction(COMMAND)
      item
    end

    def separator(menu)
      menu.addItem(Cocoa::NSMenuItem.separatorItem)
    end
  end
end
