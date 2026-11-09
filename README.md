# tododdle-support

SDKs for one-way in-app issue reporting into a ToDoddle Support project.

- `contract/openapi.yaml`: the v1 HTTP contract every SDK follows. Validate it with
  `npx @redocly/cli lint contract/openapi.yaml`.
- `contract/cases/cases.json`: shared conformance cases and the retry policy every SDK runs.
- Design, data model, limits and abuse controls: `docs/engineering/support-sdk.md` in the ToDoddle
  app repository.

Planned packages (one folder each, with an example app):

| Folder | Package |
|---|---|
| `packages/js` | `@krffl/tododdle-support` (headless core for web and React Native, plus a small web dialog) |
| `packages/react-native` | `@krffl/tododdle-support-react-native` |
| `swift` | `TododdleSupport` (Swift Package Manager) |
| `kotlin` | `com.tododdle:support` |
| `flutter` | `tododdle_support` |

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
