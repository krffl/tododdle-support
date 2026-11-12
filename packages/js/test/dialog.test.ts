// @vitest-environment happy-dom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { openReportDialog } from '../src/dialog';
import { TododdleSupportError, type ReportInput, type ReportResult, type TododdleSupport } from '../src/index';
import { cloneConfig } from './helpers';

function fakeSupport(report: (input: ReportInput) => Promise<ReportResult>, config = cloneConfig()): TododdleSupport {
  return {
    getConfig: vi.fn(async () => config),
    getCachedConfig: vi.fn(async () => config),
    report: vi.fn(report),
    flushQueue: vi.fn(async () => ({ sent: [], dropped: [], remaining: 0 })),
    queuedCount: vi.fn(async () => 0),
  };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

function dialog(): HTMLDialogElement {
  const node = document.querySelector('dialog');
  if (!node) throw new Error('no dialog');
  return node;
}

function set(name: string, value: string) {
  const control = dialog().querySelector<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>(
    `[name="${name}"]`,
  );
  if (!control) throw new Error(`no control ${name}`);
  control.value = value;
}

function submit() {
  dialog()
    .querySelector('form')
    ?.dispatchEvent(new Event('submit', { cancelable: true }));
}

afterEach(() => {
  document.body.replaceChildren();
});

describe('openReportDialog', () => {
  it('renders the config form with labels, theme and focus', async () => {
    const opener = document.createElement('button');
    document.body.append(opener);
    opener.focus();
    const support = fakeSupport(async () => ({ status: 'received', reportId: 'rpt_1', idempotencyKey: 'k' }));
    const closed = openReportDialog(support);
    await flush();
    const node = dialog();
    expect(node.open).toBe(true);
    expect(node.getAttribute('aria-labelledby')).toBe(node.querySelector('h2')?.id);
    expect(node.querySelector('h2')?.textContent).toBe('Tell us what happened');
    expect(node.style.getPropertyValue('--tdsk-accent')).toBe('#2f6d4f');
    const labels = Array.from(node.querySelectorAll('label'), (label) => label.firstChild?.textContent);
    expect(labels).toEqual([
      'Type',
      'Summary',
      'What happened?',
      'Where in the app?',
      'Steps to reproduce',
      'Attachments (optional)',
    ]);
    for (const label of Array.from(node.querySelectorAll('label'))) {
      expect(label.querySelector(`#${CSS.escape(label.htmlFor)}`)).not.toBeNull();
    }
    expect(document.activeElement?.getAttribute('name')).toBe('type');
    node.close();
    expect(await closed).toBeNull();
    expect(document.querySelector('dialog')).toBeNull();
    expect(document.activeElement).toBe(opener);
  });

  it('shows field errors from validation and sends nothing else', async () => {
    const support = fakeSupport(async () => {
      throw new TododdleSupportError({
        code: 'INVALID_FIELDS',
        message: 'Check.',
        httpStatus: 0,
        fields: { description: 'Describe what happened.' },
      });
    });
    void openReportDialog(support);
    await flush();
    submit();
    await flush();
    const description = dialog().querySelector('[name="description"]');
    expect(description?.getAttribute('aria-invalid')).toBe('true');
    const errorId = description?.getAttribute('aria-describedby') ?? '';
    expect(document.getElementById(errorId)?.textContent).toBe('Describe what happened.');
    expect(document.activeElement).toBe(description);
    dialog().close();
  });

  it('shows a general error when sending fails', async () => {
    const support = fakeSupport(async () => {
      throw new TododdleSupportError({ code: 'NETWORK_ERROR', message: 'x', httpStatus: 0 });
    });
    void openReportDialog(support);
    await flush();
    submit();
    await flush();
    const alert = dialog().querySelector('[role="alert"]');
    expect(alert?.hasAttribute('hidden')).toBe(false);
    expect(dialog().querySelector<HTMLButtonElement>('button[type="submit"]')?.disabled).toBe(false);
    dialog().close();
  });

  it('sends the typed values and context, then thanks the person', async () => {
    const support = fakeSupport(async () => ({ status: 'received', reportId: 'rpt_1', idempotencyKey: 'k' }));
    const onSubmitted = vi.fn();
    const closed = openReportDialog(support, {
      context: { appVersion: '2.4.0' },
      reporter: { customerReference: 'u-1' },
      defaultType: 'feedback',
      onSubmitted,
    });
    await flush();
    set('description', 'It broke.');
    set('area', 'Home');
    submit();
    await flush();
    expect(support.report).toHaveBeenCalledWith(
      expect.objectContaining({
        type: 'feedback',
        description: 'It broke.',
        fields: { area: 'Home', steps: '' },
        context: { appVersion: '2.4.0' },
        reporter: { customerReference: 'u-1' },
        attachments: [],
      }),
      expect.anything(),
    );
    expect(onSubmitted).toHaveBeenCalled();
    expect(dialog().querySelector('[role="status"] h2')?.textContent).toBe('Thanks!');
    dialog().querySelector<HTMLButtonElement>('.tdsk-done button')?.click();
    expect(await closed).toMatchObject({ reportId: 'rpt_1' });
  });

  it('lets the person add and remove chosen files', async () => {
    const support = fakeSupport(async () => ({ status: 'received', reportId: 'rpt_1', idempotencyKey: 'k' }));
    void openReportDialog(support);
    await flush();
    const input = dialog().querySelector<HTMLInputElement>('input[type="file"]');
    if (!input) throw new Error('no file input');
    const file = new File(['png'], 'shot.png', { type: 'image/png' });
    Object.defineProperty(input, 'files', { value: [file], configurable: true });
    input.dispatchEvent(new Event('change'));
    expect(dialog().querySelectorAll('li')).toHaveLength(1);
    dialog().querySelector<HTMLButtonElement>('li button')?.click();
    expect(dialog().querySelectorAll('li')).toHaveLength(0);
    dialog().close();
  });

  it('hides the type picker and file picker when not needed', async () => {
    const config = cloneConfig();
    config.form.types = [{ value: 'problem', label: 'Problem' }];
    config.form.attachments.enabled = false;
    config.theme.corners = 'square';
    config.project.logoUrl = 'https://example.test/logo.png';
    void openReportDialog(
      fakeSupport(async () => ({ status: 'queued', idempotencyKey: 'k' }), config),
      { allowAttachments: true },
    );
    await flush();
    expect(dialog().querySelector('[name="type"]')).toBeNull();
    expect(dialog().querySelector('input[type="file"]')).toBeNull();
    expect(dialog().querySelector('header img')?.getAttribute('alt')).toBe('');
    expect(dialog().style.getPropertyValue('--tdsk-radius')).toBe('0px');
    dialog().close();
  });

  it('shows the logo only from https and applies only contract hex colours', async () => {
    for (const logoUrl of ['http://example.test/logo.png', 'javascript:alert(1)', 'data:image/png;base64,AAAA']) {
      const config = cloneConfig();
      config.project.logoUrl = logoUrl;
      config.theme.accent = 'red;background:url(https://evil.example/x)';
      config.theme.onAccent = '#FFFFFF';
      void openReportDialog(fakeSupport(async () => ({ status: 'queued', idempotencyKey: 'k' }), config));
      await flush();
      expect(dialog().querySelector('header img'), logoUrl).toBeNull();
      expect(dialog().style.getPropertyValue('--tdsk-accent')).toBe('');
      expect(dialog().style.getPropertyValue('--tdsk-on-accent')).toBe('');
      dialog().close();
      document.body.replaceChildren();
    }
  });
});
