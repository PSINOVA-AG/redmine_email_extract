# Reads Outlook .msg files. Loaded on first use (see RedmineEmailExtract::Readers::Msg).
# The sameersbn/redmine image runs "bundle install" for this file on start and needs
# rubygems.org for it (see "Requirements and installation" in the README).
gem 'ruby-msg', '~> 1.5', require: false

# Needed by ruby-msg / ruby-ole, but no longer default gems since Ruby 3.4 / 3.5.
# Redmine's own dependencies pull in both, so this adds nothing new.
gem 'base64'
gem 'logger'
