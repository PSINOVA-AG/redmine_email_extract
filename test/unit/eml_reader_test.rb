# frozen_string_literal: true

require_relative '../test_helper'

class EmlReaderTest < ActiveSupport::TestCase
  PNG = "\x89PNG\r\n\x1A\n".b + ('pixel data'.b * 50)

  # Writes a mail to a temporary .eml file and yields a reader for it.
  def read(mail)
    file = Tempfile.new(['mail', '.eml'])
    file.binmode
    file.write(mail.to_s)
    file.close
    RedmineEmailExtract::MailFile.open(file.path, 'mail.eml') { |reader| yield reader }
  ensure
    file&.unlink
  end

  def plain_mail
    Mail.new do
      from    '"Example, Anna" <anna@example.org>'
      to      'Ben Example <ben@example.org>, support@example.org'
      cc      'carl@example.org'
      subject 'Rechnung für Müller'
      date    Time.utc(2026, 11, 5, 9, 31)
      body    "Hello Ben,\r\n\r\nplease check.\r\n"
    end
  end

  def mail_with_files
    png = PNG
    Mail.new do
      from    'anna@example.org'
      to      'ben@example.org'
      subject 'Files'
      text_part { body 'See the screenshot.' }
      html_part do
        content_type 'text/html; charset=UTF-8'
        body '<p>See the screenshot.</p><img src="cid:shot@example">'
      end
      add_file filename: 'screenshot.png', content: png
      add_file filename: 'offer.pdf', content: '%PDF-1.4 test'
      add_file filename: 'smime.p7s', content: 'signature'
    end.tap do |mail|
      mail.attachments['screenshot.png'].content_id = '<shot@example>'
      mail.attachments['smime.p7s'].content_type = 'application/pkcs7-signature'
    end
  end

  test 'supports .eml and .msg files only' do
    assert RedmineEmailExtract::MailFile.supported?('Mail.EML')
    assert RedmineEmailExtract::MailFile.supported?('mail.msg')
    assert_not RedmineEmailExtract::MailFile.supported?('mail.txt')
    assert_raises(ArgumentError) { RedmineEmailExtract::MailFile.open('x', 'mail.txt') { nil } }
  end

  test 'reads the header fields' do
    read(plain_mail) do |mail|
      assert_equal 'Rechnung für Müller', mail.subject
      assert_equal 'Example, Anna <anna@example.org>', mail.from
      assert_equal 'Ben Example <ben@example.org>, support@example.org', mail.to
      assert_equal 'carl@example.org', mail.cc
      assert_equal Time.utc(2026, 11, 5, 9, 31), mail.date
      # Redmine converts only UTC times into the zone of users without their own.
      assert mail.date.utc?
    end
  end

  test 'from_address is the lowercased address of the sender only' do
    read(plain_mail) { |mail| assert_equal 'anna@example.org', mail.from_address }

    {
      "From: Anna Example <Anna.Example@Example.ORG>\r\n" => 'anna.example@example.org',
      "From: \"Example, Anna\" <anna@example.org>, ben@example.org\r\n" => 'anna@example.org',
      "From: =?UTF-8?Q?M=C3=BCller?= <mueller@example.org>\r\n" => 'mueller@example.org',
      "From: ANNA@EXAMPLE.ORG\r\n" => 'anna@example.org'
    }.each do |header, address|
      read("#{header}Content-Type: text/plain\r\n\r\nText") do |mail|
        assert_equal address, mail.from_address, header
      end
    end
  end

  test 'from_address is nil without a usable From header' do
    read("Content-Type: text/plain\r\n\r\nText") { |mail| assert_nil mail.from_address }
    read("From: Anna Example\r\nContent-Type: text/plain\r\n\r\nText") do |mail|
      assert_nil mail.from_address
      assert_equal 'Anna Example', mail.from # still shown as it is
    end
  end

  test 'from_name is the name of the sender only' do
    read(plain_mail) { |mail| assert_equal 'Example, Anna', mail.from_name }

    {
      "From: =?UTF-8?Q?M=C3=BCller?= <mueller@example.org>\r\n" => 'Müller',
      "From: Anna Example <anna@example.org>, Ben <ben@example.org>\r\n" => 'Anna Example',
      # A header that holds no address is a name (and shown as such in From).
      "From: Anna Example\r\n" => 'Anna Example'
    }.each do |header, name|
      read("#{header}Content-Type: text/plain\r\n\r\nText") { |mail| assert_equal name, mail.from_name, header }
    end
  end

  test 'from_name is nil if the mail has only an address' do
    [
      "From: anna@example.org\r\n",
      "From: <anna@example.org>\r\n",
      # The address again as the name is no name.
      "From: \"Anna@Example.org\" <anna@example.org>\r\n",
      ''
    ].each do |header|
      read("#{header}Content-Type: text/plain\r\n\r\nText") { |mail| assert_nil mail.from_name, header }
    end
  end

  test 'the date is given in UTC' do
    read("Date: Thu, 05 Nov 2026 10:31:00 +0100\r\nContent-Type: text/plain\r\n\r\nText") do |mail|
      assert_equal Time.utc(2026, 11, 5, 9, 31), mail.date
      assert mail.date.utc?
    end
  end

  test 'keeps the bytes of attached text files' do
    csv = "Name;Ort\nM\xFCller;K\xF6ln\n".b
    mail = Mail.new do
      from 'anna@example.org'
      text_part { body 'See the list.' }
      add_file filename: 'list.csv', content: csv
    end
    mail.attachments['list.csv'].content_type = 'text/csv; charset=iso-8859-1'

    read(mail) do |reader|
      assert_equal ['list.csv'], reader.parts.map(&:filename)
      assert_equal csv, reader.parts.first.data
    end
  end

  test 'a mail that is one attached file is not taken as text' do
    pdf = "%PDF-1.4 \x00\x01 binary".b
    raw = "MIME-Version: 1.0\r\nContent-Type: application/pdf; name=offer.pdf\r\n" \
          "Content-Disposition: attachment; filename=offer.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\n" \
          "#{[pdf].pack('m')}"

    read(raw) do |mail|
      assert_equal '', mail.text_body
      assert_equal ['offer.pdf'], mail.parts.map(&:filename)
      assert_equal pdf, mail.parts.first.data
    end
  end

  test 'reads the text with unix line endings' do
    read(plain_mail) do |mail|
      assert_equal "Hello Ben,\n\nplease check.", mail.text_body
      assert_nil mail.html_body
      assert_empty mail.parts
    end
  end

  test 'missing header fields are nil' do
    # Written by hand: the mail gem adds a Date header when it builds a mail.
    read("MIME-Version: 1.0\r\nContent-Type: text/plain\r\n\r\nOnly text") do |mail|
      assert_nil mail.subject
      assert_nil mail.from
      assert_nil mail.cc
      assert_nil mail.date
      assert_equal 'Only text', mail.text_body
    end
  end

  test 'reads the contained files without signature files' do
    read(mail_with_files) do |mail|
      assert_equal %w[screenshot.png offer.pdf], mail.parts.map(&:filename)

      image, pdf = mail.parts
      assert image.image?
      assert image.inline_image?
      assert_equal 'shot@example', image.content_id
      assert_equal PNG, image.data
      assert_not pdf.image?
      assert_equal 'application/pdf', pdf.content_type
    end
  end

  test 'reads the HTML body' do
    read(mail_with_files) do |mail|
      assert_includes mail.html_body, 'cid:shot@example'
      assert_equal 'See the screenshot.', mail.text_body
    end
  end

  test 'file names lose control and bidirectional characters' do
    raw = "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n" \
          "--b\r\nContent-Type: text/plain\r\n\r\nText\r\n" \
          "--b\r\nContent-Type: application/octet-stream\r\n" \
          "Content-Disposition: attachment; filename=\"=?UTF-8?Q?invoice=E2=80=AEfdp.exe?=\"\r\n\r\ndata\r\n" \
          "--b--\r\n"

    read(raw) { |mail| assert_equal ['invoicefdp.exe'], mail.parts.map(&:filename) }
  end

  test 'part_at accepts only valid positions' do
    read(mail_with_files) do |mail|
      assert_equal 'offer.pdf', mail.part_at(1).filename
      assert_equal 'offer.pdf', mail.part_at('1').filename
      assert_nil mail.part_at(-1)
      assert_nil mail.part_at(99)
      assert_nil mail.part_at('abc')
      assert_nil mail.part_at(nil)
    end
  end
end
