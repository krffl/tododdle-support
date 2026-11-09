import type { components } from './generated/openapi';

type Schemas = components['schemas'];

/** The report form, wording and theme returned by `GET /config`. */
export type Config = Schemas['Config'];
export type FormConfig = Config['form'];
export type FieldDefinition = Schemas['FieldDefinition'];
export type ReportType = Schemas['ReportType'];
export type ReportContext = Schemas['ReportContext'];
export type Reporter = Schemas['Reporter'];
export type ReportRequest = Schemas['ReportRequest'];
export type ReportResponse = Schemas['ReportResponse'];
export type ApiErrorBody = Schemas['Error'];
/** Error codes the v1 contract defines. The server may add more; see `TododdleSupportError.code`. */
export type ApiErrorCode = ApiErrorBody['error']['code'];
export type AttachmentContentType = NonNullable<ReportRequest['attachments']>[number]['contentType'];
export type Theme = Config['theme'];
export type Wording = Config['wording'];

/** Bytes of a user-chosen file. */
export type AttachmentData = Blob | ArrayBuffer | Uint8Array;

/** A file the person chose and previewed. The SDK never collects files on its own. */
export interface AttachmentInput {
  fileName: string;
  contentType: AttachmentContentType;
  data: AttachmentData;
}

/** What the host app passes to `report()`. */
export interface ReportInput {
  type: ReportType;
  title?: string;
  description?: string;
  /** Values by field key: text for text fields, one of the options for SELECT fields. */
  fields?: Record<string, string>;
  context?: ReportContext;
  reporter?: Reporter;
  attachments?: AttachmentInput[];
  /** Defaults to the version of the config used for validation. */
  formVersion?: number;
}

export interface ReportOptions {
  /** Validate against this config instead of the cached one. */
  config?: Config;
  /** Skip client-side validation. The server still validates. */
  skipValidation?: boolean;
  signal?: AbortSignal;
}

export type ReportResult =
  | { status: 'received'; reportId: string; idempotencyKey: string }
  /** Saved in the offline queue. Call `flushQueue()` later to send it. */
  | { status: 'queued'; idempotencyKey: string };

export interface FlushResult {
  sent: Array<{ reportId: string; idempotencyKey: string }>;
  /** Reports the server refused for good. They are removed from the queue. */
  dropped: Array<{ idempotencyKey: string; code: string; httpStatus: number }>;
  /** Reports still waiting, for example because the device is still offline. */
  remaining: number;
}

/**
 * Key/value storage. `localStorage` and React Native `AsyncStorage` both fit.
 * Values are JSON strings.
 */
export interface SupportStorage {
  getItem(key: string): string | null | Promise<string | null>;
  setItem(key: string, value: string): void | Promise<void>;
  removeItem(key: string): void | Promise<void>;
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface TododdleSupportOptions {
  /** The project's public SDK key (`tdsk_pub_…` or `tdsk_test_…`). */
  key: string;
  /** Defaults to `https://app.tododdle.com/api/support/sdk/v1`. */
  baseUrl?: string;
  /** iOS bundle ID or Android package name. Browsers leave this out. */
  appId?: string;
  /** Defaults to the global `fetch`. */
  fetch?: FetchLike;
  /** Where to keep the last config and the offline queue. Defaults to memory. */
  storage?: SupportStorage;
  /** Queue reports without attachments when the network fails, and send them with `flushQueue()`. */
  offlineQueue?: boolean;
  /** Context merged under each report's own `context`. */
  defaultContext?: ReportContext;
  /**
   * The longest `Retry-After` (seconds) the SDK waits for inside one call. Longer waits fail with
   * `RATE_LIMITED` and `retryAfterSeconds` so the app can decide. Default 60.
   */
  maxRetryAfterSeconds?: number;
  /** SDK name for `X-Tododdle-Sdk`. Wrapper packages set this; apps should not. */
  sdkName?: string;
  /** SDK version for `X-Tododdle-Sdk`. Wrapper packages set this; apps should not. */
  sdkVersion?: string;
}

export interface TododdleSupport {
  /**
   * Reads the form config. Sends `If-None-Match` when a config is cached and returns the cached
   * one on `304`. When the network fails, returns the last good config if there is one.
   */
  getConfig(options?: { signal?: AbortSignal }): Promise<Config>;
  /** The last good config, without any network request. */
  getCachedConfig(): Promise<Config | null>;
  /** Validates, sends, uploads attachments and submits one report. */
  report(input: ReportInput, options?: ReportOptions): Promise<ReportResult>;
  /** Sends reports saved in the offline queue. */
  flushQueue(options?: { signal?: AbortSignal }): Promise<FlushResult>;
  /** Number of reports in the offline queue. */
  queuedCount(): Promise<number>;
}
