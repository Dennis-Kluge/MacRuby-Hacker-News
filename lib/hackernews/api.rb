# frozen_string_literal: true

require 'json'
require 'uri'
require 'time'

module HackerNews
  # Asynchronous access to the Hacker News API, via NSURLSession.
  #
  # Every completion handler is delivered on the main thread, because that is
  # the thread holding Ruby's global lock while the event loop runs. A handler
  # arriving on one of NSURLSession's own background threads would be calling
  # into an interpreter that is not expecting it.
  class API
    HOST       = 'https://hn.algolia.com/api/v1'
    FRONT_PAGE = "#{HOST}/search?tags=front_page&hitsPerPage=%d"
    ITEM       = 'https://hn.algolia.com/api/v1/items/%s'

    def initialize
      configuration = Cocoa::NSURLSessionConfiguration.defaultSessionConfiguration
      configuration.setTimeoutIntervalForRequest(20.0)

      @session = Cocoa::NSURLSession.sessionWithConfiguration_delegate_delegateQueue(
        configuration, nil, Cocoa::NSOperationQueue.mainQueue
      )
    end

    # Yields (stories, more_pages_exist, error). Page 0 of an unsearched Top is
    # the real front page; every page after it continues into the past week's
    # ranked stories.
    def stories(page = 0, per_page = 30, query: Query.new, &block)
      get(page_url(page, per_page, query)) do |json, error|
        next block.call(nil, false, error) if error

        hits = json['hits'] || []
        block.call(hits.map { |hit| story_from(hit) }, more_after?(page, json, query), nil)
      end
    end

    # Kept for callers that only ever want the front page.
    def front_page(limit = 30, &block)
      stories(0, limit) { |list, _more, error| block.call(list, error) }
    end

    def story_from(hit)
      {
        id:       hit['objectID'],
        title:    hit['title'].to_s,
        author:   hit['author'].to_s,
        points:   hit['points'].to_i,
        comments: hit['num_comments'].to_i,
        url:      hit['url'],
        domain:   domain_of(hit['url']),
        # Search reaches back years, so when a story is from is part of what
        # it is -- and the front page shows it too, as Hacker News does.
        age:      HTML.relative_time(hit['created_at'])
      }
    end

    # Yields (story_with_nested_children, error). Algolia returns the whole
    # comment tree in one response, which keeps this to a single request.
    def item(id, &block)
      get(format(ITEM, id)) do |json, error|
        error ? block.call(nil, error) : block.call(json, nil)
      end
    end

    # Build the URL for one page of a query.
    def page_url(page, per_page, query)
      section = query.section
      return format(FRONT_PAGE, per_page) if front_page_leads?(query) && page.zero?

      # The front page is a page of its own, so the rest are offset by one.
      offset = front_page_leads?(query) ? page - 1 : page

      parameters = ["tags=#{section.tags}", "hitsPerPage=#{per_page}", "page=#{offset}"]
      if query.search?
        parameters << "query=#{URI.encode_www_form_component(query.text)}"
        parameters.concat(query.parameters)
      end

      # A plain list is windowed to stay current; a search is windowed only if
      # asked to be, which is what lets one reach back to 2007.
      if (window = query.window)
        # The comparison has to be encoded or Algolia rejects the filter.
        parameters << "numericFilters=created_at_i%3E#{Time.now.to_i - window}"
      end

      "#{HOST}/#{query.endpoint}?#{parameters.join('&')}"
    end

    # Searching replaces the curated front page with ranked results, so the
    # special first page only applies when there is nothing to search for.
    def front_page_leads?(query)
      query.section.front_page_first? && !query.search?
    end

    # The front page has no second page of its own, but the section continues.
    def more_after?(page, json, query)
      return true if front_page_leads?(query) && page.zero?

      (json['page'].to_i + 1) < json['nbPages'].to_i
    end

    # "www.businessinsider.com" -> "businessinsider.com"; nil for text posts.
    def domain_of(url)
      return nil if url.to_s.empty?

      host = URI.parse(url).host
      host&.sub(/\Awww\./, '')
    rescue URI::InvalidURIError
      nil
    end

    private

    def get(url_string, &block)
      url = Cocoa::NSURL.URLWithString(url_string)
      return block.call(nil, "bad URL: #{url_string}") if url.nil?

      task = @session.dataTaskWithURL_completionHandler(url) do |data, response, error|
        if error
          block.call(nil, error.localizedDescription.to_s)
        elsif response && response.statusCode != 200
          block.call(nil, "HTTP #{response.statusCode}")
        else
          block.call(*decode(data))
        end
      end
      task.resume
      task
    end

    def decode(data)
      return [nil, 'empty response'] if data.nil? || data.length.zero?

      text = Cocoa::NSString.alloc.initWithData_encoding(data, 4) # NSUTF8StringEncoding
      return [nil, 'response was not UTF-8'] if text.nil?

      [JSON.parse(text.to_s), nil]
    rescue JSON::ParserError => e
      [nil, "malformed JSON: #{e.message}"]
    end
  end
end
