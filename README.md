# tododdle-support

SDKs for one-way in-app issue reporting into a ToDoddle Support project.

- `contract/openapi.yaml`: the v1 HTTP contract every SDK follows. Validate it with
  `npx @redocly/cli lint contract/openapi.yaml`.
- `contract/cases/cases.json`: shared conformance cases and the retry policy every SDK runs.
- Design, data model, limits and abuse controls: `docs/engineering/support-sdk.md` in the ToDoddle
  app repository.

Every platform is released together from one `v<version>` tag:

| Folder | Package | Install |
|---|---|---|
| `packages/js` | `@krffl/tododdle-support` (headless core plus a small web dialog) | `npm install @krffl/tododdle-support` |
| `packages/react-native` | `@krffl/tododdle-support-react-native` | `npm install @krffl/tododdle-support-react-native` |
| `swift` | `TododdleSupport` | Swift Package Manager: this repository URL, from `1.0.0` |
| `kotlin` | `com.github.krffl.tododdle-support:support` (+ `support-compose`, `support-offline`) | JitPack: `implementation("com.github.krffl.tododdle-support:support-compose:v1.0.0")` |
| `flutter` | `tododdle_support` | git dependency with `path: flutter` and `ref: v1.0.0` |
| `godot` | `addons/tododdle_support` (Godot 4 addon: client plus a report dialog) | copy `godot/addons/tododdle_support` from the `v1.0.0` tag into your game's `addons/` |

Each folder's README has the full setup and an example app.

Reports go one way: the reporter gets no email or replies. The public key (`tdsk_pub_…`) can only
read the form config and submit reports, so it is safe to ship inside an app.

## Security rules every SDK follows

- **Key:** must start with `tdsk_pub_` or `tdsk_test_`. Any other key is refused before anything
  is sent.
- **Base URL:** must be `https`. Plain `http` is allowed only for a loopback host (`127.0.0.1`,
  `::1`, `localhost`), so local test servers still work.
- **Redirects:** never followed, for API calls and uploads.
- **Upload URLs:** the server's `uploadUrl` must be `https` (plain `http` only for a loopback host).
  Otherwise the report fails with `INVALID_RESPONSE` before any file is uploaded. `Host`,
  `Authorization`, `Cookie`, `Proxy-*`, `Connection`, `Transfer-Encoding` and `Content-Length` are
  dropped from the server's upload headers.
- **`context.screen`:** everything from the first `?` or `#` is removed before sending.
- **Offline queues** (Swift, Kotlin, Flutter): at most 10 reports, none older than 7 days. When
  the Swift queue is full, a new report fails with its network error. Kotlin and Flutter instead
  drop the oldest reports first, and also keep the queue under 20 MB.

How each SDK reports a broken rule:

| SDK | Bad key or base URL | Redirect |
|---|---|---|
| JavaScript, React Native | `TypeError` from `createTododdleSupport` | `NETWORK_ERROR` (fetch `redirect: 'error'`); each attempt also times out after 30 s |
| Swift | `INVALID_KEY` or `INVALID_CONFIGURATION`, before any request | `INVALID_RESPONSE` with the 3xx status |
| Kotlin | `IllegalArgumentException` from `Configuration` | `INVALID_RESPONSE` with the 3xx status |
| Flutter | `ArgumentError` from the constructor | `HTTP_ERROR` with the 3xx status |
| Godot | `NOT_CONFIGURED` result, nothing sent | `HTTP_ERROR` with the 3xx status |

The JS web dialog and the React Native sheet show the project logo only from an `https` URL, and
the web dialog uses the accent colours only when they match the contract's `#rrggbb` form. The
Godot dialog leaves text attachments (such as logs) unticked until the player ticks them; scrub
personal data from any log you offer.

## JavaScript and React Native development

The root `package.json` is an npm workspace for `packages/js` and `packages/react-native`.

```sh
npm ci
npm test            # builds both packages, runs unit tests and the shared conformance cases
npm run lint
npm run typecheck
```

- `/VERSION` is the release version. After changing it, run `npm run sync-version`.
- `npm run generate:types` regenerates the TypeScript types from `contract/openapi.yaml`.
- Examples: `examples/web` (dialog and headless) and `examples/react-native` (report sheet).
- Releases: publish a GitHub release tagged `v<VERSION>` on a commit that is on `main`.
  `.github/workflows/publish.yml` has two jobs. `build` (read-only) checks that the tag is on
  `origin/main` and matches `VERSION`, runs every check and packs both tarballs. `publish` (the only
  job with the npm OIDC token) installs nothing and publishes those tarballs, core first.
  Pre-release versions go to the `next` tag.

## Releasing

1. Change `/VERSION`, then run `npm run sync-version`. It updates the npm packages, the Swift
   `SDKVersion.swift`, the Flutter `pubspec.yaml` and `version.dart`, and the Godot `plugin.cfg`
   and `SDK_VERSION`. Kotlin reads `/VERSION` when it builds. CI and each platform's tests fail if
   a copy is out of date.
2. If you change `contract/cases/cases.json`, run `scripts/sync-swift-cases.sh` (Swift bundles a copy).
3. Commit on `main`, then publish a GitHub release tagged `v<VERSION>`. The tag must be on `main`. The publish workflow puts both npm
   packages on npm. Swift, Flutter and Godot use the tag directly, and JitPack builds Kotlin from it
   on the first request.

Each platform has its own quality workflow (`quality.yml` for JS, plus `quality-swift.yml`,
`quality-kotlin.yml`, `quality-flutter.yml` and `quality-godot.yml`). All of them run the shared
conformance cases.

## License

MIT. See `LICENSE`. Each package carries a copy, so the Godot addon folder and the npm and Flutter packages keep it when copied or installed.
