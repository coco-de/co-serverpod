/// A schema preflight result, without an application-maintained version number.
///
/// A hash identifies a schema, not its age. [mismatch] deliberately does not
/// claim that either peer needs upgrading. Schema history or a deployment
/// policy is needed to make that distinction.
enum OfflineSyncSchemaCompatibility {
  /// Both peers were generated from the same synchronized schema.
  compatible,

  /// The schemas differ. The current protocol cannot synchronize them.
  mismatch,

  /// The peer's hash is unavailable. The stream handshake still validates it.
  unknown,
}
