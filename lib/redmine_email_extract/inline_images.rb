# frozen_string_literal: true

require 'cgi'

module RedmineEmailExtract
  # Finds where the inline images of a mail belong in its plain text.
  #
  # The plain text of a mail says nothing about images; only the HTML body shows
  # them (<img src="cid:...">). So the HTML is converted to text with a placeholder
  # for each image, and its lines are matched to the lines of the plain text: an
  # image belongs after the plain-text line that corresponds to the last HTML line
  # before it.
  module InlineImages
    IMAGE_TAG = /<img\b[^>]*?src\s*=\s*["']?cid:([^"'\s>]+)[^>]*>/i

    # Placeholder in the converted HTML; survives the conversion unchanged.
    PLACEHOLDER = /EMAILEXTRACTCID(\h+)X/

    # A line of text that stands for an image in the result of .mark.
    MARKER_LINE = /\A\u0001(\d+)\u0001\z/

    # Lines are compared by their letters and digits only: the plain text and the
    # converted HTML differ in spacing, punctuation and markup around links.
    MIN_PREFIX_LENGTH = 12
    # How many lines of text below the last matched line the next match is searched.
    # Very short lines ("Hi", "XML:") repeat often, so they only count close by.
    LOOKAHEAD = 40
    SHORT_LOOKAHEAD = 4
    MIN_KEY_LENGTH = 6

    def self.marker(number)
      "\u0001#{number}\u0001"
    end

    # Returns the text with a marker line at each place where an inline image is shown.
    # The block gets the Content-ID of an image and returns the number to put into
    # its marker, or nil to leave the image out.
    def self.mark(text, html)
      lines = text.to_s.split("\n", -1)
      images_after = Hash.new { |hash, line| hash[line] = [] }
      anchors(lines, html).each do |line, content_id|
        number = yield(content_id)
        images_after[line] << marker(number) if number
      end
      return text.to_s if images_after.empty?

      marked = images_after[-1].dup # images above the first line of text
      lines.each_with_index { |line, index| marked.push(line, *images_after[index]) }
      marked.join("\n")
    rescue StandardError => e
      RedmineEmailExtract.log_warning('inline images not placed', e)
      text.to_s
    end

    # [[index of the plain-text line the image comes after (-1: before all), content_id], ...]
    def self.anchors(lines, html)
      return [] if html.blank? || !html.match?(/cid:/i)

      keys = lines.map { |line| key(line) }
      # Empty lines do not count: where an image is, the plain text has several.
      # (Listed once, so that every HTML line costs at most its reach.)
      filled = keys.each_index.reject { |index| keys[index].empty? }
      search_from = 0
      last_match = -1
      html_lines(html).flat_map do |html_line|
        wanted = key(html_line.gsub(PLACEHOLDER, ' '))
        unless wanted.empty?
          reach = wanted.length >= MIN_KEY_LENGTH ? LOOKAHEAD : SHORT_LOOKAHEAD
          first = filled.bsearch_index { |index| index >= search_from } || filled.size
          found = filled[first, reach].find { |index| same_line?(keys[index], wanted) }
          if found
            last_match = paragraph_end(keys, found, wanted)
            search_from = last_match + 1
          end
        end
        html_line.scan(PLACEHOLDER).map { |(hex)| [last_match, [hex].pack('H*').force_encoding(Encoding::UTF_8)] }
      end
    end

    # The plain text may be wrapped where the HTML is not: a paragraph that is one
    # HTML line can be several lines of text. An image after it belongs after the
    # last of them, not into the paragraph, so the following lines are taken in as
    # long as together they are still the beginning of the HTML line.
    def self.paragraph_end(keys, index, wanted)
      joined = keys[index]
      while joined.length < wanted.length && keys[index + 1].present?
        joined += keys[index + 1]
        break unless wanted.start_with?(joined)

        index += 1
      end
      index
    end

    # The HTML as lines of text, with a placeholder where an image is shown.
    # (Content-IDs go in as hex: they contain characters a conversion could alter.)
    def self.html_lines(html)
      # Percent-decoding only: "+" is a valid character of a Content-ID, not a space.
      with_placeholders = html.gsub(IMAGE_TAG) do
        " EMAILEXTRACTCID#{CGI.unescapeURIComponent(Regexp.last_match(1)).unpack1('H*')}X "
      end
      Redmine::WikiFormatting.html_parser.to_text(with_placeholders).to_s.split("\n")
    end

    def self.key(line)
      line.downcase.gsub(/[^\p{L}\p{N}]/, '')
    end

    # The same line of the mail in both texts; one of them may be cut short by a
    # line break the other does not have.
    def self.same_line?(key, wanted)
      return true if key == wanted
      return false if key.length < MIN_PREFIX_LENGTH || wanted.length < MIN_PREFIX_LENGTH

      key.start_with?(wanted) || wanted.start_with?(key)
    end

    private_class_method :anchors, :paragraph_end, :html_lines, :key, :same_line?
  end
end
