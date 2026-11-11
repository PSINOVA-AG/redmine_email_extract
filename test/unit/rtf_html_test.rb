# frozen_string_literal: true

require_relative '../test_helper'

class RtfHtmlTest < ActiveSupport::TestCase
  # HTML wrapped into RTF the way Outlook stores it (shortened).
  ENCAPSULATED = [
    '{\rtf1\ansi\ansicpg1252\fromhtml1 \fbidi \deff0{\fonttbl{\f0\fswiss Arial;}}',
    '{\*\htmltag19 <html>}',
    '{\*\htmltag50 <body>}\htmlrtf \lang1031 \htmlrtf0 ',
    '{\*\htmltag64 <p>}\htmlrtf {\htmlrtf0 Gr\\\'fc\\\'dfe, 5 \{x\} \\\\ y',
    '{\*\htmltag84 <img src="cid:image001.png@01DC">}\htmlrtf {\pict ignored}\htmlrtf0 ',
    '{\*\htmltag72 </p>}\htmlrtf \par}\htmlrtf0 ',
    '{\*\htmltag4 \par }',
    '{\*\htmltag58 </body>}',
    '{\*\htmltag27 </html>}}'
  ].join("\r\n")

  def extract(rtf)
    RedmineEmailExtract::RtfHtml.extract(rtf)
  end

  test 'recovers the HTML and leaves out the RTF-only parts' do
    html = extract(ENCAPSULATED)

    assert_equal "<html><body><p>Grüße, 5 {x} \\ y<img src=\"cid:image001.png@01DC\"></p>\r\n</body></html>", html
    assert_equal Encoding::UTF_8, html.encoding
  end

  test 'decodes characters of the code page and Unicode characters' do
    rtf = '{\rtf1\ansi\ansicpg1250\fromhtml1 {\*\htmltag64 <p>}' \
          "\\'9a\\'e8 costs 5 \\u8364?, \\u20013\\'3f and \\u-10179?\\u-8704? end}"

    assert_equal "<p>šč costs 5 €, 中 and \u{1F600} end", extract(rtf)
  end

  test 'control words that only begin like \par or \tab are left out' do
    assert_equal "<p>Hello\r\nWorld\tx", extract('{\rtf1\fromhtml1 {\*\htmltag64 <p>}\pard\plain Hello\par World\tab x}')
  end

  test 'skips as many replacement characters as \uc says, but never markup or control words' do
    html = '{\rtf1\fromhtml1 {\*\htmltag64 <p>}'

    assert_equal '<p>äö', extract(html + '\u228\u246?}')
    assert_equal '<p><b>€</b>', extract(html + '<b>\u8364 </b>}')
    assert_equal '<p>a€b€?c', extract(html + %q(\uc2 a\u8364\'80\'80b\uc0 \u8364?c}))
  end

  test 'uses Windows-1252 if the RTF names no or an unknown code page' do
    assert_equal '<p>ü', extract("{\\rtf1\\fromhtml1 {\\*\\htmltag64 <p>}\\'fc}")
    assert_equal '<p>ü', extract("{\\rtf1\\ansicpg99999\\fromhtml1 {\\*\\htmltag64 <p>}\\'fc}")
  end

  test 'RTF that was not made from HTML gives nil' do
    assert_nil extract('{\rtf1\ansi\fromtext Plain text\par}')
    assert_nil extract('{\rtf1\ansi\fromhtml1 no html tags here}')
  end

  test 'nil and empty input give nil' do
    assert_nil extract(nil)
    assert_nil extract('')
  end

  test 'an unfinished RTF-only part does not hang or raise' do
    assert_equal '<p>', extract('{\rtf1\fromhtml1 {\*\htmltag64 <p>}\htmlrtf never closed')
  end
end
