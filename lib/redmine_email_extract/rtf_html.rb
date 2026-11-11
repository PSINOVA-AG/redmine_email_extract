# frozen_string_literal: true

require 'strscan'

module RedmineEmailExtract
  # Recovers the HTML that Outlook wraps into RTF ("encapsulated HTML", marked by
  # \fromhtml): the HTML is kept in the RTF text, between RTF-only parts that are
  # marked with \htmlrtf ... \htmlrtf0.
  #
  # Follows the extraction in ruby-msg (Mapi::RTF.rtf2html, MIT licence), which does
  # not run on Ruby 4, and adds the decoding of characters: RTF is plain ASCII, other
  # characters are written as bytes of the document's code page (\'fc) or as Unicode
  # numbers (\uN followed by a replacement character for old readers).
  class RtfHtml
    FIRST_HTML_TAG = /(?=\{\\\*\\htmltag)/
    DEFAULT_CODE_PAGE = 1252

    # Returns the HTML as UTF-8, or nil if the RTF does not contain any.
    def self.extract(rtf)
      return nil if rtf.blank? || !rtf.include?('\fromhtml')

      new(rtf).extract
    end

    def initialize(rtf)
      @scanner = StringScanner.new(rtf.b)
      @encoding = encoding_of(rtf[/\\ansicpg(\d+)/, 1])
      @html = +''
      @bytes = +''.b # characters of the code page that are not decoded yet
      @replacement_count = 1 # see \uc
    end

    def extract
      return nil unless @scanner.scan_until(FIRST_HTML_TAG)

      skipped_tag = nil # number of an \mhtmltag whose matching \htmltag is left out
      until @scanner.eos?
        if @scanner.scan(/[{}\r\n]/)
          # RTF grouping and line breaks carry no content
        elsif @scanner.scan(/\\\*\\htmltag(\d+) ?/)
          if skipped_tag == @scanner[1]
            @scanner.scan_until(/\}/)
            skipped_tag = nil
          end
        elsif @scanner.scan(/\\\*\\mhtmltag(\d+) ?/)
          skipped_tag = @scanner[1]
        elsif @scanner.scan(/\\par(?![a-z]) ?/) # not \pard
          @bytes << "\r\n"
        elsif @scanner.scan(/\\tab(?![a-z]) ?/)
          @bytes << "\t"
        elsif @scanner.scan(/\\'(\h\h)/)
          @bytes << @scanner[1].hex.chr
        elsif @scanner.scan(/\\uc(\d+) ?/)
          # Number of replacement characters after each Unicode character. (Strictly
          # it applies to the current RTF group only; Outlook sets it once.)
          @replacement_count = @scanner[1].to_i
        elsif @scanner.scan(/\\u(-?\d+) ?/)
          unicode(@scanner[1].to_i)
        elsif @scanner.scan(/\\pntext/)
          @scanner.scan_until(/\}/)
        elsif @scanner.scan(/\\htmlrtf/)
          @scanner.scan_until(/\\htmlrtf0 ?/) || @scanner.terminate
        elsif @scanner.scan(/\\[a-z-]+\d* ?/)
          # any other RTF control word
        elsif @scanner.scan(/\\([{}\\])/)
          @bytes << @scanner[1]
        else
          @bytes << @scanner.getch
        end
      end
      decode_bytes
      @html.strip.empty? ? nil : @html
    end

    private

    # \uN: a UTF-16 code unit (numbers above 32767 are written as negative ones),
    # followed by replacement characters that are skipped. Characters beyond the
    # 16 bit range (emoji) come as two units, a surrogate pair.
    def unicode(number)
      decode_bytes
      unit = number % 0x10000
      if (0xD800..0xDBFF).cover?(unit)
        @high_surrogate = unit
      elsif (0xDC00..0xDFFF).cover?(unit)
        @html << [0x10000 + ((@high_surrogate - 0xD800) << 10) + (unit - 0xDC00)].pack('U') if @high_surrogate
        @high_surrogate = nil
      else
        @html << [unit].pack('U')
      end
      skip_replacement
    end

    # Skips the replacement characters after \uN (as many as \uc says): each is a
    # \'hh byte or a plain character. Writers often leave them out, so skipping stops
    # at what cannot be one: a control word, a brace - or "<", which in this RTF
    # starts HTML markup. Line breaks in between do not count.
    def skip_replacement
      @replacement_count.times do
        @scanner.skip(/[\r\n]+/)
        break unless @scanner.skip(/\\'\h\h|[^\\{}<\r\n]/)
      end
    end

    def decode_bytes
      return if @bytes.empty?

      @html << @bytes.force_encoding(@encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      @bytes = +''.b
    end

    def encoding_of(code_page)
      code_page = (code_page || DEFAULT_CODE_PAGE).to_i
      return Encoding::UTF_8 if code_page == 65_001

      Encoding.find("CP#{code_page}")
    rescue ArgumentError
      Encoding::Windows_1252
    end
  end
end
