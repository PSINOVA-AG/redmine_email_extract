# frozen_string_literal: true

module RedmineEmailExtract
  # Splits the text of a reply / forward into its single messages, so that only the
  # newest one - or as many as wanted - can be inserted.
  #
  # Recognised separators, in the languages Outlook, Gmail and Apple Mail write them:
  #   -----Original Message-----  /  -----Ursprüngliche Nachricht-----
  #   Outlook header blocks:  From: ... Sent: ...  (Von: / Gesendet:, De: / Envoyé:, 发件人: / 发送时间:)
  #   "On <date>, <name> wrote:"  /  "Am <date> schrieb <name>:"  (may wrap onto two lines)
  module ThreadSplitter
    # Characters mail clients put around these lines: quote marks and the bold /
    # italic markers left by an HTML -> text conversion.
    DECORATION = /[\s>*_]*/

    ORIGINAL_MESSAGE_LINE = /\A#{DECORATION}-{2,}\s*(?:
      original\smessage | urspr(?:ü|ue)ngliche\snachricht | message\sd'origine | messaggio\soriginale |
      mensaje\soriginal | oorspronkelijk\sbericht | 原始邮件 | 原始郵件
    )\s*-{2,}/ix

    FROM_LINE = /\A#{DECORATION}(?:from|von|de|da|van|od|fr(?:å|a)n|发件人|寄件者|差出人)[*_]*\s*[:：]/i

    SENT_LINE = /\A#{DECORATION}(?:
      sent | date | gesendet | datum | envoy(?:é|e) | inviato | data | enviado | fecha | verzonden |
      wys(?:ł|l)ano | skickat | 发送时间 | 寄件日期 | 送信日時 | 日期
    )[*_]*\s*[:：]/ix

    # "On <date>, <name> wrote:" - German and Dutch put the name after the verb:
    # "Am <date> schrieb <name>:". The date (or time) always has a digit before the
    # verb; that tells the line from prose such as "On Monday the customer wrote
    # the following:".
    WROTE_LINE = /\A#{DECORATION}(?:on|am|le|il|el|op|dnia)\s.{0,200}?\d.{0,200}?\b(?:
      wrote | schrieb | a\s(?:é|e)crit | ha\sscritto | escribi(?:ó|o) | schreef | napisa(?:ł|l) | skrev
    )\b.{0,160}?:[*_]*\s*\z/ix

    # Parts of WROTE_LINE every matching line has, each cheap to test. The full
    # pattern takes up to about 1 ms on a line of 300 characters; most lines fail
    # one of these at once (a crafted text can pass them all, and then the line
    # length limit of #wrote_line? and the time limit of the request bound the cost).
    WROTE_LINE_PARTS = [
      /\A#{DECORATION}(?:on|am|le|il|el|op|dnia)\s/i,
      /:[*_]*\s*\z/,
      /\d/
    ].freeze

    # The end of a sentence: a line ending like this is not the first half of a
    # wrapped "On ... wrote:" line.
    SENTENCE_END = /[.!?][*_]*\s*\z/

    # Line of underscores or dashes that Outlook puts above a header block.
    RULE_LINE = /\A[\s*]*([_-])\1{15,}\s*\z/

    # A "From:" line starts a header block if a "Sent:" line follows this closely.
    HEADER_BLOCK_LINES = 4

    module_function

    # Splits the text of a mail into its messages, the newest first. Every older
    # message starts with its separator (e.g. its "From: ... Sent: ..." block);
    # rule lines around it are dropped. A mail without history gives one message.
    def split(text)
      lines = text.to_s.split("\n", -1)
      starts = message_starts(lines)
      starts.each_with_index.map do |start, number|
        following = starts[number + 1]
        message = lines[start...(following || lines.size)]
        # Drop what only separates the message from its neighbours.
        message.shift while number.positive? && message.any? && filler?(message.first)
        message.pop while following && message.any? && filler?(message.last)
        message.join("\n")
      end
    end

    # Indexes of the lines where the messages start; the first one is always 0.
    def message_starts(lines)
      separators = separator_lines(lines)
      # With nothing above the first separator - a forward without own text - the
      # forwarded mail itself is the newest message.
      separators.shift if separators.any? && lines[0...separators.first].all? { |line| filler?(line) }
      [0] + separators
    end

    # Blank lines and rule lines between two messages belong to neither.
    def filler?(line)
      line.strip.empty? || line.match?(RULE_LINE)
    end

    # Indexes of the lines where a quoted message starts (one per older message).
    def separator_lines(lines)
      separators = []
      index = 0
      while index < lines.size
        if lines[index].match?(ORIGINAL_MESSAGE_LINE)
          separators << index
          index += HEADER_BLOCK_LINES + 1 # the header block below it is not a second separator
        elsif header_block_start?(lines, index)
          rule_above = index.positive? && lines[index - 1].match?(RULE_LINE)
          separators << (rule_above ? index - 1 : index)
          index += HEADER_BLOCK_LINES
        elsif wrote_line?(lines, index)
          separators << index
          index += 2
        end
        index += 1
      end
      separators
    end

    def header_block_start?(lines, index)
      return false unless lines[index].match?(FROM_LINE)

      lines[index + 1, HEADER_BLOCK_LINES].to_a.any? { |line| line.match?(SENT_LINE) }
    end

    def wrote_line?(lines, index)
      line = lines[index]
      return false if line.strip.empty? || line.length > 300
      return true if wrote_line_text?(line)

      # "On Tue, 3 Nov 2026 at 10:15, John Doe <john@example.org>" with "wrote:" on the
      # next line. Two lines of prose can look alike when joined ("Am Montag haben wir
      # telefoniert." + "Herr Müller schrieb dazu:"), but a wrapped separator line
      # does not end a sentence where it breaks.
      return false if line.match?(SENTENCE_END)

      following = lines[index + 1].to_s
      following.length < 120 && wrote_line_text?("#{line} #{following.strip}")
    end

    # Same as text.match?(WROTE_LINE), only faster (see WROTE_LINE_PARTS).
    def wrote_line_text?(text)
      WROTE_LINE_PARTS.all? { |part| text.match?(part) } && text.match?(WROTE_LINE)
    end
  end
end
