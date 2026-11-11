# frozen_string_literal: true

module RedmineEmailExtract
  # Writes mail text as wiki text of one text formatting (subclass per formatting).
  #
  # The text of a mail is not written for Redmine: whatever in it the formatting
  # would misread, swallow or execute is escaped, and only that - the inserted text
  # stays readable and editable in the text field. What the subclasses share:
  #
  # - Lines are normalised: trailing blanks, runs of empty lines and indentation go
  #   (indented lines would become code blocks; Redmine's MailHandler does the same).
  #   Nested list items therefore become items of one flat list.
  # - Lines starting with ">" stay quotes (inline replies); their markers are written
  #   as ">>" without blanks. The page adds its own "> " levels in front of all lines.
  # - "{{name}}" of an existing macro gets Redmine's "!" escape: it is shown, not run.
  #   Redmine expands macros in every formatting, before the formatting itself.
  # - "@name" does not mention anybody (Redmine::Acts::Mentionable scans the saved
  #   text in every formatting and notifies the user of that login).
  # - A paragraph that is only "{{toc}}" (Redmine replaces it by a table of contents
  #   in every formatting) gets an invisible WORD JOINER in front.
  #
  # Deliberately not escaped: Redmine links ("#123", "r12", "[[Page]]", "user:x") -
  # Redmine's own MailHandler keeps them too and they only add links.
  class Markup
    # Spaces, tabs and non-breaking spaces (Outlook fills empty lines with the latter).
    # (Single-quoted: the escapes are read by the regular expressions it goes into.)
    BLANKS = '[ \t\u00A0]'

    # Quote markers in front of a line ("> > text"), and the rest of the line.
    QUOTED_LINE = /\A((?:#{BLANKS}*>)*)(.*)\z/o

    # An "@" that Redmine would take for a mention: MENTION_PATTERN accepts "@login"
    # after any non-word character. E-mail addresses (a@b.c) do not count.
    MENTION_AT = /(?<!\w)@/

    # The start of a macro call, see ApplicationHelper::MACROS_RE.
    MACRO_START = /\{\{(\w+)/

    # A paragraph Redmine replaces by a table of contents (ApplicationHelper::TOC_RE).
    TOC_LINE = /\A\{\{[<>]?toc\}\}\z/i

    # Invisible, and no word or line break: keeps patterns from matching what follows.
    WORD_JOINER = "\u2060"

    # Header values must be one line: a crafted Subject must not fake header lines or
    # start line markup. Bidi overrides would let a value look like something else.
    LINE_BREAKS = /[\p{Cc}\u2028\u2029]+/
    BIDI_CONTROLS = /[\u202A-\u202E\u2066-\u2069]/

    # A line of the mail: its quote depth, its text without indentation, and whether
    # the text was indented (a wrapped continuation of a list item).
    Line = Struct.new(:depth, :text, :indented) do
      def empty?
        text.empty?
      end

      # An empty line outside quotes: separates paragraphs.
      def paragraph_break?
        depth.zero? && empty?
      end

      def to_s
        return text if depth.zero?

        empty? ? '>' * depth : "#{'>' * depth} #{text}"
      end
    end

    # The markup for a text formatting (Setting.text_formatting). An unknown
    # formatting (e.g. of another plugin) is treated like none.
    def self.for(format)
      case format.to_s
      when 'textile' then TextileMarkup.new
      when 'common_mark' then CommonMarkMarkup.new
      else PlainMarkup.new
      end
    end

    # "From:" as a label of the header block.
    def label(text) = text

    # Line break between the lines of the header block (one paragraph).
    def header_break = "\n"

    # Inline image that refers to an attachment of the same container by file name.
    def image(_filename) = raise NotImplementedError

    # A header value as plain text of one line (see LINE_BREAKS), without markup
    # escapes; also used for the values that fill issue fields (FieldMapping).
    def self.one_line(text)
      text.to_s.gsub(BIDI_CONTROLS, '').gsub(LINE_BREAKS, ' ').squeeze(' ').strip
    end

    # A header field value, as text inside a line.
    def value(text)
      protect(inline(self.class.one_line(text)))
    end

    # Mail text as wiki text ('' if it has none).
    def body(text)
      lines = separate(parse(text))
      return '' if lines.empty?

      rendered = lines.each_with_index.map do |line, index|
        text = line.text
        unless line.empty?
          text = "#{WORD_JOINER}#{text}" if text.match?(TOC_LINE)
          text = escape_line(text, line, lines, index)
        end
        Line.new(line.depth, text, line.indented)
      end
      protect(join(rendered))
    end

    private

    def parse(text)
      lines = text.to_s.gsub(/\r\n?/, "\n").split("\n").map do |raw|
        markers, rest = raw.sub(/#{BLANKS}+\z/o, '').match(QUOTED_LINE).captures
        # One blank after the quote markers belongs to them, more are indentation.
        rest = rest.sub(/\A#{BLANKS}/o, '') unless markers.empty?
        Line.new(markers.count('>'), rest.sub(/\A#{BLANKS}+/o, ''), rest.match?(/\A#{BLANKS}/o))
      end
      # One empty line is enough to separate paragraphs.
      lines = lines.chunk_while { |a, b| a.empty? && b.empty? && a.depth == b.depth }.map(&:first)
      lines.shift while lines.first&.paragraph_break?
      lines.pop while lines.last&.paragraph_break?
      lines
    end

    # Lines the formatting would join to the line before although they are not
    # joined in the mail ("lazy continuation"): an empty line goes between them.
    #   - a line after a list item, unless it was indented (then it continues the item)
    #   - a line after a quote of more levels (lazy_quotes?)
    def separate(lines)
      in_item = false
      lines.each_with_object([]) do |line, result|
        previous = result.last
        if previous && !previous.empty? && !line.empty? &&
           ((lazy_quotes? && previous.depth > line.depth) ||
            (in_item && previous.depth == line.depth && !line.indented && !list_item?(line.text)))
          result << Line.new(line.depth, '', false)
        end
        in_item = list_item?(line.text) ||
                  (in_item && !line.empty? && line.indented && previous&.depth == line.depth)
        result << line
      end
    end

    def lazy_quotes? = false
    def list_item?(_text) = false

    # The text of a line (not empty) with what the formatting would misread escaped.
    # lines[index] is the line; the neighbours tell where blocks start.
    def escape_line(text, _line, _lines, _index) = inline(text)

    # Escapes inside a line (also used for header values).
    def inline(text) = text

    def join(lines) = lines.join("\n")

    # Steps on the finished text, valid in every formatting.
    def protect(text)
      escape_mentions(escape_macros(text))
    end

    # "!{{name}}" shows a macro instead of running it. Only existing macros are caught
    # by Redmine (for other names "!" would stay visible); "{{macro(1)}}" refers to a
    # caught macro of the text and is escaped as well. Every "{{name" is escaped, also
    # without its closing "}}": that may follow in a later piece of the page.
    def escape_macros(text)
      text.gsub(MACRO_START) { |start| macro?(Regexp.last_match(1)) ? "!#{start}" : start }
    end

    def macro?(name)
      name.casecmp?('macro') || Redmine::WikiFormatting::Macros.available_macros.key?(name.downcase.to_sym)
    end

    def escape_mentions(_text) = raise NotImplementedError

    # The line before, if it belongs to the same block (same quote depth, not empty).
    def same_block_before(line, lines, index)
      previous = index.positive? ? lines[index - 1] : nil
      previous if previous && previous.depth == line.depth && !previous.empty?
    end
  end
end
