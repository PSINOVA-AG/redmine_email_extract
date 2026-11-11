# frozen_string_literal: true

module RedmineEmailExtract
  module Readers
    # Reads Outlook message files (.msg) with the ruby-msg gem.
    class Msg < Base
      # MAPI properties ruby-msg has no name for.
      PR_SENDER_SMTP_ADDRESS = 0x5d01
      PR_SENT_REPRESENTING_SMTP_ADDRESS = 0x5d02
      PR_SENT_REPRESENTING_EMAIL_ADDRESS = 0x0065
      PR_INTERNET_CPID = 0x3fde
      PR_ATTACH_METHOD = 0x3705

      # Values of PR_ATTACH_METHOD: an embedded message (5) or OLE object (6).
      EMBEDDED_ATTACH_METHODS = [5, 6].freeze

      # Windows code pages (PR_INTERNET_CPID) -> Ruby encodings, for HTML bodies without a charset.
      CODE_PAGES = {
        65_001 => 'UTF-8', 1252 => 'Windows-1252', 1250 => 'Windows-1250', 28_591 => 'ISO-8859-1',
        28_605 => 'ISO-8859-15', 20_127 => 'US-ASCII', 936 => 'GBK', 54_936 => 'GB18030',
        950 => 'Big5', 932 => 'Shift_JIS', 949 => 'CP949'
      }.freeze

      private

      # The gem is loaded on first use: it is only needed for .msg files. It reads
      # from the IO given to the reader and leaves it open (MailFile.open closes it),
      # so a failure or a timeout while loading cannot leave a file handle behind.
      def msg
        @msg ||= begin
          require 'mapi/msg'
          Mapi::Log.level = Logger::FATAL # it logs a warning for every unknown property
          storage = Ole::Storage.new(@io)
          check_stream_sizes(storage.root)
          Mapi::Msg.new(storage.root)
        end
      end

      # In a crafted file many streams can share one chain of blocks, so that reading
      # each property and attachment reads the same bytes again: a small file then
      # makes ruby-msg read and keep gigabytes. In an honest file every stream has
      # blocks of its own, so the declared sizes together are smaller than the file.
      # Checked on the directory alone, before ruby-msg reads any stream (the readable
      # length of a stream never exceeds its declared size).
      def check_stream_sizes(root)
        total = 0
        pending = [root]
        until pending.empty?
          pending.pop.children.each { |entry| entry.file? ? total += entry.size : pending << entry }
        end
        raise MalformedFile, "streams of #{total} bytes in a file of #{@io.size}" if total > @io.size
      end

      def props
        msg.props
      end

      def read_subject = clean(props.subject)

      # Mails sent inside one Exchange organisation carry an X.500 address
      # ("/O=EXCHANGELABS/...") instead of an SMTP one; try the SMTP properties too.
      def read_from
        format_address(clean(props.sender_name), read_from_address)
      end

      # The name read_from shows (a mail without an SMTP address has only this).
      def read_from_name = props.sender_name

      def read_from_address
        # The sender first; the one it was sent for ("on behalf of") is the same
        # person in all but delegated mails.
        candidates = [props.sender_email_address, props[PR_SENDER_SMTP_ADDRESS],
                      props[PR_SENT_REPRESENTING_SMTP_ADDRESS], props[PR_SENT_REPRESENTING_EMAIL_ADDRESS]]
        candidates.map { |address| clean(address) }.find { |address| address.to_s.include?('@') }
      end

      def read_to = recipients(:to) || clean(props.display_to)
      def read_cc = recipients(:cc) || clean(props.display_cc)

      # In UTC: see Readers::Eml#read_date.
      def read_date
        (props.client_submit_time || props.message_delivery_time)&.to_time&.utc
      rescue StandardError
        nil
      end

      # The stored plain text; mails without one get the text of their HTML body.
      def read_text_body
        text = clean(stored(:body))
        return text if text.present?

        html_body ? html_to_text(html_body) : ''
      rescue StandardError => e
        RedmineEmailExtract.log_warning('.msg body extraction failed', e)
        ''
      end

      # The HTML is stored as such, or - usually - wrapped into compressed RTF.
      def read_html_body
        html = stored(:body_html)
        return RtfHtml.extract(props.body_rtf) if html.to_s.strip.empty?

        html = html.dup.force_encoding(Encoding::BINARY)
        charset = html[/<meta[^>]+charset=["']?([\w-]+)/i, 1] || CODE_PAGES[props[PR_INTERNET_CPID].to_i] || 'UTF-8'
        Redmine::CodesetUtil.to_utf8(html, charset)
      rescue StandardError => e
        RedmineEmailExtract.log_warning('.msg HTML extraction failed', e)
        nil
      end

      # A property as it is stored in the file. (The gem's own #body and #body_html
      # try conversions from RTF that do not run on Ruby 4.)
      def stored(name)
        value = props[name]
        value.respond_to?(:read) ? value.read : value
      end

      # The data of an attachment is a stream of the file; it is only read when the part
      # is used (a thumbnail needs one part). Its declared size decides whether it is
      # empty, so that a part has the same index whatever is read.
      def read_parts
        msg.attachments.lazy.filter_map do |attachment|
          next if embedded_object?(attachment)

          data = attachment.data
          # Rarely a string property; anything else is an embedded object, not a file.
          next unless data.is_a?(String) || data.is_a?(::RangesIO)

          size = data.is_a?(String) ? data.bytesize : data.size
          next if size.zero?

          build_part(filename: attachment.filename, mime_type: clean(attachment.props.attach_mime_tag),
                     data: data.is_a?(String) ? data.b : -> { read_stream(data) }, size: size,
                     content_id: attachment.props.attach_content_id)
        rescue StandardError => e
          RedmineEmailExtract.log_warning('.msg attachment skipped', e)
          nil
        end
      end

      def read_stream(io)
        io.rewind
        io.read.b
      end

      # Mails attached to the mail and other embedded OLE objects are not files and
      # are not supported.
      def embedded_object?(attachment)
        EMBEDDED_ATTACH_METHODS.include?(attachment.props[PR_ATTACH_METHOD])
      end

      def recipients(type)
        list = msg.recipients.select { |recipient| recipient.type == type }
        list.filter_map { |recipient| format_address(clean(recipient.name), clean(recipient.email)) }
            .join(', ').presence
      end
    end
  end
end
