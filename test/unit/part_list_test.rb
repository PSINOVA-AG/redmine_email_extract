# frozen_string_literal: true

require_relative '../test_helper'

class PartListTest < ActiveSupport::TestCase
  include RedmineEmailExtract::TestSupport

  def list(mail)
    RedmineEmailExtract::PartList.new(mail)
  end

  def placement(message, order)
    RedmineEmailExtract::PartList::Placement.new(message, order)
  end

  def filenames(entries)
    entries.map { |entry| entry.part.filename }
  end

  test 'lists regular attachments first, then images from the newest message to the oldest' do
    mail = fake_mail(parts: [
                       image_part('old.png', content_id: 'old@example'),
                       image_part('new.png', content_id: 'new@example'),
                       file_part('offer.pdf')
                     ])

    entries = list(mail).entries(0 => placement(1, 1), 1 => placement(0, 0))

    assert_equal %w[offer.pdf new.png old.png], filenames(entries)
    assert_equal [2, 1, 0], entries.map(&:index)
    assert_equal [0, 0, 1], entries.map(&:message)
  end

  test 'images that are not shown in the text come last in the newest message' do
    mail = fake_mail(parts: [
                       image_part('b.png', content_id: 'b@example'),
                       image_part('a.png', content_id: 'a@example'),
                       image_part('shown.png', content_id: 'c@example')
                     ])

    entries = list(mail).entries(2 => placement(0, 0))

    assert_equal %w[shown.png b.png a.png], filenames(entries)
    assert_equal [0, 0, 0], entries.map(&:message)
  end

  test 'marks small images such as signature logos, but never other files' do
    mail = fake_mail(parts: [
                       image_part('logo.png', size: 2_000),
                       image_part('screenshot.png', size: 50_000),
                       file_part('note.txt', content_type: 'text/plain')
                     ])

    entries = list(mail).entries

    assert_equal %w[logo.png screenshot.png note.txt], filenames(entries)
    assert_equal [true, false, false], entries.map(&:small)
  end

  test 'lists a file that is contained several times only once' do
    logo = 'same content'.b * 2_000
    mail = fake_mail(parts: [
                       image_part('image001.png', data: logo, content_id: 'a@example'),
                       image_part('image005.png', data: logo, content_id: 'b@example'),
                       image_part('other.png', content_id: 'c@example')
                     ])
    part_list = list(mail)

    assert_equal %w[image001.png other.png], filenames(part_list.entries)
    assert_equal [0, 2], part_list.entries.map(&:index)
    assert_equal 0, part_list.index_of('a@example')
    assert_equal 0, part_list.index_of('b@example'), 'a copy stands for the listed file'
    assert_equal 2, part_list.index_of('c@example')
    assert_nil part_list.index_of('unknown@example')
  end

  test 'a mail without files gives an empty list' do
    assert_empty list(fake_mail).entries
  end
end
