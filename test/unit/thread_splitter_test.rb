# frozen_string_literal: true

require_relative '../test_helper'

class ThreadSplitterTest < ActiveSupport::TestCase
  def split(text)
    RedmineEmailExtract::ThreadSplitter.split(text)
  end

  test 'a mail without history is one message' do
    result = split("Hello,\n\nplease check the invoice.\n\nRegards\nAnna")

    assert_equal ["Hello,\n\nplease check the invoice.\n\nRegards\nAnna"], result
  end

  test 'cuts at an English Outlook header block' do
    result = split(<<~MAIL)
      Thanks, that works.

      Anna

      From: Ben Example <ben@example.org>
      Sent: Monday, 2 November 2026 10:15
      To: Anna Example <anna@example.org>
      Subject: RE: Invoice

      Please try again.
    MAIL

    assert_equal 2, result.size
    assert_equal "Thanks, that works.\n\nAnna", result.first
  end

  test 'cuts at a German Outlook header block and drops the rule line above it' do
    result = split(<<~MAIL)
      Danke, das passt.
      ________________________________
      Von: Ben Beispiel <ben@example.org>
      Gesendet: Montag, 2. November 2026 10:15
      An: Anna Beispiel <anna@example.org>
      Betreff: AW: Rechnung

      Bitte nochmal versuchen.
    MAIL

    assert_equal "Danke, das passt.", result.first
    assert_equal 2, result.size
  end

  test 'recognises header blocks with bold markers and a date line' do
    result = split("Ok.\n\n*Von:* Ben\n*Datum:* 2.11.2026\n*An:* Anna\n\nAlt")

    assert_equal 'Ok.', result.first
    assert_equal 2, result.size
  end

  test 'recognises a Chinese header block' do
    result = split("好的。\n\n发件人: Ben <ben@example.org>\n发送时间: 2026年11月6日 16:04\n收件人: Anna\n\n旧消息")

    assert_equal '好的。', result.first
  end

  test 'cuts at an original message line and counts it once with its header block' do
    result = split(<<~MAIL)
      See below.

      -----Original Message-----
      From: Ben <ben@example.org>
      Sent: Monday, 2 November 2026 10:15
      Subject: Invoice

      Old text
    MAIL

    assert_equal 'See below.', result.first
    assert_equal 2, result.size
  end

  test 'cuts at a German original message line' do
    result = split("Siehe unten.\n\n-----Ursprüngliche Nachricht-----\nVon: Ben\nGesendet: Montag\n\nAlt")

    assert_equal 'Siehe unten.', result.first
    assert_equal 2, result.size
  end

  test 'cuts at an "On ... wrote:" line' do
    result = split("Fine with me.\n\nOn Tue, 3 Nov 2026 at 10:15, Ben Example <ben@example.org> wrote:\n> Is this ok?")

    assert_equal 'Fine with me.', result.first
    assert_equal 2, result.size
  end

  test 'cuts at an "On ... wrote:" line that wraps onto a second line' do
    result = split("Fine.\n\nOn Tue, 3 Nov 2026 at 10:15, Ben Example <ben@example.org>\nwrote:\n> Is this ok?")

    assert_equal 'Fine.', result.first
  end

  test 'cuts at a German "Am ... schrieb ...:" line' do
    result = split("Passt.\n\nAm 03.11.2026 um 10:15 schrieb Ben Beispiel <ben@example.org>:\n> Ist das ok?")

    assert_equal 'Passt.', result.first
  end

  test 'a sentence that merely contains such words is not a separator' do
    result = split("Am Montag schrieb ich die Rechnung.\nOn Friday he wrote the report.\n\nAnna")

    assert_equal 1, result.size
  end

  test 'prose that looks like an "On ... wrote:" line is not a separator' do
    [
      "Hallo,\n\nAm Dienstag schrieb mir Herr Meier wegen der Rechnung.\nBitte folgende Punkte prüfen:\n- Betrag",
      "Hallo,\n\nAm Montag haben wir telefoniert.\nHerr Müller schrieb dazu:\n- Termin",
      "Hello,\n\nOn Monday the customer wrote the following:\n- amount"
    ].each do |text|
      assert_equal [text], split(text), text
    end
  end

  test 'returns every message of a thread, each older one with its separator' do
    result = split(<<~MAIL)
      Newest

      From: A
      Sent: Monday

      Second
      ________________________________
      From: B
      Sent: Sunday

      Third
      ----------------------------------------
    MAIL

    assert_equal [
      'Newest',
      "From: A\nSent: Monday\n\nSecond",
      "From: B\nSent: Sunday\n\nThird\n----------------------------------------\n"
    ], result
  end

  test 'the messages together contain every line of text' do
    text = "One\n\nFrom: A\nSent: Monday\n\nTwo\n\nOn Friday, B <b@example.org> wrote:\n> Three"

    assert_equal text.split("\n").reject(&:empty?), split(text).flat_map { |message| message.split("\n") }.reject(&:empty?)
  end

  test 'a forward without own text is one message' do
    text = "From: Ben <ben@example.org>\nSent: Monday\nSubject: Invoice\n\nThe forwarded text"

    assert_equal [text], split(text)
  end

  test 'a forward of a thread without own text starts with the forwarded mail' do
    result = split("\nFrom: Ben\nSent: Monday\n\nForwarded\n\nFrom: Carl\nSent: Sunday\n\nOlder")

    assert_equal ["\nFrom: Ben\nSent: Monday\n\nForwarded", "From: Carl\nSent: Sunday\n\nOlder"], result
  end

  test 'a line starting with From: alone is not a separator' do
    result = split("From: the warehouse we got three boxes.\nPlease book them.\n\nAnna")

    assert_equal 1, result.size
  end

  test 'keeps formatting characters at the end of the newest message' do
    result = split("Regards\n*Anna Example*\n\nFrom: Ben\nSent: Monday\n\nOld")

    assert_equal "Regards\n*Anna Example*", result.first
  end

  test 'the quick checks before the "wrote:" pattern do not change which lines match' do
    splitter = RedmineEmailExtract::ThreadSplitter
    words = ['On ', 'Am ', 'ON ', 'le ', 'dnia ', '> ', '*', '_', ' ', "\t", '1', '03.11.2026', 'Anna', ',', '.',
             'wrote', 'schrieb', 'a écrit', 'napisał', ':', ': ', '**', 'x']
    random = Random.new(42)
    lines = Array.new(20_000) { Array.new(random.rand(1..12)) { words.sample(random: random) }.join }
    lines += ['On Tue, 3 Nov 2026 at 10:15, John Doe <john@example.org> wrote:',
              '> **Am 03.11.2026 um 10:15 schrieb Ben Beispiel:** ', 'On Monday the customer wrote the following:']

    matching = lines.select { |line| line.match?(splitter::WROTE_LINE) }
    assert matching.size > 3, 'the sample contains matching lines'
    assert_equal matching, lines.select { |line| splitter.wrote_line_text?(line) }
  end

  test 'handles empty and nil text' do
    assert_equal [''], split(nil)
    assert_equal [''], split('')
  end
end
