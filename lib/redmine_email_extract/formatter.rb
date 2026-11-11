# frozen_string_literal: true

module RedmineEmailExtract
  # Turns a mail into wiki text for the configured text formatting (none, Textile or
  # CommonMark; see Markup and its subclasses for what each one escapes): a block
  # with From / To / Cc / Date / Subject, and the text of its messages.
  class Formatter
    include Redmine::I18n

    # Inline image that refers to an attachment of the same container by file name
    # (stored attachment names of images only contain [\w.-]).
    def self.image_markup(filename)
      Markup.for(Setting.text_formatting).image(filename)
    end

    # mail: a reader (see Readers::Base)
    def initialize(mail)
      @mail = mail
      @markup = Markup.for(Setting.text_formatting)
    end

    # The block with From / To / Cc / Date / Subject ('' if the mail has none of them),
    # one paragraph with a line per field.
    def header
      fields = {
        email_extract_from: @mail.from,
        email_extract_to: @mail.to,
        email_extract_cc: @mail.cc,
        email_extract_date: (@mail.date && format_time(@mail.date)),
        email_extract_subject: @mail.subject
      }
      fields.transform_values { |value| @markup.value(value) }.compact_blank
            .map { |label, value| "#{@markup.label("#{l(label)}:")} #{value}" }
            .join(@markup.header_break)
    end

    # Text of the mail - all of it or one message of a thread - as wiki text.
    def body(text)
      @markup.body(text)
    end
  end
end
