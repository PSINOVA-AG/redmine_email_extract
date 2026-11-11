# frozen_string_literal: true

module RedmineEmailExtract
  # Everything the page needs to insert a mail: its header, its messages and its files.
  class Extraction
    # The From / To / ... block as wiki text ('' if the mail has none of these).
    attr_reader :header

    # The messages of the mail, the newest first; one if it is not a thread.
    # A message is a list of pieces in reading order: a String is wiki text, an
    # Integer stands for the inline image with that index (see PartList::Entry),
    # shown at this place.
    attr_reader :messages

    # The files of the mail for the picker: [PartList::Entry]
    attr_reader :entries

    def initialize(mail)
      formatter = Formatter.new(mail)
      part_list = PartList.new(mail)
      text = InlineImages.mark(mail.text_body, mail.html_body) { |content_id| part_list.index_of(content_id) }

      @header = formatter.header
      @messages = ThreadSplitter.split(text).map { |message| pieces(message, formatter) }.reject(&:empty?)
      @entries = part_list.entries(image_placements)
    end

    private

    # Cuts a message at its image markers: ["text", 4, 5, "more text"]
    def pieces(message, formatter)
      message.split("\n", -1).chunk { |line| line.match?(InlineImages::MARKER_LINE) }.flat_map do |markers, lines|
        if markers
          lines.map { |line| line[InlineImages::MARKER_LINE, 1].to_i }
        else
          [formatter.body(lines.join("\n"))].compact_blank
        end
      end
    end

    # Where each image is shown first: { index => PartList::Placement }
    def image_placements
      placements = {}
      order = 0
      @messages.each_with_index do |message, number|
        message.grep(Integer).each do |index|
          placements[index] ||= PartList::Placement.new(number, order)
          order += 1
        end
      end
      placements
    end
  end
end
