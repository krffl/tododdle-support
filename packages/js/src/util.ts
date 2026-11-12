interface CryptoLike {
  randomUUID?: () => string;
  getRandomValues?: <T extends ArrayBufferView>(array: T) => T;
}

/** 32 hex characters, generated once per report and reused on every retry. */
export function createIdempotencyKey(): string {
  const cryptoApi = (globalThis as { crypto?: CryptoLike }).crypto;
  if (cryptoApi?.randomUUID) return cryptoApi.randomUUID().replace(/-/g, '');
  const bytes = new Uint8Array(16);
  if (cryptoApi?.getRandomValues) {
    cryptoApi.getRandomValues(bytes);
  } else {
    // React Native without a crypto polyfill. The key only needs to be unique, not secret.
    for (let i = 0; i < bytes.length; i += 1) bytes[i] = Math.floor(Math.random() * 256);
  }
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

/** Removes a query string or fragment, so a route name can never carry personal data. */
export function stripQuery(value: string): string {
  const index = value.search(/[?#]/);
  return index === -1 ? value : value.slice(0, index);
}

const LOOPBACK_HOSTS: ReadonlySet<string> = new Set(['127.0.0.1', '::1', 'localhost']);

/**
 * Reads the scheme and host of an absolute URL without `URL`, whose getters React Native does not
 * implement. Userinfo is skipped; a backslash ends the host as it does in browsers. Whitespace and
 * control characters are refused rather than guessed at.
 */
function schemeAndHost(value: string): { scheme: string; host: string } | null {
  // eslint-disable-next-line no-control-regex
  if (/[\s\u0000-\u001f\u007f]/.test(value)) return null;
  const match = /^([a-z][a-z0-9+.-]*):\/\/(?:[^@/\\?#]*@)?(\[[^\]]*\]|[^:/\\?#]*)/i.exec(value);
  const scheme = match?.[1];
  const host = match?.[2]?.replace(/^\[|\]$/g, '');
  if (!scheme || !host) return null;
  return { scheme: scheme.toLowerCase(), host: host.toLowerCase() };
}

/**
 * True for an `https:` URL, or an `http:` URL whose host is loopback (127.0.0.1, ::1, localhost)
 * so local test servers still work. Every other URL, and anything that does not parse, is refused.
 */
export function isAllowedUrl(value: string): boolean {
  const parts = schemeAndHost(value);
  if (!parts) return false;
  return parts.scheme === 'https' || (parts.scheme === 'http' && LOOPBACK_HOSTS.has(parts.host));
}

/** True only for an `https:` URL, for images the SDK shows from server config. */
export function isHttpsUrl(value: string | null | undefined): value is string {
  return typeof value === 'string' && schemeAndHost(value)?.scheme === 'https';
}

/** The contract's colour form (`HexColor` in openapi.yaml): `#` and six lowercase hex digits. */
export function isHexColor(value: unknown): value is string {
  return typeof value === 'string' && /^#[0-9a-f]{6}$/.test(value);
}

const FORBIDDEN_UPLOAD_HEADERS: ReadonlySet<string> = new Set([
  'host',
  'authorization',
  'cookie',
  'connection',
  'transfer-encoding',
  'content-length',
]);

/** The server's upload headers without the ones that could leak credentials or break framing. */
export function safeUploadHeaders(headers: Record<string, string> | undefined): Record<string, string> {
  const safe: Record<string, string> = {};
  for (const [name, value] of Object.entries(headers ?? {})) {
    const lower = name.toLowerCase();
    if (FORBIDDEN_UPLOAD_HEADERS.has(lower) || lower.startsWith('proxy-')) continue;
    if (typeof value === 'string') safe[name] = value;
  }
  return safe;
}

export function byteSize(data: Blob | ArrayBuffer | Uint8Array): number {
  if (data instanceof Uint8Array) return data.byteLength;
  if (data instanceof ArrayBuffer) return data.byteLength;
  return data.size;
}
