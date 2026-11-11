# frozen_string_literal: true

require_relative '../test_helper'

# The header block and the choice of the markup; what each text formatting escapes
# is tested in plain_markup_test.rb, textile_markup_test.rb and common_mark_markup_test.rb.
class FormatterTest < ActiveSupport::TestCase
  include RedmineEmailExtract::TestSupport
  include Redmine::I18n

  setup do
    set_language_if_valid 'en'
  end

  def formatter(mail = fake_mail)
    RedmineEmailExtract::Formatter.new(mail)
  end

  def anna_mail
    fake_mail(from: 'Anna <anna@example.org>', to: 'Ben <ben@example.org>', subject: 'Invoice')
  end

  test 'common_mark header: bold labels, hard breaks, "<" escaped so the address stays' do
    with_settings text_formatting: 'common_mark' do
      assert_equal "**From:** Anna \\<anna@example.org>  \n" \
                   "**To:** Ben \\<ben@example.org>  \n" \
                   '**Subject:** Invoice', formatter(anna_mail).header
    end
  end

  test 'textile header: bold labels and plain line breaks' do
    with_settings text_formatting: 'textile' do
      assert_equal "*From:* Anna <anna@example.org>\n*To:* Ben <ben@example.org>\n*Subject:* Invoice",
                   formatter(anna_mail).header
    end
  end

  test 'header without text formatting: plain labels and line breaks' do
    with_settings text_formatting: '' do
      assert_equal "From: Anna <anna@example.org>\nTo: Ben <ben@example.org>\nSubject: Invoice",
                   formatter(anna_mail).header
    end
  end

  test 'an unknown text formatting is treated like none' do
    with_settings text_formatting: 'other_plugin' do
      assert_equal "From: Anna <anna@example.org>\nTo: Ben <ben@example.org>\nSubject: Invoice",
                   formatter(anna_mail).header
      assert_equal 'attachment:a.png', RedmineEmailExtract::Formatter.image_markup('a.png')
    end
  end

  test 'the header leaves out fields the mail does not have and shows the date' do
    mail = fake_mail(from: 'Anna', cc: '', date: Time.utc(2026, 11, 5, 9, 31))

    with_settings text_formatting: 'textile' do
      lines = formatter(mail).header.lines.map(&:strip)

      assert_equal 2, lines.size
      assert_equal '*From:* Anna', lines[0]
      assert_match(/\A\*Date:\* .*2026/, lines[1])
    end
  end

  test 'a mail without header fields has an empty header' do
    with_settings text_formatting: 'textile' do
      assert_equal '', formatter.header
      assert_equal '', formatter(fake_mail(subject: "\r\n\u202E")).header
    end
  end

  test 'header values are one line without control and bidi characters' do
    mail = fake_mail(from: "Anna\r\n*To:* boss@example.org", subject: "Pay\u0085now \u202Efdp.exe\u202C\tplease\u2028x")

    %w[textile common_mark].each do |format|
      with_settings text_formatting: format do
        lines = formatter(mail).header.split("\n")

        assert_equal 2, lines.size, format
        assert_includes lines[0], 'Anna *To:* boss@example.org', format
        assert_includes lines[1], 'Pay now fdp.exe please x', format
      end
    end
  end

  test 'header values get the escapes of the text formatting' do
    mail = fake_mail(subject: 'Question for @admin about {{include(Secret)}} &copy;')

    with_settings text_formatting: 'common_mark' do
      assert_equal '**Subject:** Question for &#64;admin about !{{include(Secret)}} \\&copy;', formatter(mail).header
    end
    with_settings text_formatting: 'textile' do
      assert_equal '*Subject:* Question for &#64;admin about !{{include(Secret)}} &amp;copy;', formatter(mail).header
    end
    with_settings text_formatting: '' do
      assert_equal "Subject: Question for @\u2060admin about !{{include(Secret)}} &copy;", formatter(mail).header
    end
  end

  test 'the body follows the text formatting' do
    text = "Hello\nsecond line\n\n# 1"

    with_settings text_formatting: 'common_mark' do
      assert_equal "Hello  \nsecond line\n\n\\# 1", formatter.body(text)
    end
    with_settings text_formatting: 'textile' do
      assert_equal "Hello\nsecond line\n\n&#35; 1", formatter.body(text)
    end
    with_settings text_formatting: '' do
      assert_equal "Hello\nsecond line\n\n# 1", formatter.body(text)
    end
  end

  test 'a blank body is empty' do
    with_settings text_formatting: 'common_mark' do
      assert_equal '', formatter.body(nil)
      assert_equal '', formatter.body(" \n\u00A0\n")
    end
  end

  test 'image markup follows the text formatting' do
    with_settings text_formatting: 'common_mark' do
      assert_equal '![](a.png)', RedmineEmailExtract::Formatter.image_markup('a.png')
    end
    with_settings text_formatting: 'textile' do
      assert_equal '!a.png!', RedmineEmailExtract::Formatter.image_markup('a.png')
    end
    with_settings text_formatting: '' do
      assert_equal 'attachment:a.png', RedmineEmailExtract::Formatter.image_markup('a.png')
    end
  end
end
