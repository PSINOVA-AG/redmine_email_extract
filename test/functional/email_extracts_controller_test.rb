# frozen_string_literal: true

require_relative '../test_helper'

# The answer of POST /email_extract for an uploaded .eml file. What is in the header
# and the messages is tested with the formatter and the extraction; here it is the
# fields filled from the mail and who may read the upload.
class EmailExtractsControllerTest < Redmine::ControllerTest
  tests EmailExtractsController

  fixtures :users, :email_addresses, :user_preferences

  # Noon in UTC: the same day in the time zone of every fixture user.
  def raw_mail(from: '"Example, Anna" <anna@example.org>')
    "From: #{from}\r\nTo: jsmith@somenet.foo\r\nSubject: Invoice 42\r\n" \
      "Date: Thu, 05 Nov 2026 12:00:00 +0000\r\nContent-Type: text/plain\r\n\r\nPlease pay.\r\n"
  end

  # An upload of the user that is not attached to anything yet, as the upload form
  # makes it.
  def upload(raw, author: User.find(2))
    attachment = Attachment.new(file: StringIO.new(raw))
    attachment.filename = 'mail.eml'
    attachment.content_type = 'message/rfc822'
    attachment.author = author
    attachment.save!
    attachment
  end

  def extract(attachment)
    post :create, params: { token: attachment.token }
    response.parsed_body
  end

  setup do
    set_tmp_attachments_directory # not the storage of the installation
    @request.session[:user_id] = 2
  end

  test 'by default the subject fills the subject field' do
    json = extract(upload(raw_mail))

    assert_response :success
    assert_equal [{ 'target' => 'subject', 'value' => 'Invoice 42' }], json['fields']
    assert_includes json['header'], 'Invoice 42'
    assert_equal 1, json['messages'].size
    assert_empty json['parts']
    assert_equal false, json['sent_by_me']
    assert_not json.key?('subject') # only as a field, if it is mapped
  end

  test 'sends the values of the mapped attributes only' do
    sender = IssueCustomField.create!(name: 'Sender of the e-mail', field_format: 'string', max_length: 8)
    field_mapping = { 'subject' => '', 'from_name' => "cf_#{sender.id}", 'date' => 'start_date', 'cc' => 'due_date' }

    with_settings plugin_redmine_email_extract: { 'field_mapping' => field_mapping } do
      json = extract(upload(raw_mail))

      assert_response :success
      # cc cannot fill a date (and the mail has no Cc).
      assert_equal [{ 'target' => sender.id, 'value' => 'Examp...' },
                    { 'target' => 'start_date', 'value' => '2026-11-05' }], json['fields']
    end
  end

  test 'a mapping to a custom field that was deleted sends nothing for it' do
    sender = IssueCustomField.create!(name: 'Sender of the e-mail', field_format: 'string')
    field_mapping = { 'subject' => 'subject', 'from' => "cf_#{sender.id}" }
    sender.destroy

    with_settings plugin_redmine_email_extract: { 'field_mapping' => field_mapping } do
      assert_equal [{ 'target' => 'subject', 'value' => 'Invoice 42' }], extract(upload(raw_mail))['fields']
    end
  end

  test 'sent_by_me if the mail is from an address of the user' do
    assert_equal true, extract(upload(raw_mail(from: 'John Smith <JSmith@Somenet.foo>')))['sent_by_me']
  end

  test 'the upload of another user is not found' do
    json = extract(upload(raw_mail, author: User.find(3)))

    assert_response :not_found
    assert json['error'].present?
  end
end
