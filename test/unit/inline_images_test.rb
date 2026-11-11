# frozen_string_literal: true

require_relative '../test_helper'

class InlineImagesTest < ActiveSupport::TestCase
  HTML = <<~HTML
    <html><body>
      <p>Hello Ben,</p>
      <p>this is the <b>first</b> screenshot of the error:</p>
      <p><img src="cid:first@example" width="300"></p>
      <p>And here is a second one, see <a href="https://example.org/help">the help page</a>:</p>
      <p><img src="cid:second@example"><img src="cid:third%40example"></p>
      <p>XML:</p>
      <p><img src="cid:fourth@example"></p>
      <p>Regards<br>Anna</p>
      <p><img src="cid:logo@example"></p>
    </body></html>
  HTML

  TEXT = <<~TEXT.chomp
    Hello Ben,

    this is the first screenshot of the error:

    And here is a second one, see the help page <https://example.org/help> :

    XML:

    Regards
    Anna
  TEXT

  NUMBERS = { 'first@example' => 1, 'second@example' => 2, 'third@example' => 3, 'fourth@example' => 4, 'logo@example' => 9 }.freeze

  # The text with "[n]" lines where the markers are.
  def mark(text, html, numbers = NUMBERS)
    marked = RedmineEmailExtract::InlineImages.mark(text, html) { |content_id| numbers[content_id] }
    marked.split("\n", -1).map { |line| line =~ RedmineEmailExtract::InlineImages::MARKER_LINE ? "[#{Regexp.last_match(1)}]" : line }
          .join("\n")
  end

  test 'puts a marker after the line of text that precedes each image' do
    %w[textile common_mark].each do |formatting|
      with_settings text_formatting: formatting do
        assert_equal <<~TEXT.chomp, mark(TEXT, HTML), formatting
          Hello Ben,

          this is the first screenshot of the error:
          [1]

          And here is a second one, see the help page <https://example.org/help> :
          [2]
          [3]

          XML:
          [4]

          Regards
          Anna
          [9]
        TEXT
      end
    end
  end

  test 'leaves out images the block returns nil for' do
    with_settings text_formatting: 'textile' do
      marked = mark(TEXT, HTML, 'first@example' => 1)

      assert_equal 1, marked.scan(/^\[\d+\]$/).size
      assert_includes marked, "error:\n[1]\n"
    end
  end

  test 'an image above all text comes first' do
    with_settings text_formatting: 'textile' do
      assert_equal "[1]\nHello Ben", mark('Hello Ben', '<p><img src="cid:first@example"></p><p>Hello Ben</p>')
    end
  end

  test 'an image whose surrounding lines are not in the text follows the last line that is' do
    html = '<p>Hello Ben</p><p>Only in the HTML version</p><p><img src="cid:first@example"></p><p>Regards, Anna</p>'

    with_settings text_formatting: 'textile' do
      assert_equal "Hello Ben\n[1]\n\nRegards, Anna", mark("Hello Ben\n\nRegards, Anna", html)
    end
  end

  test 'an image after a paragraph that the plain text wraps comes after its last line' do
    text = "Here is a long paragraph that the plain text\nversion wraps onto a second line.\nAnd a third line.\n\nRegards"
    html = '<p>Here is a long paragraph that the plain text version wraps onto a second line.</p>' \
           '<p><img src="cid:first@example"></p><p>And a third line.</p><p>Regards</p>'

    with_settings text_formatting: 'textile' do
      assert_equal "Here is a long paragraph that the plain text\nversion wraps onto a second line.\n[1]\n" \
                   "And a third line.\n\nRegards", mark(text, html)
    end
  end

  test 'a plus sign in a Content-ID is not taken for a space' do
    with_settings text_formatting: 'textile' do
      assert_equal "Hello Ben\n[1]", mark('Hello Ben', '<p>Hello Ben</p><p><img src="cid:a+b@host"></p>', 'a+b@host' => 1)
    end
  end

  test 'text stays as it is without HTML or without inline images' do
    with_settings text_formatting: 'textile' do
      assert_equal TEXT, mark(TEXT, nil)
      assert_equal TEXT, mark(TEXT, '<p>Hello</p><img src="https://example.org/a.png">')
      assert_equal '', mark(nil, HTML, {})
    end
  end
end
