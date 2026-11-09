import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  createTododdleSupport,
  memoryStorage,
  parseRetryAfter,
  SDK_VERSION,
  TododdleSupportError,
  type ReportInput,
  type SupportStorage,
} from '../src/index';
import { cloneConfig, empty, fakeFetch, json, sharedConfig } from './helpers';

const key = 'tdsk_pub_TESTKEY0000000000000000000000000';
const baseUrl = 'https://example.test/api/support/sdk/v1';
const validReport: ReportInput = { type: 'problem', description: 'It broke.', fields: { area: 'Home' } };
const received = (id = 'rpt_AAAAAAAAAAAAAAAA0001') => json(201, { reportId: id, status: 'received' });

afterEach(() => {
  vi.useRealTimers();
});

function client(fetch: ReturnType<typeof fakeFetch>, extra: Partial<Parameters<typeof createTododdleSupport>[0]> = {}) {
  return createTododdleSupport({ key, baseUrl, fetch, ...extra });
}

describe('createTododdleSupport', () => {
  it('needs a key', () => {
    expect(() => createTododdleSupport({ key: '' })).toThrow(TypeError);
  });

  it('sends the key, SDK name, app ID and trims the base URL', async () => {
    const fetch = fakeFetch([json(200, sharedConfig)]);
    await createTododdleSupport({
      key,
      baseUrl: `${baseUrl}//`,
      fetch,
      appId: 'com.example.app',
      sdkName: 'react-native',
    }).getConfig();
    expect(fetch.calls[0]?.url).toBe(`${baseUrl}/config`);
    expect(fetch.calls[0]?.headers).toMatchObject({
      'x-tododdle-key': key,
      'x-tododdle-sdk': `react-native/${SDK_VERSION}`,
      'x-tododdle-app-id': 'com.example.app',
    });
  });

  it('uses the global fetch by default and fails clearly without one', async () => {
    const original = globalThis.fetch;
    const fetch = fakeFetch([json(200, sharedConfig)]);
    vi.stubGlobal('fetch', fetch);
    try {
      await createTododdleSupport({ key, baseUrl }).getConfig();
      expect(fetch.calls).toHaveLength(1);
      vi.stubGlobal('fetch', undefined);
      await expect(createTododdleSupport({ key, baseUrl }).getConfig()).rejects.toThrow(/No fetch function/);
    } finally {
      vi.stubGlobal('fetch', original);
    }
  });
});

describe('getConfig', () => {
  it('stores the config with its ETag and revalidates', async () => {
    const storage = memoryStorage();
    const fetch = fakeFetch([json(200, sharedConfig, { ETag: '"v1"' }), empty(304)]);
    const first = client(fetch, { storage });
    await first.getConfig();
    // A new client with the same storage starts from the stored copy.
    const second = client(fetch, { storage });
    expect(await second.getCachedConfig()).toEqual(sharedConfig);
    expect(await second.getConfig()).toEqual(sharedConfig);
    expect(fetch.calls[1]?.headers['if-none-match']).toBe('"v1"');
  });

  it('falls back to the cached config when offline or the server fails', async () => {
    vi.useFakeTimers();
    const fetch = fakeFetch([
      json(200, sharedConfig, { ETag: '"v1"' }),
      new TypeError('offline'),
      new TypeError('offline'),
      new TypeError('offline'),
      empty(500),
      empty(500),
      empty(500),
    ]);
    const support = client(fetch);
    await support.getConfig();
    const offline = support.getConfig();
    await vi.runAllTimersAsync();
    expect(await offline).toEqual(sharedConfig);
    const failing = support.getConfig();
    await vi.runAllTimersAsync();
    expect(await failing).toEqual(sharedConfig);
  });

  it('does not hide a revoked key behind the cache', async () => {
    const fetch = fakeFetch([
      json(200, sharedConfig, { ETag: '"v1"' }),
      json(401, { error: { code: 'KEY_REVOKED', message: 'Revoked.' } }),
    ]);
    const support = client(fetch);
    await support.getConfig();
    await expect(support.getConfig()).rejects.toMatchObject({ code: 'KEY_REVOKED', httpStatus: 401 });
  });

  it('rejects a malformed config, a stray 304 and a network failure with no cache', async () => {
    await expect(client(fakeFetch([json(200, { nope: true })])).getConfig()).rejects.toMatchObject({
      code: 'INVALID_RESPONSE',
    });
    await expect(client(fakeFetch([empty(304)])).getConfig()).rejects.toMatchObject({ code: 'INVALID_RESPONSE' });
    await expect(client(fakeFetch([new Response('not json', { status: 200 })])).getConfig()).rejects.toMatchObject({
      code: 'INVALID_RESPONSE',
    });
    vi.useFakeTimers();
    const offline = client(fakeFetch([new TypeError('x'), new TypeError('x'), new TypeError('x')])).getConfig();
    const settled = offline.catch((error: unknown) => error);
    await vi.runAllTimersAsync();
    expect(await settled).toMatchObject({ code: 'NETWORK_ERROR', httpStatus: 0 });
  });

  it('ignores broken storage', async () => {
    const broken: SupportStorage = {
      getItem: () => {
        throw new Error('blocked');
      },
      setItem: () => {
        throw new Error('full');
      },
      removeItem: () => undefined,
    };
    const fetch = fakeFetch([json(200, sharedConfig)]);
    expect(await client(fetch, { storage: broken }).getConfig()).toEqual(sharedConfig);
  });
});

describe('retry policy', () => {
  it('backs off 1 s then 2 s and stops after 3 attempts', async () => {
    vi.useFakeTimers();
    const fetch = fakeFetch([empty(503), empty(502), empty(504)]);
    const pending = client(fetch).report(validReport, { config: sharedConfig });
    const settled = pending.catch((error: unknown) => error);
    await vi.advanceTimersByTimeAsync(999);
    expect(fetch.calls).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(fetch.calls).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(1999);
    expect(fetch.calls).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(await settled).toMatchObject({ code: 'HTTP_ERROR', httpStatus: 504 });
    expect(fetch.calls).toHaveLength(3);
    const keys = fetch.calls.map((call) => (call.body as { idempotencyKey: string }).idempotencyKey);
    expect(new Set(keys).size).toBe(1);
    expect(keys[0]).toMatch(/^[A-Za-z0-9_-]{16,64}$/);
  });

  it.each([400, 401, 403, 404, 409, 410, 413, 422, 501])('never retries %i', async (status) => {
    const fetch = fakeFetch([json(status, { error: { code: 'X', message: 'x' } })]);
    await expect(client(fetch).report(validReport, { config: sharedConfig })).rejects.toMatchObject({
      httpStatus: status,
    });
    expect(fetch.calls).toHaveLength(1);
  });

  it('retries 408 and network errors, and honours Retry-After', async () => {
    vi.useFakeTimers();
    const fetch = fakeFetch([empty(408, { 'Retry-After': '5' }), new TypeError('offline'), received()]);
    const pending = client(fetch).report(validReport, { config: sharedConfig });
    await vi.advanceTimersByTimeAsync(4999);
    expect(fetch.calls).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(fetch.calls).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(2000);
    expect(await pending).toMatchObject({ status: 'received' });
  });

  it('gives up at once when Retry-After is longer than the limit', async () => {
    const fetch = fakeFetch([
      json(429, { error: { code: 'RATE_LIMITED', message: 'Slow down.' } }, { 'Retry-After': '3600' }),
    ]);
    await expect(client(fetch).report(validReport, { config: sharedConfig })).rejects.toMatchObject({
      code: 'RATE_LIMITED',
      retryAfterSeconds: 3600,
      retryable: true,
    });
    expect(fetch.calls).toHaveLength(1);
  });

  it('can be cancelled while waiting', async () => {
    vi.useFakeTimers();
    const controller = new AbortController();
    const fetch = fakeFetch([empty(503)]);
    const pending = client(fetch)
      .report(validReport, { config: sharedConfig, signal: controller.signal })
      .catch((error: unknown) => error);
    await vi.advanceTimersByTimeAsync(10);
    controller.abort();
    expect(await pending).toMatchObject({ code: 'ABORTED' });
    const already = await client(fakeFetch([]))
      .report(validReport, { config: sharedConfig, signal: controller.signal })
      .catch((error: unknown) => error);
    expect(already).toMatchObject({ code: 'ABORTED' });
  });

  it('reports an abort during fetch as ABORTED', async () => {
    const controller = new AbortController();
    const fetch = fakeFetch([
      () => {
        controller.abort();
        return new DOMException('aborted', 'AbortError');
      },
    ]);
    await expect(
      client(fetch).report(validReport, { config: sharedConfig, signal: controller.signal }),
    ).rejects.toMatchObject({ code: 'ABORTED' });
  });

  it('parses Retry-After dates', () => {
    const now = Date.parse('2026-11-09T10:00:00Z');
    expect(parseRetryAfter('Mon, 09 Nov 2026 10:00:30 GMT', now)).toBe(30);
    expect(parseRetryAfter('Mon, 09 Nov 2026 09:00:00 GMT', now)).toBe(0);
    expect(parseRetryAfter('soon', now)).toBeUndefined();
    expect(parseRetryAfter(null, now)).toBeUndefined();
  });
});

describe('report', () => {
  it('validates before sending and sends nothing when invalid', async () => {
    const fetch = fakeFetch([]);
    const error = await client(fetch)
      .report({ type: 'problem', fields: { area: 'Moon' } }, { config: sharedConfig })
      .catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(TododdleSupportError);
    expect(error).toMatchObject({
      code: 'INVALID_FIELDS',
      httpStatus: 0,
      fields: { description: expect.any(String), area: expect.any(String) },
    });
    expect(fetch.calls).toHaveLength(0);
  });

  it('fetches the config when none is cached, then builds a clean body', async () => {
    const fetch = fakeFetch([json(200, sharedConfig), received()]);
    const support = client(fetch, { defaultContext: { platform: 'web', extra: { plan: 'pro' } } });
    const result = await support.report({
      type: 'problem',
      title: '  ',
      description: 'It broke.',
      fields: { area: 'Home', steps: '', unknown: 'dropped' },
      context: { screen: '/favourites?token=secret#top', extra: { tab: 'list' } },
      reporter: { name: 'Alex', email: '' },
    });
    expect(result).toMatchObject({ status: 'received', reportId: 'rpt_AAAAAAAAAAAAAAAA0001' });
    expect(fetch.calls[1]?.headers['content-type']).toBe('application/json');
    const body = fetch.calls[1]?.body as Record<string, unknown>;
    expect(body).toEqual({
      idempotencyKey: expect.any(String),
      type: 'problem',
      formVersion: 3,
      description: 'It broke.',
      fields: { area: 'Home' },
      context: { platform: 'web', screen: '/favourites', extra: { plan: 'pro', tab: 'list' } },
      reporter: { name: 'Alex' },
    });
  });

  it('can skip validation when the app passes formVersion', async () => {
    const fetch = fakeFetch([received()]);
    await client(fetch).report({ type: 'problem', formVersion: 7 }, { skipValidation: true });
    expect(fetch.calls[0]?.body).toMatchObject({ formVersion: 7 });
  });

  it('leaves out the title when the form has no title field', async () => {
    const config = cloneConfig();
    if (config.form.title) config.form.title.enabled = false;
    const fetch = fakeFetch([received()]);
    await client(fetch).report({ ...validReport, title: 'Hi' }, { config });
    expect(fetch.calls[0]?.body).not.toHaveProperty('title');
  });

  it('uploads each attachment with only the returned headers, then submits', async () => {
    const fetch = fakeFetch([
      json(201, {
        reportId: 'rpt_AAAAAAAAAAAAAAAA0002',
        status: 'awaiting_uploads',
        submitToken: 'st_0123456789abcdef0123456789abcdef',
        expiresAt: '2099-01-01T00:00:00Z',
        uploads: [
          { uploadUrl: 'https://files.example/1', headers: { 'Content-Type': 'image/png' }, expiresAt: '2099' },
          { uploadUrl: 'https://files.example/2', headers: { 'Content-Type': 'text/plain' }, expiresAt: '2099' },
        ],
      }),
      empty(200),
      empty(200),
      json(200, { reportId: 'rpt_AAAAAAAAAAAAAAAA0002', status: 'received' }),
    ]);
    const result = await client(fetch).report(
      {
        ...validReport,
        attachments: [
          { fileName: 'a.png', contentType: 'image/png', data: new Blob([new Uint8Array([1, 2, 3])]) },
          { fileName: 'b.txt', contentType: 'text/plain', data: new TextEncoder().encode('hi').buffer },
        ],
      },
      { config: sharedConfig },
    );
    expect(result.status).toBe('received');
    expect(fetch.calls[0]?.body).toMatchObject({
      attachments: [
        { fileName: 'a.png', contentType: 'image/png', size: 3 },
        { fileName: 'b.txt', contentType: 'text/plain', size: 2 },
      ],
    });
    expect(fetch.calls[1]?.headers).toEqual({ 'content-type': 'image/png' });
    expect(fetch.calls[3]?.url).toBe(`${baseUrl}/reports/rpt_AAAAAAAAAAAAAAAA0002/submit`);
  });

  it('fails clearly when an upload fails or the server answers oddly', async () => {
    const awaiting = (uploads: number) =>
      json(201, {
        reportId: 'rpt_AAAAAAAAAAAAAAAA0002',
        status: 'awaiting_uploads',
        submitToken: 'st_0123456789abcdef0123456789abcdef',
        uploads: Array.from({ length: uploads }, () => ({ uploadUrl: 'https://f/1', headers: {}, expiresAt: '' })),
      });
    const input: ReportInput = {
      ...validReport,
      attachments: [{ fileName: 'a.png', contentType: 'image/png', data: new Uint8Array([1]) }],
    };
    await expect(
      client(fakeFetch([awaiting(1), new Response('<Error/>', { status: 403 })])).report(input, {
        config: sharedConfig,
      }),
    ).rejects.toMatchObject({ code: 'UPLOAD_FAILED', httpStatus: 403 });
    await expect(client(fakeFetch([awaiting(0)])).report(input, { config: sharedConfig })).rejects.toMatchObject({
      code: 'INVALID_RESPONSE',
    });
    await expect(
      client(fakeFetch([awaiting(1), empty(200), json(200, { reportId: 'x', status: 'awaiting_uploads' })])).report(
        input,
        { config: sharedConfig },
      ),
    ).rejects.toMatchObject({ code: 'INVALID_RESPONSE' });
    await expect(
      client(fakeFetch([json(201, { status: 'received' })])).report(validReport, { config: sharedConfig }),
    ).rejects.toMatchObject({ code: 'INVALID_RESPONSE' });
  });

  it('keeps field errors and the request ID from the server', async () => {
    const fetch = fakeFetch([
      json(422, {
        error: {
          code: 'FIELDS_CHANGED',
          message: 'Form changed.',
          fields: { area: 'Pick one.', bad: 3 },
          requestId: 'req_1',
        },
      }),
    ]);
    await expect(client(fetch).report(validReport, { config: sharedConfig })).rejects.toMatchObject({
      code: 'FIELDS_CHANGED',
      fields: { area: 'Pick one.' },
      requestId: 'req_1',
      retryable: false,
    });
  });
});

describe('offline queue', () => {
  it('queues a report when offline and sends it later with the same key', async () => {
    vi.useFakeTimers();
    const storage = memoryStorage();
    const offline = fakeFetch([new TypeError('x'), new TypeError('x'), new TypeError('x')]);
    const pending = client(offline, { storage, offlineQueue: true }).report(validReport, { config: sharedConfig });
    await vi.runAllTimersAsync();
    const queued = await pending;
    expect(queued.status).toBe('queued');
    vi.useRealTimers();

    const online = fakeFetch([received('rpt_AAAAAAAAAAAAAAAA0009')]);
    const support = client(online, { storage, offlineQueue: true });
    expect(await support.queuedCount()).toBe(1);
    const flushed = await support.flushQueue();
    expect(flushed).toEqual({
      sent: [{ reportId: 'rpt_AAAAAAAAAAAAAAAA0009', idempotencyKey: queued.idempotencyKey }],
      dropped: [],
      remaining: 0,
    });
    expect((online.calls[0]?.body as { idempotencyKey: string }).idempotencyKey).toBe(queued.idempotencyKey);
    expect(await support.queuedCount()).toBe(0);
  });

  it('drops refused reports, keeps the rest when still offline, and never queues attachments', async () => {
    const storage = memoryStorage();
    const queueFetch = fakeFetch([
      json(503, {}, { 'Retry-After': '999' }),
      json(503, {}, { 'Retry-After': '999' }),
      json(503, {}, { 'Retry-After': '999' }),
    ]);
    const support = client(queueFetch, { storage, offlineQueue: true, maxRetryAfterSeconds: 1 });
    await support.report(validReport, { config: sharedConfig });
    await support.report(validReport, { config: sharedConfig });
    await support.report(validReport, { config: sharedConfig });
    expect(await support.queuedCount()).toBe(3);

    const flushFetch = fakeFetch([
      json(403, { error: { code: 'SUPPORT_UNAVAILABLE', message: 'Off.' } }),
      json(503, {}, { 'Retry-After': '999' }),
    ]);
    const result = await client(flushFetch, { storage, offlineQueue: true, maxRetryAfterSeconds: 1 }).flushQueue();
    expect(result.dropped).toEqual([
      { idempotencyKey: expect.any(String), code: 'SUPPORT_UNAVAILABLE', httpStatus: 403 },
    ]);
    expect(result.remaining).toBe(2);

    const withFile = client(fakeFetch([json(503, {}, { 'Retry-After': '999' })]), {
      storage,
      offlineQueue: true,
      maxRetryAfterSeconds: 1,
    });
    await expect(
      withFile.report(
        { ...validReport, attachments: [{ fileName: 'a.txt', contentType: 'text/plain', data: new Uint8Array([1]) }] },
        { config: sharedConfig },
      ),
    ).rejects.toMatchObject({ httpStatus: 503 });
  });

  it('ignores a corrupt queue or cache', async () => {
    const corrupt = (value: string): SupportStorage => ({
      getItem: () => value,
      setItem: () => undefined,
      removeItem: () => {
        throw new Error('blocked');
      },
    });
    for (const value of ['{not json', '[{"body":1}]']) {
      const support = client(fakeFetch([]), { storage: corrupt(value), offlineQueue: true });
      expect(await support.queuedCount()).toBe(0);
      expect(await support.getCachedConfig()).toBeNull();
      expect(await support.flushQueue()).toEqual({ sent: [], dropped: [], remaining: 0 });
    }
  });
});
