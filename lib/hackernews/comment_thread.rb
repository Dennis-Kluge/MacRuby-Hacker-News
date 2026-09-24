# frozen_string_literal: true

module HackerNews
  # A story's comments, flattened into a lookup table of nodes keyed by id.
  #
  # Plain Ruby: it never touches AppKit, which is what lets the shape of a
  # thread be tested without a window.
  class CommentThread
    EMPTY_TEXT = '[deleted]'

    Node = Struct.new(:id, :author, :text, :links, :age, :children, keyword_init: true) do
      def leaf?
        children.empty?
      end
    end

    def self.from(json)
      new.tap { |thread| thread.absorb_roots(json) }
    end

    def initialize
      @nodes = {}
      @roots = []
    end

    attr_reader :nodes, :roots

    def absorb_roots(json)
      @roots = children_of(json)
      self
    end

    def node(id)
      @nodes[id.to_i]
    end

    def children(id)
      id.nil? ? @roots : (node(id)&.children || [])
    end

    def expandable?(id)
      node = node(id)
      node ? !node.leaf? : false
    end

    def size
      @nodes.size
    end

    def empty?
      @roots.empty?
    end

    private

    def children_of(json)
      (json['children'] || []).map { |child| absorb(child) }.compact
    end

    def absorb(json)
      children = children_of(json)
      # Single newlines between paragraphs: spacing does the visual work, and
      # not rewriting the text afterwards keeps link ranges valid.
      rich = HTML.to_rich(json['text'], paragraph_break: "\n")

      # A deleted comment is kept only when it still holds a thread together.
      return nil if rich[:text].empty? && children.empty?

      id = json['id'].to_i
      @nodes[id] = Node.new(
        id:       id,
        author:   json['author'] || EMPTY_TEXT,
        text:     rich[:text].empty? ? EMPTY_TEXT : rich[:text],
        links:    rich[:links],
        age:      HTML.relative_time(json['created_at']),
        children: children
      )
      id
    end
  end
end
