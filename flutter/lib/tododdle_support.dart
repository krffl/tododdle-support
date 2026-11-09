/// One-way in-app issue reporting into a ToDoddle Support project.
///
/// Use [TododdleSupport] headless, or show the Material [ReportSheet] with
/// [showTododdleReportSheet].
library;

export 'src/client.dart' show QueueFlushResult, TododdleSupport;
export 'src/device_context.dart' show ContextProvider, collectDeviceContext;
export 'src/exception.dart' show TododdleErrorCodes, TododdleSupportException;
export 'src/models.dart';
export 'src/retry.dart' show DelayFunction, RetryPolicy;
export 'src/stores.dart';
export 'src/ui/report_sheet.dart'
    show ReportSheet, ReportSheetStrings, showTododdleReportSheet;
export 'src/ui/screenshot.dart' show captureRepaintBoundary;
export 'src/validation.dart' show ReportFieldKeys, validateReport;
export 'src/version.dart';
