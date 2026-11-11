/*
 * redmine_email_extract
 *
 * Every freshly uploaded .eml / .msg file in an upload form gets an "insert" chip.
 * Clicking it puts the text of the mail (by default only the newest message of a
 * thread) into the text field of the form: the notes of an issue, or the description
 * of a new one. A status line then lets the user add older messages of the thread and undo,
 * and a picker offers the images and files of the mail as attachments; attached images
 * are shown in the text where they were in the mail. Older messages are quoted; the
 * "As quote" button quotes the header and the newest message as well, i.e. the whole
 * mail. It starts switched on unless the current user sent the mail (the server
 * tells), because then the newest message is the user's own words.
 *
 * Structure:
 *   configuration, texts, icons, small DOM helpers, server requests
 *   text fields  which field a mail goes into, where its cursor was
 *   MailText     the text of a mail: messages to insert, quoting, images in place
 *   Insertion    the text this script put into a text field
 *   upload rows  files of the mail added to the upload form
 *   FilePicker   panel to choose files of the mail
 *   StatusBar    "Inserted" message, number of thread messages, quoting, undo
 *   MailRow      ties it together for one uploaded mail
 *   start-up     finds upload rows, also in forms loaded later
 */
(() => {
  'use strict';

  const MAIL_FILE = /\.(eml|msg)$/i;
  const TOKEN_FIELD = 'input[name$="[token]"]'; // only in rows of fresh uploads
  const UNDO_TIMEOUT = 10000; // ms the status line stays after the last action
  const MAX_FILES_PER_FORM = 10; // same limit as Redmine's attachments.js
  const MAX_QUOTE_DEPTH = 3; // messages are quoted by age; beyond this depth all look the same

  // --- configuration and texts ---------------------------------------------------

  const configTag = document.querySelector('meta[name="email-extract-config"]');
  if (!configTag) return; // not logged in
  const config = JSON.parse(configTag.content);

  // Text for a key, with %{name} placeholders filled from values. Entries with
  // one/other forms are chosen by values.count.
  function t(key, values = {}) {
    let text = config.labels[key];
    if (text && typeof text === 'object') text = values.count === 1 ? text.one : text.other;
    if (text === undefined) return key;
    return text.replace(/%\{(\w+)\}/g, (placeholder, name) => (name in values ? values[name] : placeholder));
  }

  // --- icons (Redmine's SVG sprite) ------------------------------------------------

  // Names of icons in Redmine's sprite (config/icon_source.yml), so that the controls
  // look like Redmine's own. The sprite has no "insert" or "undo" icon as such; these
  // are the closest ones.
  const ICONS = {
    insert: 'email', // chip next to the mail
    inserted: 'checked', // status message, like Redmine's success message
    undo: 'cancel', // arrow-back-up
    fewer: 'circle-minus',
    more: 'add', // circle-plus, the counterpart of circle-minus
    all: 'reply', // two speech bubbles: the whole thread
    quote: 'quote-filled', // quotation marks, as on Redmine's own "Quote" links
    file: 'file', // picker tile without a thumbnail
    files: 'attachment' // paperclip in the picker head
  };

  // An icon of Redmine's sprite in one of its sizes (s12 ... s20 in application.css).
  // createSVGIcon (application-legacy.js) clones the empty icon the base layout keeps
  // in #icon-copy-source, which carries the URL of the sprite. Pages without it (other
  // layouts have no upload forms) get no icon rather than an error.
  function icon(name, size = 18) {
    if (typeof window.createSVGIcon !== 'function' || !document.querySelector('#icon-copy-source svg')) return '';
    const svg = window.createSVGIcon(ICONS[name]);
    svg.classList.replace('s18', `s${size}`);
    // Icons drawn as filled shapes ("...-filled" in the sprite) are painted with fill
    // instead of stroke; Redmine's sprite_icon(style: :filled) adds this class for them.
    if (ICONS[name].endsWith('-filled')) svg.classList.add('icon-svg-filled');
    return svg;
  }

  // --- small helpers -------------------------------------------------------------

  // el('span', 'css-class', 'text' | [child nodes], { attribute: value })
  // Attributes are set in the given order (e.g. an image's "loading" before its "src").
  function el(tag, className, content, attributes) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (Array.isArray(content)) node.append(...content);
    else if (content !== undefined && content !== null) node.textContent = content;
    Object.entries(attributes || {}).forEach(([key, value]) => node.setAttribute(key, value));
    return node;
  }

  // A button with an icon and a text, or - with a tooltip instead of a text - only an icon.
  // It is a plain <button> styled by Redmine, with Redmine's icon classes for the
  // alignment of icon and text.
  function button(className, iconName, { text, tooltip } = {}) {
    const svg = icon(iconName, 16);
    if (text) {
      return el('button', `icon email-extract-button ${className}`, [svg, el('span', 'icon-label', text)],
        { type: 'button' });
    }
    return el('button', `icon-only email-extract-button ${className}`, [svg],
      { type: 'button', title: tooltip, 'aria-label': tooltip });
  }

  // An error whose message is meant for the user. Everything else thrown is a bug or
  // an answer the script does not understand: its technical text goes to the console,
  // the user gets the general error message.
  class UserError extends Error {}

  function showError(message) {
    window.alert(message);
  }

  function report(error) {
    if (error instanceof UserError) {
      showError(error.message);
      return;
    }
    console.error('[email_extract]', error); // eslint-disable-line no-console
    showError(t('error_failed'));
  }

  // True when the keyboard focus has nowhere to be: on the page itself, or on a
  // control that was just disabled or removed. A keyboard user would have to start
  // again from the top of the page.
  function focusIsLost() {
    const active = document.activeElement;
    return !active || active === document.body || !active.isConnected || active.disabled === true;
  }

  // Tells Redmine's own scripts (and browsers' form state) that a field changed.
  function notifyChange(field) {
    field.dispatchEvent(new Event('input', { bubbles: true }));
    field.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // Replaces removeLength characters at start by text. The user's cursor (or
  // selection) stays where it was in the text around it: setting the value of a
  // field moves it to the end otherwise.
  function splice(field, start, removeLength, text) {
    const { selectionStart, selectionEnd } = field;
    const move = (position) => {
      if (position <= start) return position;
      if (position >= start + removeLength) return position - removeLength + text.length;
      return start + text.length; // was inside the replaced part
    };
    field.value = field.value.slice(0, start) + text + field.value.slice(start + removeLength);
    if (typeof selectionStart === 'number') field.setSelectionRange(move(selectionStart), move(selectionEnd));
    notifyChange(field);
  }

  // --- server requests -----------------------------------------------------------

  function csrfToken() {
    const tag = document.querySelector('meta[name="csrf-token"]');
    return tag ? tag.content : '';
  }

  // Posts payload and returns the JSON answer. Every failure becomes a UserError with
  // a text that tells the user what to do; the server's own error texts are shown as
  // they are.
  async function postJSON(url, payload) {
    let response;
    try {
      response = await fetch(url, {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          'X-CSRF-Token': csrfToken(),
          'X-Requested-With': 'XMLHttpRequest'
        },
        body: JSON.stringify(payload)
      });
    } catch (error) {
      throw new UserError(t('error_network')); // fetch only fails when there is no answer at all
    }
    const type = response.headers.get('Content-Type') || '';
    const data = type.includes('json') ? await response.json().catch(() => null) : null;
    if (data && typeof data.error === 'string' && data.error) throw new UserError(data.error);
    // Redmine answers a request of an expired session with 401 or with a redirect to
    // its login page (an HTML page then), and one with an outdated CSRF token (e.g.
    // after signing in again in another tab) with 422 and an HTML page.
    if (response.status === 401 || response.status === 422 || response.redirected ||
        (response.ok && type.includes('text/html'))) {
      throw new UserError(t('error_session'));
    }
    if (!response.ok || !data || typeof data !== 'object') throw new UserError(t('error_failed'));
    return data;
  }

  // Deletes a stored upload that is not wanted any more, like its trash icon does.
  // The answer does not matter.
  function deleteUpload(path) {
    fetch(path, {
      method: 'DELETE',
      credentials: 'same-origin',
      headers: { Accept: 'text/javascript', 'X-CSRF-Token': csrfToken(), 'X-Requested-With': 'XMLHttpRequest' }
    }).catch(() => {});
  }

  // The answers of the server as the script expects them; anything else is a bug
  // (or not the plugin answering) and is not used.
  function isMail(mail) {
    return Boolean(mail) && Array.isArray(mail.messages) && mail.messages.every(Array.isArray) &&
      Array.isArray(mail.parts);
  }

  function isUpload(upload) {
    return Boolean(upload) && typeof upload.token === 'string' && typeof upload.filename === 'string' &&
      typeof upload.delete_path === 'string';
  }

  // --- text fields ---------------------------------------------------------------

  // Redmine re-renders parts of the issue form (e.g. after a tracker change) and
  // keeps the values, so an element that was replaced is looked up again by its id.
  function currentElement(element) {
    if (element.isConnected || !element.id) return element;
    return document.getElementById(element.id) || element;
  }

  function isShown(element) {
    return element.getClientRects().length > 0;
  }

  // The wiki toolbar block (jstoolbar.js) of a field that is hidden only because the
  // toolbar shows its Preview tab instead; null for any other field.
  function previewBlock(field) {
    if (!field.classList.contains('hidden')) return null;
    const block = field.closest('.jstBlock');
    return block && block.querySelector('.jstTabs .tab-preview.selected') ? block : null;
  }

  // A field the user sees, or would see on the Edit tab of its toolbar.
  function isUsable(field) {
    if (isShown(field)) return true;
    const block = previewBlock(field);
    return Boolean(block && isShown(block));
  }

  // The text field a mail goes into: the notes when editing an issue, otherwise the
  // description, otherwise the first formatted text field of the form (wiki, forum ...).
  // Apart from the notes (shown by revealField) only a usable field counts: when
  // editing an issue the description is hidden, and without the permission to add
  // notes there are no notes.
  function findTextField(form) {
    if (!form) return null;
    const notes = form.querySelector('#issue_notes');
    if (notes) return notes;
    const selectors = ['#issue_description', 'textarea.wiki-edit', 'textarea'];
    return selectors.flatMap((selector) => [...form.querySelectorAll(selector)]).find(isUsable) || null;
  }

  // Makes the field visible before a mail goes into it: the notes of an issue are
  // hidden until "Edit" is clicked, and the toolbar's Preview tab hides its field.
  function revealField(field) {
    const update = document.getElementById('update');
    if (update && update.style.display === 'none' && update.contains(field) &&
        typeof window.showAndScrollTo === 'function') {
      window.showAndScrollTo('update', field.id);
    }
    const block = previewBlock(field);
    const editTab = block && block.querySelector('.jstTabs .tab-edit');
    if (editTab) editTab.click(); // jstoolbar.js's hidePreview, as if the user clicked the tab
  }

  // The text field the user was in last and where its cursor was. A click on the chip
  // takes the focus away from the field (touch devices do not even focus the link),
  // so the cursor is remembered when the field loses the focus. Focusing anything
  // else but the chip forgets it: the mail then goes to the end of the field.
  const lastText = { field: null, end: 0 };

  function trackTextFocus() {
    document.addEventListener('focusout', (event) => {
      const field = event.target;
      if (!(field instanceof HTMLTextAreaElement)) return;
      lastText.field = field;
      lastText.end = field.selectionEnd;
    }, true);
    document.addEventListener('focusin', (event) => {
      const target = event.target;
      if (target instanceof HTMLTextAreaElement) return; // remembered when it loses the focus
      if (target instanceof Element && target.closest('.email-extract-chip')) return;
      lastText.field = null;
    }, true);
  }

  // Where text goes into the field: at its cursor if the user was in it last,
  // otherwise null (at the end).
  function caretIn(field) {
    if (document.activeElement === field) return field.selectionEnd;
    if (lastText.field === field) return Math.min(lastText.end, field.value.length);
    return null;
  }

  // --- MailText ------------------------------------------------------------------

  // The text of a mail as it is inserted: its header, the newest messages of its
  // thread and the attached images at their places.
  //
  // The server sends each message as a list of pieces: a string is text, a number
  // stands for the image with that index, shown at this place in the mail.
  class MailText {
    constructor(mail, { asQuote = false } = {}) {
      this.header = mail.header;
      this.messages = mail.messages;
      this.shownMessages = 1; // number of messages to insert, counted from the newest
      this.asQuote = asQuote; // the whole mail is quoted, header and newest message too (see compose)
      this.images = new Map(); // index of an attached image => its markup
    }

    get isEmpty() {
      return !this.header && !this.messages.length;
    }

    // Older messages are quoted by age, like mail programs do: "> " in front of every
    // line of the message before the newest, ">> " for the one before that, and so
    // on. As a quote (asQuote) the header and the newest message get "> " as well and
    // every older message one level more: the user inserts a mail someone else wrote.
    // Otherwise - the user's own mail - header and newest message stay unquoted.
    compose() {
      const placed = new Set();
      const texts = this.messages.slice(0, this.shownMessages).map((pieces) => {
        const blocks = pieces.map((piece) => {
          if (typeof piece === 'string') return piece;
          placed.add(piece);
          return this.images.get(piece);
        });
        return blocks.filter(Boolean).join('\n\n');
      });
      // The header belongs to the newest message: quoted, both form one quote block.
      const [newest = '', ...older] = texts;
      const offset = this.asQuote ? 1 : 0;
      const quoted = [[this.header, newest].filter(Boolean).join('\n\n'), ...older]
        .map((text, number) => MailText.quote(text, Math.min(number + offset, MAX_QUOTE_DEPTH)));
      // Images that have no place in the inserted messages go below them.
      const others = [...this.images].filter(([index]) => !placed.has(index)).map(([, markup]) => markup);
      return [...quoted, ...others].filter(Boolean).join('\n\n');
    }

    // "> " (">> " ...) in front of every line; Textile and Markdown both show this as
    // nested quote blocks. Empty lines get the mark alone, so that a quote with
    // paragraphs stays one block. The markdown hard breaks of the header ("  " at the
    // end of a line) are kept, so they work inside the quote as well. An empty text
    // (e.g. a message of images not attached) stays empty instead of becoming ">".
    static quote(text, depth) {
      if (!depth || !text) return text;
      const mark = '>'.repeat(depth);
      return text.split('\n').map((line) => (line ? `${mark} ${line}` : mark)).join('\n');
    }
  }

  // --- Insertion -----------------------------------------------------------------

  // A block of text this script put into a text field. It can be replaced and removed
  // again, as long as the user has not edited the block itself.
  //
  // The block is kept apart from the text around it by an empty line on both sides,
  // and the cursor is put below the empty line after it: text typed right after a
  // quote would otherwise become part of it (Markdown even continues a quote on the
  // next line). The block that must still be there for replacing and undoing is the
  // separator before it (lead) and the text; the separator after it (trail) is the
  // place where the user goes on writing and is removed by undo only if that leaves
  // the text as it was.
  class Insertion {
    constructor(field, text) {
      this.fieldElement = field;
      const caret = caretIn(field); // before revealing: the Edit tab takes the focus
      revealField(field);
      if (!isShown(field)) throw new UserError(t('error_no_field')); // never into a field the user can't see

      const value = field.value;
      const position = caret === null ? value.length : caret;
      const before = value.slice(0, position);
      const after = value.slice(position);

      this.lead = '';
      if (before && !before.endsWith('\n\n')) this.lead = before.endsWith('\n') ? '\n' : '\n\n';
      this.text = text;
      this.start = before.length; // where the block was seen last (see locate)
      const newlines = /^\n*/.exec(after)[0].length;
      this.trail = '\n'.repeat(Math.max(2 - newlines, 0));
      this.after = after; // the text that followed, to tell whether the user wrote after the block

      field.value = before + this.block + this.trail + after;
      const cursor = this.start + this.block.length + 2; // below the empty line after the block
      field.focus();
      field.setSelectionRange(cursor, cursor);
      notifyChange(field);
    }

    get block() {
      return this.lead + this.text;
    }

    // The field, looked up again if Redmine has replaced it (see currentElement).
    get field() {
      this.fieldElement = currentElement(this.fieldElement);
      return this.fieldElement;
    }

    // Where the block is in the field now, or -1 if it was edited. It is looked for
    // where it was last; text written above it moves it, and the same mail may be
    // in the field more than once (inserted twice, or copied), so then the copy
    // nearest to that place is taken.
    locate() {
      const value = this.field.value;
      const block = this.block;
      if (!block) return Math.min(this.start, value.length);
      if (value.startsWith(block, this.start)) return this.start;
      let nearest = -1;
      for (let at = value.indexOf(block); at >= 0; at = value.indexOf(block, at + 1)) {
        if (nearest < 0 || Math.abs(at - this.start) < Math.abs(nearest - this.start)) nearest = at;
      }
      return nearest;
    }

    // Adds text at the end of the field, for when the block was edited and can't be
    // replaced. Undo can't remove it then anyway, so it is not part of the block.
    append(text) {
      const field = this.field;
      const value = field.value;
      let separator = '';
      if (value && !value.endsWith('\n\n')) separator = value.endsWith('\n') ? '\n' : '\n\n';
      splice(field, value.length, 0, separator + text);
    }

    // Replaces the text of the block. Returns false if the block was edited.
    replace(text) {
      const start = this.locate();
      if (start < 0) return false;
      const oldLength = this.block.length;
      this.text = text;
      this.start = start;
      splice(this.field, start, oldLength, this.block);
      return true;
    }

    // Removes everything that was inserted. Returns false if the block was edited.
    remove() {
      const start = this.locate();
      if (start < 0) return false;
      const field = this.field;
      let length = this.block.length;
      // The empty line after the block goes too, unless the user has written below
      // it: then it keeps that text apart from the text above the block.
      const rest = field.value.slice(start + length);
      const unchanged = rest.slice(this.trail.length) === this.after;
      if (this.trail && rest.startsWith(this.trail) && (start === 0 || unchanged || rest === this.trail)) {
        length += this.trail.length;
      }
      splice(field, start, length, '');
      return true;
    }
  }

  // --- upload rows ---------------------------------------------------------------

  // Adds a file that is already stored on the server to the upload form, with the
  // markup Redmine's attachments.js creates after an upload, so that Redmine saves
  // it with the form and its trash icon deletes it.
  function addUploadRow(afterRow, upload) {
    const attachmentsForm = afterRow.closest('.attachments_form');
    const fileInput = attachmentsForm.querySelector('input.file_selector');
    const param = (fileInput && fileInput.dataset.param) || 'attachments';
    const id = window.addFile && window.addFile.nextAttachmentId ? window.addFile.nextAttachmentId++ : Date.now();
    const cloneIcon = (name) => {
      const template = attachmentsForm.querySelector(`.attachments_icons svg.svg-${name}`);
      return template ? template.cloneNode(true) : '';
    };

    const filename = el('input', 'icon icon-attachment filename readonly', null,
      { type: 'text', name: `${param}[${id}][filename]`, readonly: 'readonly' });
    filename.value = upload.filename;
    const token = el('input', 'token', null, { type: 'hidden', name: `${param}[${id}][token]` });
    token.value = upload.token;
    const remove = el('a', 'icon-only icon-del remove-upload', [cloneIcon('del')],
      { href: `${upload.delete_path}?attachment_id=${id}`, 'data-remote': 'true', 'data-method': 'delete' });

    const row = el('span', null, [cloneIcon('attachment'), filename], { id: `attachments_${id}` });
    // Rails renders data-description="true" / "false" (attachments.js checks for 0).
    const description = fileInput ? fileInput.dataset.description : undefined;
    if (description !== 'false' && description !== '0') {
      row.append(el('input', 'description', null, {
        type: 'text', name: `${param}[${id}][description]`, maxlength: 255,
        placeholder: (fileInput && fileInput.dataset.descriptionPlaceholder) || ''
      }));
    }
    row.append(token, remove);
    afterRow.after(row);
    updateFileLimit(attachmentsForm);
    return row;
  }

  // Deletes the row and the stored file, like a click on its trash icon.
  function removeUploadRow(row) {
    const remove = row.isConnected && row.querySelector('a.remove-upload');
    if (remove) remove.click();
  }

  // Number of files that can still be added to an upload form: like Redmine's
  // attachments.js, 10 for a multiple file input, otherwise 1, minus the rows there.
  function roomInForm(attachmentsForm) {
    const fileInput = attachmentsForm.querySelector('input.file_selector');
    const rows = attachmentsForm.querySelectorAll('.attachments_fields > span').length;
    const limit = fileInput && fileInput.multiple ? MAX_FILES_PER_FORM : 1;
    return Math.max(limit - rows, 0);
  }

  // Redmine hides the file chooser once a form holds the maximum number of files
  // (and shows it again by itself when a file is removed).
  function updateFileLimit(attachmentsForm) {
    const chooser = attachmentsForm.querySelector('.add_attachment');
    if (chooser && roomInForm(attachmentsForm) === 0) chooser.style.display = 'none';
  }

  // --- FilePicker ----------------------------------------------------------------

  // Panel that lists the images and files of a mail with a checkbox each.
  //   shownMessages       number of thread messages that are inserted (for the pre-selection)
  //   onAttach(indexes)   called with the chosen files; returns (a promise of) the number attached
  //   onClose(hadFocus)   called when the panel was closed; hadFocus: the keyboard focus was in it
  class FilePicker {
    constructor(parts, { shownMessages, onAttach, onClose }) {
      this.onClose = onClose;
      this.shownMessages = shownMessages;
      // manual: the user ticked or unticked it, so the pre-selection leaves it alone
      this.choices = parts.map((part) => ({ part, checkbox: null, manual: false }));

      this.attachButton = el('button', 'email-extract-button email-extract-attach', null, { type: 'button' });
      this.attachButton.addEventListener('click', () => this.attach(onAttach));
      const skip = el('a', 'email-extract-skip', t('skip'), { href: '#' });
      skip.addEventListener('click', (event) => {
        event.preventDefault();
        this.close();
      });

      this.element = el('div', 'email-extract-picker', [
        this.buildHead(parts),
        el('div', 'email-extract-tiles', this.choices.map((choice) => this.buildTile(choice))),
        el('div', 'email-extract-picker-actions', [this.attachButton, skip])
      ]);
      this.updateAttachButton();
    }

    get isOpen() {
      return this.element.isConnected;
    }

    buildHead(parts) {
      const hints = [];
      if (parts.some((part) => part.small)) hints.push(t('parts_hint_small'));
      if (parts.some((part) => part.message > 0)) hints.push(t('parts_hint_older'));
      return el('div', 'email-extract-picker-head', [
        icon('files', 16),
        el('strong', null, t('parts_title', { count: parts.length })),
        el('span', 'email-extract-hint', hints.join(' '))
      ]);
    }

    // A tile is a <div>, not a <label>: inside Redmine's ".tabular" forms every
    // label is floated into the label column, which would break the grid.
    buildTile(choice) {
      const { part } = choice;
      const checkbox = el('input', null, null, { type: 'checkbox', 'aria-label': part.filename });
      checkbox.checked = this.isSuggested(part);
      checkbox.addEventListener('change', () => {
        choice.manual = true;
        this.updateAttachButton();
      });
      choice.checkbox = checkbox;

      const tile = el('div', 'email-extract-tile', [
        checkbox,
        part.message > 0 ? el('span', 'email-extract-tag', t('older_tag')) : '',
        el('span', 'email-extract-preview', [FilePicker.preview(part)]),
        el('span', 'email-extract-filename', part.filename),
        el('span', 'email-extract-size', part.size_label)
      ], { title: part.filename });
      tile.addEventListener('click', (event) => {
        if (event.target === checkbox) return;
        checkbox.checked = !checkbox.checked;
        choice.manual = true;
        this.updateAttachButton();
      });
      return tile;
    }

    // The thumbnail of an image, the file icon otherwise and for a thumbnail that
    // fails to load. "loading" is set before "src", or the browser starts loading
    // at once; a mail can hold many images.
    static preview(part) {
      if (!part.thumb_url) return icon('file', 20); // enlarged by the stylesheet
      const image = el('img', null, null, { loading: 'lazy', decoding: 'async', alt: '', src: part.thumb_url });
      image.addEventListener('error', () => image.replaceWith(icon('file', 20)), { once: true });
      return image;
    }

    selectedIndexes() {
      return this.choices.filter((choice) => choice.checkbox.checked).map((choice) => choice.part.index);
    }

    // Worth attaching: everything that belongs to an inserted message, except small
    // images (logos, icons).
    isSuggested(part) {
      return !part.small && part.message < this.shownMessages;
    }

    // Pre-selects the files that fit the inserted text again, after the number of
    // inserted messages has changed. What the user chose by hand stays.
    selectSuggested(shownMessages) {
      this.shownMessages = shownMessages;
      this.choices.forEach(({ part, checkbox, manual }) => {
        if (!manual) checkbox.checked = this.isSuggested(part);
      });
      this.updateAttachButton();
    }

    updateAttachButton() {
      this.attachButton.textContent = t('attach_selected', { count: this.selectedIndexes().length });
    }

    async attach(onAttach) {
      const indexes = this.selectedIndexes();
      if (!indexes.length) {
        showError(t('error_none_selected'));
        return;
      }
      // The disabled button loses the focus; it is given back below.
      const hadFocus = this.element.contains(document.activeElement);
      this.attachButton.disabled = true; // also against a second click while the request runs
      this.attachButton.textContent = t('attaching');
      let attached = 0;
      try {
        attached = await onAttach(indexes);
      } catch (error) {
        report(error);
      }
      // Stays open if nothing was attached, so that other files can be chosen.
      if (attached > 0) {
        this.close(hadFocus);
        return;
      }
      this.attachButton.disabled = false;
      this.updateAttachButton();
      if (hadFocus && this.isOpen && focusIsLost()) this.attachButton.focus();
    }

    close(hadFocus = false) {
      if (!this.isOpen) return; // e.g. "Skip" while the files were being attached
      const focused = hadFocus || this.element.contains(document.activeElement);
      this.element.remove();
      this.onClose(focused);
    }
  }

  // --- StatusBar -----------------------------------------------------------------

  // Line below the mail after inserting: a message, controls for how many messages
  // of a thread are inserted (threads only), the "As quote" button and an undo button.
  // It hides itself after UNDO_TIMEOUT, but not while a mouse is over it, it has the
  // keyboard focus or is kept open. Touch screens have no hover, so every tap or key
  // press in it starts the time again.
  //   totalMessages          number of messages in the mail (1: no thread controls)
  //   onMessageCount(count)  called to insert that many messages; returns the number inserted now
  //   asQuote                starting state of the "As quote" button (true / false)
  //   onAsQuote(quoted)      called to (un)quote the whole mail; returns whether it is quoted now
  //   onUndo()               called on the undo button
  //   onHide()               called when the time is up; removes the line (see remove)
  //   keepOpen()             returns true while the line must stay (e.g. the picker is open)
  class StatusBar {
    constructor({ totalMessages, onMessageCount, asQuote, onAsQuote, onUndo, onHide, keepOpen }) {
      this.onHide = onHide;
      this.keepOpen = keepOpen;
      this.timer = null;
      this.hovered = false;

      this.messageText = el('span', 'icon-label', t('inserted'));
      const message = el('span', 'icon email-extract-message', [icon('inserted', 16), this.messageText],
        { role: 'status' });
      this.undoButton = button('email-extract-undo', 'undo', { text: t('undo') });
      this.undoButton.addEventListener('click', onUndo);
      const threadControls = totalMessages > 1 ? this.buildThreadControls(totalMessages, onMessageCount) : [];
      // Also for a single message and in every text field: whether the mail is a
      // quote depends on who wrote it, not on where it goes.
      const quoteToggle = this.buildQuoteToggle(asQuote, onAsQuote);
      this.element = el('div', 'email-extract-status',
        [message, ...threadControls, quoteToggle, this.undoButton]);

      // Hover with a mouse or pen only: a finger "enters" on every tap and does not
      // leave before the next tap elsewhere.
      this.element.addEventListener('pointerenter', (event) => {
        if (event.pointerType === 'touch') return;
        this.hovered = true;
        clearTimeout(this.timer);
      });
      this.element.addEventListener('pointerleave', () => {
        if (!this.hovered) return;
        this.hovered = false;
        this.restartTimer();
      });
      this.element.addEventListener('pointerdown', () => this.restartTimer());
      this.element.addEventListener('keydown', () => this.restartTimer());
      this.element.addEventListener('focusin', () => clearTimeout(this.timer));
      this.element.addEventListener('focusout', (event) => {
        if (!this.element.contains(event.relatedTarget)) this.restartTimer(); // not within the line
      });
    }

    // "[-] 2 of 8 messages [+]" to add or remove one older message, and "All".
    buildThreadControls(total, onMessageCount) {
      let shown = 1;
      const fewer = button('email-extract-step', 'fewer', { tooltip: t('messages_fewer') });
      const more = button('email-extract-step', 'more', { tooltip: t('messages_more') });
      const all = button('email-extract-all', 'all', { text: t('messages_all') });
      const count = el('span', 'email-extract-count', null, { 'aria-live': 'polite' });

      const refresh = () => {
        count.textContent = t('messages_shown', { count: shown, total });
        fewer.disabled = shown <= 1;
        more.disabled = shown >= total;
        all.disabled = shown >= total;
      };
      // A button that becomes disabled loses the keyboard focus; it goes to the
      // neighbour, which is enabled then (there are at least two messages).
      const show = (wanted, source, neighbour) => {
        const hadFocus = document.activeElement === source;
        shown = onMessageCount(wanted);
        refresh();
        if (hadFocus && source.disabled && !neighbour.disabled) neighbour.focus();
        this.restartTimer(); // after moving the focus: it decides whether the line stays
      };
      fewer.addEventListener('click', () => show(shown - 1, fewer, more));
      more.addEventListener('click', () => show(shown + 1, more, fewer));
      all.addEventListener('click', () => show(total, all, fewer));
      refresh();

      return [el('span', 'email-extract-stepper', [fewer, count, more], { role: 'group' }), all];
    }

    // "As quote": a toggle button (aria-pressed) that quotes the header and the newest
    // message as well, and every older message a level deeper.
    buildQuoteToggle(quoted, onAsQuote) {
      const toggle = button('email-extract-quote', 'quote', { text: t('as_quote') });
      toggle.title = t('as_quote_tooltip');

      const refresh = () => toggle.setAttribute('aria-pressed', String(quoted));
      toggle.addEventListener('click', () => {
        quoted = onAsQuote(!quoted);
        refresh();
        this.restartTimer();
      });
      refresh();
      return toggle;
    }

    setMessage(text) {
      this.messageText.textContent = text;
    }

    setUndoEnabled(enabled) {
      const hadFocus = document.activeElement === this.undoButton;
      this.undoButton.disabled = !enabled;
      if (hadFocus && !enabled) this.focusFirst();
    }

    // Gives the keyboard focus to the first control of the line that can take it.
    focusFirst() {
      const target = [...this.element.querySelectorAll('button')].find((control) => !control.disabled);
      if (target) target.focus();
    }

    restartTimer() {
      clearTimeout(this.timer);
      // A line that is already gone (e.g. focusout when it is removed) must not hide again.
      if (!this.element.isConnected || this.hovered || this.keepOpen()) return;
      // Keyboard focus inside keeps the line (a button focused by a mouse click does not).
      // During focusout the focus is already outside (document.activeElement is the body).
      const active = document.activeElement;
      if (active && this.element.contains(active) && active.matches(':focus-visible')) return;
      this.timer = setTimeout(() => this.onHide(), UNDO_TIMEOUT);
    }

    remove() {
      clearTimeout(this.timer);
      this.element.remove();
    }
  }

  // --- MailRow -------------------------------------------------------------------

  // One uploaded mail in an upload form: its chip and everything a click on it starts.
  class MailRow {
    constructor(row) {
      this.row = row;
      this.form = row.closest('form');
      this.busy = false;
      this.resetInsertState();

      // An icon link ("a.icon"), like Redmine's own controls in the row: attachments.js
      // shows all links of a row when its upload has finished. Space activates it like
      // a button (a link only reacts to Enter).
      this.chipText = el('span', 'icon-label');
      this.chip = el('a', 'icon email-extract-chip', [icon('insert'), this.chipText],
        { href: '#', role: 'button' });
      this.chip.addEventListener('click', (event) => {
        event.preventDefault();
        this.insert();
      });
      this.chip.addEventListener('keydown', (event) => {
        if (event.key !== ' ') return;
        event.preventDefault(); // no scrolling
        if (!event.repeat) this.insert();
      });

      const remove = row.querySelector('a.remove-upload');
      if (remove && remove.style.display === 'none') this.chip.style.display = 'none'; // still uploading
      row.insertBefore(this.chip, remove);
      this.updateChip();
    }

    resetInsertState() {
      this.mailText = null; // MailText: what of the mail is inserted
      this.insertion = null; // Insertion: the text in the field and where it is
      this.subjectFilled = null; // subject this script put into the empty subject field
      this.uploadRows = []; // rows of the files attached from the mail
      this.picker = null;
      this.statusBar = null;
    }

    // Rows of attachments.js have input.token, rows Redmine renders itself (e.g. after
    // a failed save) only the field name.
    get token() {
      const input = this.row.querySelector(TOKEN_FIELD);
      return input ? input.value : '';
    }

    get subjectField() {
      return this.form ? this.form.querySelector('#issue_subject') : null;
    }

    // The chip says where the mail goes, and is there only if it can go anywhere (an
    // upload form of its own, e.g. on the Files page, has no text field). Called again
    // whenever the page changes, as forms are re-rendered and loaded later. The chip is
    // also hidden while the status line is shown.
    updateChip() {
      const field = findTextField(this.form);
      const hidden = !field || Boolean(this.statusBar);
      if (this.chip.hidden !== hidden) this.chip.hidden = hidden;
      let label = t('insert');
      if (field && field.id.endsWith('notes')) label = t('insert_notes');
      else if (field && field.id.endsWith('description')) label = t('insert_description');
      // Only on a change: the text node is replaced, which the page observer sees.
      if (this.chipText.textContent !== label) {
        this.chipText.textContent = label;
        this.chip.title = label;
      }
    }

    async insert() {
      if (this.busy || this.insertion) return; // a second click while the first one is handled
      if (!this.token) {
        showError(t('error_uploading'));
        return;
      }
      if (!findTextField(this.form)) {
        this.updateChip();
        showError(t('error_no_field'));
        return;
      }

      this.setBusy(true);
      try {
        const mail = await postJSON(config.urls.extract, { token: this.token });
        if (!this.row.isConnected) return; // the mail was removed from the form meanwhile
        if (!isMail(mail)) throw new Error('unexpected answer of the server');
        if (new MailText(mail).isEmpty) throw new UserError(t('error_no_text'));
        // Looked up again: the form may have been re-rendered or changed meanwhile.
        const field = findTextField(this.form);
        if (!field) throw new UserError(t('error_no_field'));
        this.showMail(field, mail);
      } catch (error) {
        report(error);
      } finally {
        this.setBusy(false);
      }
    }

    setBusy(busy) {
      this.busy = busy;
      this.chip.classList.toggle('email-extract-busy', busy);
    }

    // Inserts the newest message of the mail and shows the status line and the picker.
    // A mail someone else sent goes in as a quote; in a mail the user sent, the newest
    // message is the user's own and is not quoted. The user can switch it.
    showMail(field, mail) {
      const mailText = new MailText(mail, { asQuote: !mail.sent_by_me });
      const insertion = new Insertion(field, mailText.compose()); // throws if the field can't be shown
      this.mailText = mailText;
      this.insertion = insertion;
      this.fillSubject(mail.subject);

      this.statusBar = new StatusBar({
        totalMessages: mail.messages.length,
        onMessageCount: (count) => this.showMessages(count),
        asQuote: this.mailText.asQuote,
        onAsQuote: (quoted) => this.setAsQuote(quoted),
        onUndo: () => this.undo(),
        onHide: () => this.finish(),
        keepOpen: () => Boolean(this.picker && this.picker.isOpen)
      });
      this.row.append(this.statusBar.element);
      this.updateChip();

      if (mail.parts.length) {
        this.picker = new FilePicker(mail.parts, {
          shownMessages: this.mailText.shownMessages,
          onAttach: (indexes) => this.attachFiles(indexes),
          onClose: (hadFocus) => this.pickerClosed(hadFocus)
        });
        this.row.append(this.picker.element);
      }
      this.statusBar.restartTimer();
    }

    // After "Skip" or attaching, a keyboard user goes on in the status line.
    pickerClosed(hadFocus) {
      if (!this.statusBar) return;
      if (hadFocus && focusIsLost()) this.statusBar.focusFirst();
      this.statusBar.restartTimer();
    }

    // Uses the subject of the mail for a new issue that has none yet.
    fillSubject(subject) {
      const field = this.subjectField;
      if (!field || typeof subject !== 'string' || !subject || field.value.trim()) return;
      field.value = subject;
      this.subjectFilled = subject;
      notifyChange(field);
    }

    // Brings the text field up to date after the mail text has changed.
    // Returns false if the user has edited the inserted text, so it can't be replaced.
    refreshText() {
      return this.insertion.replace(this.mailText.compose());
    }

    // Changes how many messages of the thread are inserted.
    // Returns the number that is inserted afterwards.
    showMessages(count) {
      const previous = this.mailText.shownMessages;
      this.mailText.shownMessages = count;
      if (this.refreshText()) {
        if (this.picker && this.picker.isOpen) this.picker.selectSuggested(count);
      } else {
        this.mailText.shownMessages = previous;
        showError(t('error_switch'));
      }
      return this.mailText.shownMessages;
    }

    // Quotes the whole mail - header and newest message too, the older messages a
    // level deeper - or not. Returns whether it is quoted afterwards.
    setAsQuote(quoted) {
      const previous = this.mailText.asQuote;
      this.mailText.asQuote = quoted;
      if (!this.refreshText()) {
        this.mailText.asQuote = previous;
        showError(t('error_switch'));
      }
      return this.mailText.asQuote;
    }

    // Stores the chosen files of the mail as uploads, lists them in the form and
    // shows the images in the inserted text, at their places in the mail.
    // Returns the number of files attached.
    async attachFiles(indexes) {
      const statusBar = this.statusBar;
      if (!statusBar || !this.row.isConnected) return 0;
      const room = roomInForm(this.row.closest('.attachments_form'));
      if (indexes.length > room) {
        throw new UserError(room > 0 ? t('error_too_many', { count: room }) : t('error_form_full'));
      }

      // Undo, the hidden status line (after "Skip") or removing the mail can end
      // this insertion while the request runs; that is noticed by its MailText.
      const mailText = this.mailText;
      statusBar.setUndoEnabled(false);
      let result;
      try {
        result = await postJSON(config.urls.attach, { token: this.token, indexes });
      } finally {
        statusBar.setUndoEnabled(true);
      }
      if (!Array.isArray(result.uploads)) throw new Error('unexpected answer of the server');
      const uploads = result.uploads.filter(isUpload);
      const errors = Array.isArray(result.errors) ? result.errors.filter((error) => typeof error === 'string') : [];
      if (this.mailText !== mailText || !this.row.isConnected) {
        uploads.forEach((upload) => deleteUpload(upload.delete_path));
        return 0;
      }

      // The user may have removed some of the rows added before.
      let lastRow = this.uploadRows.filter((row) => row.isConnected).pop() || this.row;
      uploads.forEach((upload) => {
        lastRow = addUploadRow(lastRow, upload);
        this.uploadRows.push(lastRow);
      });

      // Only images have markup; it is used as the server sends it.
      const images = uploads.filter((upload) => typeof upload.markup === 'string' && upload.markup);
      images.forEach((upload) => mailText.images.set(upload.index, upload.markup));
      if (images.length && !this.refreshText()) {
        // The inserted text was edited: leave it alone and put the images below it.
        images.forEach((upload) => mailText.images.delete(upload.index));
        this.insertion.append(images.map((upload) => upload.markup).join('\n\n'));
      }
      if (uploads.length) statusBar.setMessage(t('attached', { count: uploads.length }));
      if (errors.length) showError(errors.join('\n'));
      return uploads.length;
    }

    undo() {
      if (!this.insertion.remove()) {
        showError(t('error_undo'));
        return;
      }
      const subject = this.subjectField;
      if (subject && this.subjectFilled && subject.value === this.subjectFilled) {
        subject.value = '';
        notifyChange(subject);
      }
      this.uploadRows.forEach(removeUploadRow);
      this.finish();
    }

    // Back to the initial state: only the chip is shown. A keyboard user who was in
    // the status line or the picker continues at the chip.
    finish() {
      const active = document.activeElement;
      const hadFocus = [this.picker, this.statusBar].some((part) => part && part.element.contains(active));
      if (this.picker) this.picker.element.remove();
      if (this.statusBar) this.statusBar.remove();
      this.resetInsertState();
      this.updateChip();
      if (hadFocus && !this.chip.hidden && this.chip.isConnected) this.chip.focus();
    }
  }

  // --- start-up ------------------------------------------------------------------

  const UPLOAD_ROW = '.attachments_fields > span';
  const mailRows = new WeakMap(); // upload row => its MailRow
  const liveRows = new Set(); // MailRows on the page, whose chips are kept up to date

  // Only fresh uploads (with a token field, possibly still empty while uploading) get
  // a chip; files already attached to the object have only an [id] field.
  function setUpRow(row) {
    if (mailRows.has(row)) {
      liveRows.add(mailRows.get(row)); // moved within the page
      return;
    }
    const filename = row.querySelector('input.filename');
    if (!filename || !MAIL_FILE.test(filename.value)) return;
    if (!row.querySelector(TOKEN_FIELD)) return;
    const mailRow = new MailRow(row);
    mailRows.set(row, mailRow);
    liveRows.add(mailRow);
  }

  function setUpRowsIn(node) {
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    if (node.matches(UPLOAD_ROW)) setUpRow(node);
    node.querySelectorAll(UPLOAD_ROW).forEach(setUpRow);
  }

  // Updates the chips once per frame at most, and only while there are any: finding
  // the text field asks the browser for the layout.
  let refreshPending = false;
  function scheduleRefresh() {
    if (refreshPending || !liveRows.size) return;
    refreshPending = true;
    requestAnimationFrame(() => {
      refreshPending = false;
      liveRows.forEach((mailRow) => {
        if (mailRow.row.isConnected) mailRow.updateChip();
        else liveRows.delete(mailRow);
      });
    });
  }

  function start() {
    trackTextFocus();
    setUpRowsIn(document.body);
    // Rows appear when files are chosen, and whole forms are loaded later (e.g. inline
    // editing). Text fields come and go with re-rendered forms.
    const observer = new MutationObserver((mutations) => {
      let changed = false;
      mutations.forEach((mutation) => {
        mutation.addedNodes.forEach(setUpRowsIn);
        if (mutation.addedNodes.length || mutation.removedNodes.length) changed = true;
      });
      if (changed) scheduleRefresh();
    });
    observer.observe(document.body, { childList: true, subtree: true });
    // Some fields are shown without new elements, e.g. the description of an issue
    // after a click on its edit icon.
    document.addEventListener('click', scheduleRefresh);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
