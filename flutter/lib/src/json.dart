// Internal helpers; not exported.
// ignore_for_file: public_member_api_docs

import 'exception.dart';

/// Small helpers to read JSON from the server without trusting its shape.
///
/// Every failure is a [TododdleSupportException] with code
/// [TododdleErrorCodes.invalidResponse], so a malformed body never surfaces as
/// a raw `TypeError`.
typedef JsonMap = Map<String, Object?>;

JsonMap asMap(Object? value, String what) {
  if (value is Map) {
    return value.map((key, v) => MapEntry(key.toString(), v));
  }
  throw TododdleSupportException.invalidResponse('$what is not an object');
}

JsonMap? asMapOrNull(Object? value, String what) =>
    value == null ? null : asMap(value, what);

List<Object?> asList(Object? value, String what) {
  if (value is List) return value.cast<Object?>();
  throw TododdleSupportException.invalidResponse('$what is not a list');
}

String asString(Object? value, String what) {
  if (value is String) return value;
  throw TododdleSupportException.invalidResponse('$what is not a string');
}

String? asStringOrNull(Object? value, String what) =>
    value == null ? null : asString(value, what);

int asInt(Object? value, String what) {
  if (value is int) return value;
  if (value is double && value == value.roundToDouble()) return value.toInt();
  throw TododdleSupportException.invalidResponse('$what is not an integer');
}

int? asIntOrNull(Object? value, String what) =>
    value == null ? null : asInt(value, what);

bool asBool(Object? value, String what) {
  if (value is bool) return value;
  throw TododdleSupportException.invalidResponse('$what is not a boolean');
}

Map<String, String> asStringMap(Object? value, String what) {
  final map = asMap(value, what);
  return map.map((key, v) => MapEntry(key, asString(v, '$what.$key')));
}
