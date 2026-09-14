import 'dart:async';
import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_sync/co_sync.dart';
import 'package:test/test.dart';

const _hlc = '0000000003e8-0001-server';
const _pushRequest = SyncPushRequest(
  nodeId: 'phone',
  schemaSignature: 'schema-signature',
  schemaVersion: 3,
  changes: [],
);
const _pullRequest = SyncPullRequest(
  nodeId: 'phone',
  schemaSignature: 'schema-signature',
  schemaVersion: 3,
  cursor: 'opaque/+==cursor',
  limit: 17,
);
const _pushResponse = <String, Object?>{'applied': 1, 'hlc': _hlc};
const _pullResponse = <String, Object?>{
  'changes': [],
  'cursor': 'opaque-next/+==',
  'more': false,
};
const _window = <String, Object?>{
  'currentVersion': 3,
  'minSupportedVersion': 1,
  'currentSignature': 'signature',
};

JsonSyncTransport _transport({
  required bool strings,
  required SyncMapCallback push,
  required SyncMapCallback pull,
}) => strings
    ? JsonSyncTransport(
        pushJson: (payload) async =>
            jsonEncode(await push(jsonDecode(payload) as Map<String, Object?>)),
        pullJson: (payload) async =>
            jsonEncode(await pull(jsonDecode(payload) as Map<String, Object?>)),
      )
    : JsonSyncTransport.map(pushMap: push, pullMap: pull);

JsonSchemaWindowProbe _probe({
  required bool strings,
  required Future<Map<String, Object?>> Function() fetch,
}) => strings
    ? JsonSchemaWindowProbe(fetchJson: () async => jsonEncode(await fetch()))
    : JsonSchemaWindowProbe.map(fetchMap: fetch);

void main() {
  for (final strings in [true, false]) {
    group(strings ? 'JSON strings' : 'JSON maps', () {
      test(
        'preserves push/pull wire keys, nested values, HLC and cursor',
        () async {
          final row = RowChange(
            table: 'note',
            state: RowState(
              rowId: 'note-1',
              fields: {
                'body': const FieldValue({
                  'lines': ['한글', null, true, 1.5],
                }, Hlc(1000, 1, 'phone')),
                kDeletedField: const FieldValue(true, Hlc(1000, 2, 'phone')),
              },
            ),
          );
          final wireRow = <String, Object?>{
            'tb': 'note',
            'st': {
              'id': 'note-1',
              'f': {
                'body': {
                  'v': {
                    'lines': ['한글', null, true, 1.5],
                  },
                  't': '0000000003e8-0001-phone',
                },
                r'$deleted': {'v': true, 't': '0000000003e8-0002-phone'},
              },
            },
          };
          final transport = _transport(
            strings: strings,
            push: (payload) async {
              expect(payload, {
                'node': 'phone',
                'schema': 'schema-signature',
                'sv': 3,
                'changes': [wireRow],
              });
              return {..._pushResponse, 'futureMetadata': true};
            },
            pull: (payload) async {
              expect(payload, {
                'node': 'phone',
                'schema': 'schema-signature',
                'sv': 3,
                'cursor': 'opaque/+==cursor',
                'limit': 17,
              });
              return {
                'changes': [wireRow],
                'cursor': 'next-page/+==',
                'more': true,
                'hlc': _hlc,
              };
            },
          );

          final pushed = await transport.push(
            SyncPushRequest(
              nodeId: 'phone',
              schemaSignature: 'schema-signature',
              schemaVersion: 3,
              changes: [row],
            ),
          );
          expect(pushed.appliedCount, 1);
          expect(pushed.serverHlcPacked, _hlc);
          final pulled = await transport.pull(_pullRequest);
          expect(pulled.changes.single.toJson(), wireRow);
          expect(pulled.nextCursor, 'next-page/+==');
          expect(pulled.hasMore, isTrue);
          expect(pulled.serverHlcPacked, _hlc);
        },
      );

      test('keeps legacy versionless requests and pull without HLC', () async {
        final requests = <Map<String, Object?>>[];
        final transport = _transport(
          strings: strings,
          push: (payload) async {
            requests.add(payload);
            return _pushResponse;
          },
          pull: (payload) async {
            requests.add(payload);
            return _pullResponse;
          },
        );
        await transport.push(
          const SyncPushRequest(
            nodeId: 'old',
            schemaSignature: 's',
            changes: [],
          ),
        );
        final response = await transport.pull(
          const SyncPullRequest(
            nodeId: 'old',
            schemaSignature: 's',
            cursor: null,
          ),
        );
        expect(requests.every((json) => !json.containsKey('sv')), isTrue);
        expect(requests.last['cursor'], isNull);
        expect(response.serverHlcPacked, isNull);
        expect(transport, isNot(isA<SchemaWindowProbe>()));
      });

      for (final synchronous in [true, false]) {
        test(
          'preserves callback error identity/stack (sync=$synchronous)',
          () async {
            final stack = StackTrace.fromString('application callback origin');
            for (final error in <Object>[
              const CoSyncRemoteException(
                code: 'schema_outdated',
                message: 'old',
              ),
              TimeoutException('offline'),
              const FormatException('SDK decoder failed'),
              TypeError(),
              const SyncProtocolException('application protocol error'),
            ]) {
              Future<Map<String, Object?>> callbackFailure() {
                if (synchronous) Error.throwWithStackTrace(error, stack);
                return Future.error(error, stack);
              }

              final transport = _transport(
                strings: strings,
                push: (_) => callbackFailure(),
                pull: (_) => callbackFailure(),
              );
              final probe = _probe(strings: strings, fetch: callbackFailure);
              for (final call in <Future<Object?> Function()>[
                () => transport.push(_pushRequest),
                () => transport.pull(_pullRequest),
                probe.fetchSchemaWindow,
              ]) {
                try {
                  await call();
                  fail('Expected the callback error');
                } catch (caught, caughtStack) {
                  expect(caught, same(error));
                  expect(caughtStack.toString(), stack.toString());
                }
              }
            }
          },
        );
      }

      test(
        'rejects malformed successful push responses as protocol errors',
        () async {
          for (final json in <Map<String, Object?>>[
            {},
            {'applied': null, 'hlc': _hlc},
            {'applied': '1', 'hlc': _hlc},
            {'applied': 1.5, 'hlc': _hlc},
            {'applied': -1, 'hlc': _hlc},
            {'applied': 1},
            {'applied': 1, 'hlc': 42},
            {'applied': 1, 'hlc': 'not-an-hlc'},
          ]) {
            final transport = _transport(
              strings: strings,
              push: (_) async => json,
              pull: (_) async => _pullResponse,
            );
            await expectLater(
              transport.push(_pushRequest),
              throwsA(isA<SyncProtocolException>()),
              reason: '$json',
            );
          }
        },
      );

      test(
        'rejects malformed successful pull responses before returning a page',
        () async {
          for (final json in <Map<String, Object?>>[
            {},
            {..._pullResponse, 'changes': null},
            {..._pullResponse, 'changes': {}},
            {
              ..._pullResponse,
              'changes': [null],
            },
            {
              ..._pullResponse,
              'changes': [
                {'tb': 'note', 'st': <String, Object?>{}},
              ],
            },
            {
              ..._pullResponse,
              'changes': [
                {
                  'tb': 'note',
                  'st': {
                    'id': 'r1',
                    'f': {
                      'body': {'v': 'v', 't': 'bad'},
                    },
                  },
                },
              ],
            },
            {..._pullResponse, 'cursor': null},
            {..._pullResponse, 'cursor': 12},
            {..._pullResponse, 'more': 'false'},
            {..._pullResponse, 'hlc': 'bad'},
          ]) {
            final transport = _transport(
              strings: strings,
              push: (_) async => _pushResponse,
              pull: (_) async => json,
            );
            await expectLater(
              transport.pull(_pullRequest),
              throwsA(isA<SyncProtocolException>()),
              reason: '$json',
            );
          }
        },
      );

      test(
        'schema window accepts version ranges and additive metadata',
        () async {
          final probe = _probe(
            strings: strings,
            fetch: () async => {..._window, 'futureMetadata': true},
          );
          expect(await probe.fetchSchemaWindow(), (
            currentVersion: 3,
            minSupportedVersion: 1,
            currentSignature: 'signature',
          ));
        },
      );

      test(
        'schema window rejects absent fields, invalid types and inverted ranges',
        () async {
          for (final json in <Map<String, Object?>>[
            {},
            {..._window}..remove('currentVersion'),
            {..._window}..remove('minSupportedVersion'),
            {..._window}..remove('currentSignature'),
            {..._window, 'currentVersion': '3'},
            {..._window, 'currentVersion': 3.5},
            {..._window, 'minSupportedVersion': 1.5},
            {..._window, 'minSupportedVersion': 0},
            {..._window, 'minSupportedVersion': -1},
            {..._window, 'minSupportedVersion': 4},
            {..._window, 'currentSignature': 123},
            {..._window, 'currentSignature': ''},
            {..._window, 'currentSignature': '   '},
          ]) {
            final probe = _probe(strings: strings, fetch: () async => json);
            await expectLater(
              probe.fetchSchemaWindow(),
              throwsA(isA<SyncProtocolException>()),
              reason: '$json',
            );
          }
        },
      );
    });
  }

  test(
    'decoded map payloads reject SDK objects and invalid JSON values',
    () async {
      final cycle = <Object?>[];
      cycle.add(cycle);
      for (final value in <Object?>[
        DateTime.utc(2026),
        Object(),
        double.nan,
        double.infinity,
        {1: 'non-string key'},
        {
          'nested': [Object()],
        },
        cycle,
      ]) {
        final transport = JsonSyncTransport.map(
          pushMap: (_) async => _pushResponse,
          pullMap: (_) async => {
            ..._pullResponse,
            'changes': [
              {
                'tb': 'note',
                'st': {
                  'id': 'r1',
                  'f': {
                    'body': {'v': value, 't': _hlc},
                  },
                },
              },
            ],
          },
        );
        await expectLater(
          transport.pull(_pullRequest),
          throwsA(isA<SyncProtocolException>()),
        );
      }
    },
  );

  test(
    'invalid JSON and non-object roots become protocol errors without body leaks',
    () async {
      for (final body in [
        '{private-secret',
        'null',
        '[]',
        '42',
        '"private-secret"',
      ]) {
        final transport = JsonSyncTransport(
          pushJson: (_) async => body,
          pullJson: (_) async => body,
        );
        final probe = JsonSchemaWindowProbe(fetchJson: () async => body);
        final error = throwsA(
          isA<SyncProtocolException>().having(
            (e) => e.toString(),
            'diagnostics',
            isNot(contains('private-secret')),
          ),
        );
        await expectLater(transport.push(_pushRequest), error);
        await expectLater(transport.pull(_pullRequest), error);
        await expectLater(probe.fetchSchemaWindow(), error);
      }
    },
  );
}
