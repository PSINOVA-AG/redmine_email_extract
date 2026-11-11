# frozen_string_literal: true

require_relative '../test_helper'

class ExtractionTest < ActiveSupport::TestCase
  include RedmineEmailExtract::TestSupport
  include Redmine::I18n

  # A reply: the newest message shows new.png, the quoted older one old.png and a logo.
  HTML = <<~HTML
    <html><body>
      <p>Here is the new screenshot:</p>
      <p><img src="cid:new@example"></p>
      <p>Regards, Anna</p>
      <p><b>From:</b> Ben Example<br><b>Sent:</b> Monday, 2 November 2026 10:15<br><b>Subject:</b> Invoice</p>
      <p>The old screenshot:</p>
      <p><img src="cid:old@example"></p>
      <p>Regards, Ben</p>
      <p><img src="cid:logo@example"></p>
    </body></html>
  HTML

  TEXT = <<~TEXT.chomp
    Here is the new screenshot:

    Regards, Anna
    ________________________________
    From: Ben Example
    Sent: Monday, 2 November 2026 10:15
    Subject: Invoice

    The old screenshot:

    Regards, Ben
  TEXT

  setup do
    set_language_if_valid 'en'
  end

  def thread_mail
    fake_mail(subject: 'Invoice', text_body: TEXT, html_body: HTML, parts: [
                image_part('logo.png', size: 2_000, content_id: 'logo@example'),
                image_part('old.png', content_id: 'old@example'),
                image_part('new.png', content_id: 'new@example'),
                file_part('offer.pdf')
              ])
  end

  def extract(mail)
    with_settings text_formatting: 'textile' do
      RedmineEmailExtract::Extraction.new(mail)
    end
  end

  test 'gives the header and the messages as pieces of text and images' do
    extraction = extract(thread_mail)

    assert_equal '*Subject:* Invoice', extraction.header
    assert_equal [
      ['Here is the new screenshot:', 2, 'Regards, Anna'],
      ["From: Ben Example\nSent: Monday, 2 November 2026 10:15\nSubject: Invoice\n\nThe old screenshot:", 1,
       'Regards, Ben', 0]
    ], extraction.messages
  end

  test 'lists the files with the message their place in the text belongs to' do
    entries = extract(thread_mail).entries

    assert_equal %w[offer.pdf new.png old.png logo.png], entries.map { |entry| entry.part.filename }
    assert_equal [0, 0, 1, 1], entries.map(&:message)
    assert_equal [false, false, false, true], entries.map(&:small)
  end

  test 'a mail without HTML has text only, and its images belong to the newest message' do
    mail = fake_mail(text_body: TEXT, parts: [image_part('a.png', content_id: 'a@example')])
    extraction = extract(mail)

    assert_equal 2, extraction.messages.size
    assert(extraction.messages.flatten.all?(String))
    assert_equal [0], extraction.entries.map(&:message)
  end

  test 'a mail without thread is one message' do
    extraction = extract(fake_mail(text_body: "Hello\n\nRegards"))

    assert_equal [["Hello\n\nRegards"]], extraction.messages
    assert_equal '', extraction.header
  end

  test 'an empty mail has no messages' do
    assert_empty extract(fake_mail).messages
  end
end
