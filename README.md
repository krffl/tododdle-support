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

Each folder's README has the full setup and an example app.

Reports go one way: the reporter gets no email or replies. The public key (`tdsk_pub_…`) can only
read the form config and submit reports, so it is safe to ship inside an app.

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
- Releases: publish a GitHub release tagged `v<VERSION>`. `.github/workflows/publish.yml` checks the
  tag, runs the tests and publishes both npm packages. Pre-release versions go to the `next` tag.

## Releasing

1. Change `/VERSION`, then run `npm run sync-version`. It updates the npm packages, the Swift
   `SDKVersion.swift` and the Flutter `pubspec.yaml` and `version.dart`. Kotlin reads `/VERSION`
   when it builds. CI and each platform's tests fail if a copy is out of date.
2. If you change `contract/cases/cases.json`, run `scripts/sync-swift-cases.sh` (Swift bundles a copy).
3. Commit, then publish a GitHub release tagged `v<VERSION>`. The publish workflow puts both npm
   packages on npm. Swift and Flutter use the tag directly, and JitPack builds Kotlin from it on the
   first request.

Each platform has its own quality workflow (`quality.yml` for JS, plus `quality-swift.yml`,
`quality-kotlin.yml` and `quality-flutter.yml`). All of them run the shared conformance cases.
