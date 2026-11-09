/**
 * Runs the shared conformance cases in contract/cases/cases.json against a local mock server.
 * The server replays each case's `exchanges` in order and checks every `request.must` rule.
 */
import { readFileSync } from 'node:fs';
import { createServer, type IncomingMessage, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { createTododdleSupport, isTododdleSupportError, RETRY_POLICY, SDK_VERSION } from '../src/index';
import type { Config, ReportInput, ReportResult } from '../src/index';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

interface MustRules {
  headers?: string[] | Record<string, string>;
  body?: string[] | Record<string, Json>;
  rawBodyBase64?: string;
  sameIdempotencyKeyAsPrevious?: boolean;
}

interface Exchange {
  request: { method: string; path: string; must?: MustRules };
  response: { status: number; headers?: Record<string, string>; body?: Json };
}

interface Case {
  name: string;
  operation: 'getConfig' | 'getConfigTwice' | 'report' | 'reportWithAttachment';
  attachment?: { fileName: string; contentType: 'image/png' | 'text/plain'; bytesBase64: string };
  exchanges: Exchange[];
  expect: {
    ok: boolean;
    formVersion?: number;
    fieldKeys?: string[];
    reportId?: string;
    errorCode?: string;
    fieldErrors?: Record<string, string>;
    httpStatus?: number;
    requests?: number;
    minDelayMs?: number;
  };
}

interface CasesFile {
  key: string;
  config: Config;
  report: ReportInput;
  cases: Case[];
  retryPolicy: { maxAttempts: number; backoffSeconds: number[]; retryStatuses: number[] };
}

const casesPath = fileURLToPath(new URL('../../../contract/cases/cases.json', import.meta.url));
const suite = JSON.parse(readFileSync(casesPath, 'utf8')) as CasesFile;

interface Recorded {
  method: string;
  path: string;
  headers: IncomingMessage['headers'];
  raw: Buffer;
  at: number;
}

interface MockServer {
  baseUrl: string;
  recorded: Recorded[];
  failures: string[];
  remaining: () => number;
  close: () => Promise<void>;
}

function substitute(value: Json | undefined, baseUrl: string): Json | undefined {
  if (value === '$config') return suite.config as unknown as Json;
  if (typeof value === 'string') return value.replaceAll('{{baseUrl}}', baseUrl);
  if (Array.isArray(value)) return value.map((item) => substitute(item, baseUrl) ?? null);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, substitute(item, baseUrl) ?? null]));
  }
  return value;
}

function atPath(value: unknown, path: string): unknown {
  return path.split('.').reduce<unknown>((current, part) => {
    if (current === null || typeof current !== 'object') return undefined;
    return (current as Record<string, unknown>)[part];
  }, value);
}

function checkMust(
  must: MustRules,
  request: Recorded,
  previous: Recorded | undefined,
  attachmentBase64: string | undefined,
): string[] {
  const problems: string[] = [];
  const header = (name: string) => {
    const value = request.headers[name.toLowerCase()];
    return Array.isArray(value) ? value.join(', ') : value;
  };
  if (Array.isArray(must.headers)) {
    for (const name of must.headers) if (!header(name)) problems.push(`missing header ${name}`);
  } else if (must.headers) {
    for (const [name, expected] of Object.entries(must.headers)) {
      if (header(name) !== expected) problems.push(`header ${name} was ${String(header(name))}, expected ${expected}`);
    }
  }
  let body: unknown;
  const parseBody = () => {
    try {
      body = JSON.parse(request.raw.toString('utf8'));
    } catch {
      problems.push('body is not JSON');
    }
  };
  if (must.body) {
    parseBody();
    if (Array.isArray(must.body)) {
      for (const path of must.body) if (atPath(body, path) === undefined) problems.push(`missing body ${path}`);
    } else {
      for (const [path, expected] of Object.entries(must.body)) {
        if (JSON.stringify(atPath(body, path)) !== JSON.stringify(expected)) problems.push(`body ${path} differs`);
      }
    }
  }
  if (must.rawBodyBase64 !== undefined) {
    const expected = must.rawBodyBase64 === '$attachment' ? attachmentBase64 : must.rawBodyBase64;
    if (request.raw.toString('base64') !== expected) problems.push('raw body differs from the attachment');
  }
  if (must.sameIdempotencyKeyAsPrevious) {
    parseBody();
    const own = atPath(body, 'idempotencyKey');
    let before: unknown;
    try {
      before = previous ? atPath(JSON.parse(previous.raw.toString('utf8')), 'idempotencyKey') : undefined;
    } catch {
      before = undefined;
    }
    if (typeof own !== 'string' || own !== before) problems.push('idempotencyKey changed between attempts');
  }
  return problems;
}

async function startMock(testCase: Case): Promise<MockServer> {
  const queue = [...testCase.exchanges];
  const recorded: Recorded[] = [];
  const failures: string[] = [];
  let baseUrl = '';
  const server: Server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on('data', (chunk: Buffer) => chunks.push(chunk));
    req.on('end', () => {
      const path = new URL(req.url ?? '/', baseUrl).pathname;
      const request: Recorded = {
        method: req.method ?? '',
        path,
        headers: req.headers,
        raw: Buffer.concat(chunks),
        at: Date.now(),
      };
      const previous = recorded[recorded.length - 1];
      recorded.push(request);
      const exchange = queue.shift();
      if (!exchange) {
        failures.push(`unexpected request ${request.method} ${path}`);
        res.writeHead(599).end();
        return;
      }
      if (exchange.request.method !== request.method || exchange.request.path !== path) {
        failures.push(`expected ${exchange.request.method} ${exchange.request.path}, got ${request.method} ${path}`);
      }
      if (exchange.request.must) {
        for (const problem of checkMust(exchange.request.must, request, previous, testCase.attachment?.bytesBase64)) {
          failures.push(`${request.method} ${path}: ${problem}`);
        }
      }
      const body = substitute(exchange.response.body, baseUrl);
      const headers: Record<string, string> = { ...exchange.response.headers };
      if (body !== undefined) headers['Content-Type'] = 'application/json';
      res.writeHead(exchange.response.status, headers);
      res.end(body === undefined ? undefined : JSON.stringify(body));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return {
    baseUrl,
    recorded,
    failures,
    remaining: () => queue.length,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}

interface Outcome {
  ok: boolean;
  config?: Config;
  result?: ReportResult;
  error?: unknown;
}

async function runOperation(testCase: Case, baseUrl: string): Promise<Outcome> {
  const client = createTododdleSupport({ key: suite.key, baseUrl });
  try {
    switch (testCase.operation) {
      case 'getConfig':
        return { ok: true, config: await client.getConfig() };
      case 'getConfigTwice':
        await client.getConfig();
        return { ok: true, config: await client.getConfig() };
      case 'report':
        return { ok: true, result: await client.report(suite.report, { config: suite.config }) };
      case 'reportWithAttachment': {
        const attachment = testCase.attachment;
        if (!attachment) throw new Error('case has no attachment');
        const input: ReportInput = {
          ...suite.report,
          attachments: [
            {
              fileName: attachment.fileName,
              contentType: attachment.contentType,
              data: new Uint8Array(Buffer.from(attachment.bytesBase64, 'base64')),
            },
          ],
        };
        return { ok: true, result: await client.report(input, { config: suite.config }) };
      }
    }
  } catch (error) {
    return { ok: false, error };
  }
}

describe('retry policy', () => {
  it('matches retryPolicy in cases.json', () => {
    expect(RETRY_POLICY).toEqual({
      maxAttempts: suite.retryPolicy.maxAttempts,
      backoffSeconds: suite.retryPolicy.backoffSeconds,
      retryStatuses: suite.retryPolicy.retryStatuses,
    });
  });
});

describe.concurrent('conformance cases', () => {
  it('covers all 11 cases', () => {
    expect(suite.cases).toHaveLength(11);
  });

  for (const testCase of suite.cases) {
    it(testCase.name, async ({ expect, onTestFinished }) => {
      const server = await startMock(testCase);
      onTestFinished(() => server.close());
      const outcome = await runOperation(testCase, server.baseUrl);
      const { expect: want } = testCase;

      expect(server.failures).toEqual([]);
      for (const request of server.recorded) {
        if (request.path.startsWith('/upload/')) {
          expect(request.headers['x-tododdle-key']).toBeUndefined();
        } else {
          expect(request.headers['x-tododdle-key']).toBe(suite.key);
          expect(request.headers['x-tododdle-sdk']).toBe(`js/${SDK_VERSION}`);
        }
      }
      expect(outcome.ok, String(outcome.error)).toBe(want.ok);
      if (want.ok) expect(server.remaining()).toBe(0);
      if (want.formVersion !== undefined) expect(outcome.config?.form.version).toBe(want.formVersion);
      if (want.fieldKeys) expect(outcome.config?.form.fields.map((field) => field.key)).toEqual(want.fieldKeys);
      if (want.reportId !== undefined) {
        expect(outcome.result).toMatchObject({ status: 'received', reportId: want.reportId });
      }
      if (!want.ok) {
        expect(isTododdleSupportError(outcome.error)).toBe(true);
        if (!isTododdleSupportError(outcome.error)) return;
        if (want.errorCode !== undefined) expect(outcome.error.code).toBe(want.errorCode);
        if (want.fieldErrors) expect(outcome.error.fields).toEqual(want.fieldErrors);
        if (want.httpStatus !== undefined) expect(outcome.error.httpStatus).toBe(want.httpStatus);
      }
      if (want.requests !== undefined) expect(server.recorded).toHaveLength(want.requests);
      if (want.minDelayMs !== undefined) {
        const first = server.recorded[0];
        const last = server.recorded[server.recorded.length - 1];
        expect(first && last ? last.at - first.at : 0).toBeGreaterThanOrEqual(want.minDelayMs);
      }
    });
  }
});
