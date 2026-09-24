# frozen_string_literal: true

module HackerNews
  # Runs a block once the caller has stopped asking for it.
  #
  # Every keystroke in the search field is a change worth acting on, but not
  # one worth a network request; waiting for a pause turns a typed word into a
  # single question. Re-arming drops the pending request rather than queueing
  # another, so only the last one ever runs.
  class Debounce
    DEFAULT_DELAY = 0.3

    def initialize(delay: DEFAULT_DELAY, &block)
      @delay = delay
      @block = block
    end

    attr_reader :delay

    def pending?
      !@timer.nil?
    end

    # Ask for the block to run, once things go quiet. A delay of zero is for
    # tests, which have no run loop to deliver a timer.
    def schedule(*arguments)
      cancel
      return run(*arguments) if @delay.zero?

      @timer = Cocoa::NSTimer.scheduledTimerWithTimeInterval_repeats_block(
        @delay, false
      ) { |_timer| run(*arguments) }
      nil
    end

    # Run now, dropping anything pending. This is what Return in a search
    # field means: don't wait, I'm done typing.
    def flush(*arguments)
      run(*arguments)
    end

    def cancel
      @timer&.invalidate
      @timer = nil
    end

    private

    def run(*arguments)
      cancel
      @block.call(*arguments)
    end
  end
end
