# frozen_string_literal: true
#
# A Hacker News reader in Ruby, on Cocoa.
#
# Requiring this defines the whole application; bin/hackernews is what runs
# it. Stories on the left, the full comment thread on the right. Networking
# is asynchronous through NSURLSession, with every completion handler
# delivered on the main thread; the comment tree is an NSOutlineView whose
# data source is a set of Ruby blocks.

require 'cocoa'

Cocoa.framework 'AppKit'
Cocoa.framework 'WebKit'

require_relative 'hackernews/html'
require_relative 'hackernews/app_icon'
require_relative 'hackernews/favicons'
require_relative 'hackernews/typography'
require_relative 'hackernews/placeholder'
require_relative 'hackernews/list_view'
require_relative 'hackernews/story_list_view'
require_relative 'hackernews/thread_view'
require_relative 'hackernews/toolbar'
require_relative 'hackernews/search_bar'
require_relative 'hackernews/menu_bar'
require_relative 'hackernews/main_window'
require_relative 'hackernews/choices'
require_relative 'hackernews/section'
require_relative 'hackernews/search_options'
require_relative 'hackernews/query'
require_relative 'hackernews/api'
require_relative 'hackernews/reading_history'
require_relative 'hackernews/comment_thread'
require_relative 'hackernews/story_list'
require_relative 'hackernews/auto_refresh'
require_relative 'hackernews/debounce'
require_relative 'hackernews/settings'
require_relative 'hackernews/reader'
require_relative 'hackernews/preferences'
require_relative 'hackernews/app'

# Claim a name before the menu bar is first drawn, otherwise AppKit falls back
# to the process name and the menu reads "ruby". Done on load rather than in
# bin/hackernews because anything that builds an App -- the tests included --
# needs it to have happened already.
HackerNews::App.claim_app_identity
