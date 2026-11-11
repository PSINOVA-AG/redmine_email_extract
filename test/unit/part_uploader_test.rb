# frozen_string_literal: true

require_relative '../test_helper'

class PartUploaderTest < ActiveSupport::TestCase
  include RedmineEmailExtract::TestSupport

  fixtures :users

  setup do
    set_tmp_attachments_directory # not the storage of the installation
  end

  def upload(parts)
    mail = fake_mail(parts: parts)
    RedmineEmailExtract::PartUploader.new(mail, User.find(2)).upload((0...parts.size).to_a)
  end

  test 'stores the files as uploads of the user' do
    uploader = upload([file_part('offer.pdf')])

    assert_empty uploader.errors
    attachment = uploader.uploads.first.attachment
    assert_equal 'offer.pdf', attachment.filename
    assert_equal 2, attachment.author_id
    assert attachment.token.present?
  end

  test 'names are unique as Redmine stores them' do
    uploader = upload([file_part('a:b.pdf'), file_part('a_b.pdf'), file_part('A_B.pdf')])

    assert_equal %w[a_b.pdf a_b-2.pdf A_B-3.pdf], uploader.uploads.map { |upload| upload.attachment.filename }
  end

  test 'indexes are positions, each once, at most as many as the upload form takes' do
    assert_equal [1, 0, 3], RedmineEmailExtract::PartUploader.indexes(['1', '0', '01', 'x', nil, '-1', '3', 1])
    assert_equal [2], RedmineEmailExtract::PartUploader.indexes('2')
    assert_empty RedmineEmailExtract::PartUploader.indexes(nil)
    assert_empty RedmineEmailExtract::PartUploader.indexes({ 'a' => '1' })
    assert_equal [*0...10], RedmineEmailExtract::PartUploader.indexes((0...25).map(&:to_s))
  end

  test 'ignores invalid indexes and stores each file once' do
    mail = fake_mail(parts: [file_part('a.pdf'), file_part('b.pdf')])
    uploader = RedmineEmailExtract::PartUploader.new(mail, User.find(2)).upload(%w[1 01 7 -1 abc])

    assert_equal [1], uploader.uploads.map(&:index)
    assert_equal ['b.pdf'], uploader.uploads.map { |upload| upload.attachment.filename }
  end

  test 'stores at most as many files as the upload form takes' do
    uploader = upload(Array.new(12) { |number| file_part("file#{number}.pdf") })

    assert_equal RedmineEmailExtract::PartUploader::MAX_FILES, uploader.uploads.size
  end

  test 'images get an extension that Redmine shows inline' do
    jpeg = RedmineEmailExtract::MailPart.new(filename: 'photo', content_type: 'image/jpeg', data: 'jpeg data'.b)
    uploader = upload([image_part('image001'), jpeg, image_part('Shot.PNG')])
    names = uploader.uploads.map { |upload| upload.attachment.filename }

    assert_match(/\A\h{8}_image001\.png\z/, names[0])
    assert_match(/\A\h{8}_photo\.jpg\z/, names[1])
    assert_match(/\A\h{8}_Shot\.PNG\z/, names[2])
  end
end
