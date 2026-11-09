import type { ApiErrorCode } from './types';

/** Codes the SDK itself uses, for problems that happen before or outside the server. */
export type ClientErrorCode =
  'NETWORK_ERROR' | 'ABORTED' | 'UPLOAD_FAILED' | 'INVALID_RESPONSE' | 'CONFIG_UNAVAILABLE' | 'HTTP_ERROR';

/** Known codes, plus any string a newer server sends. */
export type TododdleSupportErrorCode = ApiErrorCode | ClientErrorCode | (string & {});

export interface TododdleSupportErrorInit {
  code: TododdleSupportErrorCode;
  message: string;
  /** `0` when no HTTP response was received or the SDK refused before sending. */
  httpStatus: number;
  fields?: Record<string, string>;
  requestId?: string;
  retryAfterSeconds?: number;
  cause?: unknown;
}

export class TododdleSupportError extends Error {
  override readonly name = 'TododdleSupportError';
  readonly code: TododdleSupportErrorCode;
  readonly httpStatus: number;
  /** For `INVALID_FIELDS` and `FIELDS_CHANGED`: a message per field key. */
  readonly fields: Record<string, string>;
  readonly requestId: string | undefined;
  readonly retryAfterSeconds: number | undefined;

  constructor(init: TododdleSupportErrorInit) {
    super(init.message, init.cause === undefined ? undefined : { cause: init.cause });
    this.code = init.code;
    this.httpStatus = init.httpStatus;
    this.fields = init.fields ?? {};
    this.requestId = init.requestId;
    this.retryAfterSeconds = init.retryAfterSeconds;
  }

  /** True when trying again later may work (network trouble, rate limits, server errors). */
  get retryable(): boolean {
    return (
      this.code === 'NETWORK_ERROR' || this.httpStatus === 408 || this.httpStatus === 429 || this.httpStatus >= 500
    );
  }
}

export function isTododdleSupportError(value: unknown): value is TododdleSupportError {
  return value instanceof TododdleSupportError;
}
