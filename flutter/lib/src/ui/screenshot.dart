import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Captures the [RepaintBoundary] with [boundaryKey] as PNG bytes.
///
/// Call it only when the person asks for a screenshot (the report sheet does
/// this when they tap "Add screenshot"). Returns null if the boundary is not
/// on screen.
///
/// ```dart
/// final appKey = GlobalKey();
/// RepaintBoundary(key: appKey, child: MyApp());
/// ```
Future<Uint8List?> captureRepaintBoundary(
  GlobalKey boundaryKey, {
  double? pixelRatio,
}) async {
  final context = boundaryKey.currentContext;
  final object = context?.findRenderObject();
  if (context == null || object is! RenderRepaintBoundary) return null;
  final ratio =
      pixelRatio ?? MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
  final image = await object.toImage(pixelRatio: ratio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
