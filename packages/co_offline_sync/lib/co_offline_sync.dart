/// Offline-first sync engine core for Cocode apps.
///
/// 구성 요소:
///
/// - [Hlc] / [HlcClock] — 하이브리드 논리 시계 (필드 버전 스탬프)
/// - [RowState] / [mergeRowStates] — 필드 단위 LWW 병합 + tombstone
/// - [RowChange] / 프로토콜 타입 — 커서 기반 델타 동기화 와이어 포맷
/// - [ClientSyncStore] / [ServerSyncStore] — 저장소 계약 (인메모리 참조 구현 포함)
/// - [CoSyncClient] / [CoSyncServer] / [SyncTransport] — 동기화 엔진
///
/// 설계 배경: coco-de/unibook#12634 (Project — Offline Sync 전면 전환) 의
/// S1 설계 문서 `docs/architecture-offline-sync-crdt-s1.md` §8 B안.
library;

export 'src/change.dart';
export 'src/client.dart';
export 'src/exceptions.dart';
export 'src/hlc.dart';
export 'src/memory_store.dart';
export 'src/merge.dart';
export 'src/protocol.dart';
export 'src/row_state.dart';
export 'src/schema_signature.dart';
export 'src/server.dart';
export 'src/store.dart';
export 'src/transport.dart';
