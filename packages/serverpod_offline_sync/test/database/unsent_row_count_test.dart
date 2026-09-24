import 'dart:async';

import 'package:serverpod_offline_sync/src/database/unsent_row_count.dart';
import 'package:test/test.dart';

/// The pipeline behind `OfflineSyncDatabase.watchUnsentRowCount`
/// (unibook#14183). The stream over a real database is tested in
/// `test/offline_sync_watch_test_client/test/sync_status_test.dart`; a count
/// that fails without the watch failing cannot be made there.
void main() {
  /// Everything [countOnEachTrigger] emits for [triggerCount] triggers, errors
  /// as `'error'`.
  Future<List<Object>> emitted(
    int triggerCount,
    Future<int> Function() count,
  ) async {
    final triggers = StreamController<void>();
    final events = <Object>[];
    final done = Completer<void>();
    countOnEachTrigger(triggers.stream, count).listen(
      events.add,
      onError: (Object _) => events.add('error'),
      onDone: done.complete,
    );
    for (var i = 0; i < triggerCount; i++) {
      triggers.add(null);
    }
    await triggers.close();
    await done.future;
    return events;
  }

  group('Given countOnEachTrigger,', () {
    test(
      'when a count fails, then it emits the error and goes on with the next '
      'trigger.',
      () async {
        final results = <Object>[0, StateError('Database stopped.'), 1];
        var calls = 0;

        final events = await emitted(3, () async {
          final result = results[calls++];
          if (result is Error) throw result;
          return result as int;
        });

        expect(events, [0, 'error', 1]);
      },
    );

    test(
      'when a count equals the last one emitted, then it is not emitted, even '
      'across an error.',
      () async {
        final results = <Object>[0, 0, 1, StateError('busy'), 1, 0];
        var calls = 0;

        final events = await emitted(6, () async {
          final result = results[calls++];
          if (result is Error) throw result;
          return result as int;
        });

        expect(calls, 6);
        expect(events, [0, 1, 'error', 0]);
      },
    );

    test(
      'when triggers arrive while a count runs, then the counts run one at a '
      'time in trigger order.',
      () async {
        var calls = 0;
        var running = 0;
        var mostRunning = 0;

        final events = await emitted(3, () async {
          final call = calls++;
          running++;
          if (running > mostRunning) mostRunning = running;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          running--;
          return call;
        });

        expect(mostRunning, 1);
        expect(events, [0, 1, 2]);
      },
    );
  });
}
