# frozen_string_literal: true

module RedmineEmailExtract
  # Which attribute of a mail fills which field of the issue form, as the
  # administrator configured it in the plugin settings, and the values a mail gives
  # these fields.
  #
  # An attribute is offered the fields of its own type only: text goes into text
  # fields, the date the mail was sent into date fields.
  #
  # The setting is stored as { 'field_mapping' => { attribute => target } } with the
  # targets 'subject', 'start_date', 'due_date' and 'cf_<id>' (an issue custom field,
  # named like in Redmine's queries); '' means not mapped. The page gets only the
  # values of mapped attributes (see #fills) and fills each into its field if that is
  # in the form and empty (email_extract.js).
  #
  #   mapping = FieldMapping.current             # reads the settings and custom fields
  #   mapping.fills(mail)                        # => [{ target: 'subject', value: 'Invoice' }]
  class FieldMapping
    # In this order on the settings page; also the order in which two attributes
    # mapped to the same field are decided: the first one fills it.
    #
    # "date" is the moment the mail was sent, converted to what a date field holds: the
    # day. There is no attribute for its time of day, as Redmine has no field of a
    # time type that could take it.
    ATTRIBUTES = %w[subject from from_name from_address to cc date].freeze

    # The type of the fields an attribute can fill.
    DATE_ATTRIBUTES = %w[date].freeze

    # Standard fields of an issue, by type: target => label. The description is a
    # text field too, but it is where the mail itself is inserted, so it is never
    # empty when the fields are filled.
    STANDARD_TARGETS = {
      text: { 'subject' => :field_subject },
      date: { 'start_date' => :field_start_date, 'due_date' => :field_due_date }
    }.freeze

    # Custom field formats, by type. "link" holds text too, but the value would be
    # shown as a link to wherever the mail says.
    CUSTOM_FIELD_FORMATS = { text: %w[string text], date: %w[date] }.freeze

    # The length of Issue#subject.
    SUBJECT_MAX_LENGTH = 255

    # As in 1.2.0, which only filled the subject.
    DEFAULT = { 'subject' => 'subject' }.freeze

    # The mapping of the current plugin settings. Reads the database (settings and
    # custom fields): not to be called while a mail is read under a time limit (see
    # EmailExtractsController#read_mail), #fills itself does not.
    def self.current
      new(Setting.plugin_redmine_email_extract)
    end

    # settings: the plugin settings (a Hash, see above); anything else is the default.
    # custom_fields: the issue custom fields there are.
    def initialize(settings, custom_fields: IssueCustomField.sorted.to_a)
      @custom_fields = custom_fields.index_by { |field| "cf_#{field.id}" }
      @stored = stored_mapping(settings)
    end

    # The fields an attribute can fill: [[label, target]], standard fields first.
    def choices(attribute)
      type = type(attribute)
      return [] unless type

      standard = STANDARD_TARGETS[type].map { |target, label| [::I18n.t(label), target] }
      custom = @custom_fields.filter_map do |target, field|
        [field.name, target] if compatible?(attribute, target)
      end
      standard + custom
    end

    # The target stored for an attribute, if it can still be used: nil for one that
    # is not mapped, a custom field that no longer exists and a field whose type is
    # not that of the attribute (then it is shown as not mapped in the settings, too).
    def target(attribute)
      target = @stored[attribute.to_s]
      target if target.present? && compatible?(attribute, target)
    end

    # Attributes that are mapped to a field an attribute before them fills already:
    # { attribute => attribute that fills the field }. They are ignored.
    def duplicates
      first = {}
      ATTRIBUTES.each_with_object({}) do |attribute, result|
        target = target(attribute)
        next unless target

        if first.key?(target)
          result[attribute] = first[target]
        else
          first[target] = attribute
        end
      end
    end

    # The values a mail gives the mapped fields, of the attributes that have one:
    # [{ target: 'subject' | 'start_date' | 'due_date' | <custom field id>, value: String }]
    # Text is plain text of one line, as short as the field takes; a date is ISO 8601,
    # as date inputs take it. Uses no database except what
    # EmailExtractsController#read_mail reads before (the time zone of the user).
    #
    # mail: a reader (see Readers::Base)
    def fills(mail)
      ignored = duplicates
      ATTRIBUTES.filter_map do |attribute|
        target = target(attribute)
        next if target.nil? || ignored.key?(attribute)

        value = value(mail, attribute, target)
        { target: json_target(target), value: value } if value.present?
      end
    end

    private

    def stored_mapping(settings)
      mapping = (settings['field_mapping'] || settings[:field_mapping] if settings.is_a?(Hash))
      return DEFAULT unless mapping.is_a?(Hash)

      # Saved settings are a HashWithIndifferentAccess, whose #to_h takes no block.
      mapping.each_with_object({}) { |(attribute, target), result| result[attribute.to_s] = target.to_s }
             .slice(*ATTRIBUTES)
    end

    # :text or :date; nil for something that is no attribute.
    def type(attribute)
      attribute = attribute.to_s
      return nil unless ATTRIBUTES.include?(attribute)

      DATE_ATTRIBUTES.include?(attribute) ? :date : :text
    end

    def compatible?(attribute, target)
      type = type(attribute)
      return false unless type
      return true if STANDARD_TARGETS[type].key?(target)

      field = @custom_fields[target]
      field.present? && !field.multiple? && CUSTOM_FIELD_FORMATS[type].include?(field.field_format)
    end

    # The page finds the field by its id: issue_subject, issue_custom_field_values_5.
    def json_target(target)
      @custom_fields.key?(target) ? @custom_fields[target].id : target
    end

    def value(mail, attribute, target)
      return date_value(mail.date) if type(attribute) == :date

      limit(Markup.one_line(mail.public_send(attribute)), max_length(target))
    end

    # The day the mail was sent, for the user: in their time zone, as the Date header
    # line shows it.
    def date_value(time)
      User.current.convert_time_to_user_timezone(time).to_date.iso8601 if time
    end

    def max_length(target)
      return SUBJECT_MAX_LENGTH if target == 'subject'

      length = @custom_fields[target]&.max_length.to_i
      length if length.positive?
    end

    # Cut like 1.2.0 cut the subject ("..." at the end); a limit too short for that
    # gets the first characters only.
    def limit(text, length)
      return text if length.nil? || text.length <= length

      length > 3 ? text.truncate(length) : text[0, length]
    end
  end
end
