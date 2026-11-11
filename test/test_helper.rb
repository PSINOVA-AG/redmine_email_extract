# frozen_string_literal: true

# Load the test helper of Redmine (plugins/redmine_email_extract/test -> redmine/test).
require File.expand_path('../../../test/test_helper', __dir__)

module RedmineEmailExtract
  module TestSupport
    # Stand-in for a mail reader (see RedmineEmailExtract::Readers::Base).
    FakeMail = Struct.new(:subject, :from, :from_address, :to, :cc, :date, :text_body, :html_body, :parts,
                          keyword_init: true) do
      def part_at(index)
        parts[index]
      end
    end

    def fake_mail(**attributes)
      FakeMail.new(text_body: '', parts: [], **attributes)
    end

    def image_part(filename, size: 20_000, content_id: nil, data: nil)
      RedmineEmailExtract::MailPart.new(
        filename: filename, content_type: 'image/png',
        data: data || (filename + ('x' * size)).b, content_id: content_id
      )
    end

    def file_part(filename, content_type: 'application/pdf')
      RedmineEmailExtract::MailPart.new(filename: filename, content_type: content_type, data: "file #{filename}".b)
    end
  end
end
