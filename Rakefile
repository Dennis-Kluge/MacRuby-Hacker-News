# frozen_string_literal: true

require 'rake/testtask'

# The reader is the repository; the bridge it is built on is a subproject of
# its own under cocoa/, with its own library, extension, tests and examples.
BRIDGE     = 'cocoa'
EXT_DIR    = File.join(BRIDGE, 'ext', 'objc')
EXT_BUNDLE = File.join(EXT_DIR, 'objc_ext.bundle')
LIB_BUNDLE = File.join(BRIDGE, 'lib', 'cocoa', 'objc_ext.bundle')

desc 'Build the native extension the bridge is made of'
task :compile do
  Dir.chdir(EXT_DIR) do
    # Always regenerate: mkmf bakes the source list into the Makefile, so a
    # newly added .c file is silently left out of a stale one.
    sh 'ruby extconf.rb'
    sh 'make'
  end
  cp EXT_BUNDLE, LIB_BUNDLE if File.exist?(EXT_BUNDLE)
end

desc 'Run the reader from the checkout'
task run: :compile do
  sh 'bin/hackernews'
end

desc 'Build Hacker News.app into build/'
task app: :compile do
  sh 'ruby tools/build_app.rb'
end

desc "Open the bridge's demo window"
task demo: :compile do
  sh "ruby #{File.join(BRIDGE, 'examples', 'hello_window.rb')}"
end

Rake::TestTask.new(app_test: :compile) do |t|
  t.description = "Run the reader's tests"
  t.libs << 'lib' << File.join(BRIDGE, 'lib') << 'test'
  t.test_files = FileList['test/test_*.rb']
  t.warning = false
end

Rake::TestTask.new(bridge_test: :compile) do |t|
  t.description = "Run the bridge's tests"
  t.libs << File.join(BRIDGE, 'lib') << File.join(BRIDGE, 'test')
  t.test_files = FileList[File.join(BRIDGE, 'test', 'test_*.rb')]
  t.warning = false
end

# Two processes rather than one, because each suite drives the single shared
# NSApplication -- and the class browser installs a main menu of its own.
desc 'Run every test'
task test: %i[app_test bridge_test]

desc 'Remove build artefacts'
task :clean do
  rm_rf 'build'
  rm_f Dir[File.join(EXT_DIR, '*.o')]
  rm_f Dir[File.join(EXT_DIR, '*.bundle')]
  rm_f File.join(EXT_DIR, 'Makefile')
  rm_f LIB_BUNDLE
  rm_rf File.join(EXT_DIR, 'cocoa')
end

task default: :test
