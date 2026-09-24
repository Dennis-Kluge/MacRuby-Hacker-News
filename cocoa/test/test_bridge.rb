# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'cocoa'
require 'cocoa/pooled_tests'

Cocoa.framework 'AppKit'

# AppKit routes target/action dispatch through NSApp, so it must exist before
# any test that relies on it. Creating it here keeps the suite order-independent.
Cocoa::NSApplication.sharedApplication

class TestClassLookup < Minitest::Test
  def test_known_class_resolves
    assert_equal 'NSString', Cocoa::NSString.name
  end

  def test_unknown_class_raises
    assert_raises(NameError) { Cocoa::NSDefinitelyNotAClass }
  end

  def test_class_list_is_populated
    assert_operator ObjC.class_names.size, :>, 1000
  end
end

class TestMessaging < Minitest::Test
  def setup
    @s = Cocoa::NSString.stringWithUTF8String('hello world')
  end

  def test_string_round_trip
    assert_equal 'hello world', @s.to_s
  end

  def test_integer_return
    assert_equal 11, @s.length
  end

  def test_object_return
    assert_equal 'HELLO WORLD', @s.uppercaseString.to_s
  end

  def test_bool_return_maps_to_true_and_false
    assert_equal true,  @s.hasPrefix('hello')
    assert_equal false, @s.hasPrefix('nope')
  end

  def test_ruby_string_is_converted_to_nsstring_argument
    assert_equal true, @s.isEqualToString('hello world')
  end

  def test_unknown_selector_raises
    assert_raises(NoMethodError) { @s.thisSelectorDoesNotExist }
  end

  def test_nil_argument
    arr = Cocoa::NSArray.arrayWithArray(%w[a b])
    assert_equal 2, arr.count
  end
end

class TestSelectorMangling < Minitest::Test
  def test_plain_name
    assert_equal ['length'], Cocoa.selector_candidates(:length, 0)
  end

  def test_single_argument_gets_a_colon
    assert_includes Cocoa.selector_candidates(:setTitle, 1), 'setTitle:'
  end

  def test_underscores_become_colons
    assert_includes Cocoa.selector_candidates(:initWithContentRect_styleMask_backing_defer, 4),
                    'initWithContentRect:styleMask:backing:defer:'
  end

  def test_snake_case_is_offered_as_camel_case
    assert_includes Cocoa.selector_candidates(:set_title, 1), 'setTitle:'
  end

  def test_assignment_form
    assert_includes Cocoa.selector_candidates(:title=, 1), 'setTitle:'
  end
end

class TestStructMarshalling < Minitest::Test
  # NSRect is 32 bytes: passed in memory and, on x86_64, returned via
  # objc_msgSend_stret. This is the part most likely to break silently.
  def test_rect_round_trip
    v = Cocoa::NSValue.valueWithRect([10, 20, 480, 320])
    assert_equal [10.0, 20.0, 480.0, 320.0], v.rectValue
  end

  def test_nested_and_flat_input_are_equivalent
    a = Cocoa::NSValue.valueWithRect([1, 2, 3, 4]).rectValue
    b = Cocoa::NSValue.valueWithRect([[1, 2], [3, 4]]).rectValue
    assert_equal a, b
  end

  # NSRange is 16 bytes: returned in registers, not via stret.
  def test_range_return
    s = Cocoa::NSString.stringWithUTF8String('hello world')
    assert_equal [6, 5], s.rangeOfString('world')
  end

  def test_point_round_trip
    v = Cocoa::NSValue.valueWithPoint([3.5, 4.5])
    assert_equal [3.5, 4.5], v.pointValue
  end
end

class TestBridgeSupport < Minitest::Test
  def test_enums_resolve_from_apple_metadata
    assert_equal 1, Cocoa::NSWindowStyleMaskTitled
    assert_equal 2, Cocoa::NSWindowStyleMaskClosable
    assert_equal 2, Cocoa::NSBackingStoreBuffered
  end

  def test_string_constants_resolve_through_dlsym
    name = Cocoa::NSApplicationDidFinishLaunchingNotification
    assert_equal 'NSApplicationDidFinishLaunchingNotification', name.to_s
  end

  def test_metadata_is_substantial
    assert_operator Cocoa.frameworks['AppKit'].enums.size, :>, 1000
    assert_operator Cocoa.frameworks['Foundation'].constants.size, :>, 100
  end
end

class TestRubyImplementedMethods < Minitest::Test
  def setup
    @cls = ObjC.define_class('TestRubyImpl', 'NSObject')
  end

  def test_object_return
    ObjC.add_method(@cls, 'shout:', '@@:@') { |_s, t| t.to_s.upcase }
    obj = @cls.alloc.init
    assert_equal 'LOUD', obj.objc_send('shout:', 'loud').to_s
  end

  def test_integer_return
    ObjC.add_method(@cls, 'triple:', 'q@:q') { |_s, n| n * 3 }
    obj = @cls.alloc.init
    assert_equal 33, obj.objc_send('triple:', 11)
  end

  def test_bool_return
    ObjC.add_method(@cls, 'alwaysTrue', 'B@:') { |_s| true }
    obj = @cls.alloc.init
    assert_equal true, obj.objc_send('alwaysTrue')
  end

  # The important case: Objective-C, not Ruby, initiating the call.
  def test_called_back_from_foundation
    ObjC.add_method(@cls, 'echo:', '@@:@') { |_s, t| "echo:#{t}" }
    obj = @cls.alloc.init
    result = obj.objc_send('performSelector:withObject:', 'echo:', 'hi')
    assert_equal 'echo:hi', result.to_s
  end

  # A Ruby exception must not unwind through Objective-C frames, but it must
  # still reach the caller once control is back in Ruby.
  def test_exception_in_body_reaches_the_caller
    ObjC.add_method(@cls, 'boom', 'v@:') { |_s| raise 'intentional' }
    obj = @cls.alloc.init
    err = assert_raises(RuntimeError) { obj.objc_send('boom') }
    assert_equal 'intentional', err.message
  end
end

class TestMemory < Minitest::Test
  # Exercise the retain/release paths hard enough that an imbalance shows up
  # as a crash or a leak rather than passing silently.
  def test_churn_under_gc_pressure
    5_000.times do |i|
      s = Cocoa::NSString.stringWithUTF8String("object #{i}")
      s.uppercaseString
      Cocoa::NSArray.arrayWithArray([s])
    end
    GC.start
    assert true
  end

  def test_alloc_init_does_not_double_retain
    2_000.times do
      Cocoa::NSObject.alloc.init
    end
    GC.start
    assert true
  end

  def test_autorelease_pool_runs_block
    result = Cocoa.autorelease_pool { 42 }
    assert_equal 42, result
  end
end

class TestGeometryObjects < Minitest::Test
  def test_window_can_be_constructed_without_a_run_loop
    style = Cocoa::NSWindowStyleMaskTitled | Cocoa::NSWindowStyleMaskClosable
    w = Cocoa::NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
      [0, 0, 400, 300], style, Cocoa::NSBackingStoreBuffered, false
    )
    w.setTitle('test window')
    assert_equal 'test window', w.title.to_s
    assert_equal 400.0, w.frame[2]
  end
end

class TestAppKitCallsRuby < Minitest::Test
  # The end-to-end case: AppKit's own target/action dispatch invoking a Ruby
  # block, with no Ruby frame anywhere in between.
  def test_button_action_runs_ruby_block
    fired = []

    handler_class = ObjC.define_class('TestActionHandler', 'NSObject')
    ObjC.add_method(handler_class, 'clicked:', 'v@:@') do |_self, sender|
      fired << sender.objc_class_name
    end
    handler = handler_class.alloc.init

    button = Cocoa::NSButton.alloc.initWithFrame([0, 0, 100, 32])
    button.setTitle('go')
    button.setTarget(handler)
    button.setAction('clicked:')

    button.performClick(nil)   # dispatched by AppKit, not by us

    assert_equal 1, fired.size
    assert_match(/NSButton/, fired.first)
  end

  def test_view_hierarchy_renders_to_a_bitmap
    view = Cocoa::NSView.alloc.initWithFrame([0, 0, 200, 100])
    field = Cocoa::NSTextField.alloc.initWithFrame([10, 10, 180, 40])
    field.setStringValue('rendered')
    view.addSubview(field)

    rep = view.bitmapImageRepForCachingDisplayInRect(view.bounds)
    view.cacheDisplayInRect_toBitmapImageRep(view.bounds, rep)
    png = rep.representationUsingType_properties(Cocoa::NSBitmapImageFileTypePNG, {})

    assert_operator png.length, :>, 100
    assert_equal 1, view.subviews.count
  end
end

class TestBlocks < Minitest::Test
  def setup
    @arr = Cocoa::NSArray.arrayWithArray(%w[alpha beta gamma delta])
  end

  def test_explicit_block_reports_its_signature
    blk = ObjC.make_block('v', ['@']) { |_o| }
    assert_kind_of ObjC::Block, blk
    assert_equal 1, blk.arity
    assert_match(/\Av\d+@\?0@\d+\z/, blk.signature)
  end

  def test_block_can_be_called_directly_from_ruby
    adder = ObjC.make_block('q', %w[q q]) { |a, b| a + b }
    assert_equal 42, adder.call(19, 23)
  end

  # Foundation invoking a Ruby block, with the signature resolved from the
  # metadata Apple ships rather than supplied by hand.
  def test_enumeration_block_is_resolved_automatically
    seen = []
    @arr.enumerateObjectsUsingBlock { |obj, idx, _stop| seen << [idx, obj.to_s] }
    assert_equal [[0, 'alpha'], [1, 'beta'], [2, 'gamma'], [3, 'delta']], seen
  end

  def test_out_parameter_stops_enumeration
    seen = []
    @arr.enumerateObjectsUsingBlock do |obj, _idx, stop|
      seen << obj.to_s
      stop.write_bool(true) if seen.size == 2
    end
    assert_equal %w[alpha beta], seen
  end

  def test_block_return_value_drives_a_sort
    sorted = @arr.sortedArrayUsingComparator { |a, b| a.to_s.length <=> b.to_s.length }
    assert_equal %w[beta alpha gamma delta], sorted.to_ruby
  end

  # The same selector carries a different block signature on NSSet, which only
  # resolves correctly if metadata is looked up per class.
  def test_same_selector_different_signature_per_class
    assert_equal 3, Cocoa.block_signature_for(@arr, 'enumerateObjectsUsingBlock:', 0)[:args].size

    set = Cocoa::NSSet.setWithArray(%w[x yy])
    assert_equal 2, Cocoa.block_signature_for(set, 'enumerateObjectsUsingBlock:', 0)[:args].size

    seen = []
    set.enumerateObjectsUsingBlock { |obj, _stop| seen << obj.to_s }
    assert_equal %w[x yy], seen.sort
  end

  def test_metadata_found_through_the_superclass
    # The receiver is really a __NSArrayI; the metadata lives on NSArray.
    assert_includes @arr.objc_class_chain, 'NSArray'
    refute_equal 'NSArray', @arr.objc_class_name
  end

  def test_dictionary_enumeration
    dict = Cocoa::NSDictionary.dictionaryWithDictionary('a' => 1, 'b' => 2)
    pairs = []
    dict.enumerateKeysAndObjectsUsingBlock { |k, v, _stop| pairs << [k.to_s, v.to_ruby] }
    assert_equal [['a', 1.0], ['b', 2.0]], pairs.sort
  end

  def test_predicate_block
    assert_equal 2, @arr.indexOfObjectPassingTest { |obj, _i, _stop| obj.to_s.start_with?('g') }
  end

  # A block travelling the other way: handed to a Ruby-implemented method as an
  # argument, wrapped, and invoked from Ruby.
  def test_block_received_as_an_argument
    got = nil
    cls = ObjC.define_class('TestBlockTaker', 'NSObject')
    ObjC.add_method(cls, 'runIt:', 'v@:@?') { |_self, blk| blk.call(7) }

    receiver = cls.alloc.init
    callback = Cocoa.block('v', ['q']) { |n| got = n }
    receiver.objc_send('runIt:', callback)

    assert_equal 7, got
  end

  def test_exception_in_block_body_reaches_the_caller
    blk = ObjC.make_block('v', ['@']) { |_o| raise 'intentional block failure' }
    err = assert_raises(RuntimeError) { blk.call(nil) }
    assert_equal 'intentional block failure', err.message
  end

  def test_missing_metadata_gives_an_actionable_error
    s = Cocoa::NSString.stringWithUTF8String('x')
    err = assert_raises(Cocoa::Error) do
      Cocoa.convert_block_args(s, 'someSelectorWithNoMetadata:', [proc { }])
    end
    assert_match(/Cocoa\.block/, err.message)
  end
end

class TestPointerAccessors < Minitest::Test
  def test_bool_round_trip
    captured = nil
    arr = Cocoa::NSArray.arrayWithArray(['only'])
    arr.enumerateObjectsUsingBlock do |_obj, _idx, stop|
      captured = stop.read_bool
      stop.write_bool(true)
    end
    assert_equal false, captured
  end
end

class TestExceptions < Minitest::Test
  # Cocoa raising while we are inside ffi_call used to reach libc++abi and
  # terminate the process.
  def test_cocoa_exception_becomes_a_ruby_exception
    arr = Cocoa::NSArray.arrayWithArray(['a'])
    err = assert_raises(ObjC::Exception) { arr.objectAtIndex(5) }

    assert_equal 'NSRangeException', err.name
    assert_match(/beyond bounds/, err.reason)
    assert_equal 'NSException', err.objc_exception.objc_class_name
  end

  def test_it_is_an_ordinary_ruby_exception
    arr = Cocoa::NSArray.arrayWithArray(['a'])
    assert_raises(StandardError) { arr.objectAtIndex(5) }
    assert_operator ObjC::Exception, :<, ObjC::Error
  end

  def test_the_process_survives_and_keeps_working
    arr = Cocoa::NSArray.arrayWithArray(['a'])
    5.times { assert_raises(ObjC::Exception) { arr.objectAtIndex(9) } }

    # The bridge must still be usable afterwards.
    assert_equal 'HELLO', Cocoa::NSString.stringWithUTF8String('hello').uppercaseString.to_s
  end

  def test_exception_raised_by_a_class_method
    assert_raises(ObjC::Exception) do
      Cocoa::NSException.raise_format('RubyTestException', 'deliberate')
    end
  end

  # A Ruby exception thrown inside a block invoked by Foundation must surface
  # at the Ruby call site with its own class and message intact.
  def test_ruby_exception_from_a_block_reaches_the_call_site
    err = assert_raises(ArgumentError) do
      Cocoa::NSArray.arrayWithArray(%w[a b c]).enumerateObjectsUsingBlock do |_o, i, _s|
        raise ArgumentError, "boom at #{i}" if i == 1
      end
    end
    assert_equal 'boom at 1', err.message
  end

  def test_custom_exception_class_is_preserved
    custom = Class.new(StandardError)
    Object.const_set(:CocoaTestCustomError, custom) unless defined?(CocoaTestCustomError)

    assert_raises(CocoaTestCustomError) do
      Cocoa::NSArray.arrayWithArray(%w[a]).enumerateObjectsUsingBlock do |_o, _i, _s|
        raise CocoaTestCustomError, 'custom'
      end
    end
  end

  # Once a callback raises, its body must not run again for the remaining
  # elements of the enumeration.
  def test_a_raising_block_stops_being_called
    calls = 0
    assert_raises(RuntimeError) do
      Cocoa::NSArray.arrayWithArray(%w[a b c d e]).enumerateObjectsUsingBlock do |_o, _i, _s|
        calls += 1
        raise 'stop here'
      end
    end
    assert_equal 1, calls
  end

  def test_no_exception_leaks_between_calls
    arr = Cocoa::NSArray.arrayWithArray(%w[a b])
    assert_raises(RuntimeError) do
      arr.enumerateObjectsUsingBlock { |_o, _i, _s| raise 'first' }
    end

    # A later, unrelated call must not see the earlier exception.
    seen = []
    arr.enumerateObjectsUsingBlock { |o, _i, _s| seen << o.to_s }
    assert_equal %w[a b], seen
  end
end

class TestNameCollisions < Minitest::Test
  # Ruby's Object methods shadow same-named Objective-C selectors, since
  # method_missing never fires for a method that already exists.
  def test_display_dispatches_to_objective_c
    view = Cocoa::NSView.alloc.initWithFrame([0, 0, 10, 10])
    # Ruby's Object#display would print the receiver and return nil; AppKit's
    # -display draws it. Reaching AppKit means no output on stdout.
    out, = capture_io { view.display }
    assert_empty out
  end

  def test_class_and_hash_keep_their_ruby_meaning
    s = Cocoa::NSString.stringWithUTF8String('x')
    assert_equal ObjC::Object, s.class
    assert_kind_of Integer, s.hash
    assert_includes ObjC::Object::SHADOWED_SELECTORS, 'class'
  end

  def test_shadowed_selectors_remain_reachable
    s = Cocoa::NSString.stringWithUTF8String('x')
    assert_kind_of Integer, s.objc_send('hash')
    assert_equal 'NSTaggedPointerString', s.objc_send('class').name
  end
end

class TestNamedStructFields < Minitest::Test
  def setup
    @rect = Cocoa::NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
      [10, 20, 480, 320], Cocoa::NSWindowStyleMaskTitled,
      Cocoa::NSBackingStoreBuffered, false
    ).frame
  end

  def test_struct_returns_carry_their_field_names
    assert_instance_of Cocoa::CGRect, @rect
    assert_equal 10.0, @rect.x
    assert_equal 20.0, @rect.y
    assert_equal 480.0, @rect.width
  end

  def test_nested_fields_are_structs_too
    assert_instance_of Cocoa::CGPoint, @rect.origin
    assert_instance_of Cocoa::CGSize, @rect.size
    assert_equal 10.0, @rect.origin.x
    assert_equal 480.0, @rect.size.width
  end

  # The struct is still the flat array it always was.
  def test_it_remains_an_array
    assert_kind_of Array, @rect
    assert_equal 480.0, @rect[2]
    assert_equal [10.0, 20.0, 480.0, @rect[3]], @rect
    assert_equal 4, @rect.count
    assert_instance_of Array, @rect.to_a
  end

  # A field named `size` shadows Array#size, which is the right trade for a
  # value object; `count` remains the arity.
  def test_field_names_win_over_array_methods
    assert_instance_of Cocoa::CGSize, @rect.size
    assert_equal 4, @rect.count

    range = Cocoa::NSString.stringWithUTF8String('hello world').rangeOfString('world')
    assert_equal 6, range.location
    assert_equal 5, range.length
    assert_equal 2, range.count
  end

  def test_structs_still_work_as_arguments
    round_tripped = Cocoa::NSValue.valueWithRect(@rect).rectValue
    assert_equal @rect, round_tripped
    assert_equal @rect.width, round_tripped.width
  end

  def test_to_h_uses_the_leaf_names
    assert_equal %w[x y width height], @rect.to_h.keys
  end

  def test_inspect_names_the_fields
    assert_match(/CGRect x=10\.0 y=20\.0 width=480\.0/, @rect.inspect)
  end

  def test_a_point_round_trips
    point = Cocoa::NSValue.valueWithPoint([3.5, 4.5]).pointValue
    assert_instance_of Cocoa::CGPoint, point
    assert_equal 3.5, point.x
    assert_equal 4.5, point.y
  end

  def test_tag_is_taken_from_the_encoding_not_the_advertised_name
    # BridgeSupport calls it NSRange; the encoding says _NSRange.
    assert Cocoa::Structs.definitions.key?('_NSRange')
    refute Cocoa::Structs.definitions.key?('NSRange')
    assert_equal '_NSRange', Cocoa::Structs.class_for('_NSRange').struct_tag
  end

  def test_unknown_structs_degrade_to_plain_arrays
    assert_nil Cocoa::Structs.class_for('NotARealStructTag')
  end
end

class TestBlockLifetime < Minitest::Test
  # Counts are process-wide and other tests hold blocks, so these assert that
  # a block does not outlive its references, not that nothing else is alive.
  def baseline
    GC.start
    ObjC.reap_blocks[:live]
  end

  def test_a_block_is_freed_once_nothing_references_it
    start  = baseline
    before = ObjC.reap_blocks[:reaped]

    block = ObjC.make_block('q', %w[q]) { |n| n * 2 }
    assert_equal 8, block.call(4)

    block = nil
    GC.start
    after = ObjC.reap_blocks

    assert_operator after[:live], :<=, start
    assert_operator after[:reaped], :>, before
  end

  # The reason blocks are reference counted rather than simply freed: Cocoa
  # may hold one long after Ruby has forgotten it.
  def test_a_block_retained_by_cocoa_survives_its_ruby_wrapper
    start  = baseline
    keeper = Cocoa::NSMutableArray.array
    block  = ObjC.make_block('q', %w[q]) { |n| n * 3 }
    keeper.addObject(block)

    block = nil
    GC.start
    GC.start

    # Still alive, because the array holds it.
    assert_operator ObjC.reap_blocks[:live], :>, start

    recovered = keeper.objectAtIndex(0)
    assert_instance_of ObjC::Block, recovered
    assert_equal 42, recovered.call(14)

    keeper.removeAllObjects
    recovered = nil
    GC.start
    GC.start
    assert_operator ObjC.reap_blocks[:live], :<=, start
  end

  # A block coming back through a plain "@" return is still recognised.
  def test_blocks_are_detected_even_when_typed_as_a_plain_object
    keeper = Cocoa::NSMutableArray.array
    keeper.addObject(ObjC.make_block('v', []) {})
    assert_instance_of ObjC::Block, keeper.objectAtIndex(0)
  end

  def test_repeated_use_does_not_accumulate_blocks
    start = baseline
    array = Cocoa::NSArray.arrayWithArray(%w[a b c])

    500.times do
      collected = []
      array.enumerateObjectsUsingBlock { |o, _i, _s| collected << o.to_s }
      assert_equal 3, collected.size
    end

    GC.start
    GC.start
    # 500 blocks were created; none may still be alive.
    assert_operator ObjC.reap_blocks[:live], :<=, start
  end
end

class TestInitOwnership < Minitest::Test
  # An init that fails releases the object it was handed and returns nil. A
  # wrapper that went on owning that object would release freed memory the
  # next time the GC ran.
  def test_a_failing_init_returns_nil_without_a_double_release
    assert_nil Cocoa::NSImage.alloc.initWithData(Cocoa::NSData.data)

    2_000.times { Cocoa::NSImage.alloc.initWithData(Cocoa::NSData.data) }
    GC.start
    GC.start
    assert true, 'survived collecting failed allocations'
  end

  def test_a_successful_init_keeps_the_object_alive
    string = Cocoa::NSString.alloc.initWithString('hello')
    GC.start
    GC.start
    assert_equal 'hello', string.to_s
  end

  def test_alloc_init_churn_is_balanced
    2_000.times { Cocoa::NSMutableArray.alloc.init.addObject('x') }
    GC.start
    assert true
  end

  # init is in the family that hands ownership over; initialize is not.
  def test_only_the_init_family_consumes_the_receiver
    object = Cocoa::NSObject.alloc.init
    refute_nil object
    assert_equal 'NSObject', object.objc_class_name
  end
end
