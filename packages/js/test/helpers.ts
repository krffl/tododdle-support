import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Config, FetchLike } from '../src/index';

const casesPath = join(import.meta.dirname, '../../../contract/cases/cases.json');
export const sharedConfig = (JSON.parse(readFileSync(casesPath, 'utf8')) as { config: Config }).config;

export function cloneConfig(): Config {
  return structuredClone(sharedConfig);
}

export interface Call {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
  redirect: RequestRedirect | undefined;
  signal: AbortSignal | undefined;
}

type Responder = Response | Error | ((call: Call) => Response | Error);

/** A fetch that answers from a list and records each call. */
export function fakeFetch(responders: Responder[]): FetchLike & { calls: Call[] } {
  const calls: Call[] = [];
  const fn = async (url: string, init?: RequestInit): Promise<Response> => {
    const headers: Record<string, string> = {};
    new Headers(init?.headers).forEach((value, key) => {
      headers[key] = value;
    });
    const call: Call = {
      url,
      method: init?.method ?? 'GET',
      headers,
      body: typeof init?.body === 'string' ? JSON.parse(init.body) : init?.body,
      redirect: init?.redirect,
      signal: init?.signal ?? undefined,
    };
    calls.push(call);
    const next = responders.shift();
    if (next === undefined) throw new Error(`unexpected ${call.method} ${url}`);
    const value = typeof next === 'function' ? next(call) : next;
    if (value instanceof Error) throw value;
    return value;
  };
  return Object.assign(fn, { calls });
}

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });
}

export function empty(status: number, headers: Record<string, string> = {}): Response {
  return new Response(null, { status, headers });
}
