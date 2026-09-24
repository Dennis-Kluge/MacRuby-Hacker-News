# frozen_string_literal: true

require 'fileutils'

module HackerNews
  # Site icons for the story list.
  #
  # Fetched straight from each domain rather than through one of the favicon
  # services, so no third party is handed the list of what is being read.
  # Everything is cached on disk; a domain that has no icon falls back to a
  # monogram so a row never waits on the network to look finished.
  class Favicons
    SIZE      = 16.0
    TIMEOUT   = 10.0
    CACHE_DIR = File.expand_path('~/Library/Caches/org.example.hackernews/favicons')

    # Deterministic per domain, so a site keeps the same colour between runs.
    MONOGRAM_COLOURS = [
      [0.90, 0.30, 0.24], [0.20, 0.60, 0.86], [0.18, 0.80, 0.44],
      [0.95, 0.61, 0.07], [0.61, 0.35, 0.71], [0.09, 0.63, 0.52],
      [0.83, 0.33, 0.00], [0.20, 0.29, 0.37]
    ].freeze

    def initialize(cache_dir: CACHE_DIR, on_ready: nil)
      @cache_dir = cache_dir
      @on_ready  = on_ready
      @images    = {}
      @attempted = {}
      FileUtils.mkdir_p(@cache_dir)
    rescue SystemCallError
      @cache_dir = nil
    end

    attr_accessor :on_ready

    # Returns something drawable straight away, and fetches in the background
    # if this domain has not been tried yet.
    def icon_for(domain)
      return nil if domain.to_s.empty?

      key = domain.to_s
      return @images[key] if @images.key?(key)

      from_disk = load_from_disk(key)
      return @images[key] = from_disk if from_disk

      fetch(key) unless @attempted[key]
      @images[key] = monogram(key)
    end

    # Already-known icons only; used by tests and by callers that must not
    # start network traffic.
    def cached(domain)
      @images[domain.to_s]
    end

    def fetched?(domain)
      @attempted[domain.to_s] == :done
    end

    private

    def session
      @session ||= begin
        configuration = Cocoa::NSURLSessionConfiguration.defaultSessionConfiguration
        configuration.setTimeoutIntervalForRequest(TIMEOUT)
        # Completion handlers on the main thread, where Ruby is expecting them.
        Cocoa::NSURLSession.sessionWithConfiguration_delegate_delegateQueue(
          configuration, nil, Cocoa::NSOperationQueue.mainQueue
        )
      end
    end

    def fetch(domain)
      @attempted[domain] = :pending
      url = Cocoa::NSURL.URLWithString("https://#{domain}/favicon.ico")
      return @attempted[domain] = :done if url.nil?

      task = session.dataTaskWithURL_completionHandler(url) do |data, response, error|
        @attempted[domain] = :done
        next if error || data.nil? || data.length.zero?
        next if response && response.statusCode != 200

        image = image_from(data)
        next if image.nil?

        @images[domain] = image
        write_to_disk(domain, data)
        @on_ready&.call(domain)
      end
      task.resume
    end

    def image_from(data)
      image = Cocoa::NSImage.alloc.initWithData(data)
      return nil if image.nil? || image.size.width.zero?

      image.setSize([SIZE, SIZE])
      image
    rescue ObjC::Exception
      nil
    end

    def path_for(domain)
      return nil if @cache_dir.nil?

      File.join(@cache_dir, "#{domain.gsub(%r{[^\w.-]}, '_')}.ico")
    end

    def load_from_disk(domain)
      path = path_for(domain)
      return nil if path.nil? || !File.file?(path)

      data = Cocoa::NSData.dataWithContentsOfFile(path)
      data && image_from(data)
    end

    def write_to_disk(domain, data)
      path = path_for(domain)
      data.writeToFile_atomically(path, true) if path
    rescue ObjC::Exception
      nil
    end

    # A coloured tile with the domain's initial, for sites with no icon.
    def monogram(domain)
      letter = domain.sub(/\Awww\./, '')[0].to_s.upcase
      letter = '?' if letter.empty?

      image = Cocoa::NSImage.alloc.initWithSize([SIZE, SIZE])
      image.lockFocus

      red, green, blue = MONOGRAM_COLOURS[domain.sum % MONOGRAM_COLOURS.size]
      Cocoa::NSColor.colorWithSRGBRed_green_blue_alpha(red, green, blue, 1.0).set
      Cocoa::NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
        [0, 0, SIZE, SIZE], 3.5, 3.5
      ).fill

      style = Cocoa::NSMutableParagraphStyle.alloc.init
      style.setAlignment(Cocoa::NSTextAlignmentCenter)
      Cocoa::NSAttributedString.alloc.initWithString_attributes(
        letter,
        Cocoa::NSFontAttributeName            => Cocoa::NSFont.boldSystemFontOfSize(10),
        Cocoa::NSForegroundColorAttributeName => Cocoa::NSColor.whiteColor,
        Cocoa::NSParagraphStyleAttributeName  => style
      ).drawInRect([0, 1, SIZE, SIZE - 2])

      image.unlockFocus
      image
    rescue ObjC::Exception
      nil
    end
  end
end
