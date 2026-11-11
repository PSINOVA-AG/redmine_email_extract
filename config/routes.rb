# frozen_string_literal: true

# See EmailExtractsController.
post 'email_extract', to: 'email_extracts#create', as: 'email_extract'
get 'email_extract/part', to: 'email_extracts#part', as: 'email_extract_part'
post 'email_extract/attach', to: 'email_extracts#attach', as: 'email_extract_attach'
