# E-mail Extract (redmine_email_extract)

Redmine plugin: puts the content of an uploaded e-mail file (`.eml` or Outlook `.msg`)
into the text of an issue.

## What it does

When an e-mail file is uploaded in an upload form, an **"In Notiz einfügen" /
"In Beschreibung einfügen"** chip appears next to it. A click

- inserts From / To / Cc / Date / Subject and the text of the mail into the notes
  (editing an issue) or the description (new issue), written for the text formatting
  Redmine is set to (see "Text formattings"),
- inserts only the **newest message** of a reply thread; with "−" and "+" (or "Alle")
  the user adds or removes older messages one by one,
- quotes the mail by the age of its messages (`>`, `>>`, at most `>>>`). The
  **"Als Zitat" / "As quote"** button in the status line (in every text field, also
  for a mail with a single message) decides whether the whole mail is a quote:
  - on: the header lines and the newest message are quoted with `>` (as one quote
    block: the header belongs to the newest message), the message before with `>>`,
    older ones with `>>>`;
  - off: header lines and newest message are not quoted, the older messages get `>`,
    `>>`, `>>>`.

  It starts switched **on**, unless the current user sent the mail: the From address
  of the mail is one of the user's e-mail addresses in Redmine (compared ignoring
  case). A mail from someone else is a quote as a whole; in a mail the user sent, the
  newest message is their own words. The text is updated at once when it is switched.
  Images in a message are quoted along with it,
- fills issue fields from the mail if they are still empty: by default the subject of
  the issue with the subject of the mail; which attributes fill which fields is set in
  the plugin settings (see "Issue fields from the mail"),
- offers the **images and files of the mail** in a picker. Chosen files become normal
  attachments of the form; images are also shown in the inserted text, at the place
  they have in the mail.
  Small images (logos) and images of messages that are not inserted are not pre-selected,
- can be undone for a short time (text, filled fields and attached files).

Files that are already attached to an issue do not get the chip.

## Issue fields from the mail

In Administration > Plugins > E-mail Extract > Configure an administrator chooses for
each attribute of a mail which field of the issue form it fills, or "(not mapped)":

| Attribute | Value | Fields it can fill |
|---|---|---|
| Subject, From (name and address), Sender name, Sender address, To, Cc | text, as in the header lines; the sender address lowercased | text fields: Subject; custom fields of the formats Text and Long text |
| Date sent | the day the mail was sent | date fields: Start date, Due date; custom fields of the format Date |

Each select lists the standard and custom fields of the type of its attribute only:
text goes into text fields, the date into date fields, and the value is converted to
what the field holds. Redmine has no field of a time type, so the time of day at which
a mail was sent cannot be mapped (it is in the Date line of the inserted text). Not
offered either: the description (the mail itself is inserted there) and the other
custom field formats (lists, users, numbers, links, yes/no, fields with multiple values).
The default is Subject -> Subject, everything else not mapped; it fills the subject
exactly as before 1.3.0, and can be set to "(not mapped)" too.

When a mail is inserted (in the new-issue and the edit form alike), each mapped
attribute that the mail has fills its field if that field is in the form and empty;
what the user entered is never replaced. Fields that are not in the form (a custom
field not enabled for the tracker or project, a field read-only by the workflow) are
left out without a message. Undo empties the fields again unless they were edited.

- Values are plain text of one line: line breaks and control characters become a space,
  bidirectional formatting characters are removed (as in the header lines, but without
  the escapes of the text formatting). They are cut to 255 characters for the subject
  and to the maximum length of a custom field, if it has one.
- The date is the day in the current user's time zone, as in the Date line. It is the
  `Date:` header of an `.eml` file, and the time Outlook sent a `.msg` file (or, if
  that is missing, the time it was delivered).
- With "Use current date as start date for new issues" (Administration > Settings >
  Issue tracking), Redmine fills the start date of a new issue with today's date when
  the form opens. The field is then not empty, so "Date sent" -> Start date does not
  fill it on new issues; this is deliberate, as a filled field is never replaced. Map
  the date to the due date or a date custom field to have it on new issues.
- If two attributes are mapped to the same field, the first one in the order of the
  settings page fills it and the other one is ignored; the settings page says so.
  (Redmine's plugin settings cannot reject a value when they are saved.)
- A mapping to a custom field that has been deleted is ignored and shown as not mapped;
  it is removed when the settings are saved next time.

## Text formattings

The inserted text is written for the text formatting Redmine is set to (Administration
> Settings > General) and renders correctly in all three. Only what the formatting
would misread, swallow or execute is escaped, so the mail stays readable in the text
field.

| | none (plain text) | Textile | CommonMark |
|---|---|---|---|
| Header labels | `From: ...` | `*From:* ...` | `**From:** ...` |
| Line breaks | as in the mail | as in the mail | two spaces at the end of the line |
| Quotes | `>` lines are plain text | quote blocks | quote blocks; an empty line is added after a quote or list item so that the next line is not pulled into it |
| Lists | text | `* item` stays a list, `# x` is literal (`&#35; x`) | `- item`, `* item`, `+ item`, `1. item` stay lists |
| Escapes | none needed | HTML entities, e.g. `p&#46; 5`, `&lt;pre>`, `&#33;word!`, `USB&#40;3.0)` | backslashes, e.g. `\<word>`, `\# Title`, `\--` under a text line, `\[1]: url`, `\![alt](url)`, `\\server\share` |
| "@name" (would notify that user) | invisible U+2060 WORD JOINER after the `@` | `&#64;name` | `&#64;name` |
| Attached image | `attachment:name.png` (a link) | `!name.png!` | `![](name.png)` |

In every formatting:

- `{{macro}}` of an existing macro is inserted as `!{{macro}}`: shown, not executed. A
  line that is only `{{toc}}` gets an invisible U+2060 in front.
- Header values are one line: line breaks and control characters become a space and
  bidirectional override characters are removed.
- Indentation is removed (it would become a code block), so nested lists become flat.
- The inserted block is kept apart from the surrounding text by an empty line, and the
  cursor is put below the empty line after it. The mail is inserted at the cursor if
  the text field was the last thing used before the chip, otherwise at the end.

Deliberately not escaped: inline emphasis as mail programs write it (`*bold*`,
`_italic_`, in Textile also `-deleted-`, `+inserted+`), tables written with `|`,
a `---` line of its own (a rule) and Redmine links such as `#123` or `[[Page]]` (Redmine's
own mail handler keeps them too).


## Requirements and installation

- Redmine 6.1 or later. Developed and run on Redmine 7.0.3 / Ruby 4.0 only; 6.1 is the
  first version that has the script helper and icons the plugin uses (Redmine 6.0 has
  neither `createSVGIcon` nor the quote icon), but it has not been run there.
- The `ruby-msg` gem (see `Gemfile`); it is installed with the plugin's bundle.

Clone the repository into Redmine's `plugins` folder (the folder name must be
`redmine_email_extract`), install the gems and restart Redmine:

```
cd /path/to/redmine
git clone https://github.com/PSINOVA-AG/redmine_email_extract.git plugins/redmine_email_extract
bundle install
```

There are no database migrations. The plugin settings (see "Issue fields from the
mail") work without being saved once. To update, run `git pull` in the plugin folder,
`bundle install`, and restart Redmine. To remove the plugin, delete the folder and
restart.

With the `sameersbn/redmine` image, mount the folder to
`/home/redmine/data/plugins/redmine_email_extract` (writable: the image changes the
owner of everything below its data directory on start).

Operations notes:

- The `sameersbn/redmine` image runs `bundle install` for the `Gemfile`s of plugins on
  start. The first start after adding the plugin therefore needs access to rubygems.org
  (or an image in which the gems are already installed). If the installation fails,
  Redmine does not start.
- With a bind mount, the `chown` of the image on start also changes the owner of the
  plugin folder on the host (to the user id of the `redmine` user in the container).
  Expect this when the folder is under version control or edited by another user; a
  named volume avoids it.
- Files that the plugin creates as uploads (the files of a mail chosen in the picker,
  and the mail file itself) but that are never saved with a form stay in Redmine's files
  directory, like every other abandoned upload. Redmine does not remove them by itself;
  only `bundle exec rake redmine:attachments:prune RAILS_ENV=production` does (run it
  regularly, e.g. by cron).

## How it is built

```
app/controllers/email_extracts_controller.rb   JSON endpoints used by the script
app/views/email_extracts/_html_head.html.erb   loads script, styles and texts on every page
app/views/settings/_email_extract_settings.html.erb   plugin settings (issue fields from the mail)
assets/javascripts/email_extract.js            chip, status line, file picker
assets/stylesheets/email_extract.css
lib/redmine_email_extract/
  mail_file.rb         picks the reader for a file
  readers/eml.rb       reads .eml (mail gem)
  readers/msg.rb       reads .msg (ruby-msg)
  mail_part.rb         a file contained in a mail
  rtf_html.rb          recovers the HTML body Outlook wraps into RTF
  thread_splitter.rb   splits the text of a reply into its single messages
  inline_images.rb     finds where the inline images belong in the text
  formatter.rb         mail -> wiki text
  markup.rb            mail text as wiki text of one text formatting; subclasses:
  plain_markup.rb, textile_markup.rb, common_mark_markup.rb
  part_list.rb         order and pre-selection of the picker
  extraction.rb        header, messages and files of a mail, as sent to the page
  field_mapping.rb     which mail attribute fills which issue field; their values
  part_uploader.rb     stores chosen files as Redmine uploads
  hooks.rb             view hook
```

The endpoints only accept the upload token of a file that the current user has
uploaded and that is not attached to anything yet.

## Tests

The tests need a Redmine development or test setup with a test database; the
production image has neither the test gems nor a test database, so they cannot run
there. In such a setup:

```
bundle exec rake redmine:plugins:test:units NAME=redmine_email_extract RAILS_ENV=test
bundle exec rake redmine:plugins:test:functionals NAME=redmine_email_extract RAILS_ENV=test
```

The unit tests cover thread splitting, image placement, formatting, the picker list,
the HTML recovery from RTF, the limits on files, the field mapping and the `.eml`
reader, with mails built in the tests.
The `.msg` reader is tested with files built in the tests with ruby-ole (there is no real
`.msg` fixture: Outlook files contain customer data). The uploader test needs Redmine's
user fixtures. The functional test of the controller covers the answer of
`POST /email_extract` (the filled fields with the default and a custom mapping, and
`sent_by_me`) for an `.eml` upload made in the test; it needs Redmine's user and e-mail
address fixtures. There is no JavaScript test.

## Known limits

- Mails attached to a mail (a forwarded `.msg`) are not offered as files.
- The place of an image is found by matching the lines of the HTML body to the plain
  text. An image whose surroundings are not found follows the last line that is; images
  of mails without an HTML body go below the text of the newest message.
- The messages of a thread are found by their reply separators, so their number can
  differ slightly from the real number of mails.
- The inserted text is the plain text of the mail: formatting and tables are lost.
- `.msg` files are read with the `ruby-msg` gem, which is no longer maintained. Only its
  container, property and attachment reading is used; the parts of it that do not run
  on Ruby 4 are replaced by `rtf_html.rb`.
- Reading one mail file may take at most 5 seconds (`EXTRACTION_TIMEOUT`), because the
  readers are not hardened against crafted files (ruby-ole can loop forever on one).
- A mail lists at most 200 files, and its files together at most 4 times the size of the
  mail file (attached mails repeat the files they contain); further files are not
  offered. A `.msg` file whose internal streams together declare more bytes than the file
  has is rejected as unreadable (a crafted file does this to make the reader read the
  same data over and over). At most 10 files are stored per request, as in Redmine's
  upload form.
- Only the reading of the mail is time-limited; database access and the response are
  outside the limit.
- Control characters and bidirectional formatting characters (which can disguise e.g.
  `.exe` as `.pdf`) are removed from the names of contained files.
- Errors are logged with the attachment id and the error class only; file names and
  error messages, which can contain mail content, are logged at debug level.
- A thumbnail request reads the mail again; for `.msg` files only the requested image is
  read from it, for `.eml` files the whole mail is parsed and its attachments decoded.
- The invisible U+2060 that breaks mentions in plain text and guards `{{toc}}` stays in
  the saved text (a search for "@name" does not find it there).
- The thumbnails of the picker are requested with the upload token in the URL, so the
  token appears in the web server's access log. It is only valid for its uploader and
  only until the form is saved.

## Licence

Copyright (C) 2026 PSINOVA AG

This program is free software; you can redistribute it and/or modify it under the
terms of the GNU General Public License version 2 as published by the Free Software
Foundation, the licence of Redmine itself. See [LICENSE](LICENSE).

## Credits and licences

`lib/redmine_email_extract/rtf_html.rb` follows the extraction of encapsulated HTML from
RTF in the `ruby-msg` gem (`Mapi::RTF.rtf2html`), which is under the MIT licence
(Copyright (c) 2007-2014 Charles Lowe). The full notice is in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Changelog

### 1.3.0

- Plugin settings: which attributes of a mail (subject, sender, sender name and
  address, To, Cc, date sent) fill which issue fields of the same type (text: subject
  and text custom fields; date: start date, due date and date custom fields). The
  default fills the subject as before. Fields are filled only if they are in the
  form and empty, in the new-issue and the edit form.
- Undo also empties the fields that were filled, unless they were edited since.
- The subject that fills the issue subject is plain text of one line: line breaks
  and control characters become a space, bidirectional formatting characters are
  removed.
- The answer of `POST /email_extract` has `fields` (the mapped fields and their
  values) instead of `subject`.
- Sender name of a mail (`from_name`) in both readers.
- Unit tests of the field mapping; controller test.

### 1.2.0

- The inserted text is correct for all three text formattings (Textile, CommonMark,
  plain text): escaping, quotes, mentions and images in plain text.
- Responsive layout that also works on touch screens: no horizontal overflow on narrow
  screens, larger hit areas, a picker that scrolls when a mail has many files.
- The text is inserted at the cursor position of the field.
- Handling of the preview tab of the text field.
- Limits against crafted `.msg` files.
- Less data in the log.
- Accessibility fixes (focus, pressed state of the quote button, messages).
- Tests.
