import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// URL of Naver's user info API.
const naverUserInfoUrl = 'https://openapi.naver.com/v1/nid/me';

/// URL of Naver's OAuth token endpoint.
const naverTokenEndpointUrl = 'https://nid.naver.com/oauth2.0/token';

/// A JSON [http.Response] with [status].
http.Response jsonResponse(final Object body, [final int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// The body of a successful user info response for [id].
Map<String, Object?> naverProfile({
  required final String id,
  final String? email,
  final String? name,
}) => {
  'resultcode': '00',
  'message': 'success',
  'response': {
    'id': id,
    if (email != null) 'email': email,
    if (name != null) 'name': name,
  },
};

/// A Naver API stand-in that records every request it receives.
class FakeNaverApi {
  /// Creates a stand-in.
  ///
  /// [userInfo] is the body of the user info response. With [hang] no request
  /// is ever answered, which is what a stalled provider looks like to the
  /// caller.
  FakeNaverApi({final Object? userInfo, this.hang = false})
    : userInfo = userInfo ?? naverProfile(id: '32742776');

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
      naverUserInfoUrl => jsonResponse(userInfo),
      naverTokenEndpointUrl => jsonResponse({
        'access_token': 'exchanged-token',
        'token_type': 'bearer',
      }),
      _ => jsonResponse({'msg': 'not found'}, 404),
    };
  });
}
