# frozen_string_literal: true

module RedmineEmailExtract
  class Hooks < Redmine::Hook::ViewListener
    # Loads the script, styles and configuration on every page: upload forms appear in
    # many places (issues, wiki, forums, documents ...) and are also loaded dynamically.
    render_on :view_layouts_base_html_head, partial: 'email_extracts/html_head'
  end
end
