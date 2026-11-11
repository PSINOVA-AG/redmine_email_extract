# frozen_string_literal: true

module RedmineEmailExtract
  # Mail text for Redmine's CommonMark (commonmarker with the GFM extensions table,
  # strikethrough, tagfilter, autolink, footnotes, tasklist and alerts; raw HTML
  # allowed, then sanitized; no hard breaks unless configured). Escapes are
  # backslashes: the most readable in the text field.
  #
  # Escaped, because content would be lost or garbled:
  #   "<word>", "</div>", "<!--", "<?"   raw HTML / comments vanish or swallow text
  #   "Name <a@b.c>"                     -> "Name \<a@b.c>": brackets stay, address linked
  #   "<http://x/y>"                     -> "\<http://x/y&gt;": the autolink extension
  #                                      would take ">" into the URL
  #   "---", "===" under a line          setext heading (signature "-- ", "---")
  #   "# Title"                          ATX heading
  #   "```", "~~~~~~~~"                  code fence: swallows everything after it
  #   "[1]: http://...", "[^1]: x"       link reference / footnote definition: vanish
  #   "[!NOTE]"                          alert, once the page quotes the line
  #   "![alt](url)", "![alt][ref]"       remote image (tracking pixel)
  #   "-", "+", "*" alone                empty list item: the character vanishes
  #   "\\server\share", "C:\_temp"       CommonMark takes the backslash for an escape
  #   "&copy;", "&#64;"                  would be shown as the character
  #
  # Kept, because it does no harm: "- item", "* item", "+ item", "1. item", "1) item"
  # lists (also "2026. was ..." at the start of a paragraph, shown as a list with
  # that number), pipe tables, "---" rules after an empty line, URLs and e-mail
  # addresses (linked), inline *bold*, _italic_, `code`, ~~strike~~ and [text](url) -
  # mail clients write emphasis like that, and escaping it would make every mail
  # unreadable in the text field.
  class CommonMarkMarkup < Markup
    # Bullet or ordered list item (CommonMark: up to 9 digits, "." or ")").
    LIST_ITEM = /\A(?:[-+*]|\d{1,9}[.)])[ \t]/

    # Backslash before ASCII punctuation (an escape in CommonMark) or at the line end
    # (a hard break).
    BACKSLASH = /\\(?=[!-\/:-@\[-`{-~]|\z)/

    # "&" that starts an entity reference.
    ENTITY = /&(?=#?[A-Za-z0-9]+;)/

    # "<" that can start raw HTML, a comment, a processing instruction or an autolink.
    TAG_START = %r{<(?=[A-Za-z/!?])}

    # ">" right after a URL; the autolink extension takes it into the URL.
    URL_END = %r{((?:\b[A-Za-z][A-Za-z0-9+.-]*://|\bwww\.)[^\s<>]*)>}

    ATX_HEADING = /\A\#{1,6}(?=[ \t]|\z)/
    BACKTICK_FENCE = /\A`{3,}/
    TILDE_FENCE = /\A~{3,}/
    # Link reference / footnote definition "[x]: ...", alert "[!NOTE]".
    DEFINITION = /\A\[(?:[^\]]+\]:|!\w+\])/
    SETEXT_UNDERLINE = /\A(?:=+|-+)\z/
    LONE_BULLET = /\A[-+*]\z/

    def label(text) = "**#{text}**"

    # Markdown joins lines; two trailing spaces keep a line break.
    def header_break = "  \n"

    def image(filename) = "![](#{filename})"

    private

    # "> a" followed by "b" would pull "b" into the quote.
    def lazy_quotes? = true

    def list_item?(text) = text.match?(LIST_ITEM)

    def escape_line(text, line, lines, index)
      text = inline(text)
      if text.match?(BACKTICK_FENCE)
        # All of them: two backticks left over would start an inline code span.
        text.sub(BACKTICK_FENCE) { |fence| fence.gsub('`') { '\\`' } }
      elsif text.match?(ATX_HEADING) || text.match?(TILDE_FENCE) || text.match?(DEFINITION) ||
            text.match?(LONE_BULLET) ||
            (text.match?(SETEXT_UNDERLINE) && same_block_before(line, lines, index))
        "\\#{text}"
      else
        text
      end
    end

    def inline(text)
      # First, so that the escapes written below are not escaped again.
      text = text.gsub(BACKSLASH) { '\\\\' }
      text = text.gsub(ENTITY) { '\\&' }
      text = text.gsub(TAG_START) { '\\<' }
      text = text.gsub('![') { '\\![' }
      text.gsub(URL_END) { "#{Regexp.last_match(1)}&gt;" }
    end

    # Two trailing spaces where a line of the mail goes on in the same paragraph;
    # not before an empty line or a change of the quote depth, where they would
    # only dangle.
    def join(lines)
      lines.each_with_index.map do |line, index|
        following = lines[index + 1]
        continues = following && following.depth == line.depth && !following.empty? && !line.empty?
        continues ? "#{line}  " : line.to_s
      end.join("\n")
    end

    # Shown as "@" by CommonMark, but not taken for a mention.
    def escape_mentions(text)
      text.gsub(MENTION_AT, '&#64;')
    end
  end
end
