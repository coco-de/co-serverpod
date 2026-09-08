// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'co_sync_database.dart';

// ignore_for_file: type=lint
class $CoSyncRowsTable extends CoSyncRows
    with TableInfo<$CoSyncRowsTable, CoSyncRowData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CoSyncRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _logicalTableMeta = const VerificationMeta(
    'logicalTable',
  );
  @override
  late final GeneratedColumn<String> logicalTable = GeneratedColumn<String>(
    'logical_table',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rowIdMeta = const VerificationMeta('rowId');
  @override
  late final GeneratedColumn<String> rowId = GeneratedColumn<String>(
    'row_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateJsonMeta = const VerificationMeta(
    'stateJson',
  );
  @override
  late final GeneratedColumn<String> stateJson = GeneratedColumn<String>(
    'state_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _maxHlcMeta = const VerificationMeta('maxHlc');
  @override
  late final GeneratedColumn<String> maxHlc = GeneratedColumn<String>(
    'max_hlc',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pendingMeta = const VerificationMeta(
    'pending',
  );
  @override
  late final GeneratedColumn<bool> pending = GeneratedColumn<bool>(
    'pending',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pending" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _pendingSnapshotHlcMeta =
      const VerificationMeta('pendingSnapshotHlc');
  @override
  late final GeneratedColumn<String> pendingSnapshotHlc =
      GeneratedColumn<String>(
        'pending_snapshot_hlc',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    logicalTable,
    rowId,
    stateJson,
    maxHlc,
    pending,
    pendingSnapshotHlc,
    deleted,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'co_sync_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<CoSyncRowData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('logical_table')) {
      context.handle(
        _logicalTableMeta,
        logicalTable.isAcceptableOrUnknown(
          data['logical_table']!,
          _logicalTableMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_logicalTableMeta);
    }
    if (data.containsKey('row_id')) {
      context.handle(
        _rowIdMeta,
        rowId.isAcceptableOrUnknown(data['row_id']!, _rowIdMeta),
      );
    } else if (isInserting) {
      context.missing(_rowIdMeta);
    }
    if (data.containsKey('state_json')) {
      context.handle(
        _stateJsonMeta,
        stateJson.isAcceptableOrUnknown(data['state_json']!, _stateJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_stateJsonMeta);
    }
    if (data.containsKey('max_hlc')) {
      context.handle(
        _maxHlcMeta,
        maxHlc.isAcceptableOrUnknown(data['max_hlc']!, _maxHlcMeta),
      );
    } else if (isInserting) {
      context.missing(_maxHlcMeta);
    }
    if (data.containsKey('pending')) {
      context.handle(
        _pendingMeta,
        pending.isAcceptableOrUnknown(data['pending']!, _pendingMeta),
      );
    }
    if (data.containsKey('pending_snapshot_hlc')) {
      context.handle(
        _pendingSnapshotHlcMeta,
        pendingSnapshotHlc.isAcceptableOrUnknown(
          data['pending_snapshot_hlc']!,
          _pendingSnapshotHlcMeta,
        ),
      );
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {logicalTable, rowId};
  @override
  CoSyncRowData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CoSyncRowData(
      logicalTable: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}logical_table'],
      )!,
      rowId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}row_id'],
      )!,
      stateJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state_json'],
      )!,
      maxHlc: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}max_hlc'],
      )!,
      pending: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pending'],
      )!,
      pendingSnapshotHlc: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pending_snapshot_hlc'],
      ),
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
    );
  }

  @override
  $CoSyncRowsTable createAlias(String alias) {
    return $CoSyncRowsTable(attachedDatabase, alias);
  }
}

class CoSyncRowData extends DataClass implements Insertable<CoSyncRowData> {
  /// 논리 테이블 이름 (drift `Table.tableName` 과의 충돌을 피해 개명).
  final String logicalTable;

  /// 행 id (전역 고유 문자열).
  final String rowId;

  /// 코어 `RowState.toJson()` 직렬화.
  final String stateJson;

  /// 행의 최대 HLC (packed) — pending 가드의 SQL 비교 대상.
  final String maxHlc;

  /// push 대기 여부.
  final bool pending;

  /// pending 스냅샷 시점의 maxHlc (packed) — ack 해제 가드.
  final String? pendingSnapshotHlc;

  /// tombstone 물질화 (S7-2, #12753 — v3).
  ///
  /// 코어의 삭제는 `stateJson` 안의 `$deleted` LWW 필드라 SQL 로 걸러지지
  /// 않는다 — 논리 테이블 단위 **watch/COUNT** 가 행마다 JSON 디코드를
  /// 요구하게 되어 성립하지 않았다. `putRow` 가 저장 시점에
  /// `RowState.isDeleted(tombstonePolicy)` 판정을 이 컬럼으로 동기한다.
  ///
  /// ⚠️ 이 값은 **스토어에 배선된 `TombstonePolicy` 기준의 파생값**이다 —
  /// 정책을 바꾸면 기존 행과 어긋나므로, 정책 변경은 재마이그레이션
  /// (전행 재판정)을 동반해야 한다. 판정의 정본은 여전히 `stateJson` 이다.
  final bool deleted;
  const CoSyncRowData({
    required this.logicalTable,
    required this.rowId,
    required this.stateJson,
    required this.maxHlc,
    required this.pending,
    this.pendingSnapshotHlc,
    required this.deleted,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['logical_table'] = Variable<String>(logicalTable);
    map['row_id'] = Variable<String>(rowId);
    map['state_json'] = Variable<String>(stateJson);
    map['max_hlc'] = Variable<String>(maxHlc);
    map['pending'] = Variable<bool>(pending);
    if (!nullToAbsent || pendingSnapshotHlc != null) {
      map['pending_snapshot_hlc'] = Variable<String>(pendingSnapshotHlc);
    }
    map['deleted'] = Variable<bool>(deleted);
    return map;
  }

  CoSyncRowsCompanion toCompanion(bool nullToAbsent) {
    return CoSyncRowsCompanion(
      logicalTable: Value(logicalTable),
      rowId: Value(rowId),
      stateJson: Value(stateJson),
      maxHlc: Value(maxHlc),
      pending: Value(pending),
      pendingSnapshotHlc: pendingSnapshotHlc == null && nullToAbsent
          ? const Value.absent()
          : Value(pendingSnapshotHlc),
      deleted: Value(deleted),
    );
  }

  factory CoSyncRowData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CoSyncRowData(
      logicalTable: serializer.fromJson<String>(json['logicalTable']),
      rowId: serializer.fromJson<String>(json['rowId']),
      stateJson: serializer.fromJson<String>(json['stateJson']),
      maxHlc: serializer.fromJson<String>(json['maxHlc']),
      pending: serializer.fromJson<bool>(json['pending']),
      pendingSnapshotHlc: serializer.fromJson<String?>(
        json['pendingSnapshotHlc'],
      ),
      deleted: serializer.fromJson<bool>(json['deleted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'logicalTable': serializer.toJson<String>(logicalTable),
      'rowId': serializer.toJson<String>(rowId),
      'stateJson': serializer.toJson<String>(stateJson),
      'maxHlc': serializer.toJson<String>(maxHlc),
      'pending': serializer.toJson<bool>(pending),
      'pendingSnapshotHlc': serializer.toJson<String?>(pendingSnapshotHlc),
      'deleted': serializer.toJson<bool>(deleted),
    };
  }

  CoSyncRowData copyWith({
    String? logicalTable,
    String? rowId,
    String? stateJson,
    String? maxHlc,
    bool? pending,
    Value<String?> pendingSnapshotHlc = const Value.absent(),
    bool? deleted,
  }) => CoSyncRowData(
    logicalTable: logicalTable ?? this.logicalTable,
    rowId: rowId ?? this.rowId,
    stateJson: stateJson ?? this.stateJson,
    maxHlc: maxHlc ?? this.maxHlc,
    pending: pending ?? this.pending,
    pendingSnapshotHlc: pendingSnapshotHlc.present
        ? pendingSnapshotHlc.value
        : this.pendingSnapshotHlc,
    deleted: deleted ?? this.deleted,
  );
  CoSyncRowData copyWithCompanion(CoSyncRowsCompanion data) {
    return CoSyncRowData(
      logicalTable: data.logicalTable.present
          ? data.logicalTable.value
          : this.logicalTable,
      rowId: data.rowId.present ? data.rowId.value : this.rowId,
      stateJson: data.stateJson.present ? data.stateJson.value : this.stateJson,
      maxHlc: data.maxHlc.present ? data.maxHlc.value : this.maxHlc,
      pending: data.pending.present ? data.pending.value : this.pending,
      pendingSnapshotHlc: data.pendingSnapshotHlc.present
          ? data.pendingSnapshotHlc.value
          : this.pendingSnapshotHlc,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CoSyncRowData(')
          ..write('logicalTable: $logicalTable, ')
          ..write('rowId: $rowId, ')
          ..write('stateJson: $stateJson, ')
          ..write('maxHlc: $maxHlc, ')
          ..write('pending: $pending, ')
          ..write('pendingSnapshotHlc: $pendingSnapshotHlc, ')
          ..write('deleted: $deleted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    logicalTable,
    rowId,
    stateJson,
    maxHlc,
    pending,
    pendingSnapshotHlc,
    deleted,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CoSyncRowData &&
          other.logicalTable == this.logicalTable &&
          other.rowId == this.rowId &&
          other.stateJson == this.stateJson &&
          other.maxHlc == this.maxHlc &&
          other.pending == this.pending &&
          other.pendingSnapshotHlc == this.pendingSnapshotHlc &&
          other.deleted == this.deleted);
}

class CoSyncRowsCompanion extends UpdateCompanion<CoSyncRowData> {
  final Value<String> logicalTable;
  final Value<String> rowId;
  final Value<String> stateJson;
  final Value<String> maxHlc;
  final Value<bool> pending;
  final Value<String?> pendingSnapshotHlc;
  final Value<bool> deleted;
  final Value<int> rowid;
  const CoSyncRowsCompanion({
    this.logicalTable = const Value.absent(),
    this.rowId = const Value.absent(),
    this.stateJson = const Value.absent(),
    this.maxHlc = const Value.absent(),
    this.pending = const Value.absent(),
    this.pendingSnapshotHlc = const Value.absent(),
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CoSyncRowsCompanion.insert({
    required String logicalTable,
    required String rowId,
    required String stateJson,
    required String maxHlc,
    this.pending = const Value.absent(),
    this.pendingSnapshotHlc = const Value.absent(),
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : logicalTable = Value(logicalTable),
       rowId = Value(rowId),
       stateJson = Value(stateJson),
       maxHlc = Value(maxHlc);
  static Insertable<CoSyncRowData> custom({
    Expression<String>? logicalTable,
    Expression<String>? rowId,
    Expression<String>? stateJson,
    Expression<String>? maxHlc,
    Expression<bool>? pending,
    Expression<String>? pendingSnapshotHlc,
    Expression<bool>? deleted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (logicalTable != null) 'logical_table': logicalTable,
      if (rowId != null) 'row_id': rowId,
      if (stateJson != null) 'state_json': stateJson,
      if (maxHlc != null) 'max_hlc': maxHlc,
      if (pending != null) 'pending': pending,
      if (pendingSnapshotHlc != null)
        'pending_snapshot_hlc': pendingSnapshotHlc,
      if (deleted != null) 'deleted': deleted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CoSyncRowsCompanion copyWith({
    Value<String>? logicalTable,
    Value<String>? rowId,
    Value<String>? stateJson,
    Value<String>? maxHlc,
    Value<bool>? pending,
    Value<String?>? pendingSnapshotHlc,
    Value<bool>? deleted,
    Value<int>? rowid,
  }) {
    return CoSyncRowsCompanion(
      logicalTable: logicalTable ?? this.logicalTable,
      rowId: rowId ?? this.rowId,
      stateJson: stateJson ?? this.stateJson,
      maxHlc: maxHlc ?? this.maxHlc,
      pending: pending ?? this.pending,
      pendingSnapshotHlc: pendingSnapshotHlc ?? this.pendingSnapshotHlc,
      deleted: deleted ?? this.deleted,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (logicalTable.present) {
      map['logical_table'] = Variable<String>(logicalTable.value);
    }
    if (rowId.present) {
      map['row_id'] = Variable<String>(rowId.value);
    }
    if (stateJson.present) {
      map['state_json'] = Variable<String>(stateJson.value);
    }
    if (maxHlc.present) {
      map['max_hlc'] = Variable<String>(maxHlc.value);
    }
    if (pending.present) {
      map['pending'] = Variable<bool>(pending.value);
    }
    if (pendingSnapshotHlc.present) {
      map['pending_snapshot_hlc'] = Variable<String>(pendingSnapshotHlc.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CoSyncRowsCompanion(')
          ..write('logicalTable: $logicalTable, ')
          ..write('rowId: $rowId, ')
          ..write('stateJson: $stateJson, ')
          ..write('maxHlc: $maxHlc, ')
          ..write('pending: $pending, ')
          ..write('pendingSnapshotHlc: $pendingSnapshotHlc, ')
          ..write('deleted: $deleted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CoSyncMetaTable extends CoSyncMeta
    with TableInfo<$CoSyncMetaTable, CoSyncMetaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CoSyncMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _metaKeyMeta = const VerificationMeta(
    'metaKey',
  );
  @override
  late final GeneratedColumn<String> metaKey = GeneratedColumn<String>(
    'meta_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _metaValueMeta = const VerificationMeta(
    'metaValue',
  );
  @override
  late final GeneratedColumn<String> metaValue = GeneratedColumn<String>(
    'meta_value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [metaKey, metaValue];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'co_sync_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<CoSyncMetaData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('meta_key')) {
      context.handle(
        _metaKeyMeta,
        metaKey.isAcceptableOrUnknown(data['meta_key']!, _metaKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_metaKeyMeta);
    }
    if (data.containsKey('meta_value')) {
      context.handle(
        _metaValueMeta,
        metaValue.isAcceptableOrUnknown(data['meta_value']!, _metaValueMeta),
      );
    } else if (isInserting) {
      context.missing(_metaValueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {metaKey};
  @override
  CoSyncMetaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CoSyncMetaData(
      metaKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}meta_key'],
      )!,
      metaValue: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}meta_value'],
      )!,
    );
  }

  @override
  $CoSyncMetaTable createAlias(String alias) {
    return $CoSyncMetaTable(attachedDatabase, alias);
  }
}

class CoSyncMetaData extends DataClass implements Insertable<CoSyncMetaData> {
  /// 메타 키.
  final String metaKey;

  /// 메타 값.
  final String metaValue;
  const CoSyncMetaData({required this.metaKey, required this.metaValue});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['meta_key'] = Variable<String>(metaKey);
    map['meta_value'] = Variable<String>(metaValue);
    return map;
  }

  CoSyncMetaCompanion toCompanion(bool nullToAbsent) {
    return CoSyncMetaCompanion(
      metaKey: Value(metaKey),
      metaValue: Value(metaValue),
    );
  }

  factory CoSyncMetaData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CoSyncMetaData(
      metaKey: serializer.fromJson<String>(json['metaKey']),
      metaValue: serializer.fromJson<String>(json['metaValue']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'metaKey': serializer.toJson<String>(metaKey),
      'metaValue': serializer.toJson<String>(metaValue),
    };
  }

  CoSyncMetaData copyWith({String? metaKey, String? metaValue}) =>
      CoSyncMetaData(
        metaKey: metaKey ?? this.metaKey,
        metaValue: metaValue ?? this.metaValue,
      );
  CoSyncMetaData copyWithCompanion(CoSyncMetaCompanion data) {
    return CoSyncMetaData(
      metaKey: data.metaKey.present ? data.metaKey.value : this.metaKey,
      metaValue: data.metaValue.present ? data.metaValue.value : this.metaValue,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CoSyncMetaData(')
          ..write('metaKey: $metaKey, ')
          ..write('metaValue: $metaValue')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(metaKey, metaValue);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CoSyncMetaData &&
          other.metaKey == this.metaKey &&
          other.metaValue == this.metaValue);
}

class CoSyncMetaCompanion extends UpdateCompanion<CoSyncMetaData> {
  final Value<String> metaKey;
  final Value<String> metaValue;
  final Value<int> rowid;
  const CoSyncMetaCompanion({
    this.metaKey = const Value.absent(),
    this.metaValue = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CoSyncMetaCompanion.insert({
    required String metaKey,
    required String metaValue,
    this.rowid = const Value.absent(),
  }) : metaKey = Value(metaKey),
       metaValue = Value(metaValue);
  static Insertable<CoSyncMetaData> custom({
    Expression<String>? metaKey,
    Expression<String>? metaValue,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (metaKey != null) 'meta_key': metaKey,
      if (metaValue != null) 'meta_value': metaValue,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CoSyncMetaCompanion copyWith({
    Value<String>? metaKey,
    Value<String>? metaValue,
    Value<int>? rowid,
  }) {
    return CoSyncMetaCompanion(
      metaKey: metaKey ?? this.metaKey,
      metaValue: metaValue ?? this.metaValue,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (metaKey.present) {
      map['meta_key'] = Variable<String>(metaKey.value);
    }
    if (metaValue.present) {
      map['meta_value'] = Variable<String>(metaValue.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CoSyncMetaCompanion(')
          ..write('metaKey: $metaKey, ')
          ..write('metaValue: $metaValue, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CoReplicaRowsTable extends CoReplicaRows
    with TableInfo<$CoReplicaRowsTable, CoReplicaRowData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CoReplicaRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _domainMeta = const VerificationMeta('domain');
  @override
  late final GeneratedColumn<String> domain = GeneratedColumn<String>(
    'domain',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rowIdMeta = const VerificationMeta('rowId');
  @override
  late final GeneratedColumn<String> rowId = GeneratedColumn<String>(
    'row_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataJsonMeta = const VerificationMeta(
    'dataJson',
  );
  @override
  late final GeneratedColumn<String> dataJson = GeneratedColumn<String>(
    'data_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverUpdatedAtMillisMeta =
      const VerificationMeta('serverUpdatedAtMillis');
  @override
  late final GeneratedColumn<int> serverUpdatedAtMillis = GeneratedColumn<int>(
    'server_updated_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    domain,
    rowId,
    dataJson,
    serverUpdatedAtMillis,
    deleted,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'co_replica_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<CoReplicaRowData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('domain')) {
      context.handle(
        _domainMeta,
        domain.isAcceptableOrUnknown(data['domain']!, _domainMeta),
      );
    } else if (isInserting) {
      context.missing(_domainMeta);
    }
    if (data.containsKey('row_id')) {
      context.handle(
        _rowIdMeta,
        rowId.isAcceptableOrUnknown(data['row_id']!, _rowIdMeta),
      );
    } else if (isInserting) {
      context.missing(_rowIdMeta);
    }
    if (data.containsKey('data_json')) {
      context.handle(
        _dataJsonMeta,
        dataJson.isAcceptableOrUnknown(data['data_json']!, _dataJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_dataJsonMeta);
    }
    if (data.containsKey('server_updated_at_millis')) {
      context.handle(
        _serverUpdatedAtMillisMeta,
        serverUpdatedAtMillis.isAcceptableOrUnknown(
          data['server_updated_at_millis']!,
          _serverUpdatedAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverUpdatedAtMillisMeta);
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {domain, rowId};
  @override
  CoReplicaRowData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CoReplicaRowData(
      domain: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}domain'],
      )!,
      rowId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}row_id'],
      )!,
      dataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data_json'],
      )!,
      serverUpdatedAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}server_updated_at_millis'],
      )!,
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
    );
  }

  @override
  $CoReplicaRowsTable createAlias(String alias) {
    return $CoReplicaRowsTable(attachedDatabase, alias);
  }
}

class CoReplicaRowData extends DataClass
    implements Insertable<CoReplicaRowData> {
  /// replica 도메인 (예: `book_order_summary`, `book_meta`).
  final String domain;

  /// 행 id (도메인 내 고유 — 서버 PK 의 문자열 표현).
  final String rowId;

  /// 서버 상태의 JSON 직렬화 (thin projection — S6-2 계약).
  final String dataJson;

  /// 서버 `updatedAt` (epoch millis, UTC) — 진단·정렬용.
  ///
  /// ⚠️ 증분 판정은 이 값이 아니라 **서버가 발급한 opaque 커서**
  /// (`CoReplicaCursors`)로 한다 — 동률·시계 후퇴 처리는 서버 소관.
  final int serverUpdatedAtMillis;

  /// 서버측 삭제 여부 (soft-delete 전파).
  final bool deleted;
  const CoReplicaRowData({
    required this.domain,
    required this.rowId,
    required this.dataJson,
    required this.serverUpdatedAtMillis,
    required this.deleted,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['domain'] = Variable<String>(domain);
    map['row_id'] = Variable<String>(rowId);
    map['data_json'] = Variable<String>(dataJson);
    map['server_updated_at_millis'] = Variable<int>(serverUpdatedAtMillis);
    map['deleted'] = Variable<bool>(deleted);
    return map;
  }

  CoReplicaRowsCompanion toCompanion(bool nullToAbsent) {
    return CoReplicaRowsCompanion(
      domain: Value(domain),
      rowId: Value(rowId),
      dataJson: Value(dataJson),
      serverUpdatedAtMillis: Value(serverUpdatedAtMillis),
      deleted: Value(deleted),
    );
  }

  factory CoReplicaRowData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CoReplicaRowData(
      domain: serializer.fromJson<String>(json['domain']),
      rowId: serializer.fromJson<String>(json['rowId']),
      dataJson: serializer.fromJson<String>(json['dataJson']),
      serverUpdatedAtMillis: serializer.fromJson<int>(
        json['serverUpdatedAtMillis'],
      ),
      deleted: serializer.fromJson<bool>(json['deleted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'domain': serializer.toJson<String>(domain),
      'rowId': serializer.toJson<String>(rowId),
      'dataJson': serializer.toJson<String>(dataJson),
      'serverUpdatedAtMillis': serializer.toJson<int>(serverUpdatedAtMillis),
      'deleted': serializer.toJson<bool>(deleted),
    };
  }

  CoReplicaRowData copyWith({
    String? domain,
    String? rowId,
    String? dataJson,
    int? serverUpdatedAtMillis,
    bool? deleted,
  }) => CoReplicaRowData(
    domain: domain ?? this.domain,
    rowId: rowId ?? this.rowId,
    dataJson: dataJson ?? this.dataJson,
    serverUpdatedAtMillis: serverUpdatedAtMillis ?? this.serverUpdatedAtMillis,
    deleted: deleted ?? this.deleted,
  );
  CoReplicaRowData copyWithCompanion(CoReplicaRowsCompanion data) {
    return CoReplicaRowData(
      domain: data.domain.present ? data.domain.value : this.domain,
      rowId: data.rowId.present ? data.rowId.value : this.rowId,
      dataJson: data.dataJson.present ? data.dataJson.value : this.dataJson,
      serverUpdatedAtMillis: data.serverUpdatedAtMillis.present
          ? data.serverUpdatedAtMillis.value
          : this.serverUpdatedAtMillis,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CoReplicaRowData(')
          ..write('domain: $domain, ')
          ..write('rowId: $rowId, ')
          ..write('dataJson: $dataJson, ')
          ..write('serverUpdatedAtMillis: $serverUpdatedAtMillis, ')
          ..write('deleted: $deleted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(domain, rowId, dataJson, serverUpdatedAtMillis, deleted);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CoReplicaRowData &&
          other.domain == this.domain &&
          other.rowId == this.rowId &&
          other.dataJson == this.dataJson &&
          other.serverUpdatedAtMillis == this.serverUpdatedAtMillis &&
          other.deleted == this.deleted);
}

class CoReplicaRowsCompanion extends UpdateCompanion<CoReplicaRowData> {
  final Value<String> domain;
  final Value<String> rowId;
  final Value<String> dataJson;
  final Value<int> serverUpdatedAtMillis;
  final Value<bool> deleted;
  final Value<int> rowid;
  const CoReplicaRowsCompanion({
    this.domain = const Value.absent(),
    this.rowId = const Value.absent(),
    this.dataJson = const Value.absent(),
    this.serverUpdatedAtMillis = const Value.absent(),
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CoReplicaRowsCompanion.insert({
    required String domain,
    required String rowId,
    required String dataJson,
    required int serverUpdatedAtMillis,
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : domain = Value(domain),
       rowId = Value(rowId),
       dataJson = Value(dataJson),
       serverUpdatedAtMillis = Value(serverUpdatedAtMillis);
  static Insertable<CoReplicaRowData> custom({
    Expression<String>? domain,
    Expression<String>? rowId,
    Expression<String>? dataJson,
    Expression<int>? serverUpdatedAtMillis,
    Expression<bool>? deleted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (domain != null) 'domain': domain,
      if (rowId != null) 'row_id': rowId,
      if (dataJson != null) 'data_json': dataJson,
      if (serverUpdatedAtMillis != null)
        'server_updated_at_millis': serverUpdatedAtMillis,
      if (deleted != null) 'deleted': deleted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CoReplicaRowsCompanion copyWith({
    Value<String>? domain,
    Value<String>? rowId,
    Value<String>? dataJson,
    Value<int>? serverUpdatedAtMillis,
    Value<bool>? deleted,
    Value<int>? rowid,
  }) {
    return CoReplicaRowsCompanion(
      domain: domain ?? this.domain,
      rowId: rowId ?? this.rowId,
      dataJson: dataJson ?? this.dataJson,
      serverUpdatedAtMillis:
          serverUpdatedAtMillis ?? this.serverUpdatedAtMillis,
      deleted: deleted ?? this.deleted,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (domain.present) {
      map['domain'] = Variable<String>(domain.value);
    }
    if (rowId.present) {
      map['row_id'] = Variable<String>(rowId.value);
    }
    if (dataJson.present) {
      map['data_json'] = Variable<String>(dataJson.value);
    }
    if (serverUpdatedAtMillis.present) {
      map['server_updated_at_millis'] = Variable<int>(
        serverUpdatedAtMillis.value,
      );
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CoReplicaRowsCompanion(')
          ..write('domain: $domain, ')
          ..write('rowId: $rowId, ')
          ..write('dataJson: $dataJson, ')
          ..write('serverUpdatedAtMillis: $serverUpdatedAtMillis, ')
          ..write('deleted: $deleted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CoReplicaCursorsTable extends CoReplicaCursors
    with TableInfo<$CoReplicaCursorsTable, CoReplicaCursorData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CoReplicaCursorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _domainMeta = const VerificationMeta('domain');
  @override
  late final GeneratedColumn<String> domain = GeneratedColumn<String>(
    'domain',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cursorMeta = const VerificationMeta('cursor');
  @override
  late final GeneratedColumn<String> cursor = GeneratedColumn<String>(
    'cursor',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [domain, cursor];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'co_replica_cursors';
  @override
  VerificationContext validateIntegrity(
    Insertable<CoReplicaCursorData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('domain')) {
      context.handle(
        _domainMeta,
        domain.isAcceptableOrUnknown(data['domain']!, _domainMeta),
      );
    } else if (isInserting) {
      context.missing(_domainMeta);
    }
    if (data.containsKey('cursor')) {
      context.handle(
        _cursorMeta,
        cursor.isAcceptableOrUnknown(data['cursor']!, _cursorMeta),
      );
    } else if (isInserting) {
      context.missing(_cursorMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {domain};
  @override
  CoReplicaCursorData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CoReplicaCursorData(
      domain: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}domain'],
      )!,
      cursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cursor'],
      )!,
    );
  }

  @override
  $CoReplicaCursorsTable createAlias(String alias) {
    return $CoReplicaCursorsTable(attachedDatabase, alias);
  }
}

class CoReplicaCursorData extends DataClass
    implements Insertable<CoReplicaCursorData> {
  /// replica 도메인.
  final String domain;

  /// 서버가 발급한 opaque 커서 — 다음 pull 의 시작점.
  final String cursor;
  const CoReplicaCursorData({required this.domain, required this.cursor});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['domain'] = Variable<String>(domain);
    map['cursor'] = Variable<String>(cursor);
    return map;
  }

  CoReplicaCursorsCompanion toCompanion(bool nullToAbsent) {
    return CoReplicaCursorsCompanion(
      domain: Value(domain),
      cursor: Value(cursor),
    );
  }

  factory CoReplicaCursorData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CoReplicaCursorData(
      domain: serializer.fromJson<String>(json['domain']),
      cursor: serializer.fromJson<String>(json['cursor']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'domain': serializer.toJson<String>(domain),
      'cursor': serializer.toJson<String>(cursor),
    };
  }

  CoReplicaCursorData copyWith({String? domain, String? cursor}) =>
      CoReplicaCursorData(
        domain: domain ?? this.domain,
        cursor: cursor ?? this.cursor,
      );
  CoReplicaCursorData copyWithCompanion(CoReplicaCursorsCompanion data) {
    return CoReplicaCursorData(
      domain: data.domain.present ? data.domain.value : this.domain,
      cursor: data.cursor.present ? data.cursor.value : this.cursor,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CoReplicaCursorData(')
          ..write('domain: $domain, ')
          ..write('cursor: $cursor')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(domain, cursor);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CoReplicaCursorData &&
          other.domain == this.domain &&
          other.cursor == this.cursor);
}

class CoReplicaCursorsCompanion extends UpdateCompanion<CoReplicaCursorData> {
  final Value<String> domain;
  final Value<String> cursor;
  final Value<int> rowid;
  const CoReplicaCursorsCompanion({
    this.domain = const Value.absent(),
    this.cursor = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CoReplicaCursorsCompanion.insert({
    required String domain,
    required String cursor,
    this.rowid = const Value.absent(),
  }) : domain = Value(domain),
       cursor = Value(cursor);
  static Insertable<CoReplicaCursorData> custom({
    Expression<String>? domain,
    Expression<String>? cursor,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (domain != null) 'domain': domain,
      if (cursor != null) 'cursor': cursor,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CoReplicaCursorsCompanion copyWith({
    Value<String>? domain,
    Value<String>? cursor,
    Value<int>? rowid,
  }) {
    return CoReplicaCursorsCompanion(
      domain: domain ?? this.domain,
      cursor: cursor ?? this.cursor,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (domain.present) {
      map['domain'] = Variable<String>(domain.value);
    }
    if (cursor.present) {
      map['cursor'] = Variable<String>(cursor.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CoReplicaCursorsCompanion(')
          ..write('domain: $domain, ')
          ..write('cursor: $cursor, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$CoSyncDatabase extends GeneratedDatabase {
  _$CoSyncDatabase(QueryExecutor e) : super(e);
  $CoSyncDatabaseManager get managers => $CoSyncDatabaseManager(this);
  late final $CoSyncRowsTable coSyncRows = $CoSyncRowsTable(this);
  late final $CoSyncMetaTable coSyncMeta = $CoSyncMetaTable(this);
  late final $CoReplicaRowsTable coReplicaRows = $CoReplicaRowsTable(this);
  late final $CoReplicaCursorsTable coReplicaCursors = $CoReplicaCursorsTable(
    this,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    coSyncRows,
    coSyncMeta,
    coReplicaRows,
    coReplicaCursors,
  ];
}

typedef $$CoSyncRowsTableCreateCompanionBuilder =
    CoSyncRowsCompanion Function({
      required String logicalTable,
      required String rowId,
      required String stateJson,
      required String maxHlc,
      Value<bool> pending,
      Value<String?> pendingSnapshotHlc,
      Value<bool> deleted,
      Value<int> rowid,
    });
typedef $$CoSyncRowsTableUpdateCompanionBuilder =
    CoSyncRowsCompanion Function({
      Value<String> logicalTable,
      Value<String> rowId,
      Value<String> stateJson,
      Value<String> maxHlc,
      Value<bool> pending,
      Value<String?> pendingSnapshotHlc,
      Value<bool> deleted,
      Value<int> rowid,
    });

class $$CoSyncRowsTableFilterComposer
    extends Composer<_$CoSyncDatabase, $CoSyncRowsTable> {
  $$CoSyncRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get logicalTable => $composableBuilder(
    column: $table.logicalTable,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stateJson => $composableBuilder(
    column: $table.stateJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get maxHlc => $composableBuilder(
    column: $table.maxHlc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pending => $composableBuilder(
    column: $table.pending,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pendingSnapshotHlc => $composableBuilder(
    column: $table.pendingSnapshotHlc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CoSyncRowsTableOrderingComposer
    extends Composer<_$CoSyncDatabase, $CoSyncRowsTable> {
  $$CoSyncRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get logicalTable => $composableBuilder(
    column: $table.logicalTable,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stateJson => $composableBuilder(
    column: $table.stateJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get maxHlc => $composableBuilder(
    column: $table.maxHlc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pending => $composableBuilder(
    column: $table.pending,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pendingSnapshotHlc => $composableBuilder(
    column: $table.pendingSnapshotHlc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CoSyncRowsTableAnnotationComposer
    extends Composer<_$CoSyncDatabase, $CoSyncRowsTable> {
  $$CoSyncRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get logicalTable => $composableBuilder(
    column: $table.logicalTable,
    builder: (column) => column,
  );

  GeneratedColumn<String> get rowId =>
      $composableBuilder(column: $table.rowId, builder: (column) => column);

  GeneratedColumn<String> get stateJson =>
      $composableBuilder(column: $table.stateJson, builder: (column) => column);

  GeneratedColumn<String> get maxHlc =>
      $composableBuilder(column: $table.maxHlc, builder: (column) => column);

  GeneratedColumn<bool> get pending =>
      $composableBuilder(column: $table.pending, builder: (column) => column);

  GeneratedColumn<String> get pendingSnapshotHlc => $composableBuilder(
    column: $table.pendingSnapshotHlc,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);
}

class $$CoSyncRowsTableTableManager
    extends
        RootTableManager<
          _$CoSyncDatabase,
          $CoSyncRowsTable,
          CoSyncRowData,
          $$CoSyncRowsTableFilterComposer,
          $$CoSyncRowsTableOrderingComposer,
          $$CoSyncRowsTableAnnotationComposer,
          $$CoSyncRowsTableCreateCompanionBuilder,
          $$CoSyncRowsTableUpdateCompanionBuilder,
          (
            CoSyncRowData,
            BaseReferences<_$CoSyncDatabase, $CoSyncRowsTable, CoSyncRowData>,
          ),
          CoSyncRowData,
          PrefetchHooks Function()
        > {
  $$CoSyncRowsTableTableManager(_$CoSyncDatabase db, $CoSyncRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CoSyncRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CoSyncRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CoSyncRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> logicalTable = const Value.absent(),
                Value<String> rowId = const Value.absent(),
                Value<String> stateJson = const Value.absent(),
                Value<String> maxHlc = const Value.absent(),
                Value<bool> pending = const Value.absent(),
                Value<String?> pendingSnapshotHlc = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CoSyncRowsCompanion(
                logicalTable: logicalTable,
                rowId: rowId,
                stateJson: stateJson,
                maxHlc: maxHlc,
                pending: pending,
                pendingSnapshotHlc: pendingSnapshotHlc,
                deleted: deleted,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String logicalTable,
                required String rowId,
                required String stateJson,
                required String maxHlc,
                Value<bool> pending = const Value.absent(),
                Value<String?> pendingSnapshotHlc = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CoSyncRowsCompanion.insert(
                logicalTable: logicalTable,
                rowId: rowId,
                stateJson: stateJson,
                maxHlc: maxHlc,
                pending: pending,
                pendingSnapshotHlc: pendingSnapshotHlc,
                deleted: deleted,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CoSyncRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$CoSyncDatabase,
      $CoSyncRowsTable,
      CoSyncRowData,
      $$CoSyncRowsTableFilterComposer,
      $$CoSyncRowsTableOrderingComposer,
      $$CoSyncRowsTableAnnotationComposer,
      $$CoSyncRowsTableCreateCompanionBuilder,
      $$CoSyncRowsTableUpdateCompanionBuilder,
      (
        CoSyncRowData,
        BaseReferences<_$CoSyncDatabase, $CoSyncRowsTable, CoSyncRowData>,
      ),
      CoSyncRowData,
      PrefetchHooks Function()
    >;
typedef $$CoSyncMetaTableCreateCompanionBuilder =
    CoSyncMetaCompanion Function({
      required String metaKey,
      required String metaValue,
      Value<int> rowid,
    });
typedef $$CoSyncMetaTableUpdateCompanionBuilder =
    CoSyncMetaCompanion Function({
      Value<String> metaKey,
      Value<String> metaValue,
      Value<int> rowid,
    });

class $$CoSyncMetaTableFilterComposer
    extends Composer<_$CoSyncDatabase, $CoSyncMetaTable> {
  $$CoSyncMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get metaKey => $composableBuilder(
    column: $table.metaKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metaValue => $composableBuilder(
    column: $table.metaValue,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CoSyncMetaTableOrderingComposer
    extends Composer<_$CoSyncDatabase, $CoSyncMetaTable> {
  $$CoSyncMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get metaKey => $composableBuilder(
    column: $table.metaKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metaValue => $composableBuilder(
    column: $table.metaValue,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CoSyncMetaTableAnnotationComposer
    extends Composer<_$CoSyncDatabase, $CoSyncMetaTable> {
  $$CoSyncMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get metaKey =>
      $composableBuilder(column: $table.metaKey, builder: (column) => column);

  GeneratedColumn<String> get metaValue =>
      $composableBuilder(column: $table.metaValue, builder: (column) => column);
}

class $$CoSyncMetaTableTableManager
    extends
        RootTableManager<
          _$CoSyncDatabase,
          $CoSyncMetaTable,
          CoSyncMetaData,
          $$CoSyncMetaTableFilterComposer,
          $$CoSyncMetaTableOrderingComposer,
          $$CoSyncMetaTableAnnotationComposer,
          $$CoSyncMetaTableCreateCompanionBuilder,
          $$CoSyncMetaTableUpdateCompanionBuilder,
          (
            CoSyncMetaData,
            BaseReferences<_$CoSyncDatabase, $CoSyncMetaTable, CoSyncMetaData>,
          ),
          CoSyncMetaData,
          PrefetchHooks Function()
        > {
  $$CoSyncMetaTableTableManager(_$CoSyncDatabase db, $CoSyncMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CoSyncMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CoSyncMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CoSyncMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> metaKey = const Value.absent(),
                Value<String> metaValue = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CoSyncMetaCompanion(
                metaKey: metaKey,
                metaValue: metaValue,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String metaKey,
                required String metaValue,
                Value<int> rowid = const Value.absent(),
              }) => CoSyncMetaCompanion.insert(
                metaKey: metaKey,
                metaValue: metaValue,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CoSyncMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$CoSyncDatabase,
      $CoSyncMetaTable,
      CoSyncMetaData,
      $$CoSyncMetaTableFilterComposer,
      $$CoSyncMetaTableOrderingComposer,
      $$CoSyncMetaTableAnnotationComposer,
      $$CoSyncMetaTableCreateCompanionBuilder,
      $$CoSyncMetaTableUpdateCompanionBuilder,
      (
        CoSyncMetaData,
        BaseReferences<_$CoSyncDatabase, $CoSyncMetaTable, CoSyncMetaData>,
      ),
      CoSyncMetaData,
      PrefetchHooks Function()
    >;
typedef $$CoReplicaRowsTableCreateCompanionBuilder =
    CoReplicaRowsCompanion Function({
      required String domain,
      required String rowId,
      required String dataJson,
      required int serverUpdatedAtMillis,
      Value<bool> deleted,
      Value<int> rowid,
    });
typedef $$CoReplicaRowsTableUpdateCompanionBuilder =
    CoReplicaRowsCompanion Function({
      Value<String> domain,
      Value<String> rowId,
      Value<String> dataJson,
      Value<int> serverUpdatedAtMillis,
      Value<bool> deleted,
      Value<int> rowid,
    });

class $$CoReplicaRowsTableFilterComposer
    extends Composer<_$CoSyncDatabase, $CoReplicaRowsTable> {
  $$CoReplicaRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get domain => $composableBuilder(
    column: $table.domain,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverUpdatedAtMillis => $composableBuilder(
    column: $table.serverUpdatedAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CoReplicaRowsTableOrderingComposer
    extends Composer<_$CoSyncDatabase, $CoReplicaRowsTable> {
  $$CoReplicaRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get domain => $composableBuilder(
    column: $table.domain,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverUpdatedAtMillis => $composableBuilder(
    column: $table.serverUpdatedAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CoReplicaRowsTableAnnotationComposer
    extends Composer<_$CoSyncDatabase, $CoReplicaRowsTable> {
  $$CoReplicaRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get domain =>
      $composableBuilder(column: $table.domain, builder: (column) => column);

  GeneratedColumn<String> get rowId =>
      $composableBuilder(column: $table.rowId, builder: (column) => column);

  GeneratedColumn<String> get dataJson =>
      $composableBuilder(column: $table.dataJson, builder: (column) => column);

  GeneratedColumn<int> get serverUpdatedAtMillis => $composableBuilder(
    column: $table.serverUpdatedAtMillis,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);
}

class $$CoReplicaRowsTableTableManager
    extends
        RootTableManager<
          _$CoSyncDatabase,
          $CoReplicaRowsTable,
          CoReplicaRowData,
          $$CoReplicaRowsTableFilterComposer,
          $$CoReplicaRowsTableOrderingComposer,
          $$CoReplicaRowsTableAnnotationComposer,
          $$CoReplicaRowsTableCreateCompanionBuilder,
          $$CoReplicaRowsTableUpdateCompanionBuilder,
          (
            CoReplicaRowData,
            BaseReferences<
              _$CoSyncDatabase,
              $CoReplicaRowsTable,
              CoReplicaRowData
            >,
          ),
          CoReplicaRowData,
          PrefetchHooks Function()
        > {
  $$CoReplicaRowsTableTableManager(
    _$CoSyncDatabase db,
    $CoReplicaRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CoReplicaRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CoReplicaRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CoReplicaRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> domain = const Value.absent(),
                Value<String> rowId = const Value.absent(),
                Value<String> dataJson = const Value.absent(),
                Value<int> serverUpdatedAtMillis = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CoReplicaRowsCompanion(
                domain: domain,
                rowId: rowId,
                dataJson: dataJson,
                serverUpdatedAtMillis: serverUpdatedAtMillis,
                deleted: deleted,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String domain,
                required String rowId,
                required String dataJson,
                required int serverUpdatedAtMillis,
                Value<bool> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CoReplicaRowsCompanion.insert(
                domain: domain,
                rowId: rowId,
                dataJson: dataJson,
                serverUpdatedAtMillis: serverUpdatedAtMillis,
                deleted: deleted,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CoReplicaRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$CoSyncDatabase,
      $CoReplicaRowsTable,
      CoReplicaRowData,
      $$CoReplicaRowsTableFilterComposer,
      $$CoReplicaRowsTableOrderingComposer,
      $$CoReplicaRowsTableAnnotationComposer,
      $$CoReplicaRowsTableCreateCompanionBuilder,
      $$CoReplicaRowsTableUpdateCompanionBuilder,
      (
        CoReplicaRowData,
        BaseReferences<_$CoSyncDatabase, $CoReplicaRowsTable, CoReplicaRowData>,
      ),
      CoReplicaRowData,
      PrefetchHooks Function()
    >;
typedef $$CoReplicaCursorsTableCreateCompanionBuilder =
    CoReplicaCursorsCompanion Function({
      required String domain,
      required String cursor,
      Value<int> rowid,
    });
typedef $$CoReplicaCursorsTableUpdateCompanionBuilder =
    CoReplicaCursorsCompanion Function({
      Value<String> domain,
      Value<String> cursor,
      Value<int> rowid,
    });

class $$CoReplicaCursorsTableFilterComposer
    extends Composer<_$CoSyncDatabase, $CoReplicaCursorsTable> {
  $$CoReplicaCursorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get domain => $composableBuilder(
    column: $table.domain,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CoReplicaCursorsTableOrderingComposer
    extends Composer<_$CoSyncDatabase, $CoReplicaCursorsTable> {
  $$CoReplicaCursorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get domain => $composableBuilder(
    column: $table.domain,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CoReplicaCursorsTableAnnotationComposer
    extends Composer<_$CoSyncDatabase, $CoReplicaCursorsTable> {
  $$CoReplicaCursorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get domain =>
      $composableBuilder(column: $table.domain, builder: (column) => column);

  GeneratedColumn<String> get cursor =>
      $composableBuilder(column: $table.cursor, builder: (column) => column);
}

class $$CoReplicaCursorsTableTableManager
    extends
        RootTableManager<
          _$CoSyncDatabase,
          $CoReplicaCursorsTable,
          CoReplicaCursorData,
          $$CoReplicaCursorsTableFilterComposer,
          $$CoReplicaCursorsTableOrderingComposer,
          $$CoReplicaCursorsTableAnnotationComposer,
          $$CoReplicaCursorsTableCreateCompanionBuilder,
          $$CoReplicaCursorsTableUpdateCompanionBuilder,
          (
            CoReplicaCursorData,
            BaseReferences<
              _$CoSyncDatabase,
              $CoReplicaCursorsTable,
              CoReplicaCursorData
            >,
          ),
          CoReplicaCursorData,
          PrefetchHooks Function()
        > {
  $$CoReplicaCursorsTableTableManager(
    _$CoSyncDatabase db,
    $CoReplicaCursorsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CoReplicaCursorsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CoReplicaCursorsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CoReplicaCursorsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> domain = const Value.absent(),
                Value<String> cursor = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CoReplicaCursorsCompanion(
                domain: domain,
                cursor: cursor,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String domain,
                required String cursor,
                Value<int> rowid = const Value.absent(),
              }) => CoReplicaCursorsCompanion.insert(
                domain: domain,
                cursor: cursor,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CoReplicaCursorsTableProcessedTableManager =
    ProcessedTableManager<
      _$CoSyncDatabase,
      $CoReplicaCursorsTable,
      CoReplicaCursorData,
      $$CoReplicaCursorsTableFilterComposer,
      $$CoReplicaCursorsTableOrderingComposer,
      $$CoReplicaCursorsTableAnnotationComposer,
      $$CoReplicaCursorsTableCreateCompanionBuilder,
      $$CoReplicaCursorsTableUpdateCompanionBuilder,
      (
        CoReplicaCursorData,
        BaseReferences<
          _$CoSyncDatabase,
          $CoReplicaCursorsTable,
          CoReplicaCursorData
        >,
      ),
      CoReplicaCursorData,
      PrefetchHooks Function()
    >;

class $CoSyncDatabaseManager {
  final _$CoSyncDatabase _db;
  $CoSyncDatabaseManager(this._db);
  $$CoSyncRowsTableTableManager get coSyncRows =>
      $$CoSyncRowsTableTableManager(_db, _db.coSyncRows);
  $$CoSyncMetaTableTableManager get coSyncMeta =>
      $$CoSyncMetaTableTableManager(_db, _db.coSyncMeta);
  $$CoReplicaRowsTableTableManager get coReplicaRows =>
      $$CoReplicaRowsTableTableManager(_db, _db.coReplicaRows);
  $$CoReplicaCursorsTableTableManager get coReplicaCursors =>
      $$CoReplicaCursorsTableTableManager(_db, _db.coReplicaCursors);
}
