/// The last good config and its `ETag`.
class CachedConfig {
  /// Creates a cached config.
  const CachedConfig({required this.etag, required this.body});

  /// The `ETag` the server sent, or null if it sent none.
  final String? etag;

  /// The raw JSON body of the config.
  final String body;
}

/// Keeps the last good config between launches, so the report sheet still
/// opens offline. Implement it with `shared_preferences`, a file or any other
/// storage. The SDK always keeps a copy in memory too.
abstract interface class ConfigStore {
  /// Returns the stored config, or null.
  Future<CachedConfig?> read();

  /// Stores [config], replacing any earlier one.
  Future<void> write(CachedConfig config);
}

/// A [ConfigStore] that keeps the config in memory only.
class MemoryConfigStore implements ConfigStore {
  CachedConfig? _config;

  @override
  Future<CachedConfig?> read() async => _config;

  @override
  Future<void> write(CachedConfig config) async => _config = config;
}

/// Keeps reports that could not be sent, so they can be sent later with the
/// same idempotency key. Each entry is an opaque JSON string, including any
/// attachment bytes as base64.
///
/// Entries can hold what the person typed and their attachments. Store them
/// in app-private storage only.
abstract interface class ReportQueueStore {
  /// Returns the queued entries, oldest first.
  Future<List<String>> read();

  /// Replaces the queued entries.
  Future<void> write(List<String> entries);
}

/// A [ReportQueueStore] that keeps entries in memory only. Entries are lost
/// when the app stops.
class MemoryReportQueueStore implements ReportQueueStore {
  List<String> _entries = const [];

  @override
  Future<List<String>> read() async => List.of(_entries);

  @override
  Future<void> write(List<String> entries) async =>
      _entries = List.unmodifiable(entries);
}
