# frozen_string_literal: true

module Cocoa
  # Reads the .bridgesupport metadata Apple ships inside each framework.
  #
  # The Objective-C runtime can describe every *method* at runtime, but it knows
  # nothing about enums, #defines, plain C functions or struct layouts. That
  # information lives in these files, which Apple still generates and ships for
  # 200+ frameworks (including arm64e variants). This class is what makes
  # constants like NSWindowStyleMaskTitled resolvable at all.
  class BridgeSupport
    FRAMEWORK_DIRS = [
      '/System/Library/Frameworks',
      '/System/Library/PrivateFrameworks'
    ].freeze

    attr_reader :name, :enums, :constants, :functions, :structs, :block_methods

    def initialize(name)
      @name          = name
      @enums         = {}
      @constants     = {}
      @functions     = {}
      @structs       = {}
      # class name => selector => { argument_index => { args:, retval: } }
      # Keyed by class because the same selector carries different block
      # signatures on different classes: NSArray's enumerateObjectsUsingBlock:
      # block takes (obj, idx, stop) while NSSet's takes (obj, stop).
      @block_methods = {}
    end

    def self.path_for(framework)
      FRAMEWORK_DIRS.each do |dir|
        base = File.join(dir, "#{framework}.framework", 'Resources', 'BridgeSupport')
        candidate = File.join(base, "#{framework}.bridgesupport")
        return candidate if File.exist?(candidate)
      end
      nil
    end

    def self.load(framework)
      path = path_for(framework)
      return nil unless path

      bs = new(framework)
      bs.parse(File.read(path, encoding: 'UTF-8', invalid: :replace, undef: :replace))
      bs
    end

    # The files are large (AppKit is ~430 KB) but shallow and line-oriented, so
    # a scan beats a DOM parse by a wide margin and avoids an XML dependency.
    #
    # Block-taking methods nest their signature inside the argument element:
    #
    #   <method selector='enumerateObjectsUsingBlock:'>
    #   <arg function_pointer='true' index='0' type64='@?'>
    #   <arg type64='@'/><arg type64='Q'/><arg type64='^B'/>
    #   <retval type64='v'/>
    #   </arg>
    #   </method>
    def parse(xml)
      klass     = nil     # name of the <class> currently open
      selector  = nil     # selector of the <method> currently open
      fn_name   = nil     # name of the <function> currently open
      fn_args   = nil
      fn_ret    = nil
      block_arg = nil     # {index:, args: [], retval:} while inside a callback arg

      xml.each_line do |line|
        case line
        when /<enum\s/
          name  = line[/name='([^']+)'/, 1]
          value = line[/value64='([^']*)'/, 1] || line[/value='([^']*)'/, 1]
          next if name.nil? || value.nil? || value.empty?
          @enums[name] = value.include?('.') ? value.to_f : value.to_i

        when /<constant\s/
          name = line[/name='([^']+)'/, 1]
          type = type_of(line)
          @constants[name] = type if name && type

        when /<struct\s/
          name = line[/name='([^']+)'/, 1]
          type = type_of(line)
          @structs[name] = type if name && type

        when /<class\s+name='([^']+)'/
          klass = Regexp.last_match(1)

        when %r{</class>}
          klass = nil

        when /<method\s/
          selector = line[/selector='([^']+)'/, 1]
          selector = nil if line.include?('/>')

        when %r{</method>}
          selector = nil

        when /<function\s+name='([^']+)'/
          fn_name = Regexp.last_match(1)
          fn_args = []
          fn_ret  = 'v'
          if line.include?('/>')
            @functions[fn_name] = { args: [], retval: 'v' }
            fn_name = nil
          end

        when %r{</function>}
          @functions[fn_name] = { args: fn_args, retval: fn_ret } if fn_name
          fn_name = nil

        when /<arg\s/
          if line.include?("function_pointer='true'") && !line.include?('/>')
            # Opening a callback argument: what follows describes its signature.
            block_arg = { index: line[/index='(\d+)'/, 1].to_i, args: [], retval: 'v' }
          elsif block_arg
            t = type_of(line)
            block_arg[:args] << t if t
          elsif fn_name
            t = type_of(line)
            fn_args << t if t
          end

        when /<retval\s/
          t = type_of(line)
          next unless t
          if block_arg
            block_arg[:retval] = t
          elsif fn_name
            fn_ret = t
          end

        when %r{</arg>}
          if block_arg && selector && klass
            by_selector = (@block_methods[klass] ||= {})
            (by_selector[selector] ||= {})[block_arg[:index]] =
              { args: block_arg[:args], retval: block_arg[:retval] }
          end
          block_arg = nil
        end
      end

      self
    end

    private

    def type_of(line)
      unescape(line[/type64='([^']*)'/, 1] || line[/type='([^']*)'/, 1])
    end

    def unescape(str)
      return nil if str.nil?
      str.gsub('&quot;', '"').gsub('&amp;', '&').gsub('&lt;', '<').gsub('&gt;', '>')
    end
  end
end
