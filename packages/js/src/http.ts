import { TododdleSupportError } from './errors';
import type { FetchLike } from './types';

/** Mirrors `retryPolicy` in contract/cases/cases.json. Every SDK follows it. */
export const RETRY_POLICY = {
  maxAttempts: 3,
  backoffSeconds: [1, 2, 4],
  retryStatuses: [408, 429, 500, 502, 503, 504],
} as const;

const retryStatuses: readonly number[] = RETRY_POLICY.retryStatuses;

export interface SendOptions {
  fetch: FetchLike;
  signal?: AbortSignal | undefined;
  maxRetryAfterSeconds: number;
}

/**
 * Sends one logical request with the shared retry policy: at most 3 attempts; retry only network
 * errors and the retry statuses; wait `Retry-After` seconds when given, otherwise 1 s then 2 s.
 * Returns the last response, which may still be an error response.
 */
export async function sendWithRetry(url: string, init: RequestInit, options: SendOptions): Promise<Response> {
  const { signal } = options;
  for (let attempt = 1; ; attempt += 1) {
    throwIfAborted(signal);
    const isLast = attempt >= RETRY_POLICY.maxAttempts;
    let response: Response;
    try {
      response = await options.fetch(url, { ...init, signal });
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
