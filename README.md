# tododdle-support

SDKs for one-way in-app issue reporting into a ToDoddle Support project.

- `contract/openapi.yaml`: the v1 HTTP contract every SDK follows. Validate it with
  `npx @redocly/cli lint contract/openapi.yaml`.
- Design, data model, limits and abuse controls: `docs/engineering/support-sdk.md` in the ToDoddle
  app repository.

Planned packages (one folder each, with an example app):

| Folder | Package |
|---|---|
| `packages/js` | `@tododdle/support` (headless core for web and React Native) |
| `packages/react-native` | `@tododdle/support-react-native` |
| `swift` | `TododdleSupport` (Swift Package Manager) |
| `kotlin` | `com.github.krffl.tododdle-support:support` (JitPack), plus `support-compose` and `support-offline` |
| `flutter` | `tododdle_support` |

Reports go one way: the reporter gets no email or replies. The public key (`tdsk_pub_…`) can only
read the form config and submit reports, so it is safe to ship inside an app.
