# frozen_string_literal: true

module RedmineEmailExtract
  # Mail text for Redmine without text formatting (NullFormatter): the text is
  # HTML-escaped and shown as it is - blank line = paragraph, line break = <br>.
  # Nothing is misread, so only macros and mentions need care (see Markup).
  class PlainMarkup < Markup
    # Redmine links "attachment:name" in every formatting, so the place of the image
    # in the mail stays visible and the image is a click away.
    def image(filename) = "attachment:#{filename}"

    private

    # An entity would be shown as it is here ("&#64;"), so the mention is broken by
    # an invisible WORD JOINER after the "@" instead: MENTION_PATTERN needs a login
    # character, punctuation, a blank or the line end right after it.
    def escape_mentions(text)
      text.gsub(MENTION_AT, "@#{WORD_JOINER}")
    end
  end
end
