# frozen_string_literal: true

require_relative '../test_helper'

class MailPartTest < ActiveSupport::TestCase
  def part(content_type: 'image/png', **attributes)
    RedmineEmailExtract::MailPart.new(filename: 'image001.png', content_type: content_type, data: 'bytes'.b,
                                      **attributes)
  end

  test 'data can be given as it is' do
    image = part

    assert_equal 'bytes', image.data
    assert_equal 5, image.size
    assert_equal Digest::SHA256.hexdigest('bytes'), image.digest
  end

  test 'data can be read when it is first needed' do
    calls = 0
    reader = lambda do
      calls += 1
      'lazy bytes'.b
    end
    image = part(data: reader, size: 10)

    assert_equal 10, image.size
    assert image.image?
    assert_equal 0, calls, 'size and type do not read the data'

    assert_equal 'lazy bytes', image.data
    assert_equal Digest::SHA256.hexdigest('lazy bytes'), image.digest
    assert_equal 10, image.size
    assert_equal 1, calls, 'read once'
  end

  test 'without a size, lazy data is read for it' do
    assert_equal 4, part(data: -> { 'four'.b }).size
  end

  test 'only raster images are images, each with the extension Redmine shows inline' do
    assert_equal 'png', part.image_extension
    assert_equal 'jpg', part(content_type: 'IMAGE/JPEG').image_extension
    assert_not part(content_type: 'image/svg+xml').image?
    assert_nil part(content_type: 'application/pdf').image_extension
  end

  test 'an image with a Content-ID is an inline image' do
    assert part(content_id: '<image001.png@01DC>').inline_image?
    assert_equal 'image001.png@01DC', part(content_id: '<image001.png@01DC>').content_id
    assert_not part.inline_image?
  end
end
