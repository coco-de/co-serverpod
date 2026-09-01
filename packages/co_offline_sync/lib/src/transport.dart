import 'dart:convert';

import 'protocol.dart';
import 'server.dart';

Map<String, Object?> _jsonRoundTrip(Map<String, Object?> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, Object?>;

/// 클라이언트가 서버와 통신하는 방법의 추상화.
///
/// 프로덕션 구현은 Serverpod 엔드포인트 호출(소비 측 앱에서 배선), 테스트는
/// [InProcessTransport].
abstract interface class SyncTransport {
  /// push 요청을 서버에 전달하고 응답을 돌려준다.
  Future<SyncPushResponse> push(SyncPushRequest request);

  /// pull 요청을 서버에 전달하고 응답을 돌려준다.
  Future<SyncPullResponse> pull(SyncPullRequest request);
}

/// 같은 프로세스 안의 [CoSyncServer] 로 직접 연결하는 전송 (테스트용).
///
/// JSON 왕복(직렬화 → 역직렬화)을 실제로 수행해 와이어 코덱까지 함께 검증한다.
class InProcessTransport implements SyncTransport {
  /// 대상 서버를 담아 생성한다.
  InProcessTransport(this._server);

  final CoSyncServer _server;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    final response = await _server.handlePush(
      SyncPushRequest.fromJson(_jsonRoundTrip(request.toJson())),
    );
    return SyncPushResponse.fromJson(_jsonRoundTrip(response.toJson()));
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async {
    final response = await _server.handlePull(
      SyncPullRequest.fromJson(_jsonRoundTrip(request.toJson())),
    );
    return SyncPullResponse.fromJson(_jsonRoundTrip(response.toJson()));
  }
}
