import type { ReportContext } from '@krffl/tododdle-support';
import { Platform } from 'react-native';

export interface AppInfo {
  /** The host app's version, for example `2.4.0`. */
  appVersion?: string;
  /** The host app's build number. */
  build?: string;
}

/**
 * Context React Native knows without asking anyone: the OS name and version. The app version and
 * build come from the host app, because React Native core cannot read them without a native module.
 */
export function platformContext(app: AppInfo = {}): ReportContext {
  const context: ReportContext = {
    platform: 'react-native',
    osName: Platform.OS,
    osVersion: String(Platform.Version),
  };
  if (app.appVersion) context.appVersion = app.appVersion;
  if (app.build) context.build = app.build;
  return context;
}
