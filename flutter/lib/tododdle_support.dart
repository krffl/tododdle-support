/// One-way in-app issue reporting into a ToDoddle Support project.
///
/// Use [TododdleSupport] to read the form config and send reports.
library;

export 'src/client.dart' show QueueFlushResult, TododdleSupport;
export 'src/device_context.dart' show ContextProvider, collectDeviceContext;
export 'src/exception.dart' show TododdleErrorCodes, TododdleSupportException;
export 'src/models.dart';
export 'src/retry.dart' show DelayFunction, RetryPolicy;
export 'src/stores.dart';
export 'src/validation.dart' show ReportFieldKeys, validateReport;
export 'src/version.dart';
