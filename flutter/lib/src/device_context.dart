import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'models.dart';

/// Returns context to fill empty [ReportContext] values.
typedef ContextProvider = Future<ReportContext> Function();

/// Collects the app version, build, OS name and version, device model and
/// locale. Nothing else is collected: no device name, identifiers, location,
/// logs or URLs. Values that cannot be read are left out.
Future<ReportContext> collectDeviceContext() async {
  String? appVersion;
  String? build;
  String? osName;
  String? osVersion;
  String? deviceModel;

  try {
    final package = await PackageInfo.fromPlatform();
    appVersion = _clip(package.version, 50);
    build = _clip(package.buildNumber, 50);
  } catch (_) {
    // Not available on this platform or in tests.
  }

  try {
    final plugin = DeviceInfoPlugin();
    if (kIsWeb) {
      final web = await plugin.webBrowserInfo;
      osName = 'Web';
      deviceModel = web.browserName.name;
    } else {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final info = await plugin.androidInfo;
          osName = 'Android';
          osVersion = info.version.release;
          deviceModel = '${info.manufacturer} ${info.model}';
        case TargetPlatform.iOS:
          final info = await plugin.iosInfo;
          osName = info.systemName;
          osVersion = info.systemVersion;
          deviceModel = info.modelName.isNotEmpty ? info.modelName : info.model;
        case TargetPlatform.macOS:
          final info = await plugin.macOsInfo;
          osName = 'macOS';
          osVersion = info.osRelease;
          deviceModel = info.modelName.isNotEmpty ? info.modelName : info.model;
        case TargetPlatform.windows:
          final info = await plugin.windowsInfo;
          osName = 'Windows';
          osVersion = info.displayVersion;
        case TargetPlatform.linux:
          final info = await plugin.linuxInfo;
          osName = info.name;
          osVersion = info.versionId;
        case TargetPlatform.fuchsia:
          osName = 'Fuchsia';
      }
    }
  } catch (_) {
    // Not available on this platform or in tests.
  }

  String? locale;
  try {
    locale = _clip(PlatformDispatcher.instance.locale.toLanguageTag(), 35);
  } catch (_) {
    locale = null;
  }

  return ReportContext(
    platform: 'flutter',
    appVersion: _emptyToNull(appVersion),
    build: _emptyToNull(build),
    osName: _emptyToNull(_clip(osName, 50)),
    osVersion: _emptyToNull(_clip(osVersion, 50)),
    deviceModel: _emptyToNull(_clip(deviceModel?.trim(), 100)),
    locale: locale == 'und' ? null : _emptyToNull(locale),
  );
}

String? _clip(String? value, int max) =>
    value == null || value.length <= max ? value : value.substring(0, max);

String? _emptyToNull(String? value) =>
    value == null || value.isEmpty ? null : value;
