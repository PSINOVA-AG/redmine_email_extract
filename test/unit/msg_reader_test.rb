# frozen_string_literal: true

require_relative '../test_helper'
require 'mapi/msg'

class MsgReaderTest < ActiveSupport::TestCase
  # Builds a .msg in memory the way Outlook stores one: an OLE compound file with a
  # stream per property (__substg1.0_<tag><type>), the fixed-size properties in
  # __properties_version1.0, and a storage per recipient and per attachment.
  class MsgBuilder
    def initialize
      @entries = Hash.new { |hash, storage| hash[storage] = { streams: {}, properties: [] } }
      @entries[nil]
      @recipients = 0
      @attachments = 0
    end

    def string(tag, value, storage = nil)
      @entries[storage][:streams][format('__substg1.0_%04X001F', tag)] = value.encode('UTF-16LE').b
      self
    end

    def binary(tag, value, storage = nil)
      @entries[storage][:streams][format('__substg1.0_%04X0102', tag)] = value.b
      self
    end

    def long(tag, value, storage = nil)
      @entries[storage][:properties] << property(tag, 0x0003, [value, 0].pack('VV'))
      self
    end

    def time(tag, time)
      filetime = (time.to_r * 10_000_000).to_i + 116_444_736_000_000_000
      @entries[nil][:properties] << property(tag, 0x0040, [filetime].pack('Q<'))
      self
    end

    # type: 1 To, 2 Cc
    def recipient(name, email, type: 1)
      storage = format('__recip_version1.0_#%08X', @recipients)
      @recipients += 1
      string(0x3001, name, storage).string(0x39fe, email, storage).long(0x0c15, type, storage)
    end

    # method: PR_ATTACH_METHOD (1 a file, 5 an embedded message)
    def attachment(filename, data, mime_type: 'application/octet-stream', content_id: nil, method: 1)
      storage = format('__attach_version1.0_#%08X', @attachments)
      @attachments += 1
      string(0x3707, filename, storage).string(0x370e, mime_type, storage).binary(0x3701, data, storage)
      string(0x3712, content_id, storage) if content_id
      long(0x3705, method, storage)
    end

    # share_data: the attachments after the first get the blocks of the first one,
    # as a crafted file can declare them: the data is stored once, read many times.
    def to_s(share_data: false)
      io = StringIO.new(+''.b)
      Ole::Storage.open(io) do |ole|
        @entries.each do |storage, entry|
          ole.dir.mkdir(storage) if storage
          header = storage ? 8 : 32
          entry[:streams].merge('__properties_version1.0' => ("\0" * header).b + entry[:properties].join)
                         .each { |name, data| ole.file.open([storage, name].compact.join('/'), 'w') { |f| f.write(data) } }
        end
        share_blocks(ole) if share_data
      end
      io.string
    end

    private

    def property(tag, type, value)
      [(tag << 16) | type, 6].pack('VV') + value
    end

    def share_blocks(ole)
      first, *others = ole.root.children.select { |dirent| dirent.name.start_with?('__attach') }
                          .map { |dirent| dirent / '__substg1.0_37010102' }
      others.each do |data|
        data.first_block = first.first_block
        data.size = first.size
      end
    end
  end

  def read(data, &block)
    RedmineEmailExtract::MailFile.open(StringIO.new(data), 'mail.msg', &block)
  end

  # Writes the mail to a temporary file and yields a reader for it.
  def read_file(data, &block)
    file = Tempfile.new(['mail', '.msg'])
    file.binmode
    file.write(data)
    file.close
    RedmineEmailExtract::MailFile.open(file.path, 'mail.msg', &block)
  ensure
    file&.unlink
  end

  def plain_msg
    MsgBuilder.new
              .string(0x0037, 'Rechnung für Müller')
              .string(0x0c1a, 'Anna Example')
              .string(0x0c1f, '/O=EXCHANGELABS/OU=EXCHANGE/CN=RECIPIENTS/CN=ANNA')
              .string(0x5d01, 'Anna.Example@Example.org')
              .string(0x1000, "Hello Ben,\r\n\r\nplease check.\r\n")
              .time(0x0039, Time.utc(2026, 11, 5, 9, 31))
              .recipient('Ben Example', 'ben@example.org')
              .recipient('support@example.org', 'support@example.org')
              .recipient('Carl Example', 'carl@example.org', type: 2)
  end

  PNG = "\x89PNG\r\n\x1A\n".b + ('pixel data'.b * 500)

  def msg_with_files
    plain_msg.attachment('image001.png', PNG, mime_type: 'image/png', content_id: 'image001.png@01DC')
             .attachment('offer.pdf', '%PDF-1.4 test', mime_type: 'application/pdf')
             .attachment('Forwarded mail', 'not a file', method: 5)
             .attachment('empty.txt', '', mime_type: 'text/plain')
             .attachment('notes.txt', 'some notes', mime_type: 'text/plain')
  end

  test 'reads the header fields' do
    read(plain_msg.to_s) do |mail|
      assert_equal 'Rechnung für Müller', mail.subject
      assert_equal 'Anna Example <Anna.Example@Example.org>', mail.from
      assert_equal 'Ben Example <ben@example.org>, support@example.org', mail.to
      assert_equal 'Carl Example <carl@example.org>', mail.cc
      # ruby-ole converts the FILETIME with floats: off by microseconds
      assert_equal Time.utc(2026, 11, 5, 9, 31), mail.date.round
      assert mail.date.utc?
      assert_equal "Hello Ben,\n\nplease check.", mail.text_body
    end
  end

  test 'from_address prefers the sender and falls back to the SMTP properties' do
    x500 = '/O=EXCHANGELABS/OU=EXCHANGE/CN=RECIPIENTS/CN=ANNA'
    {
      { 0x0c1f => 'Anna@Example.org', 0x5d01 => 'other@example.org' } => 'anna@example.org',
      { 0x0c1f => x500, 0x5d01 => 'Sender@Example.org', 0x5d02 => 'boss@example.org' } => 'sender@example.org',
      { 0x0c1f => x500, 0x5d02 => 'Boss@Example.org', 0x0065 => 'other@example.org' } => 'boss@example.org',
      { 0x0c1f => x500, 0x0065 => 'Boss@Example.org' } => 'boss@example.org',
      { 0x0c1f => x500, 0x0065 => x500 } => nil
    }.each do |addresses, expected|
      builder = MsgBuilder.new.string(0x0c1a, 'Anna Example')
      addresses.each { |tag, address| builder.string(tag, address) }

      read(builder.to_s) do |mail|
        if expected
          assert_equal expected, mail.from_address, addresses.inspect
        else
          assert_nil mail.from_address, addresses.inspect
        end
      end
    end
  end

  test 'from_name is the name of the sender only' do
    read(plain_msg.to_s) { |mail| assert_equal 'Anna Example', mail.from_name }

    # Without an SMTP address the name is all there is (and From shows it).
    read(MsgBuilder.new.string(0x0c1a, 'Anna Example').string(0x0c1f, '/O=EXCHANGELABS/CN=ANNA').to_s) do |mail|
      assert_equal 'Anna Example', mail.from_name
      assert_equal 'Anna Example', mail.from
    end
  end

  test 'from_name is nil if the mail has only an address' do
    # Outlook gives the address as the name when it knows no name.
    read(MsgBuilder.new.string(0x0c1a, 'Anna@Example.org').string(0x0c1f, 'anna@example.org').to_s) do |mail|
      assert_nil mail.from_name
      assert_equal 'anna@example.org', mail.from_address
    end
    read(MsgBuilder.new.string(0x0c1f, 'anna@example.org').to_s) { |mail| assert_nil mail.from_name }
  end

  test 'reads the contained files without embedded messages and empty files' do
    read(msg_with_files.to_s) do |mail|
      assert_equal %w[image001.png offer.pdf notes.txt], mail.parts.map(&:filename)

      image, pdf, notes = mail.parts
      assert image.inline_image?
      assert_equal 'image001.png@01DC', image.content_id
      assert_equal PNG, image.data
      assert_equal 'application/pdf', pdf.content_type
      assert_equal '%PDF-1.4 test', pdf.data
      assert_equal 'some notes', notes.data
      assert_equal 'notes.txt', mail.part_at('2').filename
    end
  end

  test 'reads the data of a file only when it is used' do
    read_file(msg_with_files.to_s) do |mail|
      image, pdf = mail.parts
      assert_equal PNG.bytesize, image.size
      assert_equal PNG, image.data
      @pdf = pdf
    end

    # Not read before the file was closed: it cannot be read any more.
    assert_equal 13, @pdf.size
    assert_raises(IOError) { @pdf.data }
  end

  test 'file names lose control and bidirectional characters' do
    data = MsgBuilder.new
                     .attachment("invoice\u202Efdp.exe", 'x', mime_type: 'application/octet-stream')
                     .attachment("two\r\nlines\t.pdf", 'x', mime_type: 'application/pdf')
                     .attachment("\u2066\u0007", 'x', mime_type: 'application/pdf')
                     .to_s
    read(data) do |mail|
      assert_equal ['invoicefdp.exe', 'two lines .pdf', 'attachment.pdf'], mail.parts.map(&:filename)
    end
  end

  test 'rejects a file whose streams share their blocks' do
    builder = MsgBuilder.new.string(0x0037, 'Crafted')
    builder.attachment('first.bin', 'x' * 20_000)
    20.times { |number| builder.attachment("copy#{number}.bin", 'y') }
    data = builder.to_s(share_data: true)

    error = assert_raises(RedmineEmailExtract::Readers::Base::MalformedFile) { read(data, &:subject) }
    assert_match(/streams of \d+ bytes in a file of #{data.bytesize}/, error.message)
  end

  test 'closes the file when it cannot be read' do
    io = nil
    assert_raises(StandardError) do
      read_file(("no OLE file\n" * 100).b) do |mail|
        io = mail.instance_variable_get(:@io)
        mail.subject
      end
    end
    assert io.closed?
  end

  test 'closes the file when the time limit interrupts the reading' do
    io = nil
    assert_raises(Timeout::Error) do
      Timeout.timeout(0.1) do
        read_file(plain_msg.to_s) do |mail|
          io = mail.instance_variable_get(:@io)
          mail.subject
          sleep 1
        end
      end
    end
    assert io.closed?
  end
end
