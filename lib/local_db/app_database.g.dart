// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $SyncJobsTable extends SyncJobs with TableInfo<$SyncJobsTable, SyncJob> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncJobsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _jobTypeMeta = const VerificationMeta(
    'jobType',
  );
  @override
  late final GeneratedColumn<String> jobType = GeneratedColumn<String>(
    'job_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stepsMeta = const VerificationMeta('steps');
  @override
  late final GeneratedColumn<String> steps = GeneratedColumn<String>(
    'steps',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _currentStepIndexMeta = const VerificationMeta(
    'currentStepIndex',
  );
  @override
  late final GeneratedColumn<int> currentStepIndex = GeneratedColumn<int>(
    'current_step_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _retryCountMeta = const VerificationMeta(
    'retryCount',
  );
  @override
  late final GeneratedColumn<int> retryCount = GeneratedColumn<int>(
    'retry_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resultDoctypeMeta = const VerificationMeta(
    'resultDoctype',
  );
  @override
  late final GeneratedColumn<String> resultDoctype = GeneratedColumn<String>(
    'result_doctype',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resultNameMeta = const VerificationMeta(
    'resultName',
  );
  @override
  late final GeneratedColumn<String> resultName = GeneratedColumn<String>(
    'result_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dependsOnJobIdMeta = const VerificationMeta(
    'dependsOnJobId',
  );
  @override
  late final GeneratedColumn<int> dependsOnJobId = GeneratedColumn<int>(
    'depends_on_job_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _localPhotoPathMeta = const VerificationMeta(
    'localPhotoPath',
  );
  @override
  late final GeneratedColumn<String> localPhotoPath = GeneratedColumn<String>(
    'local_photo_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    jobType,
    status,
    payload,
    steps,
    currentStepIndex,
    retryCount,
    lastError,
    resultDoctype,
    resultName,
    dependsOnJobId,
    localPhotoPath,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_jobs';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncJob> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('job_type')) {
      context.handle(
        _jobTypeMeta,
        jobType.isAcceptableOrUnknown(data['job_type']!, _jobTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_jobTypeMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('steps')) {
      context.handle(
        _stepsMeta,
        steps.isAcceptableOrUnknown(data['steps']!, _stepsMeta),
      );
    }
    if (data.containsKey('current_step_index')) {
      context.handle(
        _currentStepIndexMeta,
        currentStepIndex.isAcceptableOrUnknown(
          data['current_step_index']!,
          _currentStepIndexMeta,
        ),
      );
    }
    if (data.containsKey('retry_count')) {
      context.handle(
        _retryCountMeta,
        retryCount.isAcceptableOrUnknown(data['retry_count']!, _retryCountMeta),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    if (data.containsKey('result_doctype')) {
      context.handle(
        _resultDoctypeMeta,
        resultDoctype.isAcceptableOrUnknown(
          data['result_doctype']!,
          _resultDoctypeMeta,
        ),
      );
    }
    if (data.containsKey('result_name')) {
      context.handle(
        _resultNameMeta,
        resultName.isAcceptableOrUnknown(data['result_name']!, _resultNameMeta),
      );
    }
    if (data.containsKey('depends_on_job_id')) {
      context.handle(
        _dependsOnJobIdMeta,
        dependsOnJobId.isAcceptableOrUnknown(
          data['depends_on_job_id']!,
          _dependsOnJobIdMeta,
        ),
      );
    }
    if (data.containsKey('local_photo_path')) {
      context.handle(
        _localPhotoPathMeta,
        localPhotoPath.isAcceptableOrUnknown(
          data['local_photo_path']!,
          _localPhotoPathMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncJob map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncJob(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      jobType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}job_type'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      steps: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}steps'],
      ),
      currentStepIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}current_step_index'],
      )!,
      retryCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}retry_count'],
      )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
      resultDoctype: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}result_doctype'],
      ),
      resultName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}result_name'],
      ),
      dependsOnJobId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}depends_on_job_id'],
      ),
      localPhotoPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_photo_path'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $SyncJobsTable createAlias(String alias) {
    return $SyncJobsTable(attachedDatabase, alias);
  }
}

class SyncJob extends DataClass implements Insertable<SyncJob> {
  final int id;

  /// e.g. `sales_order_create`, `expense_claim_vehicle_log_chain` — see
  /// `SyncJobType`.
  final String jobType;

  /// `pending` / `in_progress` / `success` / `failed` / `needs_review`.
  final String status;

  /// The exact request body the screen would have sent live, as JSON.
  final String payload;

  /// Null for single-step jobs. For a chained job (the vehicle-log →
  /// expense-claim sequence) a JSON array of step records, each gaining a
  /// `resolvedName` once that step succeeds server-side — so a resumed
  /// replay never re-issues a step that already went through.
  final String? steps;
  final int currentStepIndex;
  final int retryCount;

  /// Human-readable (Arabic) — reuses `ErpException.message` where
  /// possible so this reads the same as a live-failure message would.
  final String? lastError;

  /// Populated once the job's primary document exists server-side, so a
  /// completed row can deep-link via `documentDetailRoute`.
  final String? resultDoctype;
  final String? resultName;

  /// For a `photo_attach` job queued against a document that was ITSELF
  /// created offline and hasn't synced yet — the photo job can't run
  /// until the parent job has a `resultName`.
  final int? dependsOnJobId;

  /// `photo_attach` jobs only — the durable on-device copy (never the
  /// original picker cache path, which the OS can clear at any time).
  final String? localPhotoPath;
  final DateTime createdAt;
  final DateTime updatedAt;
  const SyncJob({
    required this.id,
    required this.jobType,
    required this.status,
    required this.payload,
    this.steps,
    required this.currentStepIndex,
    required this.retryCount,
    this.lastError,
    this.resultDoctype,
    this.resultName,
    this.dependsOnJobId,
    this.localPhotoPath,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['job_type'] = Variable<String>(jobType);
    map['status'] = Variable<String>(status);
    map['payload'] = Variable<String>(payload);
    if (!nullToAbsent || steps != null) {
      map['steps'] = Variable<String>(steps);
    }
    map['current_step_index'] = Variable<int>(currentStepIndex);
    map['retry_count'] = Variable<int>(retryCount);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    if (!nullToAbsent || resultDoctype != null) {
      map['result_doctype'] = Variable<String>(resultDoctype);
    }
    if (!nullToAbsent || resultName != null) {
      map['result_name'] = Variable<String>(resultName);
    }
    if (!nullToAbsent || dependsOnJobId != null) {
      map['depends_on_job_id'] = Variable<int>(dependsOnJobId);
    }
    if (!nullToAbsent || localPhotoPath != null) {
      map['local_photo_path'] = Variable<String>(localPhotoPath);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  SyncJobsCompanion toCompanion(bool nullToAbsent) {
    return SyncJobsCompanion(
      id: Value(id),
      jobType: Value(jobType),
      status: Value(status),
      payload: Value(payload),
      steps: steps == null && nullToAbsent
          ? const Value.absent()
          : Value(steps),
      currentStepIndex: Value(currentStepIndex),
      retryCount: Value(retryCount),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      resultDoctype: resultDoctype == null && nullToAbsent
          ? const Value.absent()
          : Value(resultDoctype),
      resultName: resultName == null && nullToAbsent
          ? const Value.absent()
          : Value(resultName),
      dependsOnJobId: dependsOnJobId == null && nullToAbsent
          ? const Value.absent()
          : Value(dependsOnJobId),
      localPhotoPath: localPhotoPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localPhotoPath),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory SyncJob.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncJob(
      id: serializer.fromJson<int>(json['id']),
      jobType: serializer.fromJson<String>(json['jobType']),
      status: serializer.fromJson<String>(json['status']),
      payload: serializer.fromJson<String>(json['payload']),
      steps: serializer.fromJson<String?>(json['steps']),
      currentStepIndex: serializer.fromJson<int>(json['currentStepIndex']),
      retryCount: serializer.fromJson<int>(json['retryCount']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      resultDoctype: serializer.fromJson<String?>(json['resultDoctype']),
      resultName: serializer.fromJson<String?>(json['resultName']),
      dependsOnJobId: serializer.fromJson<int?>(json['dependsOnJobId']),
      localPhotoPath: serializer.fromJson<String?>(json['localPhotoPath']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'jobType': serializer.toJson<String>(jobType),
      'status': serializer.toJson<String>(status),
      'payload': serializer.toJson<String>(payload),
      'steps': serializer.toJson<String?>(steps),
      'currentStepIndex': serializer.toJson<int>(currentStepIndex),
      'retryCount': serializer.toJson<int>(retryCount),
      'lastError': serializer.toJson<String?>(lastError),
      'resultDoctype': serializer.toJson<String?>(resultDoctype),
      'resultName': serializer.toJson<String?>(resultName),
      'dependsOnJobId': serializer.toJson<int?>(dependsOnJobId),
      'localPhotoPath': serializer.toJson<String?>(localPhotoPath),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  SyncJob copyWith({
    int? id,
    String? jobType,
    String? status,
    String? payload,
    Value<String?> steps = const Value.absent(),
    int? currentStepIndex,
    int? retryCount,
    Value<String?> lastError = const Value.absent(),
    Value<String?> resultDoctype = const Value.absent(),
    Value<String?> resultName = const Value.absent(),
    Value<int?> dependsOnJobId = const Value.absent(),
    Value<String?> localPhotoPath = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => SyncJob(
    id: id ?? this.id,
    jobType: jobType ?? this.jobType,
    status: status ?? this.status,
    payload: payload ?? this.payload,
    steps: steps.present ? steps.value : this.steps,
    currentStepIndex: currentStepIndex ?? this.currentStepIndex,
    retryCount: retryCount ?? this.retryCount,
    lastError: lastError.present ? lastError.value : this.lastError,
    resultDoctype: resultDoctype.present
        ? resultDoctype.value
        : this.resultDoctype,
    resultName: resultName.present ? resultName.value : this.resultName,
    dependsOnJobId: dependsOnJobId.present
        ? dependsOnJobId.value
        : this.dependsOnJobId,
    localPhotoPath: localPhotoPath.present
        ? localPhotoPath.value
        : this.localPhotoPath,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  SyncJob copyWithCompanion(SyncJobsCompanion data) {
    return SyncJob(
      id: data.id.present ? data.id.value : this.id,
      jobType: data.jobType.present ? data.jobType.value : this.jobType,
      status: data.status.present ? data.status.value : this.status,
      payload: data.payload.present ? data.payload.value : this.payload,
      steps: data.steps.present ? data.steps.value : this.steps,
      currentStepIndex: data.currentStepIndex.present
          ? data.currentStepIndex.value
          : this.currentStepIndex,
      retryCount: data.retryCount.present
          ? data.retryCount.value
          : this.retryCount,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      resultDoctype: data.resultDoctype.present
          ? data.resultDoctype.value
          : this.resultDoctype,
      resultName: data.resultName.present
          ? data.resultName.value
          : this.resultName,
      dependsOnJobId: data.dependsOnJobId.present
          ? data.dependsOnJobId.value
          : this.dependsOnJobId,
      localPhotoPath: data.localPhotoPath.present
          ? data.localPhotoPath.value
          : this.localPhotoPath,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncJob(')
          ..write('id: $id, ')
          ..write('jobType: $jobType, ')
          ..write('status: $status, ')
          ..write('payload: $payload, ')
          ..write('steps: $steps, ')
          ..write('currentStepIndex: $currentStepIndex, ')
          ..write('retryCount: $retryCount, ')
          ..write('lastError: $lastError, ')
          ..write('resultDoctype: $resultDoctype, ')
          ..write('resultName: $resultName, ')
          ..write('dependsOnJobId: $dependsOnJobId, ')
          ..write('localPhotoPath: $localPhotoPath, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    jobType,
    status,
    payload,
    steps,
    currentStepIndex,
    retryCount,
    lastError,
    resultDoctype,
    resultName,
    dependsOnJobId,
    localPhotoPath,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncJob &&
          other.id == this.id &&
          other.jobType == this.jobType &&
          other.status == this.status &&
          other.payload == this.payload &&
          other.steps == this.steps &&
          other.currentStepIndex == this.currentStepIndex &&
          other.retryCount == this.retryCount &&
          other.lastError == this.lastError &&
          other.resultDoctype == this.resultDoctype &&
          other.resultName == this.resultName &&
          other.dependsOnJobId == this.dependsOnJobId &&
          other.localPhotoPath == this.localPhotoPath &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class SyncJobsCompanion extends UpdateCompanion<SyncJob> {
  final Value<int> id;
  final Value<String> jobType;
  final Value<String> status;
  final Value<String> payload;
  final Value<String?> steps;
  final Value<int> currentStepIndex;
  final Value<int> retryCount;
  final Value<String?> lastError;
  final Value<String?> resultDoctype;
  final Value<String?> resultName;
  final Value<int?> dependsOnJobId;
  final Value<String?> localPhotoPath;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  const SyncJobsCompanion({
    this.id = const Value.absent(),
    this.jobType = const Value.absent(),
    this.status = const Value.absent(),
    this.payload = const Value.absent(),
    this.steps = const Value.absent(),
    this.currentStepIndex = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.lastError = const Value.absent(),
    this.resultDoctype = const Value.absent(),
    this.resultName = const Value.absent(),
    this.dependsOnJobId = const Value.absent(),
    this.localPhotoPath = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  SyncJobsCompanion.insert({
    this.id = const Value.absent(),
    required String jobType,
    this.status = const Value.absent(),
    required String payload,
    this.steps = const Value.absent(),
    this.currentStepIndex = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.lastError = const Value.absent(),
    this.resultDoctype = const Value.absent(),
    this.resultName = const Value.absent(),
    this.dependsOnJobId = const Value.absent(),
    this.localPhotoPath = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  }) : jobType = Value(jobType),
       payload = Value(payload);
  static Insertable<SyncJob> custom({
    Expression<int>? id,
    Expression<String>? jobType,
    Expression<String>? status,
    Expression<String>? payload,
    Expression<String>? steps,
    Expression<int>? currentStepIndex,
    Expression<int>? retryCount,
    Expression<String>? lastError,
    Expression<String>? resultDoctype,
    Expression<String>? resultName,
    Expression<int>? dependsOnJobId,
    Expression<String>? localPhotoPath,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (jobType != null) 'job_type': jobType,
      if (status != null) 'status': status,
      if (payload != null) 'payload': payload,
      if (steps != null) 'steps': steps,
      if (currentStepIndex != null) 'current_step_index': currentStepIndex,
      if (retryCount != null) 'retry_count': retryCount,
      if (lastError != null) 'last_error': lastError,
      if (resultDoctype != null) 'result_doctype': resultDoctype,
      if (resultName != null) 'result_name': resultName,
      if (dependsOnJobId != null) 'depends_on_job_id': dependsOnJobId,
      if (localPhotoPath != null) 'local_photo_path': localPhotoPath,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  SyncJobsCompanion copyWith({
    Value<int>? id,
    Value<String>? jobType,
    Value<String>? status,
    Value<String>? payload,
    Value<String?>? steps,
    Value<int>? currentStepIndex,
    Value<int>? retryCount,
    Value<String?>? lastError,
    Value<String?>? resultDoctype,
    Value<String?>? resultName,
    Value<int?>? dependsOnJobId,
    Value<String?>? localPhotoPath,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
  }) {
    return SyncJobsCompanion(
      id: id ?? this.id,
      jobType: jobType ?? this.jobType,
      status: status ?? this.status,
      payload: payload ?? this.payload,
      steps: steps ?? this.steps,
      currentStepIndex: currentStepIndex ?? this.currentStepIndex,
      retryCount: retryCount ?? this.retryCount,
      lastError: lastError ?? this.lastError,
      resultDoctype: resultDoctype ?? this.resultDoctype,
      resultName: resultName ?? this.resultName,
      dependsOnJobId: dependsOnJobId ?? this.dependsOnJobId,
      localPhotoPath: localPhotoPath ?? this.localPhotoPath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (jobType.present) {
      map['job_type'] = Variable<String>(jobType.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (steps.present) {
      map['steps'] = Variable<String>(steps.value);
    }
    if (currentStepIndex.present) {
      map['current_step_index'] = Variable<int>(currentStepIndex.value);
    }
    if (retryCount.present) {
      map['retry_count'] = Variable<int>(retryCount.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (resultDoctype.present) {
      map['result_doctype'] = Variable<String>(resultDoctype.value);
    }
    if (resultName.present) {
      map['result_name'] = Variable<String>(resultName.value);
    }
    if (dependsOnJobId.present) {
      map['depends_on_job_id'] = Variable<int>(dependsOnJobId.value);
    }
    if (localPhotoPath.present) {
      map['local_photo_path'] = Variable<String>(localPhotoPath.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncJobsCompanion(')
          ..write('id: $id, ')
          ..write('jobType: $jobType, ')
          ..write('status: $status, ')
          ..write('payload: $payload, ')
          ..write('steps: $steps, ')
          ..write('currentStepIndex: $currentStepIndex, ')
          ..write('retryCount: $retryCount, ')
          ..write('lastError: $lastError, ')
          ..write('resultDoctype: $resultDoctype, ')
          ..write('resultName: $resultName, ')
          ..write('dependsOnJobId: $dependsOnJobId, ')
          ..write('localPhotoPath: $localPhotoPath, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $ReferenceCacheTable extends ReferenceCache
    with TableInfo<$ReferenceCacheTable, ReferenceCacheData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReferenceCacheTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _doctypeMeta = const VerificationMeta(
    'doctype',
  );
  @override
  late final GeneratedColumn<String> doctype = GeneratedColumn<String>(
    'doctype',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
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
  static const VerificationMeta _cachedAtMeta = const VerificationMeta(
    'cachedAt',
  );
  @override
  late final GeneratedColumn<DateTime> cachedAt = GeneratedColumn<DateTime>(
    'cached_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [doctype, name, dataJson, cachedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reference_cache';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReferenceCacheData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('doctype')) {
      context.handle(
        _doctypeMeta,
        doctype.isAcceptableOrUnknown(data['doctype']!, _doctypeMeta),
      );
    } else if (isInserting) {
      context.missing(_doctypeMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('data_json')) {
      context.handle(
        _dataJsonMeta,
        dataJson.isAcceptableOrUnknown(data['data_json']!, _dataJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_dataJsonMeta);
    }
    if (data.containsKey('cached_at')) {
      context.handle(
        _cachedAtMeta,
        cachedAt.isAcceptableOrUnknown(data['cached_at']!, _cachedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_cachedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {doctype, name};
  @override
  ReferenceCacheData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReferenceCacheData(
      doctype: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}doctype'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      dataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data_json'],
      )!,
      cachedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}cached_at'],
      )!,
    );
  }

  @override
  $ReferenceCacheTable createAlias(String alias) {
    return $ReferenceCacheTable(attachedDatabase, alias);
  }
}

class ReferenceCacheData extends DataClass
    implements Insertable<ReferenceCacheData> {
  final String doctype;
  final String name;

  /// The cached document/row, as JSON — same shape `ErpService.getDoc`/
  /// `getList` already return, so a cache-read can be swapped in wherever
  /// a live call currently sits with no reshaping.
  final String dataJson;
  final DateTime cachedAt;
  const ReferenceCacheData({
    required this.doctype,
    required this.name,
    required this.dataJson,
    required this.cachedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['doctype'] = Variable<String>(doctype);
    map['name'] = Variable<String>(name);
    map['data_json'] = Variable<String>(dataJson);
    map['cached_at'] = Variable<DateTime>(cachedAt);
    return map;
  }

  ReferenceCacheCompanion toCompanion(bool nullToAbsent) {
    return ReferenceCacheCompanion(
      doctype: Value(doctype),
      name: Value(name),
      dataJson: Value(dataJson),
      cachedAt: Value(cachedAt),
    );
  }

  factory ReferenceCacheData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReferenceCacheData(
      doctype: serializer.fromJson<String>(json['doctype']),
      name: serializer.fromJson<String>(json['name']),
      dataJson: serializer.fromJson<String>(json['dataJson']),
      cachedAt: serializer.fromJson<DateTime>(json['cachedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'doctype': serializer.toJson<String>(doctype),
      'name': serializer.toJson<String>(name),
      'dataJson': serializer.toJson<String>(dataJson),
      'cachedAt': serializer.toJson<DateTime>(cachedAt),
    };
  }

  ReferenceCacheData copyWith({
    String? doctype,
    String? name,
    String? dataJson,
    DateTime? cachedAt,
  }) => ReferenceCacheData(
    doctype: doctype ?? this.doctype,
    name: name ?? this.name,
    dataJson: dataJson ?? this.dataJson,
    cachedAt: cachedAt ?? this.cachedAt,
  );
  ReferenceCacheData copyWithCompanion(ReferenceCacheCompanion data) {
    return ReferenceCacheData(
      doctype: data.doctype.present ? data.doctype.value : this.doctype,
      name: data.name.present ? data.name.value : this.name,
      dataJson: data.dataJson.present ? data.dataJson.value : this.dataJson,
      cachedAt: data.cachedAt.present ? data.cachedAt.value : this.cachedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReferenceCacheData(')
          ..write('doctype: $doctype, ')
          ..write('name: $name, ')
          ..write('dataJson: $dataJson, ')
          ..write('cachedAt: $cachedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(doctype, name, dataJson, cachedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReferenceCacheData &&
          other.doctype == this.doctype &&
          other.name == this.name &&
          other.dataJson == this.dataJson &&
          other.cachedAt == this.cachedAt);
}

class ReferenceCacheCompanion extends UpdateCompanion<ReferenceCacheData> {
  final Value<String> doctype;
  final Value<String> name;
  final Value<String> dataJson;
  final Value<DateTime> cachedAt;
  final Value<int> rowid;
  const ReferenceCacheCompanion({
    this.doctype = const Value.absent(),
    this.name = const Value.absent(),
    this.dataJson = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReferenceCacheCompanion.insert({
    required String doctype,
    required String name,
    required String dataJson,
    required DateTime cachedAt,
    this.rowid = const Value.absent(),
  }) : doctype = Value(doctype),
       name = Value(name),
       dataJson = Value(dataJson),
       cachedAt = Value(cachedAt);
  static Insertable<ReferenceCacheData> custom({
    Expression<String>? doctype,
    Expression<String>? name,
    Expression<String>? dataJson,
    Expression<DateTime>? cachedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (doctype != null) 'doctype': doctype,
      if (name != null) 'name': name,
      if (dataJson != null) 'data_json': dataJson,
      if (cachedAt != null) 'cached_at': cachedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReferenceCacheCompanion copyWith({
    Value<String>? doctype,
    Value<String>? name,
    Value<String>? dataJson,
    Value<DateTime>? cachedAt,
    Value<int>? rowid,
  }) {
    return ReferenceCacheCompanion(
      doctype: doctype ?? this.doctype,
      name: name ?? this.name,
      dataJson: dataJson ?? this.dataJson,
      cachedAt: cachedAt ?? this.cachedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (doctype.present) {
      map['doctype'] = Variable<String>(doctype.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (dataJson.present) {
      map['data_json'] = Variable<String>(dataJson.value);
    }
    if (cachedAt.present) {
      map['cached_at'] = Variable<DateTime>(cachedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReferenceCacheCompanion(')
          ..write('doctype: $doctype, ')
          ..write('name: $name, ')
          ..write('dataJson: $dataJson, ')
          ..write('cachedAt: $cachedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SyncJobsTable syncJobs = $SyncJobsTable(this);
  late final $ReferenceCacheTable referenceCache = $ReferenceCacheTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    syncJobs,
    referenceCache,
  ];
}

typedef $$SyncJobsTableCreateCompanionBuilder =
    SyncJobsCompanion Function({
      Value<int> id,
      required String jobType,
      Value<String> status,
      required String payload,
      Value<String?> steps,
      Value<int> currentStepIndex,
      Value<int> retryCount,
      Value<String?> lastError,
      Value<String?> resultDoctype,
      Value<String?> resultName,
      Value<int?> dependsOnJobId,
      Value<String?> localPhotoPath,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
    });
typedef $$SyncJobsTableUpdateCompanionBuilder =
    SyncJobsCompanion Function({
      Value<int> id,
      Value<String> jobType,
      Value<String> status,
      Value<String> payload,
      Value<String?> steps,
      Value<int> currentStepIndex,
      Value<int> retryCount,
      Value<String?> lastError,
      Value<String?> resultDoctype,
      Value<String?> resultName,
      Value<int?> dependsOnJobId,
      Value<String?> localPhotoPath,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
    });

class $$SyncJobsTableFilterComposer
    extends Composer<_$AppDatabase, $SyncJobsTable> {
  $$SyncJobsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get jobType => $composableBuilder(
    column: $table.jobType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get steps => $composableBuilder(
    column: $table.steps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get currentStepIndex => $composableBuilder(
    column: $table.currentStepIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resultDoctype => $composableBuilder(
    column: $table.resultDoctype,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resultName => $composableBuilder(
    column: $table.resultName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dependsOnJobId => $composableBuilder(
    column: $table.dependsOnJobId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPhotoPath => $composableBuilder(
    column: $table.localPhotoPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncJobsTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncJobsTable> {
  $$SyncJobsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get jobType => $composableBuilder(
    column: $table.jobType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get steps => $composableBuilder(
    column: $table.steps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get currentStepIndex => $composableBuilder(
    column: $table.currentStepIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resultDoctype => $composableBuilder(
    column: $table.resultDoctype,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resultName => $composableBuilder(
    column: $table.resultName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dependsOnJobId => $composableBuilder(
    column: $table.dependsOnJobId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPhotoPath => $composableBuilder(
    column: $table.localPhotoPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncJobsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncJobsTable> {
  $$SyncJobsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get jobType =>
      $composableBuilder(column: $table.jobType, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<String> get steps =>
      $composableBuilder(column: $table.steps, builder: (column) => column);

  GeneratedColumn<int> get currentStepIndex => $composableBuilder(
    column: $table.currentStepIndex,
    builder: (column) => column,
  );

  GeneratedColumn<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<String> get resultDoctype => $composableBuilder(
    column: $table.resultDoctype,
    builder: (column) => column,
  );

  GeneratedColumn<String> get resultName => $composableBuilder(
    column: $table.resultName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get dependsOnJobId => $composableBuilder(
    column: $table.dependsOnJobId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get localPhotoPath => $composableBuilder(
    column: $table.localPhotoPath,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SyncJobsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncJobsTable,
          SyncJob,
          $$SyncJobsTableFilterComposer,
          $$SyncJobsTableOrderingComposer,
          $$SyncJobsTableAnnotationComposer,
          $$SyncJobsTableCreateCompanionBuilder,
          $$SyncJobsTableUpdateCompanionBuilder,
          (SyncJob, BaseReferences<_$AppDatabase, $SyncJobsTable, SyncJob>),
          SyncJob,
          PrefetchHooks Function()
        > {
  $$SyncJobsTableTableManager(_$AppDatabase db, $SyncJobsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncJobsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncJobsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncJobsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> jobType = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<String?> steps = const Value.absent(),
                Value<int> currentStepIndex = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<String?> resultDoctype = const Value.absent(),
                Value<String?> resultName = const Value.absent(),
                Value<int?> dependsOnJobId = const Value.absent(),
                Value<String?> localPhotoPath = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => SyncJobsCompanion(
                id: id,
                jobType: jobType,
                status: status,
                payload: payload,
                steps: steps,
                currentStepIndex: currentStepIndex,
                retryCount: retryCount,
                lastError: lastError,
                resultDoctype: resultDoctype,
                resultName: resultName,
                dependsOnJobId: dependsOnJobId,
                localPhotoPath: localPhotoPath,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String jobType,
                Value<String> status = const Value.absent(),
                required String payload,
                Value<String?> steps = const Value.absent(),
                Value<int> currentStepIndex = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<String?> resultDoctype = const Value.absent(),
                Value<String?> resultName = const Value.absent(),
                Value<int?> dependsOnJobId = const Value.absent(),
                Value<String?> localPhotoPath = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => SyncJobsCompanion.insert(
                id: id,
                jobType: jobType,
                status: status,
                payload: payload,
                steps: steps,
                currentStepIndex: currentStepIndex,
                retryCount: retryCount,
                lastError: lastError,
                resultDoctype: resultDoctype,
                resultName: resultName,
                dependsOnJobId: dependsOnJobId,
                localPhotoPath: localPhotoPath,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncJobsTable, SyncJob>(table),
                  BaseReferences<_$AppDatabase, $SyncJobsTable, SyncJob>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncJobsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncJobsTable,
      SyncJob,
      $$SyncJobsTableFilterComposer,
      $$SyncJobsTableOrderingComposer,
      $$SyncJobsTableAnnotationComposer,
      $$SyncJobsTableCreateCompanionBuilder,
      $$SyncJobsTableUpdateCompanionBuilder,
      (SyncJob, BaseReferences<_$AppDatabase, $SyncJobsTable, SyncJob>),
      SyncJob,
      PrefetchHooks Function()
    >;
typedef $$ReferenceCacheTableCreateCompanionBuilder =
    ReferenceCacheCompanion Function({
      required String doctype,
      required String name,
      required String dataJson,
      required DateTime cachedAt,
      Value<int> rowid,
    });
typedef $$ReferenceCacheTableUpdateCompanionBuilder =
    ReferenceCacheCompanion Function({
      Value<String> doctype,
      Value<String> name,
      Value<String> dataJson,
      Value<DateTime> cachedAt,
      Value<int> rowid,
    });

class $$ReferenceCacheTableFilterComposer
    extends Composer<_$AppDatabase, $ReferenceCacheTable> {
  $$ReferenceCacheTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get doctype => $composableBuilder(
    column: $table.doctype,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReferenceCacheTableOrderingComposer
    extends Composer<_$AppDatabase, $ReferenceCacheTable> {
  $$ReferenceCacheTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get doctype => $composableBuilder(
    column: $table.doctype,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReferenceCacheTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReferenceCacheTable> {
  $$ReferenceCacheTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get doctype =>
      $composableBuilder(column: $table.doctype, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get dataJson =>
      $composableBuilder(column: $table.dataJson, builder: (column) => column);

  GeneratedColumn<DateTime> get cachedAt =>
      $composableBuilder(column: $table.cachedAt, builder: (column) => column);
}

class $$ReferenceCacheTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ReferenceCacheTable,
          ReferenceCacheData,
          $$ReferenceCacheTableFilterComposer,
          $$ReferenceCacheTableOrderingComposer,
          $$ReferenceCacheTableAnnotationComposer,
          $$ReferenceCacheTableCreateCompanionBuilder,
          $$ReferenceCacheTableUpdateCompanionBuilder,
          (
            ReferenceCacheData,
            BaseReferences<
              _$AppDatabase,
              $ReferenceCacheTable,
              ReferenceCacheData
            >,
          ),
          ReferenceCacheData,
          PrefetchHooks Function()
        > {
  $$ReferenceCacheTableTableManager(
    _$AppDatabase db,
    $ReferenceCacheTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReferenceCacheTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReferenceCacheTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReferenceCacheTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> doctype = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> dataJson = const Value.absent(),
                Value<DateTime> cachedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReferenceCacheCompanion(
                doctype: doctype,
                name: name,
                dataJson: dataJson,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String doctype,
                required String name,
                required String dataJson,
                required DateTime cachedAt,
                Value<int> rowid = const Value.absent(),
              }) => ReferenceCacheCompanion.insert(
                doctype: doctype,
                name: name,
                dataJson: dataJson,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReferenceCacheTable, ReferenceCacheData>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ReferenceCacheTable,
                    ReferenceCacheData
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReferenceCacheTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ReferenceCacheTable,
      ReferenceCacheData,
      $$ReferenceCacheTableFilterComposer,
      $$ReferenceCacheTableOrderingComposer,
      $$ReferenceCacheTableAnnotationComposer,
      $$ReferenceCacheTableCreateCompanionBuilder,
      $$ReferenceCacheTableUpdateCompanionBuilder,
      (
        ReferenceCacheData,
        BaseReferences<_$AppDatabase, $ReferenceCacheTable, ReferenceCacheData>,
      ),
      ReferenceCacheData,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SyncJobsTableTableManager get syncJobs =>
      $$SyncJobsTableTableManager(_db, _db.syncJobs);
  $$ReferenceCacheTableTableManager get referenceCache =>
      $$ReferenceCacheTableTableManager(_db, _db.referenceCache);
}
