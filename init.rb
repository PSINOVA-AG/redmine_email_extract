# frozen_string_literal: true

Redmine::Plugin.register :redmine_email_extract do
  name 'E-mail Extract'
  author 'PSINOVA AG'
  description 'Inserts the text of uploaded .eml / .msg files into the issue description or notes ' \
              'and attaches the images and files they contain.'
  version '1.2.0'
  url 'https://github.com/PSINOVA-AG/redmine_email_extract'
  author_url 'https://www.psinova.com'
  # 6.1 is the first version with createSVGIcon and the "quote-filled" icon that
  # email_extract.js uses; the plugin has only been run on 7.0.
  requires_redmine version_or_higher: '6.1'
end

# The plugin code in lib/ is autoloaded; view hooks register themselves when their
# class is loaded, so load it once the application is ready.
Rails.application.config.after_initialize do
  RedmineEmailExtract::Hooks
end
