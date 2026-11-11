# frozen_string_literal: true

require_relative '../test_helper'

# Mail text for Redmine without text formatting, and what all formattings share.
class PlainMarkupTest < ActiveSupport::TestCase
  MENTION_PATTERN = Redmine::Acts::Mentionable::InstanceMethods::MENTION_PATTERN
  WJ = "\u2060"

  def markup
    RedmineEmailExtract::PlainMarkup.new
  end

  def all_markups
    [RedmineEmailExtract::PlainMarkup.new, RedmineEmailExtract::TextileMarkup.new,
     RedmineEmailExtract::CommonMarkMarkup.new]
  end

  test 'ordinary mail text passes through unchanged' do
    text = "Hallo Jürgen, Grüße aus Köln\na < b and 1 > 0\nhttps://example.org/a_b?c=1 anna@example.org\n" \
           "Re: #123, see C:\\Users\\anna\n50% - 60%"

    assert_equal text, markup.body(text)
  end

  test 'markup of other formattings is plain text here and stays' do
    text = "# Title\n<word> &copy; *bold* \\\\server\\share\n---\np. 5\n!image!\n[1]: http://x.example"

    assert_equal text, markup.body(text)
  end

  test 'loses trailing blanks, runs of empty lines and indentation' do
    nbsp = "\u00A0"

    assert_equal "Hello\n\nindented\ntext\n* item\nTab\ta",
                 markup.body("\n Hello   \n#{nbsp}\n \n\n\n    indented\n#{nbsp}text\n  * item\n\tTab\ta\n\n")
    assert_equal '', markup.body(" \n#{nbsp}\n")
    assert_equal '', markup.body(nil)
  end

  test 'quote markers are kept, written without blanks between them' do
    assert_equal "> a\n>> b\n>\n> c\nreply", markup.body("> a\n> > b\n>\n>    c\nreply")
  end

  test 'a mention is broken by an invisible word joiner after the "@"' do
    text = "Hi @admin and (@jsmith),\nmail anna@example.org\n@@team ü@admin a@@admin @admin."

    assert_equal "Hi @#{WJ}admin and (@#{WJ}jsmith),\nmail anna@example.org\n" \
                 "@#{WJ}@#{WJ}team ü@#{WJ}admin a@@#{WJ}admin @#{WJ}admin.", markup.body(text)
  end

  test 'no formatting leaves anything Redmine would take for a mention' do
    text = "@admin (@admin) @@team\n@admin\nx @admin. ü@admin a@b.c a@@admin @admin, [@admin]"

    all_markups.each do |markup|
      escaped = markup.body(text)

      assert_empty escaped.scan(MENTION_PATTERN).flatten.compact_blank, markup.class.name
      assert_includes escaped, 'a@b.c', markup.class.name
    end
  end

  test 'existing macros are shown, not run, in every formatting' do
    text = '{{include(Secret)}} {{Include(Secret)}} {{nothing_like_this}} !{{collapse}} {{macro(1)}}'

    all_markups.each do |markup|
      assert_equal '!{{include(Secret)}} !{{Include(Secret)}} {{nothing_like_this}} !!{{collapse}} !{{macro(1)}}',
                   markup.body(text), markup.class.name
    end
  end

  test 'a macro with a block of text is escaped at its start' do
    assert_equal "!{{collapse(More)\nhidden\n}}", markup.body("{{collapse(More)\nhidden\n}}")
  end

  test 'a paragraph that is only a table of contents gets a word joiner in front' do
    all_markups.each do |markup|
      assert_equal "#{WJ}{{toc}}", markup.body('{{toc}}'), markup.class.name
      assert_equal "> #{WJ}{{>toc}}", markup.body('> {{>toc}}'), markup.class.name
    end
    assert_equal 'see {{toc}}', markup.body('see {{toc}}')
  end

  test 'images are links to the attachment' do
    assert_equal 'attachment:a-1_b.png', markup.image('a-1_b.png')
  end
end
