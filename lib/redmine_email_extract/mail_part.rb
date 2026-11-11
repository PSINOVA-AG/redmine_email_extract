# frozen_string_literal: true

module RedmineEmailExtract
  # A file contained in a mail: an inline image or a regular attachment.
  class MailPart
    # Raster images only (no SVG: it can carry scripts when served inline), with the
    # file extension Redmine shows inline for each.
    IMAGE_TYPES = {
      'image/png' => 'png', 'image/jpeg' => 'jpg', 'image/gif' => 'gif', 'image/bmp' => 'bmp', 'image/webp' => 'webp'
    }.freeze

    attr_reader :filename, :content_type, :content_id

    # data:       the bytes of the file (String), or an object that returns them when
    #             called. A reader can then list the files of a mail without reading
    #             them: a picker thumbnail needs only one. Called once, when the bytes
    #             are first needed.
    # size:       the size in bytes while data is not read yet
    # content_id: the Content-ID an HTML body uses to show the file inline ("cid:..."), if any.
    def initialize(filename:, content_type:, data:, content_id: nil, size: nil)
      @filename = filename
      @content_type = content_type.to_s.downcase
      @data = data
      @size = size
      @content_id = content_id.to_s.delete('<>').presence
    end

    def data
      @data = @data.call if @data.respond_to?(:call)
      @data
    end

    def size
      @data.respond_to?(:call) && @size ? @size : data.bytesize
    end

    def digest
      @digest ||= Digest::SHA256.hexdigest(data)
    end

    def image?
      IMAGE_TYPES.key?(content_type)
    end

    # The extension Redmine shows inline for this type of image; nil for other files.
    def image_extension
      IMAGE_TYPES[content_type]
    end

    def inline_image?
      image? && content_id.present?
    end

    # S/MIME signature / envelope files are mail plumbing, not content for an issue.
    def signature?
      content_type.match?(%r{pkcs7|multipart/signed}) || filename.match?(/\Asmime\.p7[ms]\z/i)
    end
  end
end
