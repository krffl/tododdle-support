#!/usr/bin/env node
// A local mock of the ToDoddle Support SDK API for the Godot tests.
//
// It replays one scenario at a time, like packages/js/test/conformance.test.ts: each request is
// matched in order against the scenario's `exchanges` and checked against `request.must`.
// The Godot test runner drives it through two control routes:
//
//   POST /__mock/scenario  { "case": "<name in contract/cases/cases.json>" }
//                          or { "exchanges": [...], "attachmentBase64": "..." }
//   GET  /__mock/state     { failures, remaining, requests: [{ method, path, headers, at, bodyBase64 }] }
//
// It prints its port on the first line of stdout. Only for tests; it listens on 127.0.0.1.
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const casesPath = join(dirname(fileURLToPath(import.meta.url)), '../../contract/cases/cases.json');
const suite = JSON.parse(readFileSync(casesPath, 'utf8'));

let baseUrl = '';
let scenario = { exchanges: [], attachmentBase64: undefined };
let queue = [];
let recorded = [];
let failures = [];

function load(next) {
  scenario = next;
  queue = [...next.exchanges];
  recorded = [];
  failures = [];
}

function substitute(value) {
  if (value === '$config') return suite.config;
  if (typeof value === 'string') return value.replaceAll('{{baseUrl}}', baseUrl);
  if (Array.isArray(value)) return value.map((item) => substitute(item));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, substitute(item)]));
  }
  return value;
}

function atPath(value, path) {
  return path.split('.').reduce((current, part) => {
    if (current === null || typeof current !== 'object') return undefined;
    return current[part];
  }, value);
}

function parseJson(raw) {
  try {
    return JSON.parse(raw.toString('utf8'));
  } catch {
    return undefined;
  }
}

function checkMust(must, request, previous) {
  const problems = [];
  const header = (name) => {
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
  const body = parseJson(request.raw);
  if (must.body) {
    if (body === undefined) problems.push('body is not JSON');
    if (Array.isArray(must.body)) {
      for (const path of must.body) if (atPath(body, path) === undefined) problems.push(`missing body ${path}`);
    } else {
      for (const [path, expected] of Object.entries(must.body)) {
        if (JSON.stringify(atPath(body, path)) !== JSON.stringify(expected)) problems.push(`body ${path} differs`);
      }
    }
  }
  if (must.rawBodyBase64 !== undefined) {
    const expected = must.rawBodyBase64 === '$attachment' ? scenario.attachmentBase64 : must.rawBodyBase64;
    if (request.raw.toString('base64') !== expected) problems.push('raw body differs from the attachment');
  }
  if (must.sameIdempotencyKeyAsPrevious) {
    const own = atPath(body, 'idempotencyKey');
    const before = previous ? atPath(parseJson(previous.raw), 'idempotencyKey') : undefined;
    if (typeof own !== 'string' || own !== before) problems.push('idempotencyKey changed between attempts');
  }
  return problems;
}

function sendJson(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

function control(req, res, raw) {
  if (req.method === 'POST' && req.url === '/__mock/scenario') {
    const input = parseJson(raw) ?? {};
    if (typeof input.case === 'string') {
      const found = suite.cases.find((item) => item.name === input.case);
      if (!found) return sendJson(res, 404, { error: `no case ${input.case}` });
      load({ exchanges: found.exchanges, attachmentBase64: found.attachment?.bytesBase64 });
    } else {
      load({ exchanges: input.exchanges ?? [], attachmentBase64: input.attachmentBase64 });
    }
    return sendJson(res, 200, { loaded: queue.length });
  }
  if (req.method === 'GET' && req.url === '/__mock/state') {
    return sendJson(res, 200, {
      failures,
      remaining: queue.length,
      requests: recorded.map((r) => ({
        method: r.method,
        path: r.path,
        headers: r.headers,
        at: r.at,
        bodyBase64: r.raw.toString('base64'),
      })),
    });
  }
  return sendJson(res, 404, { error: 'unknown control route' });
}

const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const raw = Buffer.concat(chunks);
    const path = new URL(req.url ?? '/', baseUrl).pathname;
    if (path.startsWith('/__mock/')) return control(req, res, raw);

    const request = { method: req.method ?? '', path, headers: req.headers, raw, at: Date.now() };
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
      for (const problem of checkMust(exchange.request.must, request, previous)) {
        failures.push(`${request.method} ${path}: ${problem}`);
      }
    }
    const body = substitute(exchange.response.body);
    const headers = { ...exchange.response.headers };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    res.writeHead(exchange.response.status, headers);
    res.end(body === undefined ? undefined : JSON.stringify(body));
  });
});

server.listen(0, '127.0.0.1', () => {
  const { port } = server.address();
  baseUrl = `http://127.0.0.1:${port}`;
  process.stdout.write(`${port}\n`);
});

for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
