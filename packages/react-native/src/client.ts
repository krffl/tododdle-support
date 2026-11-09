import {
  createTododdleSupport as createCore,
  SDK_VERSION,
  type TododdleSupport,
  type TododdleSupportOptions,
} from '@krffl/tododdle-support';
import { platformContext, type AppInfo } from './context';

export type ReactNativeSupportOptions = Omit<TododdleSupportOptions, 'sdkName' | 'sdkVersion'> & AppInfo;

/**
 * Creates a client that sends `X-Tododdle-Sdk: react-native/<version>` and adds the OS name and
 * version, plus the app version and build you pass, to every report.
 */
export function createTododdleSupport(options: ReactNativeSupportOptions): TododdleSupport {
  const { appVersion, build, defaultContext, ...rest } = options;
  return createCore({
    ...rest,
    sdkName: 'react-native',
    sdkVersion: SDK_VERSION,
    defaultContext: {
      ...platformContext({ appVersion, build }),
      ...defaultContext,
    },
  });
}
