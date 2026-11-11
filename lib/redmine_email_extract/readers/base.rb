# frozen_string_literal: true

module RedmineEmailExtract
  module Readers
    # Common interface of the mail readers. Everything is read lazily and memoized,
    # so a request only pays for what it uses (a thumbnail needs only #parts).
    #
    #   subject, from, to, cc   String or nil (for display: "Name <address>", ...)
    #   from_name               name of the sender only, or nil (also when the mail
    #                           gives the address again as the name)
    #   from_address            e-mail address of the sender only, lowercased, or nil
    #   date                    Time or nil
    #   text_body               plain text of the mail ('' if none)
    #   html_body               HTML of the mail, or nil
    #   parts                   [MailPart] contained files, without signature files
    #                           (at most MAX_PARTS, see #collect_parts)
    #
    # What has been read stays available after #close; what has not (e.g. the data of
    # a part a reader reads lazily) cannot be read any more.
    #
    # Subclasses implement the private read_* methods; read_parts returns an
    # Enumerable that may produce the parts lazily.
    class Base
      # The file is not what an honest mail file can be (see Msg#check_stream_sizes).
      class MalformedFile < StandardError; end

      # More files than a picker can sensibly offer; the rest of them is not listed.
      MAX_PARTS = 200

      # The files of a mail cannot be larger than the file that contains them:
      # base64 and quoted-printable decoding shrink, a .msg stores them as they are.
      # A mail attached to a mail (message/rfc822) is listed together with its own
      # files, which counts these twice; the factor leaves room for a few such levels.
      PART_SIZE_FACTOR = 4

      # Bidirectional overrides, isolates and marks change the order in which a name
      # is shown: "invoice\u202Efdp.exe" is displayed as "invoiceexe.pdf".
      BIDI_CONTROLS = /[\u202A-\u202E\u2066-\u2069\u200E\u200F\u061C]/

      # io: the mail file, open in binary mode and seekable (see MailFile.open)
      def initialize(io)
        @io = io
        @memo = {}
      end

      def close; end

      def subject = memoize(:subject) { read_subject }
      def from = memoize(:from) { read_from }

      # Mail programs often repeat the address as the name ("anna@example.org
      # <anna@example.org>"); that is no name.
      def from_name
        memoize(:from_name) do
          name = clean(read_from_name).presence
          name unless name&.casecmp?(from_address.to_s)
        end
      end

      # Lowercased so that it can be compared with the addresses of Redmine users.
      def from_address = memoize(:from_address) { read_from_address.to_s.downcase.presence }
      def to = memoize(:to) { read_to }
      def cc = memoize(:cc) { read_cc }
      def date = memoize(:date) { read_date }
      def text_body = memoize(:text_body) { read_text_body.to_s }
      def html_body = memoize(:html_body) { read_html_body.presence }
      def parts = memoize(:parts) { collect_parts(read_parts) }

      # The part at a position of #parts given by a client; nil unless it is a valid one.
      def part_at(index)
        index = Integer(index, exception: false)
        parts[index] if index && index >= 0
      end

      private

      # Memoizes nil results too (a missing Cc should not be looked up again).
      def memoize(name)
        @memo.fetch(name) { @memo[name] = yield }
      end

      # Takes the parts one by one, so that a reader does not decode what is not used.
      # Listing stops (instead of failing) at MAX_PARTS and where the files would get
      # larger than PART_SIZE_FACTOR times the mail file: the text of the mail is
      # still worth inserting. Both limits only depend on the file, so a part has the
      # same index in every request.
      def collect_parts(candidates)
        budget = PART_SIZE_FACTOR * @io.size
        parts = []
        candidates.each do |part|
          budget -= part.size
          next if part.signature? && !budget.negative?

          if budget.negative? || parts.size == MAX_PARTS
            RedmineEmailExtract.log_warning("only the first #{parts.size} files listed")
            break
          end
          parts << part
        end
        parts
      end

      # Normalises a string from a mail: valid UTF-8, no NULs (Outlook pads strings
      # with them), Unix line endings, no surrounding whitespace.
      def clean(value)
        return nil if value.nil?

        text = value.to_s.dup
        text = Redmine::CodesetUtil.to_utf8(text, 'UTF-8') unless text.encoding == Encoding::UTF_8 && text.valid_encoding?
        text.delete("\u0000").gsub(/\r\n?/, "\n").strip
      end

      # "Name <address>", or whichever of the two is known.
      def format_address(name, email)
        email = nil unless email.to_s.include?('@')
        return "#{name} <#{email}>" if email && name.present? && name != email

        email || name.presence
      end

      def html_to_text(html)
        clean(Redmine::WikiFormatting.html_parser.to_text(html))
      end

      # data and size: see MailPart#initialize
      def build_part(filename:, mime_type:, data:, content_id:, size: nil)
        MailPart.new(
          filename: part_filename(filename, mime_type),
          content_type: part_content_type(mime_type, filename),
          data: data,
          size: size,
          content_id: clean(content_id)
        )
      end

      # A file name is shown in the picker and becomes the name of an upload: one line,
      # displayed in the order of its characters (see BIDI_CONTROLS).
      def part_filename(name, mime_type)
        name = clean(name)&.gsub(BIDI_CONTROLS, '')&.gsub(/\p{Cc}+/, ' ')&.strip
        return name if name.present?

        extension = Redmine::MimeType::MIME_TYPES[mime_type.to_s.downcase].to_s.split(',').first
        "attachment.#{extension || 'bin'}"
      end

      # The declared type, or the one Redmine derives from the file name if none is declared.
      def part_content_type(mime_type, filename)
        mime_type = mime_type.to_s.downcase.strip
        mime_type = Redmine::MimeType.of(filename.to_s).to_s if mime_type.blank? || mime_type == 'application/octet-stream'
        mime_type.presence || 'application/octet-stream'
      end
    end
  end
end
