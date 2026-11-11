import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// URL of Kakao's access token information API.
const kakaoTokenInfoUrl = 'https://kapi.kakao.com/v1/user/access_token_info';

/// URL of Kakao's user info API.
const kakaoUserInfoUrl = 'https://kapi.kakao.com/v2/user/me';

/// URL of Kakao's OAuth token endpoint.
const kakaoTokenEndpointUrl = 'https://kauth.kakao.com/oauth/token';

/// A JSON [http.Response] with [status].
http.Response jsonResponse(final Object body, [final int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// A Kakao API stand-in that records every request it receives.
class FakeKakaoApi {
  /// Creates a stand-in.
  ///
  /// [tokenInfo] is the body of the access token information response (`null`
  /// answers 404), [userInfo] the body of the user info response. With [hang]
  /// no request is ever answered, which is what a stalled provider looks like
  /// to the caller.
  FakeKakaoApi({
    this.tokenInfo,
    this.userInfo = const {'id': 1234567890},
    this.hang = false,
  });

  /// Body of the access token information response; `null` answers 404.
  final Object? tokenInfo;

  /// Body of the user info response.
  final Object userInfo;

  /// Whether requests are left unanswered.
  final bool hang;

  /// Every request received, in order.
  final List<http.Request> requests = [];

  /// The URLs of [requests], in order.
  Iterable<String> get requestedUrls => requests.map((final r) => '${r.url}');

  /// The client to hand to the code under test.
  late final http.Client client = MockClient((final request) async {
    requests.add(request);
    if (hang) return Completer<http.Response>().future;
    return switch (request.url.toString()) {
      kakaoTokenInfoUrl when tokenInfo != null => jsonResponse(tokenInfo!),
      kakaoUserInfoUrl => jsonResponse(userInfo),
      kakaoTokenEndpointUrl => jsonResponse({
        'access_token': 'exchanged-token',
        'token_type': 'bearer',
      }),
      _ => jsonResponse({'msg': 'not found'}, 404),
    };
  });
}
