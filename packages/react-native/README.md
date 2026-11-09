# @krffl/tododdle-support-react-native

A ready-made report sheet for React Native apps, on top of
[`@krffl/tododdle-support`](../js). Reports go one way into a ToDoddle Support project.

- No native modules. Works in Expo and bare React Native.
- Nothing is collected automatically. The sheet adds the OS name and version from React Native's
  `Platform`, plus the app version and build you pass. A screenshot is attached only if your app
  provides one and the person keeps it after seeing the preview.

## Install

```sh
npm install @krffl/tododdle-support-react-native
```

Peer dependencies: `react` and `react-native`.

## Report sheet

```tsx
import { createTododdleSupport, ReportSheet } from '@krffl/tododdle-support-react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';

const support = createTododdleSupport({
  key: 'tdsk_pub_…',
  appId: 'com.example.app', // the bundle ID or package name
  appVersion: '2.4.0',
  build: '118',
  storage: AsyncStorage, // optional: keep the last config so the sheet opens offline
});

export function HelpButton() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button title="Report a problem" onPress={() => setOpen(true)} />
      <ReportSheet
        client={support}
        visible={open}
        onClose={() => setOpen(false)}
        context={{ screen: 'Favourites' }}
      />
    </>
  );
}
```

### Screenshots

The SDK never captures the screen. Your app can pass an image it already has, or let the person
pick one:

```tsx
<ReportSheet
  client={support}
  visible={open}
  onClose={() => setOpen(false)}
  screenshot={lastScreenshotUri ? { uri: lastScreenshotUri } : null} // shown with a preview and Remove
  onRequestScreenshot={async () => {
    const picked = await pickImageSomehow(); // for example expo-image-picker
    return picked ? { uri: picked.uri, fileName: picked.fileName } : null;
  }}
/>
```

The image is read with `fetch(uri)` only when the person sends the report.

### Props

| Prop | Notes |
|---|---|
| `client` | From `createTododdleSupport`. |
| `visible`, `onClose` | Controls the modal. Android back closes it. |
| `onSubmitted` | Called with the result after the report is received or queued. |
| `appVersion`, `build`, `context`, `reporter` | Added to the report. `reporter` is optional and unverified. |
| `defaultType` | The report type selected first. |
| `screenshot`, `onRequestScreenshot` | See above. |
| `labels` | Override the sheet's own words (Cancel, Close, Add screenshot and so on). The form's words come from the project config. |

## Headless

Everything from `@krffl/tododdle-support` is re-exported. The React Native `createTododdleSupport`
sends `X-Tododdle-Sdk: react-native/<version>` and adds the platform context to every report:

```ts
const result = await support.report({
  type: 'feedback',
  description: 'Love the new list view.',
});
```

See the [core README](../js/README.md) for options, retries, errors and the offline queue.
