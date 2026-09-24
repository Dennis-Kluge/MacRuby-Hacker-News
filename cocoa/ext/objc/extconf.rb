require 'mkmf'

# The interpreter's architecture is not necessarily the host's: RVM rubies on
# Apple Silicon are frequently x86_64 running under Rosetta, and rbconfig
# carries no -arch flag, so clang would otherwise build a native arm64 object
# that the interpreter cannot load.
arch = RbConfig::CONFIG['host_cpu']
$CFLAGS  << " -arch #{arch} -Wall -std=c11"
$LDFLAGS << " -arch #{arch}"

$LDFLAGS << ' -lffi -lobjc -framework Foundation'

have_header('ffi/ffi.h')    or abort 'libffi headers not found'
have_header('objc/runtime.h') or abort 'Objective-C runtime headers not found'

create_makefile('cocoa/objc_ext')
