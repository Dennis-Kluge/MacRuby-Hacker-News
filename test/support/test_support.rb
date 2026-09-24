# frozen_string_literal: true

module HackerNews
  # Driving the app without an event loop, for tests and screenshots.
  #
  # Kept apart from App so the application itself carries no test scaffolding.
  module TestSupport
    # Run the event loop until the block turns true, or the deadline passes.
    def pump(seconds = 30)
      deadline = Time.now + seconds
      loop do
        Cocoa::NSRunLoop.currentRunLoop.runUntilDate(
          Cocoa::NSDate.dateWithTimeIntervalSinceNow(0.05)
        )
        break true if block_given? && yield
        break false if Time.now > deadline
      end
    end

    def load_and_wait(seconds = 30)
      load_front_page
      pump(seconds) { !list.empty? }
    end

    def open_story_and_wait(index = 0, seconds = 40)
      return false if list.empty?

      select_story(index)
      pump(seconds) { !thread_view.thread.empty? || !loading_comments? }
    end

    def render_to(path, chrome: true)
      main_window.render_to(path, chrome: chrome)
    end
  end

  class App
    include TestSupport
  end
end
