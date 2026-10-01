# frozen_string_literal: true

# The site is checked in, so the generated page can fall behind the file it
# is generated from. This is the thing that notices.

require 'minitest/autorun'
require_relative '../tools/build_changelog'

class TestChangelogPage < Minitest::Test
  ROOT     = File.expand_path('..', __dir__)
  MARKDOWN = File.read(File.join(ROOT, 'CHANGELOG.md'), encoding: 'UTF-8')
  PAGE     = File.join(ROOT, 'docs', 'changelog.html')

  def rendered
    HackerNews::ChangelogPage.render(MARKDOWN)
  end

  # The one that matters: edit CHANGELOG.md, forget `rake site`, and this
  # says so rather than the website quietly describing an older release.
  def test_the_checked_in_page_is_up_to_date
    assert_equal rendered, File.read(PAGE, encoding: 'UTF-8'),
                 'docs/changelog.html is stale — run `rake site`'
  end

  def test_every_release_becomes_a_section
    versions = MARKDOWN.scan(/^## (.+)$/).flatten
    refute_empty versions

    versions.each { |v| assert_includes rendered, ">#{v}</h2>" }
    assert_equal versions.size, rendered.scan('<section class="release">').size
  end

  def test_bullets_become_a_list
    assert_includes rendered, '<ul>'
    assert_includes rendered, '<li>'
  end

  def test_bold_and_code_survive
    assert_includes rendered, '<strong>Search.</strong>'
    assert_includes rendered, '<code>CGColor</code>'
  end

  # Angle brackets in a release note must not become markup.
  def test_text_is_escaped
    page = HackerNews::ChangelogPage.render("## 9.9\n\nA <script> and an & sign.\n")
    assert_includes page, '&lt;script&gt;'
    assert_includes page, '&amp;'
    refute_includes page, '<script>'
  end

  # A converter that fails loudly on something it has never seen is worth
  # more here than one that quietly drops it.
  def test_it_refuses_markdown_it_does_not_understand
    assert_raises(RuntimeError) do
      HackerNews::ChangelogPage.render("## 9.9\n\nA [link](https://example.com).\n")
    end
  end

  def test_the_page_links_back_to_the_site
    assert_includes rendered, 'href="./"'
    assert_includes rendered, 'style.css'
  end
end
