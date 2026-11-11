# frozen_string_literal: true

module RedmineEmailExtract
  module Readers
    # Reads standard MIME mails (.eml) with the mail gem Redmine ships.
    class Eml < Base
      private

      def mail
        @mail ||= begin
          @io.rewind
          ::Mail.new(@io.read)
        end
      end

      def read_subject = clean(mail.subject)
      def read_from = address_header(:from)
      def read_to = address_header(:to)
      def read_cc = address_header(:cc)

      # The first address of the From header. The mail gem cannot parse every header
      # (then the field has no addresses), and a header may hold a name only.
      def read_from_address
        addresses = Array(mail[:from]&.addresses)
        clean(addresses.find { |address| address.to_s.include?('@') })
      rescue StandardError
        nil
      end

      # The display name of the address that read_from_address takes. A header without
      # any address is a name only (read_from shows it as it is, and so does this).
      def read_from_name
        address = from_addresses.find { |candidate| candidate.address.to_s.include?('@') }
        return address.display_name.to_s.sub(/\A"(.*)"\z/, '\1') if address

        from = read_from
        from unless from.to_s.include?('@')
      end

      # The addresses of the From header ([] for a header the gem cannot parse).
      def from_addresses
        Array(mail[:from]&.addrs)
      rescue StandardError
        []
      end

      # In UTC: DateTime#to_time keeps the sender's offset, and Redmine leaves such a
      # time unconverted (instead of showing it in the server's zone) for users
      # without a time zone of their own.
      def read_date
        mail.date&.to_time&.utc
      rescue StandardError
        nil # unparsable Date header
      end

      # The text of the mail, chosen like Redmine does for incoming mails: the plain
      # text parts, or the HTML parts converted to text if there is no plain text.
      # The "preferred part" setting for incoming mails reverses that order.
      def read_text_body
        types = %w[text/plain text/html]
        types.reverse! if Setting.mail_handler_preferred_body_part == 'html'
        types.each do |mime_type|
          text = clean(text_of(body_parts.select { |part| part.mime_type == mime_type }))
          return text if text.present?
        end
        # A mail that is not multipart and declares no usual text type is taken as it
        # is - but only if it is text: a mail can also consist of one attached file.
        whole_mail_text? ? clean(text_of([mail])) : ''
      end

      def whole_mail_text?
        return false if mail.multipart? || mail.attachment?

        mail.mime_type.nil? || mail.mime_type.start_with?('text/')
      end

      def read_html_body
        part = body_parts.find { |candidate| candidate.mime_type == 'text/html' }
        part && decode_text(part)
      rescue StandardError
        nil
      end

      # The parts that make up the body, i.e. all parts that are not attached files.
      def body_parts
        parts = mail.multipart? ? mail.all_parts : [mail]
        parts.reject(&:attachment?)
      end

      def text_of(parts)
        parts.map { |part| part.mime_type == 'text/html' ? html_to_text(decode_text(part)) : decode_text(part) }
             .join("\n")
      end

      # Decoded one by one, as Base#collect_parts asks for them. (The data is decoded
      # here and not lazily: whether a part is empty, and so skipped, must be known to
      # give it the same index in every request.)
      def read_parts
        attachments.lazy.filter_map do |attachment|
          # The bytes as they were sent. (#decoded would convert text files to UTF-8
          # according to their declared charset - wrongly, if it does not fit.)
          data = attachment.body.decoded.to_s.b
          next if data.empty?

          build_part(filename: attachment.filename, mime_type: attachment.mime_type,
                     data: data, content_id: attachment.content_id)
        rescue StandardError => e
          RedmineEmailExtract.log_warning('.eml attachment skipped', e)
          nil
        end
      end

      # A mail that consists of one attached file only is that file.
      def attachments
        mail.multipart? ? mail.attachments : [mail].select(&:attachment?)
      end

      def decode_text(part)
        Redmine::CodesetUtil.to_utf8(part.body.decoded, ::Mail::Utilities.pick_encoding(part.charset).to_s)
      end

      # '"Doe, John" <john@example.org>' -> 'Doe, John <john@example.org>'
      def address_header(name)
        field = mail[name]
        return nil if field.nil?

        decoded =
          begin
            field.decoded
          rescue StandardError
            field.value # malformed header: show it as it is
          end
        clean(decoded)&.gsub(/"([^"]*)"\s*</, '\1 <')
      end
    end
  end
end
