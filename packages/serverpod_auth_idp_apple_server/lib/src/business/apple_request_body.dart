import 'dart:convert';

import 'package:serverpod/serverpod.dart';

/// Reads [body] as text, giving up once it is larger than [maxBytes] bytes.
///
/// The text is decoded with [encoding], or with the charset the body declares
/// and UTF-8 otherwise, which is what `Request.readAsString` does.
///
/// Throws [MaxBodySizeExceeded] when the body is larger than [maxBytes]. A body
/// whose declared length is already over the limit is refused without being
/// read, and one of unknown length is cut off as soon as it grows past it.
Future<String> readBodyWithLimit(
  final Body body, {
  required final int maxBytes,
  final Encoding? encoding,
}) async {
  final decoder = encoding ?? body.bodyType?.encoding ?? utf8;
  return decoder.decodeStream(body.read(maxLength: maxBytes));
}
