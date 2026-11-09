import { isTododdleSupportError, TododdleSupportError } from './errors';
import { errorFromResponse, isRecord, readJsonResponse, sendWithRetry } from './http';
import { memoryStorage, readJson, writeJson } from './storage';
import type {
  AttachmentInput,
  Config,
  FetchLike,
  FlushResult,
  ReportContext,
  ReportInput,
  ReportOptions,
  Reporter,
  ReportRequest,
  ReportResponse,
  ReportResult,
  TododdleSupport,
  TododdleSupportOptions,
} from './types';
import { byteSize, createIdempotencyKey, stripQuery } from './util';
import { validateReport } from './validate';
import { SDK_VERSION } from './version';

export const DEFAULT_BASE_URL = 'https://app.tododdle.com/api/support/sdk/v1';
const DEFAULT_MAX_RETRY_AFTER_SECONDS = 60;
const MAX_QUEUED_REPORTS = 50;

interface CachedConfig {
  etag: string | null;
  config: Config;
}

interface QueuedReport {
  body: ReportRequest;
  queuedAt: string;
}

function isConfig(value: unknown): value is Config {
  if (!isRecord(value)) return false;
  const { project, form, wording, theme } = value;
  return (
    isRecord(project) &&
    typeof project.name === 'string' &&
    isRecord(form) &&
    typeof form.version === 'number' &&
    Array.isArray(form.types) &&
    form.types.length > 0 &&
    Array.isArray(form.fields) &&
    isRecord(form.attachments) &&
    isRecord(wording) &&
    isRecord(theme)
  );
}

function isCachedConfig(value: unknown): value is CachedConfig {
  return isRecord(value) && (typeof value.etag === 'string' || value.etag === null) && isConfig(value.config);
}

function isReportResponse(value: unknown): value is ReportResponse {
  return (
    isRecord(value) &&
    typeof value.reportId === 'string' &&
    (value.status === 'received' || value.status === 'awaiting_uploads')
  );
}

function isQueue(value: unknown): value is QueuedReport[] {
  return (
    Array.isArray(value) &&
    value.every((item) => isRecord(item) && isRecord(item.body) && typeof item.body.idempotencyKey === 'string')
  );
}

/** A short, stable fingerprint so two keys never share a cache entry. Not a security measure. */
function fingerprint(value: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < value.length; i += 1) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}

function invalidResponse(httpStatus: number): TododdleSupportError {
  return new TododdleSupportError({
    code: 'INVALID_RESPONSE',
    message: 'ToDoddle sent a response the SDK could not read.',
    httpStatus,
  });
}

function nonEmpty(value: string | undefined): string | undefined {
  return value === undefined || value.trim().length === 0 ? undefined : value;
}

function compact<T extends object>(value: T): T | undefined {
  const entries = Object.entries(value).filter(([, item]) => item !== undefined && item !== '');
  return entries.length === 0 ? undefined : (Object.fromEntries(entries) as T);
}

function buildContext(defaults: ReportContext | undefined, own: ReportContext | undefined): ReportContext | undefined {
  const extra = { ...defaults?.extra, ...own?.extra };
  const merged: ReportContext = { ...defaults, ...own };
  merged.extra = Object.keys(extra).length > 0 ? extra : undefined;
  if (merged.screen !== undefined) merged.screen = stripQuery(merged.screen);
  return compact(merged);
}

function buildRequest(
  input: ReportInput,
  formVersion: number,
  idempotencyKey: string,
  config: Config | null,
  defaultContext: ReportContext | undefined,
): ReportRequest {
  const knownKeys = config ? new Set(config.form.fields.map((field) => field.key)) : null;
  const fields: Record<string, string> = {};
  for (const [key, value] of Object.entries(input.fields ?? {})) {
    // The server drops unknown keys too; leaving them out keeps the body small.
    if (value.length > 0 && (knownKeys === null || knownKeys.has(key))) fields[key] = value;
  }
  const reporter: Reporter | undefined = input.reporter ? compact({ ...input.reporter }) : undefined;
  const attachments = (input.attachments ?? []).map(({ fileName, contentType, data }) => ({
    fileName,
    contentType,
    size: byteSize(data),
  }));

  const body: ReportRequest = { idempotencyKey, type: input.type, formVersion };
  const title = nonEmpty(input.title);
  if (title !== undefined && config?.form.title?.enabled !== false) body.title = title;
  const description = nonEmpty(input.description);
  if (description !== undefined) body.description = description;
  if (Object.keys(fields).length > 0) body.fields = fields;
  const context = buildContext(defaultContext, input.context);
  if (context) body.context = context;
  if (reporter) body.reporter = reporter;
  if (attachments.length > 0) body.attachments = attachments;
  return body;
}

/**
 * Creates a ToDoddle Support client. It works anywhere `fetch` exists: browsers, React Native,
 * Node 18+ and workers.
 */
export function createTododdleSupport(options: TododdleSupportOptions): TododdleSupport {
  if (typeof options.key !== 'string' || options.key.length === 0) {
    throw new TypeError('createTododdleSupport needs the project public key.');
  }
  const baseUrl = (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, '');
  const storage = options.storage ?? memoryStorage();
  const sdkHeader = `${options.sdkName ?? 'js'}/${options.sdkVersion ?? SDK_VERSION}`;
  const prefix = `tododdle-support:${fingerprint(`${baseUrl}|${options.key}`)}`;
  const configStorageKey = `${prefix}:config`;
  const queueStorageKey = `${prefix}:queue`;
  const maxRetryAfterSeconds = options.maxRetryAfterSeconds ?? DEFAULT_MAX_RETRY_AFTER_SECONDS;
  let memoryConfig: CachedConfig | null = null;
  let queueLock: Promise<unknown> = Promise.resolve();

  function fetchFn(): FetchLike {
    if (options.fetch) return options.fetch;
    if (typeof globalThis.fetch !== 'function') {
      throw new TypeError('No fetch function. Pass `fetch` to createTododdleSupport.');
    }
    return globalThis.fetch.bind(globalThis);
  }

  function apiHeaders(extra?: Record<string, string>): Record<string, string> {
    const headers: Record<string, string> = {
      Accept: 'application/json',
      'X-Tododdle-Key': options.key,
      'X-Tododdle-Sdk': sdkHeader,
      ...extra,
    };
    if (options.appId) headers['X-Tododdle-App-Id'] = options.appId;
    return headers;
  }

  function send(path: string, init: RequestInit, signal: AbortSignal | undefined): Promise<Response> {
    return sendWithRetry(`${baseUrl}${path}`, init, { fetch: fetchFn(), signal, maxRetryAfterSeconds });
  }

  function postJson(path: string, body: unknown, signal: AbortSignal | undefined): Promise<Response> {
    return send(
      path,
      { method: 'POST', headers: apiHeaders({ 'Content-Type': 'application/json' }), body: JSON.stringify(body) },
      signal,
    );
  }

  async function loadCachedConfig(): Promise<CachedConfig | null> {
    if (memoryConfig) return memoryConfig;
    memoryConfig = await readJson(storage, configStorageKey, isCachedConfig);
    return memoryConfig;
  }

  async function getConfig(callOptions: { signal?: AbortSignal } = {}): Promise<Config> {
    const cached = await loadCachedConfig();
    const extra: Record<string, string> = {};
    if (cached?.etag) extra['If-None-Match'] = cached.etag;
    let response: Response;
    try {
      response = await send('/config', { method: 'GET', headers: apiHeaders(extra) }, callOptions.signal);
    } catch (error) {
      if (cached && isTododdleSupportError(error) && error.code === 'NETWORK_ERROR') return cached.config;
      throw error;
    }
    if (response.status === 304) {
      if (cached) return cached.config;
      throw invalidResponse(304);
    }
    if (response.ok) {
      const body = await readJsonResponse(response);
      if (!isConfig(body)) throw invalidResponse(response.status);
      memoryConfig = { etag: response.headers.get('ETag'), config: body };
      await writeJson(storage, configStorageKey, memoryConfig);
      return body;
    }
    const error = await errorFromResponse(response);
    // Keep the dialog working through outages; never through a revoked key or a disabled module.
    if (cached && error.retryable) return cached.config;
    throw error;
  }

  async function getCachedConfig(): Promise<Config | null> {
    return (await loadCachedConfig())?.config ?? null;
  }

  async function createReport(body: ReportRequest, signal: AbortSignal | undefined): Promise<ReportResponse> {
    const response = await postJson('/reports', body, signal);
    if (!response.ok) throw await errorFromResponse(response);
    const created = await readJsonResponse(response);
    if (!isReportResponse(created)) throw invalidResponse(response.status);
    return created;
  }

  async function upload(
    target: NonNullable<ReportResponse['uploads']>[number],
    attachment: AttachmentInput,
    signal: AbortSignal | undefined,
  ): Promise<void> {
    // Only the returned headers: the upload URL is pre-signed and needs nothing else.
    // Every fetch implementation accepts Blob, ArrayBuffer and typed arrays as a body.
    const body = attachment.data as BodyInit;
    const response = await sendWithRetry(
      target.uploadUrl,
      { method: 'PUT', headers: { ...target.headers }, body },
      { fetch: fetchFn(), signal, maxRetryAfterSeconds },
    );
    if (!response.ok) {
      const error = await errorFromResponse(response, 'UPLOAD_FAILED');
      throw new TododdleSupportError({
        code: 'UPLOAD_FAILED',
        message: `Could not upload ${attachment.fileName}.`,
        httpStatus: response.status,
        cause: error,
      });
    }
  }

  async function finish(
    created: ReportResponse,
    attachments: AttachmentInput[],
    signal: AbortSignal | undefined,
  ): Promise<ReportResponse> {
    if (created.status === 'received') return created;
    const uploads = created.uploads ?? [];
    if (!created.submitToken || uploads.length !== attachments.length) throw invalidResponse(201);
    for (let i = 0; i < uploads.length; i += 1) {
      const target = uploads[i];
      const attachment = attachments[i];
      if (target && attachment) await upload(target, attachment, signal);
    }
    const response = await postJson(
      `/reports/${encodeURIComponent(created.reportId)}/submit`,
      { submitToken: created.submitToken },
      signal,
    );
    if (!response.ok) throw await errorFromResponse(response);
    const submitted = await readJsonResponse(response);
    if (!isReportResponse(submitted) || submitted.status !== 'received') throw invalidResponse(response.status);
    return submitted;
  }

  function withQueueLock<T>(task: () => Promise<T>): Promise<T> {
    const run = queueLock.then(task, task);
    queueLock = run.catch(() => undefined);
    return run;
  }

  async function readQueue(): Promise<QueuedReport[]> {
    return (await readJson(storage, queueStorageKey, isQueue)) ?? [];
  }

  async function saveQueue(queue: QueuedReport[]): Promise<void> {
    if (queue.length === 0) {
      try {
        await storage.removeItem(queueStorageKey);
      } catch {
        // Ignore: the queue is best effort.
      }
      return;
    }
    await writeJson(storage, queueStorageKey, queue);
  }

  async function report(input: ReportInput, reportOptions: ReportOptions = {}): Promise<ReportResult> {
    const { signal } = reportOptions;
    let config: Config | null = reportOptions.config ?? null;
    if (!config && !reportOptions.skipValidation) config = await getCachedConfig();
    if (!config && input.formVersion === undefined) config = await getConfig({ signal });
    if (config && !reportOptions.skipValidation) {
      const fields = validateReport(config, input);
      if (Object.keys(fields).length > 0) {
        throw new TododdleSupportError({
          code: 'INVALID_FIELDS',
          message: 'Check the highlighted fields.',
          httpStatus: 0,
          fields,
        });
      }
    }
    const formVersion = input.formVersion ?? config?.form.version ?? 1;
    const idempotencyKey = createIdempotencyKey();
    const body = buildRequest(input, formVersion, idempotencyKey, config, options.defaultContext);
    const attachments = input.attachments ?? [];

    let created: ReportResponse;
    try {
      created = await createReport(body, signal);
    } catch (error) {
      if (options.offlineQueue && attachments.length === 0 && isTododdleSupportError(error) && error.retryable) {
        await withQueueLock(async () => {
          const queue = await readQueue();
          queue.push({ body, queuedAt: new Date().toISOString() });
          await saveQueue(queue.slice(-MAX_QUEUED_REPORTS));
        });
        return { status: 'queued', idempotencyKey };
      }
      throw error;
    }
    const done = await finish(created, attachments, signal);
    return { status: 'received', reportId: done.reportId, idempotencyKey };
  }

  function flushQueue(flushOptions: { signal?: AbortSignal } = {}): Promise<FlushResult> {
    return withQueueLock(async () => {
      const queue = await readQueue();
      const result: FlushResult = { sent: [], dropped: [], remaining: 0 };
      let index = 0;
      for (; index < queue.length; index += 1) {
        const item = queue[index];
        if (!item) continue;
        const { idempotencyKey } = item.body;
        try {
          const created = await createReport(item.body, flushOptions.signal);
          if (created.status !== 'received') throw invalidResponse(201);
          result.sent.push({ reportId: created.reportId, idempotencyKey });
        } catch (error) {
          const typed = isTododdleSupportError(error) ? error : null;
          if (!typed || typed.retryable || typed.code === 'ABORTED') break;
          result.dropped.push({ idempotencyKey, code: typed.code, httpStatus: typed.httpStatus });
        }
      }
      const remaining = queue.slice(index);
      await saveQueue(remaining);
      result.remaining = remaining.length;
      return result;
    });
  }

  async function queuedCount(): Promise<number> {
    return (await readQueue()).length;
  }

  return { getConfig, getCachedConfig, report, flushQueue, queuedCount };
}
