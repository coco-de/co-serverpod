import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_sync/co_sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'graphql_sync_transport.dart';
import 'openapi_sync_transport.dart';

const _schema = {
  'note': ['body'],
};
const _serverHlc = '0000000003e8-0001-server';

CoSyncRuntime _device(SyncTransport transport, {SchemaWindowProbe? probe}) =>
    CoSyncRuntime(
      database: CoSyncDatabase(NativeDatabase.memory()),
      transport: transport,
      schemaProbe: probe,
      syncSchema: _schema,
      schemaVersion: 1,
      maxFieldValueChars: 64 * 1024,
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  for (final graphql in [false, true]) {
    test(
      '${graphql ? 'GraphQL' : 'OpenAPI'} connects two devices through the core server',
      () async {
        final server = CoSyncServer(
          store: InMemoryServerSyncStore(),
          clock: HlcClock(nodeId: 'server'),
          syncSchema: _schema,
        );
        Future<Map<String, Object?>> push(Map<String, Object?> payload) async =>
            (await server.handlePush(
              SyncPushRequest.fromJson(payload),
            )).toJson();
        Future<Map<String, Object?>> pull(Map<String, Object?> payload) async =>
            (await server.handlePull(
              SyncPullRequest.fromJson(payload),
            )).toJson();
        final transport = graphql
            ? graphqlSyncTransport(
                execute: (document, variables) async {
                  expect(document, contains(r'$payload: JSON!'));
                  final payload = variables['payload']! as Map<String, Object?>;
                  final isPush = document.startsWith('mutation');
                  return {
                    'data': {
                      if (isPush)
                        'syncPush': await push(payload)
                      else
                        'syncPull': await pull(payload),
                    },
                  };
                },
              )
            : openApiSyncTransport(push: push, pull: pull);
        final phone = _device(transport);
        final tablet = _device(transport);
        addTearDown(phone.dispose);
        addTearDown(tablet.dispose);
        await phone.upsert('note', 'r1', {'body': 'offline edit'});
        expect(await phone.store.pendingRows(), hasLength(1));
        expect(await phone.syncNow(), isNotNull);
        expect(await phone.store.pendingRows(), isEmpty);
        expect(await tablet.syncNow(), isNotNull);
        expect(
          (await tablet.read('note', 'r1'))!.values['body'],
          'offline edit',
        );
        expect(await tablet.store.loadCursor(), isNotNull);

        await phone.delete('note', 'r1');
        expect(await phone.syncNow(), isNotNull);
        expect(await tablet.syncNow(), isNotNull);
        expect((await tablet.read('note', 'r1'))!.isDeleted, isTrue);
        await phone.restore('note', 'r1');
        expect(await phone.syncNow(), isNotNull);
        expect(await tablet.syncNow(), isNotNull);
        expect((await tablet.read('note', 'r1'))!.isDeleted, isFalse);
      },
    );
  }

  test(
    'GraphQL partial push errors preserve pending/cursor and can retry',
    () async {
      var failPush = true;
      var pullCalls = 0;
      final transport = graphqlSyncTransport(
        execute: (document, variables) async {
          if (document.startsWith('mutation')) {
            return {
              'data': {
                'syncPush': {'applied': 1, 'hlc': _serverHlc},
              },
              if (failPush)
                'errors': [
                  {'message': 'partial failure'},
                ],
            };
          }
          pullCalls++;
          return {
            'data': {
              'syncPull': {
                'changes': <Object?>[],
                'cursor': 'next',
                'more': false,
              },
            },
          };
        },
      );
      final runtime = _device(transport);
      addTearDown(runtime.dispose);
      await runtime.store.saveCursor('before');
      await runtime.upsert('note', 'r1', {'body': 'keep pending'});

      expect(await runtime.syncNow(), isNull);
      expect(runtime.lastError, isA<GraphqlSyncException>());
      expect(await runtime.store.pendingRows(), hasLength(1));
      expect(await runtime.store.loadCursor(), 'before');
      expect(pullCalls, 0);
      expect(
        (await runtime.read('note', 'r1'))!.values['body'],
        'keep pending',
      );

      failPush = false;
      expect(await runtime.syncNow(), isNotNull);
      expect(await runtime.store.pendingRows(), isEmpty);
      expect(await runtime.store.loadCursor(), 'next');
      expect(runtime.lastError, isNull);
    },
  );

  test(
    'GraphQL partial pull errors neither apply rows nor advance the cursor',
    () async {
      var partialErrors = true;
      final requestedCursors = <Object?>[];
      final remote = RowChange(
        table: 'note',
        state: RowState(
          rowId: 'remote',
          fields: {
            'body': const FieldValue('remote value', Hlc(1000, 1, 'server')),
          },
        ),
      );
      final transport = graphqlSyncTransport(
        execute: (document, variables) async {
          expect(document, startsWith('query'));
          requestedCursors.add(
            (variables['payload']! as Map<String, Object?>)['cursor'],
          );
          return {
            'data': {
              'syncPull': {
                'changes': [remote.toJson()],
                'cursor': 'next',
                'more': false,
                'hlc': _serverHlc,
              },
            },
            if (partialErrors)
              'errors': [
                {'message': 'partial failure'},
              ],
          };
        },
      );
      final runtime = _device(transport);
      addTearDown(runtime.dispose);
      await runtime.store.saveCursor('before');
      expect(await runtime.syncNow(), isNull);
      expect(runtime.lastError, isA<GraphqlSyncException>());
      expect(await runtime.store.loadCursor(), 'before');
      expect(await runtime.read('note', 'remote'), isNull);

      partialErrors = false;
      expect(await runtime.syncNow(), isNotNull);
      expect(requestedCursors, ['before', 'before']);
      expect(await runtime.store.loadCursor(), 'next');
      expect(
        (await runtime.read('note', 'remote'))!.values['body'],
        'remote value',
      );
    },
  );

  test(
    'GraphQL rejects absent/malformed data or errors, even with HTTP-success-shaped data',
    () async {
      for (final envelope in <Map<String, Object?>>[
        {},
        {'data': null},
        {
          'data': {'syncPull': null},
        },
        {
          'data': {'syncPull': 'not an object'},
        },
        {
          'data': {'syncPull': <String, Object?>{}},
          'errors': null,
        },
        {
          'data': {'syncPull': <String, Object?>{}},
          'errors': 'bad',
        },
      ]) {
        final transport = graphqlSyncTransport(
          execute: (_, _) async => envelope,
        );
        await expectLater(
          transport.pull(
            const SyncPullRequest(
              nodeId: 'n',
              schemaSignature: 's',
              cursor: null,
            ),
          ),
          throwsA(isA<SyncProtocolException>()),
        );
      }
    },
  );

  test(
    'optional JSON probe works alongside an existing custom transport',
    () async {
      final server = CoSyncServer(
        store: InMemoryServerSyncStore(),
        clock: HlcClock(nodeId: 'server'),
        syncSchema: _schema,
      );
      final transport = InProcessTransport(server);
      var malformedWindow = false;
      final probe = JsonSchemaWindowProbe.map(
        fetchMap: () async => {
          'currentVersion': 1,
          'minSupportedVersion': malformedWindow ? 2 : 1,
          'currentSignature': computeSchemaSignature(_schema),
        },
      );
      final runtime = _device(transport, probe: probe);
      addTearDown(runtime.dispose);
      expect(await runtime.verifySchemaWindow(), CoSyncSchemaStatus.compatible);
      await runtime.upsert('note', 'r1', {'body': 'custom transport'});
      expect(await runtime.syncNow(), isNotNull);
      malformedWindow = true;
      expect(await runtime.verifySchemaWindow(), CoSyncSchemaStatus.unknown);
    },
  );
}
