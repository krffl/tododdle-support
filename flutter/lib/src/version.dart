/// The SDK version. It must match `version:` in `pubspec.yaml` and the
/// repository's `VERSION` file; a test checks this.
const String tododdleSupportSdkVersion = '1.0.1';

/// The value sent in the `X-Tododdle-Sdk` header.
const String tododdleSupportSdkHeader = 'flutter/$tododdleSupportSdkVersion';
