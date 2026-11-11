# frozen_string_literal: true

module RedmineEmailExtract
  # The files of a mail as the picker offers them: each file once, the newest first,
  # with what the picker needs to suggest which ones to attach.
  class PartList
    # index:    position of the file in mail.parts (identifies it in later requests)
    # message:  thread message the file belongs to (0 = newest)
    # small:    true for images that are probably signature logos or icons
    Entry = Struct.new(:index, :part, :message, :small, keyword_init: true)

    # Where an image is shown: in which message, and its running position in the mail.
    Placement = Struct.new(:message, :order)

    def initialize(mail)
      @parts = mail.parts
      # Files with the same content (a logo repeated in every reply) count as one
      # file: the first of them.
      @listed = @parts.each_with_index.uniq { |part, _index| part.digest }
      index_by_digest = @listed.to_h { |part, index| [part.digest, index] }
      @index_by_content_id = @parts.select(&:inline_image?).to_h { |part| [part.content_id, index_by_digest[part.digest]] }
    end

    # The listed file that an inline image with this Content-ID stands for.
    def index_of(content_id)
      @index_by_content_id[content_id]
    end

    # placements: { index => Placement } for the images that are shown in the text
    #
    # Order:
    #   1. regular attachments (PDF, Office files ...): they belong to the mail itself
    #   2. inline images, by thread message (newest first) and position in it; images
    #      that are not shown anywhere go to the end of the newest message
    def entries(placements = {})
      rows = @listed.map do |part, index|
        placement = placements[index]
        entry = Entry.new(index: index, part: part, message: placement ? placement.message : 0,
                          small: part.image? && part.size < SMALL_IMAGE_SIZE)
        [sort_key(part, index, placement), entry]
      end
      rows.sort_by(&:first).map(&:last)
    end

    private

    def sort_key(part, index, placement)
      if !part.inline_image? then [0, 0, index]
      elsif placement then [1, placement.message, placement.order]
      else [1, 0, Float::INFINITY, index]
      end
    end
  end
end
