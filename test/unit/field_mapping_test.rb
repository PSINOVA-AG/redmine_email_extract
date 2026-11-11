# frozen_string_literal: true

require_relative '../test_helper'

class FieldMappingTest < ActiveSupport::TestCase
  include RedmineEmailExtract::TestSupport
  include Redmine::I18n

  # Sent at 23:30 UTC: already the next day in Tokyo (UTC+9).
  SENT = Time.utc(2026, 11, 5, 23, 30)

  setup do
    set_language_if_valid 'en'
    user = User.new
    user.pref.time_zone = 'Tokyo'
    User.current = user
  end

  teardown do
    User.current = nil
  end

  # Custom fields in memory only: the mapping just reads their attributes.
  def custom_field(id, format, **attributes)
    IssueCustomField.new(name: "Field #{id}", field_format: format, **attributes).tap { |field| field.id = id }
  end

  def custom_fields
    @custom_fields ||= [
      custom_field(11, 'string'), custom_field(12, 'text'), custom_field(13, 'date'),
      custom_field(14, 'string', max_length: 10), custom_field(15, 'list', possible_values: %w[a b]),
      custom_field(16, 'link'), custom_field(17, 'int'), custom_field(18, 'bool'),
      custom_field(19, 'user'), custom_field(20, 'enumeration'),
      custom_field(22, 'string').tap { |field| field.multiple = true }
    ]
  end

  def mapping(field_mapping)
    RedmineEmailExtract::FieldMapping.new({ 'field_mapping' => field_mapping }, custom_fields: custom_fields)
  end

  def anna_mail(**attributes)
    fake_mail(**{ subject: 'Invoice 42', from: 'Anna Example <anna@example.org>', from_name: 'Anna Example',
                  from_address: 'anna@example.org', to: 'Ben <ben@example.org>', cc: 'carl@example.org',
                  date: SENT }.merge(attributes))
  end

  def targets(attribute, field_mapping = {})
    mapping(field_mapping).choices(attribute).map(&:last)
  end

  test 'by default the subject fills the subject and nothing else is mapped' do
    default = RedmineEmailExtract::FieldMapping.new({}, custom_fields: custom_fields)

    assert_equal 'subject', default.target('subject')
    (RedmineEmailExtract::FieldMapping::ATTRIBUTES - ['subject']).each do |attribute|
      assert_nil default.target(attribute), attribute
    end
    assert_equal [{ target: 'subject', value: 'Invoice 42' }], default.fills(anna_mail)
  end

  test 'settings without a usable mapping are the default' do
    [nil, 'garbage', { 'other' => 1 }, { 'field_mapping' => 'garbage' }].each do |settings|
      mapping = RedmineEmailExtract::FieldMapping.new(settings, custom_fields: [])
      assert_equal 'subject', mapping.target('subject'), settings.inspect
    end
  end

  test 'current reads the plugin settings' do
    with_settings plugin_redmine_email_extract: { 'field_mapping' => { 'subject' => '', 'date' => 'due_date' } } do
      mapping = RedmineEmailExtract::FieldMapping.current

      assert_nil mapping.target('subject')
      assert_equal 'due_date', mapping.target('date')
    end
  end

  test 'the subject can be unmapped' do
    assert_empty mapping({ 'subject' => '' }).fills(anna_mail)
  end

  test 'each attribute gives its value, the date as the day in the time zone of the user' do
    field_mapping = {
      'subject' => 'subject', 'from' => 'cf_11', 'from_name' => 'cf_12', 'from_address' => 'cf_14',
      'to' => 'cf_22', 'cc' => 'cf_16', 'date' => 'start_date'
    }
    # Only fields of the type are used: cf_22 (multiple) and cf_16 (link) are not.
    assert_equal [
      { target: 'subject', value: 'Invoice 42' },
      { target: 11, value: 'Anna Example <anna@example.org>' },
      { target: 12, value: 'Anna Example' },
      { target: 14, value: 'anna@ex...' }, # max_length 10
      { target: 'start_date', value: '2026-11-06' }
    ], mapping(field_mapping).fills(anna_mail)

    assert_equal [{ target: 11, value: 'Ben <ben@example.org>' }, { target: 12, value: 'carl@example.org' }],
                 mapping({ 'subject' => '', 'to' => 'cf_11', 'cc' => 'cf_12' }).fills(anna_mail)
  end

  test 'the date goes into date fields as ISO date, whatever the date format' do
    with_settings date_format: '%d.%m.%Y' do
      %w[start_date due_date].each do |target|
        assert_equal [{ target: target, value: '2026-11-06' }],
                     mapping({ 'subject' => '', 'date' => target }).fills(anna_mail)
      end
      assert_equal [{ target: 13, value: '2026-11-06' }], mapping({ 'subject' => '', 'date' => 'cf_13' }).fills(anna_mail)
    end
  end

  test 'each attribute is offered the fields of its type only' do
    %w[subject from from_name from_address to cc].each do |attribute|
      assert_equal ['subject', 'cf_11', 'cf_12', 'cf_14'], targets(attribute), attribute
    end
    assert_equal ['start_date', 'due_date', 'cf_13'], targets('date')
    assert_empty targets('unknown')
  end

  test 'text does not go into date fields and the date not into text fields' do
    crossed = mapping({ 'subject' => 'start_date', 'from' => 'cf_13', 'date' => 'cf_11' })

    %w[subject from date].each { |attribute| assert_nil crossed.target(attribute), attribute }
    assert_nil mapping({ 'date' => 'subject' }).target('date')
    assert_empty crossed.fills(anna_mail)
  end

  test 'the time of day is no attribute: a mapping stored for it is dropped' do
    old = mapping({ 'subject' => '', 'time' => 'cf_11', 'datetime' => 'cf_12' })

    assert_not_includes RedmineEmailExtract::FieldMapping::ATTRIBUTES, 'time'
    assert_nil old.target('time')
    assert_empty old.fills(anna_mail)
  end

  test 'choices are labelled with the field names' do
    choices = mapping({}).choices('date')

    assert_equal ['Start date', 'start_date'], choices.first
    assert_includes choices, ['Field 13', 'cf_13']
  end

  test 'text is cut to the length of the field' do
    long = 'x' * 300
    fills = mapping({ 'subject' => 'subject', 'from' => 'cf_14', 'to' => 'cf_11' })
            .fills(anna_mail(subject: long, from: long, to: long))

    assert_equal "#{'x' * 252}...", fills[0][:value] # as 1.2.0 cut the subject
    assert_equal "#{'x' * 7}...", fills[1][:value]
    assert_equal long, fills[2][:value] # no max_length
  end

  test 'a very short limit keeps the first characters' do
    fields = [custom_field(31, 'string', max_length: 2)]
    mapping = RedmineEmailExtract::FieldMapping.new({ 'field_mapping' => { 'subject' => 'cf_31' } },
                                                    custom_fields: fields)

    assert_equal [{ target: 31, value: 'In' }], mapping.fills(anna_mail)
  end

  test 'values are plain text of one line without control and bidi characters' do
    mail = anna_mail(subject: "Pay\r\nnow ‮fdp.exe‬\tplease x", from_name: "Anna\u0085Example",
                     cc: 'Question for @admin about {{toc}} *now* <b>')
    fills = mapping({ 'subject' => 'subject', 'from_name' => 'cf_11', 'cc' => 'cf_12' }).fills(mail)

    assert_equal 'Pay now fdp.exe please x', fills[0][:value]
    assert_equal 'Anna Example', fills[1][:value]
    # The fields take plain text: no wiki escapes.
    assert_equal 'Question for @admin about {{toc}} *now* <b>', fills[2][:value]
  end

  test 'a custom field that no longer exists or no longer fits is not mapped' do
    stale = mapping({ 'subject' => 'cf_99', 'from' => 'cf_13', 'to' => 'cf_15', 'cc' => 'due_date',
                      'date' => 'nonsense' })

    %w[subject from to cc date].each { |attribute| assert_nil stale.target(attribute), attribute }
    assert_empty stale.fills(anna_mail)
  end

  test 'attributes that are not mapped or have no value are not returned' do
    field_mapping = { 'subject' => '', 'from_name' => 'cf_11', 'cc' => 'cf_12', 'date' => 'start_date' }
    mail = anna_mail(from_name: nil, cc: " \r\n‮", date: nil)

    assert_empty mapping(field_mapping).fills(mail)
    assert_equal [{ target: 12, value: 'carl@example.org' }],
                 mapping({ 'subject' => '', 'cc' => 'cf_12' }).fills(anna_mail)
  end

  test 'of two attributes mapped to one field the first one fills it' do
    duplicate = mapping({ 'subject' => 'cf_11', 'from' => 'subject', 'to' => 'subject', 'cc' => 'cf_11' })

    assert_equal({ 'to' => 'from', 'cc' => 'subject' }, duplicate.duplicates)
    assert_equal [{ target: 11, value: 'Invoice 42' }, { target: 'subject', value: 'Anna Example <anna@example.org>' }],
                 duplicate.fills(anna_mail)
  end

  test 'an attribute that is mapped to a field of an ignored mapping is no duplicate' do
    # "from" points to a field that is gone; "to" fills the subject alone.
    assert_empty mapping({ 'subject' => '', 'from' => 'cf_99', 'to' => 'subject' }).duplicates
  end
end
