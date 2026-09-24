# frozen_string_literal: true

# Load the native bridge, preferring an installed copy but falling back to the
# build tree so the repo works without an install step.
# Skip if a build of the extension has already been loaded by hand, which is
# how the arm64 build is exercised against the system interpreter.
unless defined?(ObjC::Object)
  begin
    require 'cocoa/objc_ext'
  rescue LoadError
    require_relative '../ext/objc/objc_ext'
  end
end

require_relative 'cocoa/bridge_support'
require_relative 'cocoa/structs'

# Cocoa -- Ruby bindings for Apple's Objective-C frameworks.
#
#   Cocoa.framework 'AppKit'
#   app = Cocoa::NSApplication.sharedApplication
#   app.setActivationPolicy(0)
#
module Cocoa
  class Error < StandardError; end

  # The selector used by targets minted by Cocoa.action, exposed so callers can
  # wire it to things that take a selector directly, such as a table's
  # doubleAction or a menu item.
  ACTION_SELECTOR = 'rubyAction:'

  @frameworks = {}

  class << self
    attr_reader :frameworks

    # Load a framework's dynamic library and its BridgeSupport metadata.
    def framework(name)
      return @frameworks[name] if @frameworks.key?(name)

      # Framework binaries live in the dyld shared cache and are usually absent
      # from disk on modern macOS, so probing with File.exist? gives a false
      # negative. Ask dyld directly and let it resolve from the cache.
      loaded = BridgeSupport::FRAMEWORK_DIRS.any? do |dir|
        begin
          ObjC.load_framework(File.join(dir, "#{name}.framework", name))
          true
        rescue ObjC::Error
          false
        end
      end

      raise Error, "framework not found: #{name}" unless loaded

      @frameworks[name] = BridgeSupport.load(name)

      # Struct layouts are global, so feed every definition into one registry.
      @frameworks[name]&.structs&.each_value { |encoding| Structs.register(encoding) }
      ObjC.clear_struct_cache

      @frameworks[name]
    end

    # Resolve a bare constant to an Objective-C class, an enum value, or an
    # exported C constant, in that order.
    def const_missing(name)
      str = name.to_s

      if (cls = ObjC.class_named(str))
        const_set(name, cls)
        return cls
      end

      @frameworks.each_value do |bs|
        next unless bs
        if bs.enums.key?(str)
          value = bs.enums[str]
          const_set(name, value)
          return value
        end
      end

      # A struct described by BridgeSupport, e.g. Cocoa::CGSize.
      if (struct_class = Structs.class_for(str) || Structs.class_for("_#{str}"))
        const_set(name, struct_class) unless const_defined?(name, false)
        return const_get(name, false)
      end

      @frameworks.each_value do |bs|
        next unless bs
        next unless bs.constants.key?(str)
        value = ObjC.symbol_value(str, bs.constants[str])
        next if value.nil?
        const_set(name, value)
        return value
      end

      super
    end

    # Call a plain C function described by BridgeSupport, e.g.
    #   Cocoa.call(:NSBeep)
    def call(fn_name, *args)
      str = fn_name.to_s
      @frameworks.each_value do |bs|
        next unless bs
        meta = bs.functions[str]
        next unless meta
        return ObjC.call_c(str, meta[:retval], meta[:args], *args)
      end
      raise Error, "no BridgeSupport metadata for C function #{str}"
    end

    # Build an Objective-C block explicitly, for the cases BridgeSupport does
    # not describe:  Cocoa.block('v', ['@']) { |obj| ... }
    def block(retval, args, &body)
      raise ArgumentError, 'Cocoa.block requires a block' unless body
      ObjC.make_block(retval, args, &body)
    end

    # Find the signature Apple recorded for a callback argument, checking the
    # receiver's class and then each superclass.
    def block_signature_for(receiver, selector, index)
      receiver.objc_class_chain.each do |class_name|
        @frameworks.each_value do |bs|
          next unless bs
          found = bs.block_methods.dig(class_name, selector, index)
          return found if found
        end
      end
      nil
    end

    # Turn any Proc arguments into real Objective-C blocks using that metadata.
    def convert_block_args(receiver, selector, args)
      return args unless args.any? { |a| a.is_a?(Proc) }

      args.each_with_index.map do |arg, index|
        next arg unless arg.is_a?(Proc)

        signature = block_signature_for(receiver, selector, index)
        unless signature
          raise Error, "no block signature in BridgeSupport for #{selector} " \
                       "argument #{index}; build one explicitly with " \
                       'Cocoa.block(retval, [arg_encodings]) { ... }'
        end

        ObjC.make_block(signature[:retval], signature[:args], &arg)
      end
    end

    # Cocoa's target/action predates blocks, so controls still need an object
    # to message. This mints one whose action runs a Ruby block.
    #
    #   Cocoa.on_action(button) { |sender| puts 'clicked' }
    #
    # Controls do not retain their target, so the target is kept alive here for
    # the life of the process.
    def action(&body)
      raise ArgumentError, 'Cocoa.action requires a block' unless body

      @action_class ||= begin
        klass = ObjC.define_class('CocoaRbActionTarget', 'NSObject')
        ObjC.add_method(klass, ACTION_SELECTOR, 'v@:@') do |receiver, sender|
          handler = @action_handlers[receiver.objc_address]
          begin
            handler&.call(sender)
          rescue StandardError => e
            # An action fires from the run loop, so there is no Ruby call to
            # propagate out of until the loop exits. Report it now instead.
            warn "[cocoa] error in action handler: #{e.class}: #{e.message}"
            warn e.backtrace.first(5).join("\n") if e.backtrace
          end
        end
        klass
      end

      @action_handlers ||= {}
      @action_targets  ||= []

      target = @action_class.alloc.init
      @action_handlers[target.objc_address] = body
      @action_targets << target
      target
    end

    # Wire a control's target and action to a Ruby block in one step.
    def on_action(control, &body)
      target = action(&body)
      control.setTarget(target)
      control.setAction(ACTION_SELECTOR)
      target
    end

    # Define an Objective-C class whose methods are Ruby blocks.
    #
    #   Cocoa.define_class('MyDataSource', 'NSObject',
    #                      protocols: %w[NSTableViewDataSource]) do |c|
    #     c.define('numberOfRowsInTableView:', 'q@:@') { |_self, table| 42 }
    #   end
    #
    # The type encoding is the Objective-C convention: return type, then self
    # ('@') and _cmd (':'), then the declared arguments.
    def define_class(name, superclass = 'NSObject', protocols: [], &body)
      klass = ObjC.define_class(name, superclass)

      protocols.each do |protocol|
        begin
          ObjC.add_protocol(klass, protocol)
        rescue ObjC::Error
          # A protocol exists in the runtime only once something references
          # it, so NSOutlineViewDataSource is typically absent while
          # NSTableViewDataSource is present. AppKit dispatches through
          # respondsToSelector: either way, so this is a note, not a failure.
          (@unregistered_protocols ||= []) << protocol
        end
      end

      body&.call(ClassBuilder.new(klass))
      klass
    end

    # Protocols that could not be attached because the runtime does not know
    # them. Useful for telling a genuine typo from an unreferenced protocol.
    def unregistered_protocols
      (@unregistered_protocols ||= []).uniq
    end

    def autorelease_pool(&block)
      ObjC.autorelease_pool(&block)
    end

    # Map a Ruby method name onto the Objective-C selectors it could mean.
    #
    #   :length                                 -> "length"
    #   :setTitle,             1 arg            -> "setTitle:"
    #   :set_title,            1 arg            -> "setTitle:"
    #   :initWithFrame_style,  2 args           -> "initWithFrame:style:"
    def selector_candidates(name, argc)
      str = name.to_s
      candidates = []

      if str.end_with?('=')
        base = str[0..-2]
        candidates << "set#{base[0].upcase}#{base[1..]}:"
        candidates << "#{base}:"
      elsif argc.zero?
        candidates << str
        candidates << camelize(str) if str.include?('_')
      else
        colonized = str.tr('_', ':')
        colonized += ':' unless colonized.end_with?(':')
        candidates << colonized

        if str.include?('_')
          camel = camelize(str)
          camel += ':' unless camel.end_with?(':')
          candidates << camel
        end
      end

      candidates.uniq
    end

    def camelize(str)
      head, *rest = str.split('_')
      head.to_s + rest.map { |p| p.empty? ? '' : p[0].upcase + p[1..].to_s }.join
    end
  end
end

module Cocoa
  # Yielded by Cocoa.define_class so methods read as declarations.
  class ClassBuilder
    def initialize(klass)
      @klass = klass
    end

    def define(selector, types, &body)
      ObjC.add_method(@klass, selector, types, &body)
    end
  end
end

module ObjC
  class Object
    # Ruby's own Object methods shadow any Objective-C selector of the same
    # name, because method_missing never fires for a method that exists.
    # Across the common Cocoa classes there are exactly three: class, display
    # and hash.
    #
    # `display` is resolved in Objective-C's favour: Ruby's merely prints the
    # receiver, while NSView's draws it. The other two keep Ruby's meaning,
    # because `obj.class` and `obj.hash` are relied on by Ruby itself, and the
    # Objective-C versions remain reachable through objc_send.
    SHADOWED_SELECTORS = %w[class hash].freeze

    undef_method :display

    # Dispatch an unknown Ruby method as an Objective-C message, trying each
    # plausible selector spelling and using the first the receiver implements.
    def method_missing(name, *args, &block)
      # A trailing Ruby block is treated as the method's callback argument, so
      # arr.enumerateObjectsUsingBlock { |o, i, stop| } reads naturally.
      args += [block] if block

      Cocoa.selector_candidates(name, args.length).each do |sel|
        next unless objc_responds_to?(sel)
        return objc_send(sel, *Cocoa.convert_block_args(self, sel, args))
      end
      super
    end

    def respond_to_missing?(name, include_private = false)
      Cocoa.selector_candidates(name, 0).any? { |s| objc_responds_to?(s) } ||
        Cocoa.selector_candidates(name, 1).any? { |s| objc_responds_to?(s) } ||
        super
    end

    def inspect
      "#<#{objc_class_name} 0x#{objc_address.to_s(16)} #{self}>"
    end

    # Best-effort conversion of common Foundation containers to Ruby values.
    def to_ruby
      case objc_class_name
      when /String/  then to_s
      when /Number/  then objc_send('doubleValue')
      when /Array/   then to_a.map { |o| o.is_a?(ObjC::Object) ? o.to_ruby : o }
      else self
      end
    end

    def to_a
      count = objc_send('count')
      (0...count).map { |i| objc_send('objectAtIndex:', i) }
    end
  end

  class Class
    def method_missing(name, *args, &block)
      args += [block] if block

      Cocoa.selector_candidates(name, args.length).each do |sel|
        next unless objc_responds_to?(sel)
        return objc_send(sel, *Cocoa.convert_block_args(self, sel, args))
      end
      super
    end

    def respond_to_missing?(name, include_private = false)
      Cocoa.selector_candidates(name, 0).any? { |s| objc_responds_to?(s) } || super
    end

    def inspect
      "#<ObjC::Class #{name}>"
    end

    def to_s
      name
    end
  end
end

# Foundation is the baseline every other framework builds on. CoreFoundation
# comes with it because that is where the geometry structs (CGRect, CGPoint,
# CGSize) are described.
Cocoa.framework 'CoreFoundation'
Cocoa.framework 'Foundation'

module Cocoa
  # Human-readable rendering of an Objective-C type encoding, for
  # introspection and error messages.
  #
  #   Cocoa.describe_encoding('@32@0:8@16')
  #   # => "id method(id self, SEL _cmd, id)"
  module Encoding
    SCALARS = {
      'c' => 'char',      'C' => 'unsigned char',
      's' => 'short',     'S' => 'unsigned short',
      'i' => 'int',       'I' => 'unsigned int',
      'l' => 'long32',    'L' => 'unsigned long32',
      'q' => 'long long', 'Q' => 'unsigned long long',
      'f' => 'float',     'd' => 'double',   'D' => 'long double',
      'B' => 'bool',      'v' => 'void',     '*' => 'char *',
      '@' => 'id',        '#' => 'Class',    ':' => 'SEL',
      '?' => 'unknown'
    }.freeze

    MODIFIERS = 'rnNoORV'

    module_function

    # Split an encoding into its constituent type strings, dropping the frame
    # offsets the runtime interleaves.
    def scan(str)
      types = []
      index = 0
      while index < str.length
        if str[index] =~ /\d/
          index += 1
          next
        end
        type, index = read(str, index)
        types << type
      end
      types
    end

    def read(str, index)
      index += 1 while index < str.length && MODIFIERS.include?(str[index]) &&
                       index + 1 < str.length

      char = str[index]
      case char
      when nil  then ['void', index + 1]
      when '@'
        if str[index + 1] == '?'
          ['block', index + 2]
        else
          ['id', index + 1]
        end
      when '^'
        inner, nxt = read(str, index + 1)
        ["#{inner} *", nxt]
      when '{', '('
        close = char == '{' ? '}' : ')'
        finish = index + 1
        depth  = 1
        while finish < str.length && depth.positive?
          depth += 1 if str[finish] == char
          depth -= 1 if str[finish] == close
          finish += 1
        end
        body = str[(index + 1)...(finish - 1)].to_s
        [body.split('=').first.to_s.sub(/\A\?\z/, 'anonymous struct'), finish]
      when '['
        finish = str.index(']', index) || str.length
        ["#{str[(index + 1)...finish]} array", finish + 1]
      when 'b'
        finish = index + 1
        finish += 1 while finish < str.length && str[finish] =~ /\d/
        ['bitfield', finish]
      else
        [SCALARS.fetch(char, char), index + 1]
      end
    end
  end

  class << self
    # Render a full method encoding as a readable signature.
    def describe_encoding(encoding)
      types = Encoding.scan(encoding)
      return '' if types.empty?

      returns = types.first
      args    = types.drop(1)
      named   = args.each_with_index.map do |type, i|
        case i
        when 0 then "#{type} self"
        when 1 then "#{type} _cmd"
        else type
        end
      end
      "#{returns} method(#{named.join(', ')})"
    end
  end
end

module Cocoa
  module Structs
    class Value
      # Used by the bridge to check that a struct's arity matches its class
      # before wrapping, so a layout mismatch degrades to a plain Array.
      def self.field_count
        leaf_names.size
      end
    end
  end
end

module ObjC
  # Called from C the first time each struct tag is seen.
  def self.resolve_struct_class(tag)
    Cocoa::Structs.class_for(tag.to_s)
  rescue StandardError
    nil
  end
end
