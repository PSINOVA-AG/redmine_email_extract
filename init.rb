# frozen_string_literal: true

Redmine::Plugin.register :redmine_email_extract do
  name 'E-mail Extract'
  author 'PSINOVA AG'
  description 'Inserts the text of uploaded .eml / .msg files into the issue description or notes ' \
              'and attaches the images and files they contain.'
  version '1.3.0'
  url 'https://github.com/PSINOVA-AG/redmine_email_extract'
  author_url 'https://www.psinova.com'
  # 6.1 is the first version with createSVGIcon and the "quote-filled" icon that
  # email_extract.js uses; the plugin has only been run on 7.0.
  requires_redmine version_or_higher: '6.1'

  # Which attribute of an inserted mail fills which issue field (see
  # RedmineEmailExtract::FieldMapping). By default the subject only, as before 1.3.
  # (Written out rather than FieldMapping::DEFAULT: the reloadable plugin code is not
  # to be loaded while Redmine initializes, see the end of this file.)
  settings default: { 'field_mapping' => { 'subject' => 'subject' } },
           partial: 'settings/email_extract_settings'
end

# The plugin code in lib/ is autoloaded; view hooks register themselves when their
# class is loaded, so load it once the application is ready.
Rails.application.config.after_initialize do
  RedmineEmailExtract::Hooks
end
