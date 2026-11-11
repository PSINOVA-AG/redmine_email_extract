# frozen_string_literal: true

require_relative '../test_helper'

# What Redmine's CommonMark would misread in a mail, and what it may keep.
class CommonMarkMarkupTest < ActiveSupport::TestCase
  def markup
    RedmineEmailExtract::CommonMarkMarkup.new
  end

  def body(text)
    markup.body(text)
  end

  test 'ordinary mail text passes through unchanged, with hard breaks' do
    lines = ['Hallo Jürgen, Grüße aus Köln', 'a < b and 1 > 0, <3', 'https://example.org/a_b?c=1 anna@example.org',
             'Re: #123, see C:\\Users\\anna', '50% - 60%, AT&T, (c) a@b.example']

    assert_equal lines.join("  \n"), body(lines.join("\n"))
  end

  test 'label, line break and image' do
    assert_equal '**From:**', markup.label('From:')
    assert_equal "  \n", markup.header_break
    assert_equal '![](a.png)', markup.image('a.png')
  end

  test 'paragraphs stay apart, without hard breaks before an empty line' do
    assert_equal "Hello  \nsecond line\n\nNew paragraph", body("Hello\nsecond line\n\nNew paragraph")
  end

  test '"<" that could start HTML or an autolink is escaped' do
    assert_equal 'Name \\<anna@example.org> \\<word> \\</div> \\<!-- c --> \\<?php',
                 body('Name <anna@example.org> <word> </div> <!-- c --> <?php')
  end

  test '">" after a URL is written as an entity, so that it is not part of the link' do
    assert_equal 'link\\<https://example.org/x&gt; and www.example.org&gt;',
                 body('link<https://example.org/x> and www.example.org>')
  end

  test 'setext underlines are escaped, a rule after an empty line stays' do
    assert_equal "Regards  \n\\--  \nAnna  \n\\---  \n\\===\n\n---", body("Regards\n-- \nAnna\n---\n===\n\n---")
  end

  test 'headings are escaped' do
    assert_equal "\\# Title  \n\\###### Six  \n#123 done  \n####### seven", body("# Title\n###### Six\n#123 done\n####### seven")
  end

  test 'code fences are escaped' do
    assert_equal "\\`\\`\\`ruby  \ncode  \n\\`\\`\\`", body("```ruby\ncode\n```")
    assert_equal "\\~~~~~~~~  \nafter", body("~~~~~~~~\nafter")
  end

  test 'definitions and alerts are escaped' do
    assert_equal "Text  \n\\[1]: http://x.example  \n\\[^1]: note\n> \\[!NOTE]",
                 body("Text\n[1]: http://x.example\n[^1]: note\n> [!NOTE]")
  end

  test 'remote images are escaped' do
    assert_equal 'see \\![logo](http://t.example/p.png) and \\![x][r]',
                 body('see ![logo](http://t.example/p.png) and ![x][r]')
  end

  test 'backslashes CommonMark would eat are doubled' do
    assert_equal '\\\\\\server\\share C:\\\\_temp C:\\Users\\anna end\\\\',
                 body('\\\\server\\share C:\\_temp C:\\Users\\anna end\\')
  end

  test 'text that looks like an entity is shown as written' do
    assert_equal '\\&copy; \\&#64; AT&T', body('&copy; &#64; AT&T')
  end

  test 'a list marker alone is escaped' do
    assert_equal "\\-  \n\\+  \n\\*", body("-\n+\n*")
  end

  test 'lists stay lists' do
    assert_equal "- a  \n* b  \n+ c  \n1. d  \n1) e", body("- a\n* b\n+ c\n1. d\n1) e")
  end

  test 'a line after a quote is not pulled into it' do
    assert_equal "> quoted\n\nmy reply", body("> quoted\nmy reply")
    assert_equal ">> old\n>\n> newer\n\nreply", body("> > old\n> newer\nreply")
  end

  test 'a line after a list item is a new paragraph unless it was indented' do
    assert_equal "- one  \nwrapped\n\nnext  \n1. num\n\nafter", body("- one\n  wrapped\nnext\n1. num\nafter")
    assert_equal "> - a\n>\n> b", body("> - a\n> b")
  end

  test 'indentation is removed, so that nothing becomes a code block' do
    assert_equal "Text\n\ncode  \n- nested", body("Text\n\n    code\n    - nested")
  end

  test 'inline markup and tables of mails stay' do
    assert_equal '*bold* _italic_ `code` ~~strike~~ [text](https://example.org)',
                 body('*bold* _italic_ `code` ~~strike~~ [text](https://example.org)')
    assert_equal "a | b  \n--|--  \n1 | 2", body("a | b\n--|--\n1 | 2")
  end

  test 'mentions become entities' do
    assert_equal '&#64;admin, (&#64;jsmith) mail a@b.example', body('@admin, (@jsmith) mail a@b.example')
  end
end
