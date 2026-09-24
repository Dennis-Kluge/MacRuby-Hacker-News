# frozen_string_literal: true

module Cocoa
  # Structs cross the bridge as flat arrays of numbers. Where Apple's metadata
  # names their fields, this builds an Array subclass with named accessors, so
  # a frame reads as rect.width rather than rect[2] while still behaving as the
  # array it is.
  #
  #   rect = view.frame        # => #<Cocoa::CGRect x=0.0 y=0.0 width=480.0 height=320.0>
  #   rect.width               # => 480.0
  #   rect.size.height         # => 320.0
  #   rect[2]                  # => 480.0
  #   rect == [0, 0, 480, 320] # => true
  module Structs
    ANONYMOUS = '?'

    # An Objective-C struct, represented as its flattened scalar fields.
    class Value < Array
      class << self
        attr_accessor :struct_tag, :struct_fields, :leaf_names
      end

      def to_h
        self.class.leaf_names.zip(self).to_h
      end

      def inspect
        pairs = self.class.leaf_names.zip(self).map { |n, v| "#{n}=#{v}" }
        "#<#{self.class.name || self.class.struct_tag} #{pairs.join(' ')}>"
      end
      alias to_s inspect
    end

    @definitions = {}
    @classes     = {}

    class << self
      attr_reader :definitions

      # Record a struct definition, keyed by the tag that appears inside type
      # encodings. That is not always the name BridgeSupport advertises: it
      # calls the struct NSRange while the encoding says _NSRange.
      def register(encoding)
        tag, fields = parse(encoding)
        # Some headers yield tags like "struct (unnamed at /path/to.h:39:9)".
        return nil if tag.nil? || tag !~ /\A[A-Za-z_]\w*\z/ || fields.empty?

        @definitions[tag] = fields
        @classes.delete(tag)
        tag
      end

      # Split "{CGRect=\"origin\"{CGPoint}\"size\"{CGSize}}" into its tag and
      # its [name, encoding] field pairs.
      def parse(encoding)
        return [nil, []] unless encoding.is_a?(String) && encoding.start_with?('{')

        index = 1
        tag = +''
        tag << encoding[index] and index += 1 while index < encoding.length &&
                                                    !'=}'.include?(encoding[index])

        return [tag, []] unless encoding[index] == '='

        index += 1
        fields = []
        while index < encoding.length && encoding[index] != '}'
          name = nil
          if encoding[index] == '"'
            finish = encoding.index('"', index + 1) || encoding.length
            name   = encoding[(index + 1)...finish]
            index  = finish + 1
          end
          break if index >= encoding.length || encoding[index] == '}'

          type, index = scan_type(encoding, index)
          fields << [name || "field#{fields.size}", type]
        end

        [tag, fields]
      end

      # Return the raw encoding substring for one type, and where it ends.
      def scan_type(str, index)
        start = index
        case str[index]
        when '{', '('
          close = str[index] == '{' ? '}' : ')'
          open  = str[index]
          depth = 1
          index += 1
          while index < str.length && depth.positive?
            depth += 1 if str[index] == open
            depth -= 1 if str[index] == close
            index += 1
          end
        when '^'
          _, index = scan_type(str, index + 1)
        when '['
          finish = str.index(']', index) || str.length
          index  = finish + 1
        when 'b'
          index += 1
          index += 1 while index < str.length && str[index] =~ /\d/
        else
          index += 1
          index += 1 if str[start] == '@' && str[index] == '?'
        end
        [str[start...index], index]
      end

      # How many flattened scalars a field occupies.
      def leaf_count(encoding)
        leaf_names(encoding).size
      end

      # The flattened scalar names beneath a field encoding. A nested struct
      # contributes its own field names; anything else contributes one unnamed
      # slot.
      def leaf_names(encoding, seen = [])
        return [nil] unless encoding.start_with?('{')

        tag, fields = parse(encoding)
        fields = @definitions[tag] if fields.empty? && @definitions.key?(tag)
        return [nil] if fields.nil? || fields.empty?
        return [nil] if seen.include?(tag)   # guard against recursive types

        fields.flat_map do |name, type|
          nested = leaf_names(type, seen + [tag])
          nested.size == 1 && nested.first.nil? ? [name] : nested
        end
      end

      # Build (and memoize) the Array subclass for a struct tag.
      def class_for(tag)
        return @classes[tag] if @classes.key?(tag)

        fields = @definitions[tag]
        return @classes[tag] = nil if fields.nil? || fields.empty?

        leaves = leaf_names("{#{tag}=#{fields.map { |n, t| "\"#{n}\"#{t}" }.join}}")
        klass  = Class.new(Value)
        klass.struct_tag    = tag
        klass.struct_fields = fields
        klass.leaf_names    = leaves.each_with_index.map { |n, i| n || "field#{i}" }

        define_field_readers(klass, fields)
        define_leaf_readers(klass, klass.leaf_names)

        constant = tag.sub(/\A_/, '')
        Cocoa.const_set(constant, klass) if constant =~ /\A[A-Z]\w*\z/ &&
                                            !Cocoa.const_defined?(constant, false)

        @classes[tag] = klass
      end

      private

      # Readers for the struct's own fields. A nested struct yields another
      # struct object over the same slice.
      def define_field_readers(klass, fields)
        offset = 0
        fields.each do |name, type|
          count  = [leaf_count(type), 1].max
          at     = offset
          nested = type.start_with?('{') ? parse(type).first : nil

          if count == 1 && nested.nil?
            klass.send(:define_method, name) { self[at] }
            klass.send(:define_method, "#{name}=") { |v| self[at] = v }
          else
            klass.send(:define_method, name) do
              sub = Cocoa::Structs.class_for(nested)
              slice = self[at, count]
              sub ? sub[*slice] : slice
            end
          end

          offset += count
        end
      end

      # Convenience readers for leaves, so a CGRect answers to .width as well
      # as .size.width. Only added where the name is unambiguous.
      def define_leaf_readers(klass, leaves)
        # Array#tally is Ruby 2.7+; the system arm64 interpreter is 2.6.
        counts = leaves.each_with_object(Hash.new(0)) { |name, acc| acc[name] += 1 }
        leaves.each_with_index do |name, index|
          next if name.nil? || counts[name] != 1
          next if klass.method_defined?(name)

          klass.send(:define_method, name) { self[index] }
          klass.send(:define_method, "#{name}=") { |v| self[index] = v }
        end
      end
    end
  end
end
