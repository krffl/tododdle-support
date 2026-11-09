# @krffl/tododdle-support

One-way in-app issue reporting into a ToDoddle Support project, for the web and any JavaScript
runtime with `fetch`. It is also the core of
[`@krffl/tododdle-support-react-native`](../react-native).

- Zero runtime dependencies. ESM, CommonJS and TypeScript types.
- Reports go one way. The reporter gets no email or replies.
- Nothing is collected automatically. The SDK sends only what your app passes in, plus
  `platform: "web"` if you set it in `defaultContext`.
- The public key (`tdsk_pub_…`) can only read the form config and submit reports, so it is safe to
  ship in client code.

## Install

```sh
npm install @krffl/tododdle-support
```

## Headless use

```ts
import { createTododdleSupport, isTododdleSupportError } from '@krffl/tododdle-support';

const support = createTododdleSupport({
  key: 'tdsk_pub_…',
  storage: window.localStorage, // optional: keep the last config between visits
  defaultContext: { platform: 'web', appVersion: '2.4.0' },
});

const config = await support.getConfig(); // form, wording and theme for your own UI

try {
  const result = await support.report({
    type: 'problem',
    title: 'Favourites vanish',
    description: 'They are gone after I reopen the app.',
    fields: { area: 'Home' },
    context: { screen: 'Favourites' },
    reporter: { customerReference: 'user-42' }, // optional and unverified
    attachments: [{ fileName: file.name, contentType: 'image/png', data: file }], // chosen by the person
  });
  console.log('Reference', result.status === 'received' ? result.reportId : 'queued');
} catch (error) {
  if (isTododdleSupportError(error) && error.code === 'INVALID_FIELDS') {
    showFieldErrors(error.fields); // a message per field key
  }
}
```

### Options

| Option | Default | Notes |
|---|---|---|
| `key` | required | The project's public SDK key. |
| `baseUrl` | `https://app.tododdle.com/api/support/sdk/v1` | |
| `appId` | none | Sent as `X-Tododdle-App-Id`. Browsers leave it out; their `Origin` is checked. |
| `fetch` | global `fetch` | |
| `storage` | memory | Anything with `getItem`, `setItem`, `removeItem` (sync or async), such as `localStorage`. |
| `offlineQueue` | `false` | Queue reports without attachments when the network fails. Send them with `flushQueue()`. |
| `defaultContext` | none | Merged under each report's `context`. |
| `maxRetryAfterSeconds` | `60` | A longer `Retry-After` fails at once with `RATE_LIMITED` and `retryAfterSeconds`. |

### What the client does

- `getConfig()` sends `If-None-Match` with the stored `ETag` and reuses the stored config on `304`.
  If the network or the server fails, it returns the last good config so your form still opens.
- `report()` checks the input against the config first (report type, required values, maximum
  lengths, SELECT options, attachment count, size and type) and sends nothing if it fails. It then
  creates the report, uploads each attachment to its pre-signed URL with exactly the returned
  headers, and submits it.
- One idempotency key per report, reused on every retry, so a retry never creates a second ticket.
- Retries: at most 3 attempts for `408`, `429`, `500`, `502`, `503`, `504` and network errors.
  It waits `Retry-After` seconds when given, otherwise 1 s then 2 s. Other errors are never retried.
- `context.screen` loses any query string or fragment before it is sent.

### Errors

Every failure is a `TododdleSupportError` with `code`, `httpStatus`, `message`, `fields`,
`requestId`, `retryAfterSeconds` and `retryable`. `code` is a contract code such as
`INVALID_FIELDS`, `KEY_REVOKED` or `REPORT_EXPIRED`, any new code the server sends, or one of the
SDK's own: `NETWORK_ERROR`, `ABORTED`, `UPLOAD_FAILED`, `INVALID_RESPONSE`, `HTTP_ERROR`
(`httpStatus` is `0` when no response arrived or the SDK refused before sending).

### Offline queue

```ts
const support = createTododdleSupport({ key, storage: localStorage, offlineQueue: true });
window.addEventListener('online', () => void support.flushQueue());
```

A queued report keeps its idempotency key, so sending it twice is safe. Reports with attachments
are not queued; they fail with the network error instead.

## Web dialog

A small optional dialog built on the native `<dialog>` element. It renders the project's form,
uses the project's accent colour and corners, labels every control, moves focus into the dialog,
closes on Escape and returns focus afterwards.

```ts
import { createTododdleSupport } from '@krffl/tododdle-support';
import { openReportDialog } from '@krffl/tododdle-support/dialog';

const support = createTododdleSupport({ key: 'tdsk_pub_…' });

button.addEventListener('click', async () => {
  const result = await openReportDialog(support, {
    context: { platform: 'web', appVersion: '2.4.0', screen: location.pathname },
  });
  // result is null if the person closed the dialog without sending.
});
```

Options: `context`, `reporter`, `defaultType`, `allowAttachments` (default `true` when the form
accepts files), `parent` and `onSubmitted`.

## Contract types

`npm run generate:types` regenerates `src/generated/openapi.ts` from `contract/openapi.yaml`. The
raw types are exported as `OpenApiPaths` and `OpenApiComponents`.
