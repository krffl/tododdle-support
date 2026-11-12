import { TododdleSupportError } from './errors';
import type { FetchLike } from './types';

/** Mirrors `retryPolicy` in contract/cases/cases.json. Every SDK follows it. */
export const RETRY_POLICY = {
  maxAttempts: 3,
  backoffSeconds: [1, 2, 4],
  retryStatuses: [408, 429, 500, 502, 503, 504],
} as const;

const retryStatuses: readonly number[] = RETRY_POLICY.retryStatuses;

/** Each attempt is cancelled after this long, so a stalled connection cannot hang a report. */
export const REQUEST_TIMEOUT_MS = 30_000;

export interface SendOptions {
  fetch: FetchLike;
  signal?: AbortSignal | undefined;
  maxRetryAfterSeconds: number;
  /** Per-attempt timeout. Defaults to `REQUEST_TIMEOUT_MS`. */
  timeoutMs?: number | undefined;
}

interface AbortSignalStatics {
  timeout?: (ms: number) => AbortSignal;
  any?: (signals: AbortSignal[]) => AbortSignal;
}

/**
 * Combines the caller's signal with a timeout. Uses `AbortSignal.timeout` and `AbortSignal.any`
 * where they exist, and an `AbortController` with a timer elsewhere (older React Native runtimes).
 * Call `done` when the attempt is over so the fallback timer is cleared.
 */
export function withTimeout(
  signal: AbortSignal | undefined,
  ms: number,
  statics: AbortSignalStatics | undefined = typeof AbortSignal === 'undefined' ? undefined : AbortSignal,
): { signal: AbortSignal | undefined; done: () => void } {
  if (typeof statics?.timeout === 'function' && typeof statics.any === 'function') {
    const timeout = statics.timeout(ms);
    return { signal: signal ? statics.any([signal, timeout]) : timeout, done: () => undefined };
  }
  if (typeof AbortController === 'undefined') return { signal, done: () => undefined };
  const controller = new AbortController();
  const onAbort = () => controller.abort(signal?.reason);
  const timer = setTimeout(() => controller.abort(new Error('The request timed out.')), ms);
  if (signal?.aborted) controller.abort(signal.reason);
  else signal?.addEventListener('abort', onAbort, { once: true });
  return {
    signal: controller.signal,
    done: () => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
    },
  };
}

/**
 * Sends one logical request with the shared retry policy: at most 3 attempts; retry only network
 * errors and the retry statuses; wait `Retry-After` seconds when given, otherwise 1 s then 2 s.
 * Redirects are never followed: a server that redirects fails as a network error. Each attempt
 * times out after `REQUEST_TIMEOUT_MS`. Returns the last response, which may still be an error
 * response.
 */
export async function sendWithRetry(url: string, init: RequestInit, options: SendOptions): Promise<Response> {
  const { signal } = options;
  for (let attempt = 1; ; attempt += 1) {
    throwIfAborted(signal);
    const isLast = attempt >= RETRY_POLICY.maxAttempts;
    let response: Response;
    const timed = withTimeout(signal, options.timeoutMs ?? REQUEST_TIMEOUT_MS);
    try {
      response = await options.fetch(url, { ...init, redirect: 'error', signal: timed.signal });
    } catch (error) {
      if (signal?.aborted) throw abortedError(error);
      if (isLast) {
        throw new TododdleSupportError({
          code: 'NETWORK_ERROR',
          message: 'Could not reach ToDoddle. Check the connection and try again.',
          httpStatus: 0,
          cause: error,
        });
      }
      await sleep(backoffMs(attempt), signal);
      continue;
    } finally {
      timed.done();
    }
    if (isLast || !retryStatuses.includes(response.status)) return response;

    const retryAfter = parseRetryAfter(response.headers.get('Retry-After'));
    if (retryAfter !== undefined && retryAfter > options.maxRetryAfterSeconds) return response;
    await discardBody(response);
    await sleep(retryAfter === undefined ? backoffMs(attempt) : retryAfter * 1000, signal);
  }
}

function backoffMs(attempt: number): number {
  const seconds =
    RETRY_POLICY.backoffSeconds[attempt - 1] ?? RETRY_POLICY.backoffSeconds[RETRY_POLICY.backoffSeconds.length - 1];
  return (seconds ?? 1) * 1000;
}

/** Seconds from a `Retry-After` header: delta-seconds or an HTTP date. */
export function parseRetryAfter(value: string | null, now: number = Date.now()): number | undefined {
  if (value === null) return undefined;
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed);
  const date = Date.parse(trimmed);
  if (Number.isNaN(date)) return undefined;
  return Math.max(0, Math.ceil((date - now) / 1000));
}

async function discardBody(response: Response): Promise<void> {
  try {
    await response.arrayBuffer();
  } catch {
    // Nothing to read.
  }
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) throw abortedError(signal.reason);
}

function abortedError(cause: unknown): TododdleSupportError {
  return new TododdleSupportError({ code: 'ABORTED', message: 'The request was cancelled.', httpStatus: 0, cause });
}

function sleep(ms: number, signal: AbortSignal | undefined): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortedError(signal.reason));
      return;
    }
    const onAbort = () => {
      clearTimeout(timer);
      reject(abortedError(signal?.reason));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Turns an error response into a typed error. Unknown codes are kept as they are. */
export async function errorFromResponse(
  response: Response,
  fallbackCode = 'HTTP_ERROR',
): Promise<TododdleSupportError> {
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    body = undefined;
  }
  const error = isRecord(body) && isRecord(body.error) ? body.error : undefined;
  const code =
    typeof error?.code === 'string' && error.code.length > 0
      ? error.code
      : response.status === 429
        ? 'RATE_LIMITED'
        : fallbackCode;
  const message = typeof error?.message === 'string' ? error.message : `ToDoddle returned HTTP ${response.status}.`;
  const fields: Record<string, string> = {};
  if (isRecord(error?.fields)) {
    for (const [key, value] of Object.entries(error.fields)) {
      if (typeof value === 'string') fields[key] = value;
    }
  }
  return new TododdleSupportError({
    code,
    message,
    httpStatus: response.status,
    fields,
    requestId: typeof error?.requestId === 'string' ? error.requestId : undefined,
    retryAfterSeconds: parseRetryAfter(response.headers.get('Retry-After')),
  });
}

export async function readJsonResponse(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch (cause) {
    throw new TododdleSupportError({
      code: 'INVALID_RESPONSE',
      message: 'ToDoddle sent a response the SDK could not read.',
      httpStatus: response.status,
      cause,
    });
  }
}

export { isRecord };
