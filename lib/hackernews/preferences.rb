# frozen_string_literal: true

module HackerNews
  # The Settings window, reached from the application menu with ⌘,
  #
  # Laid out as labelled sections with a right-aligned label column, which is
  # the shape a Mac user expects preferences to take.
  class Preferences
    WIDTH    = 520
    HEIGHT   = 420   # generous; the window shrinks to fit once laid out
    BOTTOM_MARGIN = 18
    LEFT     = 24
    LABEL_W  = 168
    FIELD_X  = LEFT + LABEL_W + 12
    FIELD_W  = WIDTH - FIELD_X - LEFT

    ROW_H       = 26
    ROW_GAP     = 10
    SECTION_GAP = 18
    HEADER_H    = 18

    # Given the settings and a set of callables, so it never reaches back into
    # the application. What each change should cause is the caller's business.
    def initialize(settings:, actions:)
      @settings = settings
      @actions  = actions
      build_window
    end

    def act(name, *args)
      @actions[name]&.call(*args)
    end

    def show
      refresh
      @window.center unless @window.isVisible
      @window.makeKeyAndOrderFront(nil)
      Cocoa::NSApplication.sharedApplication.activateIgnoringOtherApps(true)
    end

    attr_reader :window, :expansion_popup, :text_size_popup, :section_popup,
                :refresh_popup, :page_size_popup, :link_target_popup,
                :favicons_checkbox, :remember_checkbox, :clear_button

    # Reflect current settings in the controls.
    def refresh
      @expansion_popup.selectItemAtIndex(Settings.index_of(@settings.expansion))
      @text_size_popup.selectItemAtIndex(Settings.index_of_text_size(@settings.text_size))
      @section_popup.selectItemAtIndex(Section.index_of(@settings.section.key))
      @refresh_popup.selectItemAtIndex(Settings.index_of_refresh(@settings.refresh_interval))
      @page_size_popup.selectItemAtIndex(Settings::PAGE_SIZES.index(@settings.page_size) || 1)
      @link_target_popup.selectItemAtIndex(
        Settings.index_of_link_target(@settings.open_links_in)
      )
      @favicons_checkbox.setState(@settings.show_favicons? ? 1 : 0)
      @remember_checkbox.setState(@settings.remember_read? ? 1 : 0)

      count = act(:read_count).to_i
      @clear_button.setTitle(
        count.zero? ? 'No Stories Marked Read' : "Forget #{count} Read #{count == 1 ? 'Story' : 'Stories'}"
      )
      @clear_button.setEnabled(count.positive?)
    end

    private

    def build_window
      style = Cocoa::NSWindowStyleMaskTitled | Cocoa::NSWindowStyleMaskClosable
      @window = Cocoa::NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
        [0, 0, WIDTH, HEIGHT], style, Cocoa::NSBackingStoreBuffered, false
      )
      @window.setTitle('Settings')
      # The window is reopened from the menu, so closing must not destroy it.
      @window.setReleasedWhenClosed(false)

      @content = @window.contentView
      @cursor  = HEIGHT - 18

      section('Reading')
      @expansion_popup = popup_row('When opening a story:', Settings.mode_labels) do |popup|
        @settings.expansion = Settings.mode_at(popup.indexOfSelectedItem)
        act(:expansion_changed)
      end
      @text_size_popup = popup_row('Text size:', Settings.text_size_labels) do |popup|
        @settings.text_size = Settings.text_size_at(popup.indexOfSelectedItem)
        act(:text_size_changed)
      end

      section('Stories')
      @section_popup = popup_row('Section at launch:', Section.labels) do |popup|
        @settings.section = Section.at(popup.indexOfSelectedItem).key
        act(:section_changed)
      end
      @refresh_popup = popup_row('Refresh automatically:', Settings.refresh_labels) do |popup|
        @settings.refresh_interval = Settings.refresh_at(popup.indexOfSelectedItem)
        act(:refresh_changed)
      end
      @favicons_checkbox = checkbox_row('Site icons:', 'Show each site\'s icon') do |box|
        @settings.show_favicons = box.state == 1
        act(:favicons_changed)
      end
      @page_size_popup = popup_row('Load at a time:', Settings.page_size_labels) do |popup|
        @settings.page_size = Settings::PAGE_SIZES[popup.indexOfSelectedItem]
        act(:feed_changed)
      end

      section('Links')
      @link_target_popup = popup_row('Open stories in:', Settings.link_target_labels) do |popup|
        @settings.open_links_in = Settings.link_target_at(popup.indexOfSelectedItem)
      end

      section('History')
      @remember_checkbox = checkbox_row('Reading history:',
                                        'Remember which stories I have read') do |box|
        act(:history_changed, box.state == 1)
        refresh
      end
      @clear_button = button_row('Forget Read Stories') do |_sender|
        act(:clear_history)
        refresh
      end

      footnote('Turning history off keeps marks for this session only; ' \
               'nothing is saved to disk.')

      fit_window
    end

    # Built top-down against a generous height, then trimmed to whatever the
    # rows actually needed. Beats keeping a hand-tuned constant in step with
    # the layout.
    def fit_window
      extra = @cursor - BOTTOM_MARGIN
      return if extra <= 0

      @content.subviews.to_a.each do |view|
        frame = view.frame
        view.setFrameOrigin([frame.x, frame.y - extra])
      end
      @window.setContentSize([WIDTH, HEIGHT - extra])
    end

    # ---- layout helpers -----------------------------------------------------

    def section(title)
      @cursor -= HEADER_H
      field = label(title, [LEFT, @cursor, WIDTH - (LEFT * 2), HEADER_H])
      field.setFont(Cocoa::NSFont.boldSystemFontOfSize(11))
      field.setTextColor(Cocoa::NSColor.secondaryLabelColor)
      @content.addSubview(field)
      @cursor -= 8
    end

    def popup_row(title, titles, &handler)
      @cursor -= ROW_H
      @content.addSubview(label(title, [LEFT, @cursor + 3, LABEL_W, 20],
                                 align: Cocoa::NSTextAlignmentRight))

      popup = Cocoa::NSPopUpButton.alloc.initWithFrame_pullsDown(
        [FIELD_X, @cursor, FIELD_W, ROW_H], false
      )
      popup.addItemsWithTitles(titles)
      Cocoa.on_action(popup, &handler)
      @content.addSubview(popup)
      @cursor -= ROW_GAP
      popup
    end

    def checkbox_row(title, text, &handler)
      @cursor -= 22
      @content.addSubview(label(title, [LEFT, @cursor, LABEL_W, 20],
                                 align: Cocoa::NSTextAlignmentRight))

      box = Cocoa::NSButton.alloc.initWithFrame([FIELD_X, @cursor, FIELD_W, 22])
      box.setButtonType(Cocoa::NSButtonTypeSwitch)
      box.setTitle(text)
      Cocoa.on_action(box, &handler)
      @content.addSubview(box)
      @cursor -= 8
      box
    end

    def button_row(title, &handler)
      @cursor -= ROW_H
      button = Cocoa::NSButton.alloc.initWithFrame([FIELD_X - 4, @cursor, 240, ROW_H])
      button.setBezelStyle(Cocoa::NSBezelStyleRounded)
      button.setTitle(title)
      Cocoa.on_action(button, &handler)
      @content.addSubview(button)
      @cursor -= ROW_GAP
      button
    end

    def footnote(text)
      @cursor -= 20
      field = label(text, [LEFT, @cursor, WIDTH - (LEFT * 2), 20])
      field.setFont(Cocoa::NSFont.systemFontOfSize(11))
      field.setTextColor(Cocoa::NSColor.tertiaryLabelColor)
      field.cell.setWraps(true)
      @content.addSubview(field)
    end

    def label(text, frame, align: Cocoa::NSTextAlignmentLeft)
      field = Cocoa::NSTextField.alloc.initWithFrame(frame)
      field.setStringValue(text)
      field.setEditable(false)
      field.setSelectable(false)
      field.setBezeled(false)
      field.setDrawsBackground(false)
      field.setAlignment(align)
      field
    end
  end
end
