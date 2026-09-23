import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

/// [OfflineSyncStatus] is what the app renders and decides on. The count is
/// nullable on purpose: unknown must never read as "nothing unsent". The
/// tracker's behavior is tested against real replicas in
/// `test/offline_sync_watch_test_client/test/sync_status_test.dart`.
void main() {
  final at = DateTime.utc(2026, 9, 24);
  final transport = OfflineSyncFailure.from(
    const OfflineSyncStreamClosedException(phase: 'test'),
  );
  final refused = OfflineSyncFailure.from(
    OpenMethodStreamException(OpenMethodStreamResponseType.authenticationFailed),
  );

  group('Given isIdle,', () {
    test('when nothing is unsent, running or failed, then it is true.', () {
      expect(const OfflineSyncStatus(unsentRowCount: 0).isIdle, isTrue);
    });

    test('when the count is unknown, then it is false.', () {
      expect(const OfflineSyncStatus().isIdle, isFalse);
    });

    test('when rows are unsent, then it is false.', () {
      expect(const OfflineSyncStatus(unsentRowCount: 1).isIdle, isFalse);
    });

    test('when a round is running, then it is false.', () {
      expect(
        const OfflineSyncStatus(
          phase: OfflineSyncPhase.syncing,
          unsentRowCount: 0,
        ).isIdle,
        isFalse,
      );
    });

    test('when the last round failed, then it is false.', () {
      expect(
        OfflineSyncStatus(
          unsentRowCount: 0,
          lastFailure: transport,
          lastFailureAt: at,
        ).isIdle,
        isFalse,
      );
    });
  });

  group('Given needsAttention,', () {
    test('when the last failure is transient, then it is false.', () {
      expect(transport.isPermanent, isFalse);
      expect(
        OfflineSyncStatus(lastFailure: transport, lastFailureAt: at).needsAttention,
        isFalse,
      );
    });

    test('when the last failure is permanent, then it is true.', () {
      expect(refused.isPermanent, isTrue);
      expect(
        OfflineSyncStatus(lastFailure: refused, lastFailureAt: at).needsAttention,
        isTrue,
      );
    });

    test('when nothing failed, then it is false.', () {
      expect(const OfflineSyncStatus().needsAttention, isFalse);
    });
  });

  group('Given copyWith,', () {
    final failed = OfflineSyncStatus(
      unsentRowCount: 2,
      lastSuccessAt: at,
      lastFailure: transport,
      lastFailureAt: at,
    );

    test('when clearLastFailure is set, then the failure and its time clear.', () {
      final cleared = failed.copyWith(clearLastFailure: true);

      expect(cleared.lastFailure, isNull);
      expect(cleared.lastFailureAt, isNull);
      expect(cleared.lastSuccessAt, at);
      expect(cleared.unsentRowCount, 2);
    });

    test('when clearUnsentRowCount is set, then the count becomes unknown.', () {
      expect(failed.copyWith(clearUnsentRowCount: true).unsentRowCount, isNull);
    });

    test('when nothing is passed, then it equals the original.', () {
      expect(failed.copyWith(), failed);
      expect(failed.copyWith().hashCode, failed.hashCode);
    });
  });

  group('Given equality,', () {
    test('when every field matches, then the statuses are equal.', () {
      expect(
        OfflineSyncStatus(unsentRowCount: 1, lastSuccessAt: at),
        OfflineSyncStatus(unsentRowCount: 1, lastSuccessAt: at),
      );
    });

    for (final (name, other) in [
      ('phase', const OfflineSyncStatus(phase: OfflineSyncPhase.syncing)),
      ('count', const OfflineSyncStatus(unsentRowCount: 0)),
      ('success', OfflineSyncStatus(lastSuccessAt: at)),
      ('failure', OfflineSyncStatus(lastFailure: transport)),
      ('failure time', OfflineSyncStatus(lastFailureAt: at)),
    ]) {
      test('when the $name differs, then they differ.', () {
        expect(other, isNot(const OfflineSyncStatus()));
      });
    }
  });
}
