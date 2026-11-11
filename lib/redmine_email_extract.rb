# frozen_string_literal: true

# Inserts the content of uploaded e-mail files (.eml / .msg) into Redmine text fields.
#
#   MailFile          opens an uploaded mail with the matching reader
#   Readers::*        read header fields, body and contained files from one mail format
#   RtfHtml           recovers the HTML body that Outlook wraps into RTF
#   ThreadSplitter    splits the text of a reply into its single messages
#   InlineImages      finds where the inline images belong in the text of a mail
#   Formatter         turns a mail into wiki text of the configured text formatting
#   Markup            writes mail text for one text formatting, escaping what it would
#                     misread: PlainMarkup (none), TextileMarkup, CommonMarkMarkup
#   PartList          the files of a mail as offered in the picker (order, pre-selection)
#   Extraction        header, messages and files of a mail, as sent to the page
#   PartUploader      turns selected files into regular Redmine uploads
module RedmineEmailExtract
  PLUGIN_ID = 'redmine_email_extract'

  # Images below this size are not pre-selected in the picker (signature logos, icons).
  SMALL_IMAGE_SIZE = 10.kilobytes

  # Logs that something of a mail was skipped. Mails are customer data and the message
  # of an error can quote them (a file name, a header), so the warning names only the
  # class of the error; its message goes to the debug level.
  #
  #   RedmineEmailExtract.log_warning('.eml attachment skipped', error)
  def self.log_warning(message, error = nil)
    Rails.logger.warn("[email_extract] #{message}#{": #{error.class}" if error}")
    Rails.logger.debug { "[email_extract] #{message}: #{error.message}" } if error
  end
end
