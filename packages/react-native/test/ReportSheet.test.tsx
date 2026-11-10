import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { act } from 'react';
import TestRenderer, { type ReactTestInstance, type ReactTestRenderer } from 'react-test-renderer';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  ReportSheet,
  TododdleSupportError,
  type Config,
  type ReportInput,
  type ReportResult,
  type TododdleSupport,
} from '../src/index';

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const casesPath = join(import.meta.dirname, '../../../contract/cases/cases.json');
const sharedConfig = (JSON.parse(readFileSync(casesPath, 'utf8')) as { config: Config }).config;

function fakeClient(
  report: (input: ReportInput) => Promise<ReportResult>,
  getConfig: () => Promise<Config> = async () => structuredClone(sharedConfig),
): TododdleSupport {
  return {
    getConfig: vi.fn(getConfig),
    getCachedConfig: vi.fn(async () => null),
    report: vi.fn(report),
    flushQueue: vi.fn(async () => ({ sent: [], dropped: [], remaining: 0 })),
    queuedCount: vi.fn(async () => 0),
  };
}

/** Host components from the mock are plain strings. */
const is = (node: ReactTestInstance, name: string) => (node.type as string) === name;

const received = async (): Promise<ReportResult> => ({ status: 'received', reportId: 'rpt_1', idempotencyKey: 'k' });

let renderer: ReactTestRenderer | undefined;
afterEach(() => {
  act(() => renderer?.unmount());
  renderer = undefined;
  vi.unstubAllGlobals();
});

async function render(element: React.ReactElement): Promise<ReactTestRenderer> {
  await act(async () => {
    renderer = TestRenderer.create(element);
  });
  if (!renderer) throw new Error('not rendered');
  return renderer;
}

function texts(root: ReactTestRenderer): string[] {
  return root.root
    .findAll((node) => is(node, 'Text'))
    .flatMap((node) => node.children.filter((c) => typeof c === 'string'));
}

function pressable(root: ReactTestRenderer, label: string): ReactTestInstance {
  return root.root.find(
    (node) =>
      is(node, 'Pressable') && node.findAll((child) => is(child, 'Text') && child.children.includes(label)).length > 0,
  );
}

async function press(root: ReactTestRenderer, label: string) {
  await act(async () => {
    (pressable(root, label).props as { onPress: () => void }).onPress();
  });
}

async function type(root: ReactTestRenderer, label: string, value: string) {
  const input = root.root.find((node) => is(node, 'TextInput') && node.props.accessibilityLabel === label);
  await act(async () => {
    (input.props as { onChangeText: (text: string) => void }).onChangeText(value);
  });
}

describe('ReportSheet', () => {
  it('renders nothing while hidden', async () => {
    const root = await render(<ReportSheet client={fakeClient(received)} visible={false} onClose={() => undefined} />);
    expect(root.toJSON()).toBeNull();
  });

  it('renders the form with branding and validates before sending', async () => {
    const client = fakeClient(received);
    const root = await render(<ReportSheet client={client} visible onClose={() => undefined} />);
    expect(texts(root)).toEqual(
      expect.arrayContaining(['Tell us what happened', 'Report a problem', 'What happened?', 'Where in the app?']),
    );
    const send = pressable(root, 'Send report');
    expect(send.props.style).toEqual(expect.arrayContaining([{ backgroundColor: '#2f6d4f', borderColor: '#2f6d4f' }]));
    await press(root, 'Send report');
    expect(client.report).not.toHaveBeenCalled();
    expect(texts(root)).toEqual(expect.arrayContaining(['This field is required.', 'Choose an option.']));
  });

  it('sends typed values with platform and host context, then thanks the person', async () => {
    const client = fakeClient(received);
    const onSubmitted = vi.fn();
    const onClose = vi.fn();
    const root = await render(
      <ReportSheet
        client={client}
        visible
        onClose={onClose}
        onSubmitted={onSubmitted}
        appVersion="2.4.0"
        build="118"
        context={{ screen: 'Favourites' }}
        reporter={{ customerReference: 'u-1' }}
        defaultType="feedback"
      />,
    );
    await type(root, 'Summary', 'Lost favourites');
    await type(root, 'What happened?', 'They vanished.');
    await press(root, 'Settings');
    await press(root, 'Send report');
    expect(client.report).toHaveBeenCalledWith(
      {
        type: 'feedback',
        title: 'Lost favourites',
        description: 'They vanished.',
        fields: { area: 'Settings' },
        context: {
          platform: 'react-native',
          osName: 'ios',
          osVersion: '18.2',
          appVersion: '2.4.0',
          build: '118',
          screen: 'Favourites',
        },
        reporter: { customerReference: 'u-1' },
      },
      expect.anything(),
    );
    expect(onSubmitted).toHaveBeenCalledWith({ status: 'received', reportId: 'rpt_1', idempotencyKey: 'k' });
    expect(texts(root)).toEqual(expect.arrayContaining(['Thanks!', 'We read every report.']));
    await press(root, 'Close');
    expect(onClose).toHaveBeenCalled();
  });

  it('attaches the host-provided screenshot unless the person removes it', async () => {
    vi.stubGlobal('fetch', async () => new Response(new Blob([new Uint8Array([1])], { type: 'image/png' })));
    const client = fakeClient(received);
    const onRequestScreenshot = vi.fn(async () => ({ uri: 'file:///b.png' }));
    const root = await render(
      <ReportSheet
        client={client}
        visible
        onClose={() => undefined}
        screenshot={{ uri: 'file:///a.png' }}
        onRequestScreenshot={onRequestScreenshot}
      />,
    );
    expect(root.root.findAll((node) => is(node, 'Image') && node.props.source.uri === 'file:///a.png')).toHaveLength(1);
    await press(root, 'Remove screenshot');
    expect(root.root.findAll((node) => is(node, 'Image'))).toHaveLength(0);
    await press(root, 'Add screenshot');
    expect(onRequestScreenshot).toHaveBeenCalled();
    await type(root, 'What happened?', 'x');
    await press(root, 'Home');
    await press(root, 'Send report');
    const input = vi.mocked(client.report).mock.calls[0]?.[0];
    expect(input?.attachments).toEqual([{ fileName: 'b.png', contentType: 'image/png', data: expect.any(Blob) }]);
  });

  it('shows server field errors and a general error', async () => {
    let attempt = 0;
    const client = fakeClient(async () => {
      attempt += 1;
      if (attempt === 1) {
        throw new TododdleSupportError({
          code: 'INVALID_FIELDS',
          message: 'x',
          httpStatus: 422,
          fields: { area: 'Choose where in the app.' },
        });
      }
      throw new TododdleSupportError({ code: 'NETWORK_ERROR', message: 'x', httpStatus: 0 });
    });
    const root = await render(<ReportSheet client={client} visible onClose={() => undefined} />);
    await type(root, 'What happened?', 'x');
    await press(root, 'Home');
    await press(root, 'Send report');
    expect(texts(root)).toContain('Choose where in the app.');
    await press(root, 'Send report');
    expect(texts(root)).toContain('The report could not be sent. Please try again.');
  });

  it('offers a retry when the config cannot load', async () => {
    let fail = true;
    const client = fakeClient(received, async () => {
      if (fail) throw new Error('offline');
      return structuredClone(sharedConfig);
    });
    const root = await render(
      <ReportSheet client={client} visible onClose={() => undefined} labels={{ retry: 'Retry' }} />,
    );
    expect(texts(root)).toContain('The report form could not be loaded. Check the connection and try again.');
    fail = false;
    await press(root, 'Retry');
    expect(texts(root)).toContain('Tell us what happened');
  });

  it('uses square corners, a logo and hides the type picker for one type', async () => {
    const config = structuredClone(sharedConfig);
    config.form.types = [{ value: 'question', label: 'Ask' }];
    config.theme.corners = 'square';
    config.project.logoUrl = 'https://example.test/logo.png';
    if (config.form.title) config.form.title.enabled = false;
    const client = fakeClient(received, async () => config);
    const root = await render(<ReportSheet client={client} visible onClose={() => undefined} />);
    expect(texts(root)).not.toContain('Ask');
    expect(
      root.root.findAll((node) => is(node, 'Image') && node.props.source.uri === config.project.logoUrl),
    ).toHaveLength(1);
    expect(pressable(root, 'Send report').props.style).toEqual(expect.arrayContaining([{ borderRadius: 0 }]));
    await type(root, 'What happened?', 'x');
    await press(root, 'Other');
    await press(root, 'Send report');
    expect(vi.mocked(client.report).mock.calls[0]?.[0]).toMatchObject({ type: 'question', title: undefined });
  });
});
