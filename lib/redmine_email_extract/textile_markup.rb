# frozen_string_literal: true

module RedmineEmailExtract
  # Mail text for Redmine's Textile (RedCloth3 as set up by
  # Redmine::WikiFormatting::Textile::Filter: hard breaks, no glyphs, the markdown
  # rule "---"). Escapes are HTML entities: RedCloth3 passes them through untouched.
  #
  # Escaped, because content would be lost or garbled:
  #   "p. 5" at the start of a block    block signatures p. h1.-h6. bq. fn1. (with
  #                                     modifiers such as "p(cls). " or "p>. ")
  #   "# x"                             numbered list - in a mail a heading or a number
  #   "=====", "{", "| x", "*", "###"   at the start of a line: Redmine's hard_break
  #                                     joins such a line to the line before
  #   "+++++", "~~~~~", "_____", "-"    separator lines (see SEPARATOR)
  #   "<pre>", "<code>", "<kbd>",       raw tags RedCloth3 keeps; they would take the
  #   "<notextile>", "<!-- -->"         rest of the text into a code block / hide it
  #   "x == 1 and y == 2"               "==...==" is notextile: the "==" vanish
  #   "!wichtig!", "!http://x/a.png!"   images
  #   "USB(3.0)"                        acronym: the parenthesis becomes a tooltip
  #   "&copy;"                          would be shown as the character
  #
  # Kept, because it does no harm: "* item" lists, "|a|b|" table rows that form a
  # table, "---" (a rule when it is a block of its own), inline *bold*, _italic_,
  # -deleted-, +inserted+, @code@ (only "@" after a word character is left, see
  # Markup), "text":url links and "word[1]" footnote references (shown as a small
  # "1") - mail clients write some of these as such, and escaping all of them would
  # make every mail unreadable in the text field.
  class TextileMarkup < Markup
    # Block signature at the start of a block (RedCloth3::BLOCK_RE, limited to the
    # tags RedCloth3 has a method for: textile_p, textile_h1..h6, textile_bq, textile_fn_).
    BLOCK_SIGNATURE = /\A((?:p|h[1-6]|bq|fn\d*)#{RedCloth3::A}#{RedCloth3::C})\.(?=(?::\S+)? )/

    # Lines Redmine's Textile::Filter#hard_break does not break before, i.e. joins
    # to the line before.
    NO_BREAK_BEFORE = /\A(?:[#*=]+(?:\s|\z)|[{|])/

    # A bulleted list item; stays a list. ("#" lists are escaped, see above.)
    LIST_ITEM = /\A\*+ /

    # A list marker with modifiers, as RedCloth3::LISTS_CONTENT_RE reads it.
    LIST_MARKER = /\A([#*]+)#{RedCloth3::A}#{RedCloth3::C} /

    TABLE_ROW = /\A\|.*\|\z/

    # Separator lines such as "+++++", "~~~~~", "_____" or a single "-": the hard
    # breaks are inline text for RedCloth3, so these characters start a <ins>, <sub>,
    # <em> ... span that runs to the next such line, and the characters vanish.
    # (Runs of "-" are safe: RedCloth3 never opens -deleted- before "--".)
    SEPARATOR = /\A(?:([+*_~^%])\1*|\?{2,}|-)\z/

    # RedCloth3 tags it keeps raw (ALLOWED_TAGS / OFFTAGS) and HTML comments.
    RAW_TAG = %r{<(?=/?(?:pre|code|kbd|notextile)\b|!--)}i

    # RedCloth3#no_textile: "==text==" after the line start or a blank.
    NOTEXTILE = /(?<=\A|\s)==(?=[^=].*?==(?:\s|\z))/

    # RedCloth3#pgl: "ABC(text)" becomes <abbr title="text">ABC</abbr>.
    ACRONYM = /\b([A-Z][A-Z0-9]+)\b\(/

    def label(text) = "*#{text}*"
    def image(filename) = "!#{filename}!"

    private

    def list_item?(text) = text.match?(LIST_ITEM)

    def escape_line(text, line, lines, index)
      text = inline(text)
      # "==" at the line start pairs with a "==" anywhere later, also in other lines.
      text = text.sub('==', '&#61;=') if text.match?(/\A==[^=]/)
      in_block = same_block_before(line, lines, index)
      text = text.sub(BLOCK_SIGNATURE, '\1&#46;') unless in_block
      numbered = text[LIST_MARKER, 1]&.include?('#')
      # (At the start of a block there is no line to join to.)
      joined = in_block && text.match?(NO_BREAK_BEFORE) && !list_item?(text) && !table_row?(lines, index)
      numbered || joined || text.match?(SEPARATOR) ? "#{entity(text[0])}#{text[1..]}" : text
    end

    def inline(text)
      # First, so that the entities written below are not escaped again
      # (RedCloth3#incoming_entities keeps "&name;" as an entity).
      text = text.gsub(/&(?=[#a-z0-9]+;)/i, '&amp;')
      text = text.gsub(RAW_TAG, '&lt;')
      text = text.gsub(NOTEXTILE, '&#61;=')
      text = text.gsub(RedCloth3::IMAGE_RE) { |image| image.sub('!', '&#33;') }
      text.gsub(ACRONYM, '\1&#40;')
    end

    # A row of a table that RedCloth3 forms: all lines up to the end of the block
    # are rows (RedCloth3::TABLE_RE needs the block to end with "|").
    def table_row?(lines, index)
      line = lines[index]
      lines[index..].take_while { |other| other.depth == line.depth && !other.empty? }
                    .all? { |other| other.text.match?(TABLE_ROW) }
    end

    def entity(char) = "&##{char.ord};"

    # Shown as "@" by RedCloth3, but not taken for a mention.
    def escape_mentions(text)
      text.gsub(MENTION_AT, '&#64;')
    end
  end
end
