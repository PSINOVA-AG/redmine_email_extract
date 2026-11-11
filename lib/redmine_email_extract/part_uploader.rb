# frozen_string_literal: true

module RedmineEmailExtract
  # Stores files of a mail as regular Redmine uploads: unattached attachments of the
  # user, identified by a token - exactly what the upload form produces. Redmine
  # attaches them when the form is saved. Uploads that are never attached (the form is
  # left without saving) stay until `rake redmine:attachments:prune` deletes them,
  # like any upload of Redmine's own forms.
  # Size and extension rules of Redmine apply as for any upload.
  class PartUploader
    # Redmine's upload form takes at most 10 files at a time (attachments.js), and the
    # page never asks for more in one request.
    MAX_FILES = 10

    # attachment: the saved Attachment; part: the MailPart it was made from;
    # index: position of the part in mail.parts
    Upload = Struct.new(:attachment, :part, :index)

    attr_reader :uploads, :errors

    # The positions a client asked for, as Integers: each once ("1" and "01" are the
    # same file), without what is not a position, at most MAX_FILES.
    def self.indexes(indexes)
      Array(indexes).filter_map { |index| Integer(index, exception: false) }
                    .select { |index| index >= 0 }.uniq.first(MAX_FILES)
    end

    def initialize(mail, author)
      @mail = mail
      @author = author
      @uploads = []
      @errors = []
      @used_filenames = Set.new
    end

    # indexes: positions in mail.parts, as given by PartList; invalid ones are ignored
    def upload(indexes)
      self.class.indexes(indexes).each do |index|
        part = @mail.part_at(index)
        next if part.nil?

        attachment = build_attachment(part)
        if attachment.save
          @uploads << Upload.new(attachment, part, index)
        else
          @errors << "#{attachment.filename}: #{attachment.errors.full_messages.join(', ')}"
        end
      end
      self
    end

    private

    # Redmine shows an attached image in the text only if its name ends like this
    # (see Redmine::WikiFormatting::InlineAttachmentsScrubber).
    INLINE_IMAGE_NAME = /\.(?:avif|bmp|gif|jpg|jpeg|jpe|png|webp)\z/i

    def build_attachment(part)
      attachment = Attachment.new(file: StringIO.new(part.data))
      attachment.author = @author
      attachment.content_type = part.content_type
      assign_unique_filename(attachment, upload_filename(part))
      attachment
    end

    # Images are shown in the text by file name. Outlook names them image001.png,
    # image002.png ... in every mail, so they get the date of the mail as a prefix to
    # stay distinct on an issue, lose characters that would break the markup and get
    # an extension Redmine recognises (inline images may come without any).
    # Other files keep their name.
    def upload_filename(part)
      return part.filename unless part.image?

      filename = "#{image_prefix(part)}_#{part.filename.gsub(/[^\w.-]/, '_')}"
      extension = part.image_extension
      filename = "#{filename}.#{extension}" if extension && !filename.match?(INLINE_IMAGE_NAME)
      filename
    end

    def image_prefix(part)
      date = @mail.date && @author.convert_time_to_user_timezone(@mail.date)
      date ? date.strftime('%Y%m%d-%H%M') : part.digest[0, 8]
    end

    # Two different files of one mail can have the same name: "image.png", "image-2.png".
    # Compared as Redmine stores them: Attachment#filename= replaces some characters,
    # so "a:b.pdf" and "a_b.pdf" become the same name.
    def assign_unique_filename(attachment, filename)
      attachment.filename = filename
      filename = attachment.filename
      counter = 1
      until @used_filenames.add?(attachment.filename.downcase)
        counter += 1
        attachment.filename = filename.sub(/(\.[^.]*)?\z/) { "-#{counter}#{Regexp.last_match(1)}" }
      end
    end
  end
end
