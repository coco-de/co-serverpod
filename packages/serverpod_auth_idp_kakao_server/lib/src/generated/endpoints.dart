/* AUTOMATICALLY GENERATED CODE DO NOT MODIFY */
/*   To generate run: "serverpod generate"    */

// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: public_member_api_docs
// ignore_for_file: type_literal_in_constant_pattern
// ignore_for_file: use_super_parameters
// ignore_for_file: invalid_use_of_internal_member

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:serverpod/serverpod.dart' as _i1;
import '../endpoints/kakao_idp_endpoint.dart' as _i2;
import 'package:serverpod_auth_idp_server/serverpod_auth_idp_server.dart'
    as _i3;
import 'package:serverpod_auth_core_server/serverpod_auth_core_server.dart'
    as _i4;

class Endpoints extends _i1.EndpointDispatch {
  @override
  void initializeEndpoints(_i1.Server server) {
    var endpoints = <String, _i1.Endpoint>{
      'kakaoIdp': _i2.KakaoIdpEndpoint()
        ..initialize(server, 'kakaoIdp', 'serverpod_auth_idp_kakao'),
    };
    connectors['kakaoIdp'] = _i1.EndpointConnector(
      name: 'kakaoIdp',
      endpoint: endpoints['kakaoIdp']!,
      methodConnectors: {
        'login': _i1.MethodConnector(
          name: 'login',
          params: {
            'code': _i1.ParameterDescription(
              name: 'code',
              type: _i1.getType<String>(),
              nullable: false,
            ),
            'codeVerifier': _i1.ParameterDescription(
              name: 'codeVerifier',
              type: _i1.getType<String>(),
              nullable: false,
            ),
            'redirectUri': _i1.ParameterDescription(
              name: 'redirectUri',
              type: _i1.getType<String>(),
              nullable: false,
            ),
          },
          call: (_i1.Session session, Map<String, dynamic> params) async =>
              (endpoints['kakaoIdp'] as _i2.KakaoIdpEndpoint).login(
                session,
                code: params['code'],
                codeVerifier: params['codeVerifier'],
                redirectUri: params['redirectUri'],
              ),
        ),
        'loginWithAccessToken': _i1.MethodConnector(
          name: 'loginWithAccessToken',
          params: {
            'accessToken': _i1.ParameterDescription(
              name: 'accessToken',
              type: _i1.getType<String>(),
              nullable: false,
            ),
          },
          call: (_i1.Session session, Map<String, dynamic> params) async =>
              (endpoints['kakaoIdp'] as _i2.KakaoIdpEndpoint)
                  .loginWithAccessToken(
                    session,
                    accessToken: params['accessToken'],
                  ),
        ),
        'hasAccount': _i1.MethodConnector(
          name: 'hasAccount',
          params: {},
          call: (_i1.Session session, Map<String, dynamic> params) async =>
              (endpoints['kakaoIdp'] as _i2.KakaoIdpEndpoint).hasAccount(
                session,
              ),
        ),
      },
    );
    modules['serverpod_auth_idp'] = _i3.Endpoints()
      ..initializeEndpoints(server);
    modules['serverpod_auth_core'] = _i4.Endpoints()
      ..initializeEndpoints(server);
  }
}
