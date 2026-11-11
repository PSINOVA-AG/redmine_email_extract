# frozen_string_literal: true

require_relative '../test_helper'

# MailFile and what all readers share (Readers::Base).
class MailFileTest < ActiveSupport::TestCase
  include RedmineEmailExtract::TestSupport

  # A reader whose files are given; counts how many of them were taken.
  class ListReader < RedmineEmailExtract::Readers::Base
    attr_reader :taken

    def initialize(io, candidates)
      super(io)
      @candidates = candidates
      @taken = 0
    end

    def part(filename, mime_type = 'application/pdf')
      build_part(filename: filename, mime_type: mime_type, data: 'x'.b, content_id: nil)
    end

    private

    def read_parts
      @candidates.lazy.map do |part|
        @taken += 1
        part
      end
    end
  end

  def reader(candidates, file_size: 10_000)
    ListReader.new(StringIO.new('x' * file_size), candidates)
  end

  def pdf(size)
    RedmineEmailExtract::MailPart.new(filename: 'offer.pdf', content_type: 'application/pdf', data: 'x'.b * size)
  end

  EML = "From: anna@example.org\r\nSubject: Hello\r\nContent-Type: text/plain\r\n\r\nText"

  test 'reads from an IO and leaves it open' do
    io = StringIO.new(EML)
    RedmineEmailExtract::MailFile.open(io, 'mail.eml') { |mail| assert_equal 'Hello', mail.subject }
    assert_not io.closed?
  end

  test 'closes a file it opened, also when the reading fails' do
    file = Tempfile.new(['mail', '.eml'])
    file.write(EML)
    file.close
    io = nil
    assert_raises(RuntimeError) do
      RedmineEmailExtract::MailFile.open(file.path, 'mail.eml') do |mail|
        io = mail.instance_variable_get(:@io)
        raise 'failed'
      end
    end
    assert io.closed?
  ensure
    file&.unlink
  end

  test 'lists at most MAX_PARTS files and reads no more of them' do
    limit = RedmineEmailExtract::Readers::Base::MAX_PARTS
    mail = reader(Array.new(limit + 50) { pdf(1) })

    assert_equal limit, mail.parts.size
    assert_equal limit + 1, mail.taken
  end

  test 'stops listing where the files get larger than the mail file allows' do
    factor = RedmineEmailExtract::Readers::Base::PART_SIZE_FACTOR
    mail = reader([pdf(400), pdf(400), pdf(400), pdf(1), pdf(1)], file_size: 1_000 / factor)

    assert_equal 2, mail.parts.size
    assert_equal 3, mail.taken
  end

  test 'signature files are not listed but count for the size' do
    signature = RedmineEmailExtract::MailPart.new(filename: 'smime.p7s', content_type: 'application/pkcs7-signature',
                                                  data: 'x'.b * 600)
    factor = RedmineEmailExtract::Readers::Base::PART_SIZE_FACTOR
    mail = reader([signature, pdf(300), pdf(300)], file_size: 1_000 / factor)

    assert_equal [300], mail.parts.map(&:size)
  end

  test 'file names lose control and bidirectional characters' do
    mail = reader([])

    assert_equal 'invoicefdp.exe', mail.part("invoice\u202Efdp.exe").filename
    assert_equal 'a b.pdf', mail.part("a\u2067\r\nb.pdf\u200F").filename
    assert_equal 'Grüße.pdf', mail.part("Grüße.pdf\u0000").filename
    assert_equal 'attachment.pdf', mail.part("\u202E\n").filename
  end

  test 'part_at accepts only valid positions' do
    mail = reader([pdf(1), pdf(2)])

    assert_equal 2, mail.part_at('1').size
    assert_nil mail.part_at(-1)
    assert_nil mail.part_at(2)
    assert_nil mail.part_at('x')
  end
end
