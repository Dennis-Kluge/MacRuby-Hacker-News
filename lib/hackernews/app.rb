# frozen_string_literal: true

require 'time'

module HackerNews
  # Wires the pieces together and owns the commands the menus and toolbar
  # invoke. The models, the views, the window and the menus each live in their
  # own class; what is left here is the conversation between them.
  class App
    APP_NAME    = 'Hacker News'
    APP_VERSION = '1.0'
    BUNDLE_ID   = 'org.example.hackernews'
    GUIDELINES  = 'https://news.ycombinator.com/newsguidelines.html'

    TOOLBAR_ID   = 'hn.toolbar'
    RELOAD_ITEM  = 'hn.reload'
    OPEN_ITEM    = 'hn.open'
    HN_ITEM      = 'hn.discussion'
    SPINNER_ITEM = 'hn.spinner'
    SECTION_ITEM = 'hn.sections'
    SHARE_ITEM   = 'hn.share'
    SEARCH_ITEM  = 'hn.search'

    SEARCH_PLACEHOLDER = 'Search Hacker News'
    SEARCH_AUTOSAVE    = 'HNRecentSearches'

    # ---- identity ------------------------------------------------------------

    # A script launched from a terminal has no bundle, so AppKit falls back to
    # the process name -- which is why the menu bar would otherwise say "ruby".
    def self.claim_app_identity(name = APP_NAME, identifier = BUNDLE_ID)
      info = Cocoa::NSBundle.mainBundle.infoDictionary
      return false if info.nil?

      {
        'CFBundleName' => name, 'CFBundleDisplayName' => name,
        'CFBundleIdentifier' => identifier,
        'CFBundleShortVersionString' => APP_VERSION, 'CFBundleVersion' => APP_VERSION,
        'NSHumanReadableCopyright' => 'A Hacker News reader built on the Cocoa bridge.'
      }.each { |key, value| info.objc_send('setObject:forKey:', value, key) }

      # This is the one AppKit actually titles the application menu with.
      Cocoa::NSProcessInfo.processInfo.setProcessName(name)
      install_icon
      true
    rescue ObjC::Exception
      false
    end

    # Without a bundle there is no icon file, so the Dock and the About panel
    # would fall back to a generic document. One is drawn instead.
    def self.app_icon
      @app_icon ||= AppIcon.image(512.0)
    end

    def self.install_icon
      icon = app_icon
      return false if icon.nil?

      Cocoa::NSApplication.sharedApplication.setApplicationIconImage(icon)
      true
    end

    # ---- construction --------------------------------------------------------

    def initialize(api: API.new)
      @api    = api
      @status = ''

      Settings.register_defaults
      @settings   = Settings.new
      @history    = ReadingHistory.new(@settings)
      @list       = StoryList.new(api: @api, history: @history, settings: @settings)
      @typography = Typography.new(@settings)

      @nsapp = Cocoa::NSApplication.sharedApplication
      # The Dock tile is created when the policy becomes Regular, so the icon
      # has to be applied after that, not before.
      @nsapp.setActivationPolicy(Cocoa::NSApplicationActivationPolicyRegular)
      self.class.install_icon

      build_views
      build_window
      build_delegate
      @menu_bar = MenuBar.new(app_name: APP_NAME, commands: commands)
      @menu_bar.install(@nsapp)
    end

    attr_reader :favicons

    attr_reader :settings, :list, :history, :typography,
                :story_view, :thread_view, :main_window, :toolbar, :menu_bar

    # The story whose comments are showing.
    attr_reader :story

    def prefetching?
      @prefetch_scheduled ? true : false
    end

    def run
      # And again once the run loop is up: the tile is not always ready to take
      # an icon before then.
      Cocoa::NSOperationQueue.mainQueue.addOperationWithBlock { self.class.install_icon }

      @main_window.restore_frame
      @main_window.show
      apply_refresh_interval
      @nsapp.activateIgnoringOtherApps(true)
      load_front_page

      if (seconds = ENV['HN_TIMEOUT'])
        Cocoa::NSTimer.scheduledTimerWithTimeInterval_repeats_block(seconds.to_f, false) do |_t|
          @nsapp.terminate(nil)
        end
      end

      @nsapp.run
    end

    # ---- commands ------------------------------------------------------------

    def commands
      {
        about:            -> { show_about_panel },
        settings:         -> { show_preferences },
        reload:           -> { load_front_page },
        open_link:        -> { open_selected_link },
        open_discussion:  -> { open_selected_discussion },
        open_externally:  -> { open_selected_externally },
        expand_all:       -> { thread_view.expand_all },
        collapse_all:     -> { thread_view.collapse_all },
        mark_all_unread:  -> { mark_all_unread },
        show_window:      -> { show_main_window },
        find:             -> { focus_search },
        clear_search:     -> { clear_search },
        share:            -> { share_selected },
        copy_link:        -> { copy_link },
        guidelines:       -> { open_link(GUIDELINES, title: 'Guidelines') }
      }.merge(section_commands).merge(search_commands)
    end

    # One command per section, so each can have a shortcut.
    def section_commands
      Section::ALL.each_with_object({}) do |item, commands|
        commands[:"section_#{item.key}"] = -> { show_section(item.key) }
      end
    end

    # The filter bar's two controls, also reachable from the View menu -- and
    # from the keyboard, which the bar itself is not.
    def search_commands
      commands = {}
      Sorting::ALL.each { |item| commands[:"sort_#{item.key}"] = -> { self.sorting = item.key } }
      Period::ALL.each  { |item| commands[:"period_#{item.key}"] = -> { self.period = item.key } }
      commands
    end

    def load_front_page
      @list.reload { |event, payload| list_changed(event, payload) }
    end
    alias reload_stories load_front_page

    # The section the list is actually showing. Settings holds the one to
    # start with next launch; the list holds the one on screen, and they part
    # company for as long as it takes the preference change to be applied.
    def section
      @list.query.section
    end

    # Switching section starts the list again from that section's first page.
    # Any search survives it: a section and a search are different halves of
    # the same question.
    def show_section(key)
      chosen = Section[key]
      return if chosen.key == section.key

      @settings.section = chosen.key
      @section_control&.setSelectedSegment(Section.index_of(chosen.key))
      @list.ask(@list.query.with_section(chosen))
      clear_thread
      load_front_page
    end

    # ---- search --------------------------------------------------------------

    # Called for every keystroke in the search field. Only the pause at the
    # end of a word reaches the network.
    def search_typed(text)
      search_debounce.schedule(text)
    end

    def search_debounce
      @search_debounce ||= Debounce.new(delay: search_delay) { |text| search(text) }
    end

    # Overridable so tests can search without waiting on a run loop.
    def search_delay
      @search_delay ||= Debounce::DEFAULT_DELAY
    end

    # Changing the delay rebuilds the timer that was using the old one.
    def search_delay=(seconds)
      @search_delay    = seconds
      @search_debounce = nil
    end

    # Search within the section that is showing. An empty string is not a
    # search -- it is the way back to the plain list.
    def search(text)
      return false unless @list.ask(query_for(text))

      update_search_bar
      clear_thread
      load_front_page
      true
    end

    # Beginning a search adopts the section's own ranking, so searching from
    # New stays newest-first. Refining one keeps whatever the bar is set to,
    # and so does going back to the plain list.
    def query_for(text)
      return @list.query.with_text(text) if @list.searching? || text.to_s.strip.empty?

      @list.query.starting_search(text)
    end

    # ---- how results are ranked ----------------------------------------------

    def sorting
      @list.query.sorting
    end

    def period
      @list.query.period
    end

    def sorting=(key)
      apply_search_options(sorting: Sorting[key])
    end

    def period=(key)
      apply_search_options(period: Period[key])
    end

    # Changing either only costs a request while a search is actually running;
    # otherwise it is remembered for the next one.
    def apply_search_options(sorting: self.sorting, period: self.period)
      return false unless @list.ask(@list.query.with_sorting(sorting).with_period(period))

      update_search_bar
      load_front_page if @list.searching?
      true
    end

    def search_bar
      @search_bar
    end

    def update_search_bar
      return if @search_bar.nil?

      @list.searching? ? @search_bar.show(@list.query) : @search_bar.hide
    end

    def searching?
      @list.searching?
    end

    def search_text
      @list.query.text
    end

    # The toolbar builds its items lazily, so asking for this is what creates
    # the field. Nil before the toolbar exists at all.
    def search_item
      @toolbar&.item(SEARCH_ITEM)
    end

    def search_field
      search_item&.searchField
    end

    # Cmd-F: bring the window forward and put the keyboard in the field.
    def focus_search
      return nil if @toolbar.nil?

      show_main_window
      @toolbar.begin_search(SEARCH_ITEM)
    end

    # Empty the field and go back to the unsearched list. Emptying the field
    # does not itself fire its action, so the search is ended here too.
    def clear_search
      search_debounce.cancel
      search_field&.setStringValue('')
      search('')
    end

    # Nothing selected, nothing to read: the state the thread pane starts in.
    def clear_thread
      @story_view.deselect
      @story = nil
      @thread_view.present(CommentThread.new, message: ThreadView::NOTHING_SELECTED)
    end

    def load_next_page
      @list.load_next { |event, payload| list_changed(event, payload) }
    end

    def select_story(index)
      return if index.negative? || index >= @list.size

      @story_view.select(index)
    end

    def selected_story
      @list[@story_view.selected_row]
    end

    def stories
      @list.stories
    end

    def status_text
      @status
    end

    # ---- reading -------------------------------------------------------------

    # Load a story's comments and show them.
    def show_story(story)
      return if story.nil? || (@story && @story[:id] == story[:id])

      @story = story
      mark_visited(story)
      @thread_view.present(CommentThread.new, message: 'Loading comments…')
      @loading_comments = true
      @spinner.startAnimation(nil)
      status("Loading #{pluralize(story[:comments], 'comment')}…")

      @api.item(story[:id]) do |tree, error|
        @loading_comments = false
        @spinner.stopAnimation(nil)
        if error
          @thread_view.show_placeholder("Could not load comments — #{error}")
          next status("Could not load comments: #{error}")
        end

        @thread_view.present(CommentThread.from(tree))
        @thread_view.apply_expansion(@settings.expansion)
        status("#{pluralize(@thread_view.thread.size, 'comment')} · " \
               "#{pluralize(story[:points], 'point')} · by #{story[:author]}")
      end
    end

    # Whether a comment thread is in flight. Distinct from the story list's own
    # loading state, which says nothing about the thread.
    def loading_comments?
      @loading_comments ? true : false
    end

    def apply_expansion
      @thread_view.apply_expansion(@settings.expansion)
    end

    def apply_favicons
      @story_view.favicons = @settings.show_favicons? ? @favicons : nil
    end

    # ---- automatic refresh ---------------------------------------------------

    def auto_refresh
      @auto_refresh ||= AutoRefresh.new(settings: @settings,
                                        on_tick: -> { refresh_if_undisturbed })
    end

    def apply_refresh_interval
      auto_refresh.restart
    end

    # Reloading would discard the pages already fetched and jump the reader
    # back to the top, so a tick is skipped unless the list is still near the
    # start of the first page.
    def undisturbed?
      return false if @list.loading?
      return false if @list.page > 1

      visible = @story_view.view.enclosingScrollView&.documentVisibleRect
      visible.nil? || visible.y < 40.0
    end

    def refresh_if_undisturbed
      return false unless undisturbed?

      keep = selected_story
      load_front_page
      restore_selection(keep)
      true
    end

    # Put the reader back on the story they were reading, if it survived.
    def restore_selection(story)
      return if story.nil?

      row = @list.index_of(story)
      @story_view.select(row) if row
    end

    # Text metrics changed, so every cached string and measured height is stale.
    def apply_text_size
      @story_view.invalidate
      @thread_view.invalidate
      apply_expansion unless @thread_view.thread.empty?
    end

    # ---- read state ----------------------------------------------------------

    def visited?(story)
      @list.read?(story)
    end

    def visited_count
      @history.size
    end

    def mark_visited(story)
      @story_view.refresh_row(@list.index_of(story)) if @list.mark_read(story)
    end

    def mark_all_unread
      @history.clear
      @story_view.invalidate
      status('Reading history cleared')
    end

    def set_remember_read(enabled)
      @history.remembering = enabled
    end

    # ---- links ---------------------------------------------------------------

    def link_for(story)
      return nil if story.nil?

      url = story[:url].to_s
      url.empty? ? discussion_url(story) : url
    end

    # An Ask HN or Show HN post has no external link, so it falls back to its
    # discussion page rather than doing nothing.
    def discussion_url(story)
      story && "https://news.ycombinator.com/item?id=#{story[:id]}"
    end

    def open_selected_link
      story = selected_story
      mark_visited(story)
      open_link(link_for(story), title: story && story[:title])
    end

    def open_selected_discussion
      story = selected_story
      open_link(discussion_url(story), title: story && story[:title])
    end

    # Always leaves the app, whatever the preference says.
    def open_selected_externally
      story = selected_story
      mark_visited(story)
      open_in_default_browser(link_for(story))
    end

    def open_link(string, title: nil)
      return status('Select a story first') if string.nil?

      if @settings.open_links_in == :app
        open_in_reader(string, title: title)
      else
        open_in_default_browser(string)
      end
    end

    def reader
      @reader ||= Reader.new(on_external: ->(url) { open_in_default_browser(url) })
    end

    def open_in_reader(string, title: nil)
      return status('Select a story first') if string.nil?
      return status("Could not parse that URL: #{string}") unless valid_url?(string)

      reader.open(string, title: title)
      status("Reading #{string}")
    end

    def open_in_default_browser(string)
      return status('Select a story first') if string.nil?

      url = Cocoa::NSURL.URLWithString(string)
      return status("Could not parse that URL: #{string}") if url.nil?

      status(browser_opener.call(url) ? "Opened #{string}" : "Nothing could open #{string}")
    end

    # Kept for callers that mean "leave the app".
    alias open_url open_in_default_browser

    # ---- the window ----------------------------------------------------------

    # Closing the window leaves the app running, so there has to be a way back.
    # The Dock asks the delegate; the Window menu asks directly.
    # Objective-C classes are registered globally by name, so a delegate class
    # defined per instance would have its methods replaced by the next one --
    # and then answer for the wrong app. Each delegate instance finds its own.
    def self.delegate_owners
      @delegate_owners ||= {}
    end

    def self.delegate_class
      @delegate_class ||= Cocoa.define_class(
        'HNAppDelegate', 'NSObject', protocols: %w[NSApplicationDelegate]
      ) do |c|
        c.define('applicationShouldHandleReopen:hasVisibleWindows:', 'B@:@B') do |receiver, _sender, visible|
          App.delegate_owners[receiver.objc_address]&.show_main_window unless visible
          true
        end
      end
    end

    def build_delegate
      @delegate = self.class.delegate_class.alloc.init
      self.class.delegate_owners[@delegate.objc_address] = self
      @nsapp.setDelegate(@delegate) # NSApplication holds it weakly
    end

    def show_main_window
      @main_window.show
      @nsapp.activateIgnoringOtherApps(true)
      @main_window.window
    end

    def main_window_visible?
      @main_window.window.isVisible
    end

    # ---- the context menu ----------------------------------------------------

    # A right-click acts on the row under the pointer, which is not necessarily
    # the selected one.
    def context_story
      @list[@story_view.context_row]
    end

    def context_commands
      {
        open:          -> { open_context_link },
        discussion:    -> { open_context_discussion },
        copy_article:  -> { copy_article_link },
        copy_comments: -> { copy_comments_link },
        toggle_read:   -> { toggle_context_read },
        share:         -> { share_context },
        read?:         -> { visited?(context_story) }
      }
    end

    def open_context_link
      story = context_story
      mark_visited(story)
      open_link(link_for(story), title: story && story[:title])
    end

    def open_context_discussion
      story = context_story
      open_link(discussion_url(story), title: story && story[:title])
    end

    # The article itself. A text post has none, so its discussion stands in.
    def copy_article_link
      copy_to_pasteboard(link_for(context_story))
    end

    # Always the Hacker News thread, whatever the story links to.
    def copy_comments_link
      copy_to_pasteboard(discussion_url(context_story))
    end

    # Returns the story it changed, or nil when there was nothing to act on.
    def toggle_context_read
      story = context_story
      if story.nil?
        status('Select a story first')
        return nil
      end

      if visited?(story)
        @list.mark_unread(story)
        status("Marked “#{story[:title]}” unread")
      else
        @list.mark_read(story)
        status("Marked “#{story[:title]}” read")
      end
      @story_view.refresh_row(@list.index_of(story))
      story
    end

    def share_context
      story = context_story
      return nil if story.nil?

      @story_view.select(@list.index_of(story))
      share_selected
    end

    # ---- sharing -------------------------------------------------------------

    # What the share sheet is handed: the story's link, or its discussion page
    # when there is no article to point at.
    def share_items
      link = link_for(selected_story)
      return [] if link.nil?

      url = Cocoa::NSURL.URLWithString(link)
      url.nil? ? [] : [url]
    end

    # Anchored to the selected row, which is what the sheet points at.
    # Returns the picker it showed, or nil when there was nothing to share.
    def share_selected
      items = share_items
      if items.empty?
        status('Select a story first')
        return nil
      end

      table = @story_view.view
      row   = @story_view.selected_row
      rect  = row.negative? ? table.visibleRect : table.rectOfRow(row)

      picker = Cocoa::NSSharingServicePicker.alloc.initWithItems(items)
      picker.showRelativeToRect_ofView_preferredEdge(rect, table, Cocoa::NSRectEdgeMaxY)
      status('Sharing…')
      picker
    end

    # Returns the link it copied, or nil when there was nothing to copy.
    def copy_link
      copy_to_pasteboard(link_for(selected_story))
    end

    def copy_to_pasteboard(link)
      if link.nil?
        status('Select a story first')
        return nil
      end

      pasteboard = Cocoa::NSPasteboard.generalPasteboard
      pasteboard.clearContents
      pasteboard.writeObjects([link])
      status("Copied #{link}")
      link
    end

    # Replaceable so tests can check routing without launching a browser.
    def browser_opener
      @browser_opener ||= ->(url) { Cocoa::NSWorkspace.sharedWorkspace.openURL(url) }
    end

    attr_writer :browser_opener

    # ---- preferences and about -----------------------------------------------

    def preferences
      @preferences ||= Preferences.new(settings: @settings, actions: {
                                         expansion_changed: -> { apply_expansion },
                                         text_size_changed: -> { apply_text_size },
                                         section_changed:   -> { show_section(@settings.section.key) },
                                         refresh_changed:   -> { apply_refresh_interval },
                                         favicons_changed:  -> { apply_favicons },
                                         history_changed:   ->(on) { set_remember_read(on) },
                                         clear_history:     -> { mark_all_unread },
                                         read_count:        -> { visited_count }
                                       })
    end

    def show_preferences
      preferences.show
    end

    def about_options
      options = {
        Cocoa::NSAboutPanelOptionApplicationName    => APP_NAME,
        Cocoa::NSAboutPanelOptionApplicationVersion => APP_VERSION,
        Cocoa::NSAboutPanelOptionVersion            => RUBY_DESCRIPTION.split.first(2).join(' '),
        Cocoa::NSAboutPanelOptionCredits            => credits
      }
      icon = self.class.app_icon
      options[Cocoa::NSAboutPanelOptionApplicationIcon] = icon if icon
      options
    end

    def show_about_panel
      @nsapp.orderFrontStandardAboutPanelWithOptions(about_options)
      @nsapp.activateIgnoringOtherApps(true)
    end

    private

    # ---- wiring --------------------------------------------------------------

    def build_views
      @favicons = Favicons.new(on_ready: ->(domain) { @story_view&.refresh_domain(domain) })

      @story_view = StoryListView.new(
        list: @list, typography: @typography,
        favicons: @settings.show_favicons? ? @favicons : nil,
        context: context_commands,
        width: MainWindow::SIDEBAR_MIN, height: MainWindow::HEIGHT,
        on_select:   ->(row) { show_story(@list[row]) },
        on_activate: -> { open_selected_link },
        on_prefetch: -> { schedule_prefetch }
      )

      @thread_view = ThreadView.new(
        typography: @typography, width: 640, height: MainWindow::HEIGHT
      )
    end

    def build_window
      @spinner = Cocoa::NSProgressIndicator.alloc.initWithFrame([0, 0, 18, 18])
      @spinner.setStyle(Cocoa::NSProgressIndicatorStyleSpinning)
      @spinner.setControlSize(2)
      @spinner.setDisplayedWhenStopped(false)

      @section_control = build_section_control

      toolbar = Toolbar.new(identifier: TOOLBAR_ID, items: [
                              Toolbar::Button.new(identifier: RELOAD_ITEM, label: 'Reload',
                                                  symbol: 'arrow.clockwise',
                                                  action: -> { load_front_page }),
                              Toolbar::Custom.new(identifier: SECTION_ITEM,
                                                  view: @section_control),
                              Toolbar::SPACE,
                              Toolbar::Custom.new(identifier: SPINNER_ITEM, view: @spinner),
                              Toolbar::Search.new(identifier: SEARCH_ITEM, label: 'Search',
                                                  placeholder: SEARCH_PLACEHOLDER,
                                                  autosave: SEARCH_AUTOSAVE,
                                                  on_search: ->(text) { search_typed(text) }),
                              Toolbar::Button.new(identifier: OPEN_ITEM, label: 'Open Link',
                                                  symbol: 'safari',
                                                  action: -> { open_selected_link }),
                              Toolbar::Button.new(identifier: HN_ITEM, label: 'Discussion',
                                                  symbol: 'bubble.left.and.bubble.right',
                                                  action: -> { open_selected_discussion }),
                              Toolbar::Share.new(identifier: SHARE_ITEM, label: 'Share',
                                                 items: -> { share_items })
                            ])
      @toolbar = toolbar

      @search_bar = SearchBar.new(width: MainWindow::WIDTH) do |sorting, period|
        apply_search_options(sorting: sorting, period: period)
      end

      @main_window = MainWindow.new(
        title: APP_NAME,
        sidebar: @story_view.pane,
        content: @thread_view.pane,
        toolbar: toolbar,
        accessory: @search_bar
      )
    end

    # Hacker News's own sections, in its own order.
    def build_section_control
      control = Cocoa::NSSegmentedControl.alloc.init
      control.setSegmentCount(Section::ALL.size)
      control.setSegmentStyle(Cocoa::NSSegmentStyleSeparated)
      control.setTrackingMode(Cocoa::NSSegmentSwitchTrackingSelectOne)

      Section::ALL.each_with_index do |item, index|
        control.setLabel_forSegment(item.label, index)
      end
      control.setSelectedSegment(Section.index_of(@settings.section.key))
      control.sizeToFit

      Cocoa.on_action(control) do |sender|
        show_section(Section.at(sender.selectedSegment).key)
      end
      control
    end

    # The table is midway through updating its visible rows while it asks for
    # views, and changing its row count during that throws
    # NSInternalInconsistencyException. Waiting for the next turn of the run
    # loop keeps the load outside that update.
    def schedule_prefetch
      return if @list.loading? || !@list.more? || @prefetch_scheduled

      @prefetch_scheduled = true
      Cocoa::NSOperationQueue.mainQueue.addOperationWithBlock do
        @prefetch_scheduled = false
        load_next_page
      end
    end

    # Translate a change in the list into what the window shows.
    def list_changed(event, payload)
      case event
      when :reset
        # Whatever the last message said, the list is about to be re-asked.
        @story_view.hide_empty
        @story_view.reload
      when :loading
        @spinner.startAnimation(nil)
        status(loading_status)
      when :error
        @spinner.stopAnimation(nil)
        @story_view.show_empty("Could not load stories — #{payload}") if @list.empty?
        status("Could not load stories: #{payload}")
      when :loaded
        @spinner.stopAnimation(nil)
        @story_view.note_rows_changed
        show_empty_state
        status(story_status)
      end
    end

    # A search that found nothing leaves a blank table, which says nothing.
    def show_empty_state
      return @story_view.hide_empty unless @list.empty?

      if @list.searching?
        @story_view.show_empty("No stories match “#{@list.query.text}”",
                               symbol: StoryListView::NO_RESULTS_SYMBOL)
      else
        @story_view.show_empty('Nothing to read here yet',
                               symbol: StoryListView::NO_STORIES_SYMBOL)
      end
    end

    def loading_status
      return 'Loading more stories…' unless @list.empty?
      return "Searching for “#{@list.query.text}”…" if @list.searching?

      'Loading front page…'
    end

    def story_status
      return empty_status if @list.empty?

      count = if @list.searching?
                found = "#{pluralize(@list.size, 'result')} for “#{@list.query.text}”"
                @list.query.period.all_time? ? found : "#{found} · #{period_phrase}"
              else
                pluralize(@list.size, 'story', 'stories')
              end
      @list.more? ? "#{count} · scroll for more" : "#{count} · that's everything"
    end

    def empty_status
      return 'No stories' unless @list.searching?

      found = "Nothing found for “#{@list.query.text}”"
      @list.query.period.all_time? ? found : "#{found} in the #{period_phrase}"
    end

    # "Past Week" reads as a button; mid-sentence it wants to be lower case.
    def period_phrase
      @list.query.period.label.downcase
    end

    def valid_url?(string)
      !Cocoa::NSURL.URLWithString(string).nil?
    end

    def credits
      text = "A Hacker News reader written in Ruby, talking to Cocoa through libffi.\n\n" \
             "CRuby #{RUBY_VERSION} · #{RUBY_PLATFORM}\n" \
             'Stories and comments from the Algolia Hacker News API.'

      paragraph = Cocoa::NSMutableParagraphStyle.alloc.init
      paragraph.setAlignment(Cocoa::NSTextAlignmentCenter)

      Cocoa::NSAttributedString.alloc.initWithString_attributes(
        text,
        Cocoa::NSFontAttributeName            => Cocoa::NSFont.systemFontOfSize(11),
        Cocoa::NSForegroundColorAttributeName => Cocoa::NSColor.secondaryLabelColor,
        Cocoa::NSParagraphStyleAttributeName  => paragraph
      )
    end

    def pluralize(count, singular, plural = "#{singular}s")
      "#{count} #{count == 1 ? singular : plural}"
    end

    def status(text)
      @status = text
      @main_window&.subtitle = text
    end
  end
end
