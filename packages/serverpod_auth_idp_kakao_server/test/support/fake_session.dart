import 'package:serverpod/serverpod.dart';

/// A [Session] that only records log messages.
///
/// Every other member throws, so a test that reaches the database or the
/// authenticated user fails loudly instead of silently depending on them. That
/// keeps these tests runnable without a database.
class FakeSession implements Session {
  /// Messages passed to [log], in order.
  final List<String> logs = [];

  @override
  void log(
    final String message, {
    final LogLevel? level,
    final dynamic exception,
    final StackTrace? stackTrace,
    final Map<String, Object?>? metadata,
  }) {
    logs.add(message);
  }

  @override
  dynamic noSuchMethod(final Invocation invocation) => throw UnimplementedError(
    'Session.${invocation.memberName} is not available in this test',
  );
}
