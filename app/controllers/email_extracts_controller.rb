# frozen_string_literal: true

# JSON endpoints behind the "insert e-mail" control of the upload form (email_extract.js).
#
# All actions work on an e-mail file the current user has uploaded but not yet saved
# with an issue. It is identified by its upload token, like in Redmine's own forms.
#
#   POST /email_extract        token            text of the mail and a list of its files
#   GET  /email_extract/part   token, index     one image of the mail (picker thumbnail)
#   POST /email_extract/attach token, indexes   store files of the mail as uploads
class EmailExtractsController < ApplicationController
  # Seconds a request may spend reading a mail file. A mail of several MB takes well
  # under one; see #read_mail for why there is a limit at all.
  EXTRACTION_TIMEOUT = 5

  before_action :require_login
  before_action :find_uploaded_mail

  # fields:   values of the mail for the issue fields the plugin settings map them to,
  #           [{ target:, value: }] (see FieldMapping#fills); the page fills the
  #           empty ones of these fields that its form has
  # header:   the From / To / ... block as wiki text
  # messages: the messages of the thread, the newest first (one if no thread). Each is
  #           a list of pieces: wiki text, or the index of an image shown at that place.
  #           The page inserts the header and as many messages as the user wants.
  # parts:    the files of the mail, see #entry_json
  # sent_by_me: the current user sent the mail; the page then does not insert it as a
  #           quote at first (see #sent_by_current_user?)
  def create
    # Settings and custom fields come from the database: read before the time limit.
    mapping = RedmineEmailExtract::FieldMapping.current
    result = read_mail do |mail|
      extraction = RedmineEmailExtract::Extraction.new(mail)
      {
        fields: mapping.fills(mail),
        header: extraction.header,
        messages: extraction.messages,
        entries: extraction.entries, # their data is read: PartList compares it
        from_address: mail.from_address
      }
    end
    return if performed?

    render json: {
      fields: result[:fields],
      header: result[:header],
      messages: result[:messages],
      parts: result[:entries].map { |entry| entry_json(entry) },
      sent_by_me: sent_by_current_user?(result[:from_address])
    }
  end

  def part
    part = read_mail do |mail|
      found = mail.part_at(params[:index])
      found.data if found&.image? # read it while the file is open
      found
    end
    return if performed?
    return head(:not_found) unless part&.image?

    # The bytes come from the mail, i.e. from outside: never let a browser treat them
    # as anything but the image type they were checked against.
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Content-Security-Policy'] = "default-src 'none'; sandbox"
    expires_in 1.hour
    send_data part.data, type: part.content_type, disposition: 'inline', filename: part.filename
  end

  def attach
    indexes = RedmineEmailExtract::PartUploader.indexes(params[:indexes])
    # Only the reading is time-limited (see #read_mail): saving the uploads must not
    # be interrupted halfway. The reader keeps what it has read after it is closed,
    # so read here what the uploader uses.
    mail = read_mail do |reader|
      indexes.each { |index| reader.part_at(index)&.data }
      reader.date
      reader
    end
    return if performed?

    uploader = RedmineEmailExtract::PartUploader.new(mail, User.current).upload(indexes)
    render json: { uploads: uploader.uploads.map { |upload| upload_json(upload) }, errors: uploader.errors }
  rescue StandardError => e
    render_failure(e)
  end

  private

  def find_uploaded_mail
    @uploaded_mail = Attachment.find_by_token(params[:token])
    return if @uploaded_mail && @uploaded_mail.author_id == User.current.id && @uploaded_mail.readable? &&
              RedmineEmailExtract::MailFile.supported?(@uploaded_mail.filename)

    render json: { error: l(:email_extract_not_found) }, status: :not_found
  end

  # Yields the reader for the uploaded mail and returns what the block returns; the
  # block must take from the reader all it needs, as the file is closed afterwards.
  # Mail files come in countless variants; whatever goes wrong while reading one
  # becomes a JSON error for the page to show (and nil is returned).
  #
  # The file is untrusted input and the parsers are not hardened against it: ruby-ole
  # follows the block chains of a .msg file without checking for cycles, so a small
  # crafted file makes it loop - and allocate memory - forever, and deeply nested
  # MIME parts exhaust the stack. Hence the time limit, so that such a file cannot
  # block a server thread.
  #
  # Only the reading is inside the limit: Timeout interrupts the code at any point,
  # which must not be a database query or the response. So the file is opened and
  # closed outside of it, what the readers, the formatter and FieldMapping#fills look
  # up in the database (settings, the time zone of the user for the Date line and the
  # mapped dates) is read before it, and the caller renders after it. (The field
  # mapping itself, with its settings and custom fields, is read by the caller.)
  #
  # Rescued: StandardError includes Timeout::Error (the timeout itself is raised as
  # Timeout::ExitException, which the code inside cannot rescue, and turned into
  # Timeout::Error when it leaves Timeout.timeout); LoadError: the ruby-msg gem is
  # missing; SystemStackError: nested MIME parts (neither is a StandardError).
  def read_mail(&block)
    Setting.text_formatting
    Setting.mail_handler_preferred_body_part
    Setting.date_format
    Setting.time_format
    User.current.time_zone
    File.open(@uploaded_mail.diskfile, 'rb') do |file|
      Timeout.timeout(EXTRACTION_TIMEOUT) do
        RedmineEmailExtract::MailFile.open(file, @uploaded_mail.filename, &block)
      end
    end
  rescue StandardError, LoadError, SystemStackError => e
    render_failure(e)
    nil
  end

  # A mail someone else sent is inserted as a quote as a whole; in a mail the user
  # sent, the newest message is their own words. Any of the user's addresses counts
  # (Redmine compares addresses case-insensitively as well).
  def sent_by_current_user?(address)
    address.present? && User.current.mails.any? { |mine| mine.casecmp?(address) }
  end

  # The mail is customer data, and the message of an error can quote it: the error
  # log names the attachment and the class of the error only.
  def render_failure(error)
    logger.error("[email_extract] attachment #{@uploaded_mail.id}: #{error.class}")
    logger.debug { "[email_extract] attachment #{@uploaded_mail.id} (#{@uploaded_mail.filename}): #{error.message}" }
    render json: { error: l(:email_extract_failed) }, status: :unprocessable_content unless performed?
  end

  # message: number of the thread message the file belongs to (0 = newest)
  # small:   an image that is probably a logo or icon
  def entry_json(entry)
    part = entry.part
    {
      index: entry.index,
      filename: part.filename,
      size_label: helpers.number_to_human_size(part.size),
      thumb_url: (email_extract_part_path(token: params[:token], index: entry.index) if part.image?),
      message: entry.message,
      small: entry.small
    }
  end

  def upload_json(upload)
    attachment = upload.attachment
    {
      index: upload.index,
      token: attachment.token,
      filename: attachment.filename,
      markup: (RedmineEmailExtract::Formatter.image_markup(attachment.filename) if upload.part.image?),
      delete_path: attachment_path(attachment, format: 'js')
    }
  end
end
