# frozen_string_literal: true

module RedmineEmailExtract
  # Entry point for reading an e-mail file: picks the reader by file extension.
  #
  #   MailFile.open(path, 'offer.msg') { |mail| mail.subject }
  #   MailFile.open(io, 'offer.msg') { |mail| mail.subject }
  module MailFile
    READERS = {
      '.eml' => 'RedmineEmailExtract::Readers::Eml',
      '.msg' => 'RedmineEmailExtract::Readers::Msg'
    }.freeze

    def self.supported?(filename)
      READERS.key?(extension(filename))
    end

    # Yields a reader (see Readers::Base) and closes it afterwards. The mail is read
    # from a path (opened and closed here) or from an open, seekable IO in binary
    # mode, which stays open: whoever opened it closes it. That way the file is
    # closed even if a timeout interrupts the reading (see EmailExtractsController).
    def self.open(source, filename, &block)
      reader_class = READERS.fetch(extension(filename)) do
        raise ArgumentError, "unsupported e-mail file type: #{filename}"
      end
      return File.open(source, 'rb') { |file| read(reader_class, file, &block) } if source.is_a?(String)

      read(reader_class, source, &block)
    end

    def self.read(reader_class, io)
      reader = reader_class.constantize.new(io)
      begin
        yield reader
      ensure
        reader.close
      end
    end

    def self.extension(filename)
      File.extname(filename.to_s).downcase
    end
    private_class_method :read, :extension
  end
end
