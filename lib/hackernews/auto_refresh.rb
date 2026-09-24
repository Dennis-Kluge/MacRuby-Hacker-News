# frozen_string_literal: true

module HackerNews
  # Refetches the story list on a timer.
  #
  # The timer only asks; whether a refresh actually happens is the caller's
  # decision, because reloading under someone who has scrolled away would
  # throw their place away.
  class AutoRefresh
    def initialize(settings:, on_tick:)
      @settings = settings
      @on_tick  = on_tick
    end

    def interval
      @settings.refresh_interval
    end

    def running?
      !@timer.nil?
    end

    # Called at startup and whenever the preference changes.
    def restart
      stop
      seconds = interval
      return false if seconds.zero?

      @timer = Cocoa::NSTimer.scheduledTimerWithTimeInterval_repeats_block(
        seconds.to_f, true
      ) { |_timer| @on_tick.call }
      true
    end

    def stop
      @timer&.invalidate
      @timer = nil
    end
  end
end
