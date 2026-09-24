# frozen_string_literal: true

# Runs every Minitest test inside an autorelease pool.
#
#   require 'minitest/autorun'
#   require 'cocoa/pooled_tests'
#
# Shipped with the bridge because it is not one suite's problem: anything
# driving Cocoa from Ruby, rather than from the run loop, needs this.
#
# A running app never needs this: each user action is dispatched by the run
# loop, which pushes a pool around the event and drains it afterwards. Tests
# call into Cocoa directly instead, so without a pool of their own every
# autoreleased string, number and attributed string accumulates for the whole
# run.
module PooledTests
  def run(*args)
    result = nil
    Cocoa.autorelease_pool { result = super }
    result
  end
end

Minitest::Test.prepend(PooledTests)
