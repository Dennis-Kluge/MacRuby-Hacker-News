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
end
