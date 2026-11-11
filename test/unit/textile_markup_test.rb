# frozen_string_literal: true

require_relative '../test_helper'

# What Redmine's Textile would misread in a mail, and what it may keep.
class TextileMarkupTest < ActiveSupport::TestCase
  def markup
    RedmineEmailExtract::TextileMarkup.new
  end

  def body(text)
    markup.body(text)
  end

  test 'ordinary mail text passes through unchanged' do
    text = "Hallo Jürgen, Grüße aus Köln\na < b and 1 > 0, <word>\nhttps://example.org/a_b?c=1 anna@example.org\n" \
           "Re: #123, see C:\\Users\\anna and \\\\server\\share\n50% - 60%, AT&T, (c) Hi! How are you!"

    assert_equal text, body(text)
  end

  test 'label and image' do
    assert_equal '*From:*', markup.label('From:')
    assert_equal '!a.png!', markup.image('a.png')
  end

  test 'block signatures at the start of a block are escaped' do
    assert_equal 'p&#46; 5 of the contract', body('p. 5 of the contract')
    assert_equal "Text\n\nbq&#46; quoted", body("Text\n\nbq. quoted")
    assert_equal 'h2(cls)&#46; Title', body('h2(cls). Title')
    assert_equal 'p>&#46; right', body('p>. right')
    assert_equal 'fn1&#46; note', body('fn1. note')
    assert_equal '> h1&#46; quoted heading', body('> h1. quoted heading')
  end

  test 'block signatures inside a paragraph stay' do
    assert_equal "Text\np. 5", body("Text\np. 5")
  end

  test 'numbered list lines are escaped, bulleted lists stay' do
    assert_equal "&#35; one\n&#35;# two", body("# one\n## two")
    assert_equal "Text\n* item\n** sub", body("Text\n* item\n** sub")
  end

  test 'lines Redmine would join to the line before are escaped' do
    assert_equal "Text\n&#61;====\n&#123;x}\n&#124; quoted\n&#35;##\n&#42;",
                 body("Text\n=====\n{x}\n| quoted\n###\n*")
  end

  test 'table rows that form a table stay' do
    assert_equal "Text\n|a|b|\n|1|2|", body("Text\n|a|b|\n|1|2|")
    assert_equal "Text\n&#124;a|b|\nmore", body("Text\n|a|b|\nmore")
  end

  test 'separator lines are escaped, dashes and a rule stay' do
    assert_equal "a\n&#43;++++\nb\n&#126;~~~~\nc\n&#95;____\nd\n&#45;\ne\n&#94;^^",
                 body("a\n+++++\nb\n~~~~~\nc\n_____\nd\n-\ne\n^^^")
    assert_equal "Regards\n--\nAnna\n\n---", body("Regards\n-- \nAnna\n\n---")
  end

  test 'raw tags and comments are escaped, other tags stay' do
    assert_equal 'a &lt;pre>b &lt;/pre> &lt;code>c&lt;/code> &lt;kbd>k&lt;/kbd> &lt;notextile>n&lt;/notextile> ' \
                 '&lt;!-- x --> <div>',
                 body('a <pre>b </pre> <code>c</code> <kbd>k</kbd> <notextile>n</notextile> <!-- x --> <div>')
  end

  test 'notextile "==" is escaped where it pairs' do
    assert_equal 'x &#61;= 1 and y == 2', body('x == 1 and y == 2')
    assert_equal "&#61;=foo\nbar==", body("==foo\nbar==")
    assert_equal 'a == b', body('a == b')
  end

  test 'images are escaped' do
    assert_equal 'Achtung &#33;wichtig! und &#33;http://x.example/a.png!',
                 body('Achtung !wichtig! und !http://x.example/a.png!')
  end

  test 'acronyms do not hide the parenthesis' do
    assert_equal 'USB&#40;3.0) and PDF&#40;s)', body('USB(3.0) and PDF(s)')
  end

  test 'text that looks like an entity is shown as written' do
    assert_equal '&amp;copy; &amp;#64; &amp;amp;', body('&copy; &#64; &amp;')
  end

  test 'a line after a list item is a new paragraph unless it was indented' do
    assert_equal "* item\nwrapped\n\nnext", body("* item\n  wrapped\nnext")
    assert_equal "> * item\n>\n> next", body("> * item\n> next")
  end

  test 'quotes stay quotes and need no separation' do
    assert_equal ">> old\n> newer\nreply", body("> > old\n> newer\nreply")
    assert_equal "> &#35; quoted\nreply", body("> # quoted\nreply")
  end

  test 'mentions become entities; e-mail addresses stay, so no @code@ span forms' do
    assert_equal '&#64;admin, (&#64;jsmith) &#64;&#64;team mail a@b.example and x@y.example',
                 body('@admin, (@jsmith) @@team mail a@b.example and x@y.example')
  end

  test 'inline markup of mails stays' do
    text = '*bold* _italic_ -deleted- +inserted+ "link":https://example.org word[1]'

    assert_equal text, body(text)
  end
end
