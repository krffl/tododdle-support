/**
 * A small, optional report dialog for the web, built on the native `<dialog>` element.
 * Import it from `@krffl/tododdle-support/dialog`. It renders the project's config form and
 * sends the report with the client you pass in. It collects only what the person types or chooses.
 */
import { isTododdleSupportError } from './errors';
import type {
  AttachmentContentType,
  AttachmentInput,
  Config,
  ReportContext,
  Reporter,
  ReportInput,
  ReportResult,
  ReportType,
  TododdleSupport,
} from './types';
import { isHexColor, isHttpsUrl } from './util';
import { DESCRIPTION_MAX_LENGTH, fieldMaxLength, TITLE_MAX_LENGTH } from './validate';

export interface ReportDialogOptions {
  /** Context to attach, such as `appVersion` or `screen`. Nothing is added automatically. */
  context?: ReportContext;
  /** Optional, unverified reporter details the app already knows. */
  reporter?: Reporter;
  /** The report type selected at first. Defaults to the first type in the config. */
  defaultType?: ReportType;
  /** Set to false to hide the file picker even when the form accepts attachments. */
  allowAttachments?: boolean;
  /** Where to put the dialog. Defaults to `document.body`. */
  parent?: HTMLElement;
  /** Called after the report is received or queued, before the thank-you view shows. */
  onSubmitted?: (result: ReportResult) => void;
}

const STYLE = `
.tdsk{--tdsk-accent:#1d1d1f;--tdsk-on-accent:#fff;--tdsk-bg:#fff;--tdsk-fg:#1d1d1f;--tdsk-muted:#5f6368;--tdsk-line:#c8cbd0;--tdsk-error:#b3261e;
color:var(--tdsk-fg);background:var(--tdsk-bg);border:1px solid var(--tdsk-line);border-radius:var(--tdsk-radius);
padding:0;width:min(32rem,calc(100vw - 2rem));max-height:calc(100vh - 2rem);font:15px/1.45 system-ui,sans-serif}
@media (prefers-color-scheme:dark){.tdsk{--tdsk-bg:#1f2123;--tdsk-fg:#f1f3f4;--tdsk-muted:#b0b4b9;--tdsk-line:#4a4e53;--tdsk-error:#f2b8b5}}
.tdsk::backdrop{background:rgb(0 0 0/.45)}
.tdsk form,.tdsk .tdsk-done{display:grid;gap:.9rem;padding:1.25rem}
.tdsk header{display:flex;gap:.75rem;align-items:center}
.tdsk header img{width:2rem;height:2rem;object-fit:contain}
.tdsk h2{margin:0;font-size:1.2rem;line-height:1.3}
.tdsk p{margin:0}
.tdsk .tdsk-muted{color:var(--tdsk-muted)}
.tdsk label{display:grid;gap:.3rem;font-weight:600}
.tdsk input,.tdsk select,.tdsk textarea{font:inherit;font-weight:400;color:inherit;background:transparent;
border:1px solid var(--tdsk-line);border-radius:calc(var(--tdsk-radius)/2);padding:.5rem .6rem}
.tdsk textarea{min-height:6rem;resize:vertical}
.tdsk :focus-visible{outline:2px solid var(--tdsk-accent);outline-offset:2px}
.tdsk [aria-invalid=true]{border-color:var(--tdsk-error)}
.tdsk .tdsk-error{color:var(--tdsk-error);font-weight:400;font-size:.9em}
.tdsk ul{list-style:none;margin:0;padding:0;display:grid;gap:.3rem}
.tdsk li{display:flex;justify-content:space-between;gap:.5rem;align-items:center}
.tdsk .tdsk-actions{display:flex;justify-content:flex-end;gap:.5rem}
.tdsk button{font:inherit;font-weight:600;border-radius:calc(var(--tdsk-radius)/2);padding:.5rem 1rem;cursor:pointer;
border:1px solid var(--tdsk-line);background:transparent;color:inherit}
.tdsk button.tdsk-primary{background:var(--tdsk-accent);color:var(--tdsk-on-accent);border-color:var(--tdsk-accent)}
.tdsk button:disabled{opacity:.6;cursor:default}
`;

let nextId = 0;

type Attributes = Record<string, string | boolean | number | undefined>;

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attributes: Attributes = {},
  ...children: Array<Node | string | null>
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (value === undefined || value === false) continue;
    node.setAttribute(name, value === true ? '' : String(value));
  }
  for (const child of children) if (child !== null) node.append(child);
  return node;
}

function typeOf(file: File, allowed: readonly string[]): AttachmentContentType | null {
  return allowed.includes(file.type) ? (file.type as AttachmentContentType) : null;
}

/**
 * Opens the report dialog. Resolves with the result after the person closes the dialog, or with
 * `null` if they closed it without sending. Rejects only if the config cannot be loaded.
 */
export async function openReportDialog(
  support: TododdleSupport,
  options: ReportDialogOptions = {},
): Promise<ReportResult | null> {
  const config = await support.getConfig();
  return showDialog(support, config, options);
}

function showDialog(
  support: TododdleSupport,
  config: Config,
  options: ReportDialogOptions,
): Promise<ReportResult | null> {
  const { form, wording, theme, project } = config;
  const id = `tdsk-${(nextId += 1)}`;
  const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const errorNodes = new Map<string, { control: HTMLElement; message: HTMLElement }>();
  const attachments: AttachmentInput[] = [];
  let result: ReportResult | null = null;

  const dialog = el('dialog', { class: 'tdsk', 'aria-labelledby': `${id}-title` });
  // Only colours in the contract's form reach the stylesheet; anything else keeps the defaults.
  if (isHexColor(theme.accent)) dialog.style.setProperty('--tdsk-accent', theme.accent);
  if (isHexColor(theme.onAccent)) dialog.style.setProperty('--tdsk-on-accent', theme.onAccent);
  dialog.style.setProperty('--tdsk-radius', theme.corners === 'square' ? '0px' : '12px');

  function field(key: string, label: string, control: HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement) {
    const message = el('span', { class: 'tdsk-error', id: `${id}-${key}-error`, hidden: true });
    control.id = `${id}-${key}`;
    control.name = key;
    errorNodes.set(key, { control, message });
    return el('label', { for: control.id }, label, control, message);
  }

  function selectControl(
    values: Array<{ value: string; label: string }>,
    placeholder: string | null,
    required: boolean,
  ) {
    const select = el('select', { required });
    if (placeholder !== null) select.append(el('option', { value: '' }, placeholder));
    for (const option of values) select.append(el('option', { value: option.value }, option.label));
    return select;
  }

  const typeSelect = selectControl(form.types, null, true);
  const initialType = form.types.find((option) => option.value === options.defaultType) ?? form.types[0];
  if (initialType) typeSelect.value = initialType.value;
  const titleInput = form.title?.enabled
    ? el('input', {
        type: 'text',
        required: form.title.required,
        maxlength: form.title.maxLength ?? TITLE_MAX_LENGTH,
      })
    : null;
  const descriptionInput = el('textarea', {
    required: form.description?.required ?? false,
    maxlength: form.description?.maxLength ?? DESCRIPTION_MAX_LENGTH,
    placeholder: form.description?.placeholder,
  });
  const customControls = form.fields.map((definition) => {
    const control =
      definition.type === 'SELECT'
        ? selectControl(
            (definition.options ?? []).map((option) => ({ value: option, label: option })),
            'Choose…',
            definition.required,
          )
        : el(definition.type === 'LONG_TEXT' ? 'textarea' : 'input', {
            type: definition.type === 'LONG_TEXT' ? undefined : 'text',
            required: definition.required,
            maxlength: fieldMaxLength(definition),
          });
    return { definition, control };
  });

  const allowFiles = options.allowAttachments !== false && form.attachments.enabled && form.attachments.maxCount > 0;
  const fileList = el('ul', { 'aria-live': 'polite' });
  const fileInput = el('input', { type: 'file', multiple: true, accept: form.attachments.contentTypes.join(',') });
  function renderFiles() {
    fileList.replaceChildren(
      ...attachments.map((attachment, index) => {
        const remove = el('button', { type: 'button', 'aria-label': `Remove ${attachment.fileName}` }, 'Remove');
        remove.addEventListener('click', () => {
          attachments.splice(index, 1);
          renderFiles();
          fileInput.focus();
        });
        return el('li', {}, attachment.fileName, remove);
      }),
    );
  }
  fileInput.addEventListener('change', () => {
    for (const file of Array.from(fileInput.files ?? [])) {
      const contentType = typeOf(file, form.attachments.contentTypes);
      // Unsupported types are kept with their own type so validation can explain the problem.
      attachments.push({
        fileName: file.name,
        contentType: contentType ?? (file.type as AttachmentContentType),
        data: file,
      });
    }
    fileInput.value = '';
    renderFiles();
  });

  const formError = el('p', { class: 'tdsk-error', role: 'alert', hidden: true });
  const submit = el('button', { type: 'submit', class: 'tdsk-primary' }, wording.submitLabel);
  const cancel = el('button', { type: 'button' }, 'Cancel');
  cancel.addEventListener('click', () => dialog.close());

  const header = el(
    'header',
    {},
    isHttpsUrl(project.logoUrl) ? el('img', { src: project.logoUrl, alt: '' }) : null,
    el('h2', { id: `${id}-title` }, wording.dialogTitle),
  );
  const formNode = el(
    'form',
    { novalidate: true },
    header,
    wording.intro ? el('p', { class: 'tdsk-muted' }, wording.intro) : null,
    form.types.length > 1 ? field('type', 'Type', typeSelect) : null,
    titleInput && form.title ? field('title', form.title.label, titleInput) : null,
    field('description', form.description?.label ?? 'Description', descriptionInput),
    ...customControls.map(({ definition, control }) => field(definition.key, definition.label, control)),
    allowFiles ? field('attachments', 'Attachments (optional)', fileInput) : null,
    allowFiles ? fileList : null,
    formError,
    el('div', { class: 'tdsk-actions' }, cancel, submit),
  );
  dialog.append(el('style', {}, STYLE), formNode);

  function showErrors(fields: Record<string, string>) {
    let first: HTMLElement | null = null;
    for (const [key, { control, message }] of errorNodes) {
      const text = fields[key];
      message.textContent = text ?? '';
      message.hidden = text === undefined;
      control.setAttribute('aria-invalid', String(text !== undefined));
      if (text === undefined) control.removeAttribute('aria-describedby');
      else {
        control.setAttribute('aria-describedby', message.id);
        first ??= control;
      }
    }
    first?.focus();
    return first !== null;
  }

  function collect(): ReportInput {
    const fields: Record<string, string> = {};
    for (const { definition, control } of customControls) fields[definition.key] = control.value;
    return {
      type: typeSelect.value as ReportType,
      title: titleInput?.value,
      description: descriptionInput.value,
      fields,
      attachments: allowFiles ? [...attachments] : [],
      context: options.context,
      reporter: options.reporter,
    };
  }

  function showThanks() {
    const close = el('button', { type: 'button', class: 'tdsk-primary' }, 'Close');
    close.addEventListener('click', () => dialog.close());
    const done = el(
      'div',
      { class: 'tdsk-done', role: 'status' },
      el('h2', { id: `${id}-title` }, wording.thankYouTitle),
      el('p', {}, wording.thankYouMessage),
      el('div', { class: 'tdsk-actions' }, close),
    );
    formNode.replaceWith(done);
    close.focus();
  }

  formNode.addEventListener('submit', (event) => {
    event.preventDefault();
    if (submit.disabled) return;
    formError.hidden = true;
    showErrors({});
    submit.disabled = true;
    submit.textContent = 'Sending…';
    support
      .report(collect(), { config })
      .then((sent) => {
        result = sent;
        options.onSubmitted?.(sent);
        showThanks();
      })
      .catch((error: unknown) => {
        const fields = isTododdleSupportError(error) ? error.fields : {};
        if (showErrors(fields)) return;
        formError.textContent = 'The report could not be sent. Please try again.';
        formError.hidden = false;
      })
      .finally(() => {
        submit.disabled = false;
        submit.textContent = wording.submitLabel;
      });
  });

  return new Promise((resolve) => {
    dialog.addEventListener('close', () => {
      dialog.remove();
      previousFocus?.focus();
      resolve(result);
    });
    (options.parent ?? document.body).append(dialog);
    if (typeof dialog.showModal === 'function') {
      dialog.showModal();
    } else {
      // Very old browsers: no modal, so handle Escape here.
      dialog.setAttribute('open', '');
      dialog.addEventListener('keydown', (event) => {
        if (event.key === 'Escape') dialog.close();
      });
    }
    (form.types.length > 1 ? typeSelect : (titleInput ?? descriptionInput)).focus();
  });
}
