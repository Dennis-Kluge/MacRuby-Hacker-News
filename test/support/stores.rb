# frozen_string_literal: true

# Stand-ins for NSUserDefaults, so the stores can be exercised without
# touching the reader's real preferences -- and so a test run leaves nothing
# behind on the machine it ran on.
module HackerNews
  # Stands in for NSUserDefaults.
  class MemoryStore
    def initialize
      @data = {}
    end
    def read(key)
      @data[key]
    end
    def write(key, values)
      @data[key] = values.dup
    end
    def delete(key)
      @data.delete(key)
    end
    def [](key)
      @data[key]
    end
  end

  # Stands in for NSUserDefaults where the value is a single string.
  class MemoryText
    def initialize(value = nil)
      @data = {}
      @data[HackerNews::Favorites::KEY] = value if value
    end

    attr_reader :data

    def read(key)
      @data[key]
    end

    def write(key, string)
      @data[key] = string
    end

    def delete(key)
      @data.delete(key)
    end
  end

  # Stands in for NSUserDefaults, registrations and all.
  #
  # The real one is shared by every process on the machine, including the
  # reader itself, so a test that used it would change what the reader shows
  # the next time it launches -- which is exactly what happened once.
  class MemoryDefaults
    def initialize
      @values     = {}
      @registered = {}
    end

    def registerDefaults(hash)
      hash.each { |key, value| @registered[key.to_s] = value }
      hash
    end

    def objectForKey(key)
      @values.key?(key.to_s) ? @values[key.to_s] : @registered[key.to_s]
    end

    def stringForKey(key)
      value = objectForKey(key)
      value.nil? ? nil : value.to_s
    end

    # A registered false has to read as false, not as "nothing stored".
    def boolForKey(key)
      objectForKey(key) ? true : false
    end

    def integerForKey(key)
      objectForKey(key).to_i
    end

    def setObject_forKey(value, key)
      @values[key.to_s] = value
    end
    alias setBool_forKey setObject_forKey
    alias setInteger_forKey setObject_forKey

    def removeObjectForKey(key)
      @values.delete(key.to_s)
    end
  end
end
