import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:postgres/postgres.dart' show ServerException;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/core/services/workspace_store.dart';
import 'package:termora/features/database/data/connection_store.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/data/postgres_service.dart'
    show PostgresService;
import 'package:termora/features/database/data/db_metrics_service.dart';
import 'package:termora/features/database/data/db_transfer_service.dart';
import 'package:termora/features/database/data/db_transfer_task_store.dart';
import 'package:termora/features/database/domain/db_metrics.dart';
import 'package:termora/features/database/domain/db_transfer_task.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/core/l10n/app_l10n.dart';

// ----------------------------------------------------------------------
// 已保存的连接列表
// ----------------------------------------------------------------------

class DbConnectionsController extends Notifier<List<DbConnectionConfig>> {
  @override
  List<DbConnectionConfig> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    state = await DbConnectionStore.load();
  }

  /// 新增或更新(按 id 匹配)
  Future<void> upsert(DbConnectionConfig config) async {
    final index = state.indexWhere((c) => c.id == config.id);
    if (index < 0) {
      state = [...state, config];
    } else {
      state = [
        for (final c in state)
          if (c.id == config.id) config else c,
      ];
    }
    await DbConnectionStore.save(state);
  }

  Future<void> remove(String id) async {
    state = [
      for (final c in state)
        if (c.id != id) c,
    ];
    await DbConnectionStore.save(state);
    // 清掉该连接的工作区快照;若是上次活动连接则取消自动重连
    await WorkspaceStore.clearWorkspace(id);
    if (await WorkspaceStore.loadLastConnection() == id) {
      await WorkspaceStore.clearLastConnection();
    }
  }
}

final dbConnectionsProvider =
    NotifierProvider<DbConnectionsController, List<DbConnectionConfig>>(
      DbConnectionsController.new,
    );

// ----------------------------------------------------------------------
// 活动会话(单连接,多表 Tab 工作区)
// ----------------------------------------------------------------------

enum DbSessionStatus { disconnected, connecting, connected }

/// 一个打开的表 Tab(数据浏览 + 结构)
class DbTableTab {
  DbTableTab({
    required this.schema,
    required this.table,
    this.isView = false,
    this.loading = false,
    this.output,
    this.error,
    this.page = 0,
    this.hasMore = false,
    this.sortColumn,
    this.sortAscending = true,
    this.filter = '',
    this.columnFilters = const [],
    this.totalRows,
    this.editContext,
    DbEditSession? edits,
    this.saving = false,
    this.structure,
    this.structureLoading = false,
    this.structureError,
  }) : edits = edits ?? _emptyEdits;

  static final DbEditSession _emptyEdits = DbEditSession();

  final String schema;
  final String table;
  final bool isView;

  final bool loading;
  final DbQueryOutput? output;
  final String? error;
  final int page;
  final bool hasMore;

  /// 服务端排序列(null = 自然顺序)
  final String? sortColumn;
  final bool sortAscending;

  /// 全行 ILIKE 过滤
  final String filter;

  /// 列级过滤条件(dbeaver 列过滤)
  final List<DbColumnFilter> columnFilters;

  /// count(*) 总行数(异步统计,null = 统计中)
  final int? totalRows;

  /// 编辑上下文(有完整主键时可编辑)
  final DbEditContext? editContext;

  /// 累积编辑缓冲
  final DbEditSession edits;

  /// 正在批量提交
  final bool saving;

  final DbTableStructure? structure;
  final bool structureLoading;
  final String? structureError;

  bool get editable => editContext?.editable ?? false;

  String get qualifiedName => '$schema.$table';

  DbTableTab copyWith({
    bool? loading,
    DbQueryOutput? output,
    String? error,
    int? page,
    bool? hasMore,
    String? sortColumn,
    bool? sortAscending,
    String? filter,
    List<DbColumnFilter>? columnFilters,
    int? totalRows,
    DbEditContext? editContext,
    DbEditSession? edits,
    bool? saving,
    DbTableStructure? structure,
    bool? structureLoading,
    String? structureError,
    bool clearError = false,
    bool clearSort = false,
    bool clearTotal = false,
  }) {
    return DbTableTab(
      schema: schema,
      table: table,
      isView: isView,
      loading: loading ?? this.loading,
      output: output ?? this.output,
      error: clearError ? null : (error ?? this.error),
      page: page ?? this.page,
      hasMore: hasMore ?? this.hasMore,
      sortColumn: clearSort ? null : (sortColumn ?? this.sortColumn),
      sortAscending: sortAscending ?? this.sortAscending,
      filter: filter ?? this.filter,
      columnFilters: columnFilters ?? this.columnFilters,
      totalRows: clearTotal ? null : (totalRows ?? this.totalRows),
      editContext: editContext ?? this.editContext,
      edits: edits ?? this.edits,
      saving: saving ?? this.saving,
      structure: structure ?? this.structure,
      structureLoading: structureLoading ?? this.structureLoading,
      structureError: structureError ?? this.structureError,
    );
  }
}

/// SQL 编辑器执行状态
class DbSqlState {
  DbSqlState({
    this.running = false,
    this.output,
    this.error,
    this.editContext,
    DbEditSession? edits,
    this.saving = false,
    this.baseQuery,
    this.hasMore = false,
    this.loadingMore = false,
  }) : edits = edits ?? DbEditSession();

  final bool running;
  final DbQueryOutput? output;
  final String? error;

  /// 查询结果的编辑上下文(单表来源 + 完整主键时结果可直接编辑)
  final DbEditContext? editContext;

  /// 累积编辑缓冲
  final DbEditSession edits;
  final bool saving;

  /// 可分页的原始 SELECT(自动分页时保存,供"加载更多"续拉);null=不分页
  final String? baseQuery;

  /// 是否还有下一页(自动分页时有效)
  final bool hasMore;

  /// 正在加载下一页(下滑触发,底部转圈而非整块 spinner)
  final bool loadingMore;

  bool get editable => editContext?.editable ?? false;

  DbSqlState copyWith({
    bool? running,
    DbQueryOutput? output,
    String? error,
    DbEditContext? editContext,
    DbEditSession? edits,
    bool? saving,
    String? baseQuery,
    bool? hasMore,
    bool? loadingMore,
  }) {
    return DbSqlState(
      running: running ?? this.running,
      output: output ?? this.output,
      error: error ?? this.error,
      editContext: editContext ?? this.editContext,
      edits: edits ?? this.edits,
      saving: saving ?? this.saving,
      baseQuery: baseQuery ?? this.baseQuery,
      hasMore: hasMore ?? this.hasMore,
      loadingMore: loadingMore ?? this.loadingMore,
    );
  }
}

/// SQL 编辑器所在的固定 Tab 下标
const int kSqlTabIndex = -1;

/// 概览仪表盘所在的固定 Tab 下标(连接后默认展示)
const int kOverviewTabIndex = -2;

class DbSessionState {
  DbSessionState({
    this.status = DbSessionStatus.disconnected,
    this.config,
    this.connectError,
    this.serverVersion,
    this.schemas = const [],
    this.tables = const {},
    this.loadingSchemas = const {},
    this.tabs = const [],
    this.activeTab = kOverviewTabIndex,
    DbSqlState? sql,
  }) : sql = sql ?? DbSqlState();

  final DbSessionStatus status;
  final DbConnectionConfig? config;
  final String? connectError;
  final String? serverVersion;
  final List<String> schemas;

  /// schema → 已加载的表列表(懒加载)
  final Map<String, List<DbTableInfo>> tables;
  final Set<String> loadingSchemas;

  /// 打开的表 Tab 列表
  final List<DbTableTab> tabs;

  /// 活动 Tab:kSqlTabIndex 表示 SQL 编辑器,>=0 为 tabs 下标
  final int activeTab;

  final DbSqlState sql;

  DbTableTab? get activeTableTab =>
      activeTab >= 0 && activeTab < tabs.length ? tabs[activeTab] : null;

  DbSessionState copyWith({
    DbSessionStatus? status,
    DbConnectionConfig? config,
    String? connectError,
    String? serverVersion,
    List<String>? schemas,
    Map<String, List<DbTableInfo>>? tables,
    Set<String>? loadingSchemas,
    List<DbTableTab>? tabs,
    int? activeTab,
    DbSqlState? sql,
    bool clearConnectError = false,
  }) {
    return DbSessionState(
      status: status ?? this.status,
      config: config ?? this.config,
      connectError: clearConnectError
          ? null
          : (connectError ?? this.connectError),
      serverVersion: serverVersion ?? this.serverVersion,
      schemas: schemas ?? this.schemas,
      tables: tables ?? this.tables,
      loadingSchemas: loadingSchemas ?? this.loadingSchemas,
      tabs: tabs ?? this.tabs,
      activeTab: activeTab ?? this.activeTab,
      sql: sql ?? this.sql,
    );
  }
}

class DbSessionsState {
  DbSessionsState({
    this.sessions = const {},
    this.activeId,
  });

  final Map<String, DbSessionState> sessions;
  final String? activeId;

  DbSessionState sessionFor(String? id) =>
      (id != null ? sessions[id] : null) ?? DbSessionState();

  DbSessionState get activeSession => sessionFor(activeId);

  DbSessionStatus get status => activeSession.status;
  DbConnectionConfig? get config => activeSession.config;
  String? get connectError => activeSession.connectError;
  String? get serverVersion => activeSession.serverVersion;
  List<String> get schemas => activeSession.schemas;
  Map<String, List<DbTableInfo>> get tables => activeSession.tables;
  Set<String> get loadingSchemas => activeSession.loadingSchemas;
  List<DbTableTab> get tabs => activeSession.tabs;
  int get activeTab => activeSession.activeTab;
  DbSqlState get sql => activeSession.sql;
  DbTableTab? get activeTableTab => activeSession.activeTableTab;

  DbSessionsState copyWith({
    Map<String, DbSessionState>? sessions,
    String? activeId,
    bool clearActiveId = false,
  }) {
    return DbSessionsState(
      sessions: sessions ?? this.sessions,
      activeId: clearActiveId ? null : (activeId ?? this.activeId),
    );
  }
}

class DbSessionController extends Notifier<DbSessionsState> {
  final Map<String, DbConnection> _conns = {};
  final Map<String, int> _generations = {};

  /// 正在恢复工作区(期间不回写快照,避免抖动)
  bool _restoring = false;

  @override
  DbSessionsState build() {
    ref.onDispose(() {
      for (final conn in _conns.values) {
        try {
          conn.close();
        } catch (_) {}
      }
    });
    return DbSessionsState();
  }

  /// 判断是否为「连接已断」类错误 —— 这类错误意味着查询根本没发到服务器,
  /// 因此重连后重试是安全的(不会重复执行已提交的语句)。
  static bool _isConnectionDown(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('connection is not open') ||
        s.contains('connection is closed') ||
        s.contains('connection closed') ||
        s.contains('connection is already closed') ||
        s.contains('socket has been closed');
  }

  /// 用会话配置就地重连,替换缓存连接。失败返回 null(保持原状)。
  Future<DbConnection?> _reopen(String id) async {
    final config = state.sessionFor(id).config;
    if (config == null) return null;
    final old = _conns[id];
    try {
      final fresh = await DbService.open(config);
      _conns[id] = fresh;
      if (old != null && !identical(old, fresh)) {
        try {
          await old.close();
        } catch (_) {}
      }
      return fresh;
    } catch (_) {
      return null;
    }
  }

  /// 在连接上执行一次数据库操作,自愈断连:
  /// ① 用前自检 [DbConnection.isOpen],已断则先重连(断网/休眠后 socket 死掉);
  /// ② 万一执行时才发现连接未打开(查询没发出),重连后再安全重试一次。
  /// 无可用连接或重连失败则抛 StateError,由调用方按错误渲染。
  Future<T> _exec<T>(String id, Future<T> Function(DbConnection conn) op) async {
    var conn = _conns[id];
    if (conn == null) throw StateError(tr('连接不可用'));
    if (!conn.isOpen) {
      conn = await _reopen(id) ?? (throw StateError(tr('连接已断开,自动重连失败')));
    }
    try {
      return await op(conn);
    } catch (e) {
      if (!_isConnectionDown(e)) rethrow;
      final fresh = await _reopen(id);
      if (fresh == null) throw StateError(tr('连接已断开,自动重连失败'));
      return await op(fresh);
    }
  }

  void _updateSession(
    String id,
    DbSessionState Function(DbSessionState current) updater,
  ) {
    final current = state.sessionFor(id);
    final updated = updater(current);
    state = state.copyWith(sessions: {...state.sessions, id: updated});
  }

  void selectConnection(String id) {
    if (state.activeId == id) return;
    state = state.copyWith(activeId: id);
  }

  // ══════════════ 连接 ══════════════

  Future<void> connect(
    DbConnectionConfig config, {
    bool forceReconnect = false,
  }) async {
    final id = config.id;
    final existing = state.sessionFor(id);
    if (!forceReconnect && existing.status == DbSessionStatus.connected) {
      selectConnection(id);
      return;
    }

    // 只断开当前配置旧连接，不影响其它任何数据库的连接
    await disconnect(id: id);

    final generation = (_generations[id] ?? 0) + 1;
    _generations[id] = generation;

    state = state.copyWith(
      activeId: id,
      sessions: {
        ...state.sessions,
        id: DbSessionState(status: DbSessionStatus.connecting, config: config),
      },
    );

    try {
      final conn = await DbService.open(config);
      if (generation != _generations[id]) {
        await conn.close();
        return;
      }
      _conns[id] = conn;

      String? version;
      List<String> schemas = const [];
      try {
        version = await DbService.serverVersion(conn);
        schemas = await DbService.listSchemas(conn);
      } catch (e) {
        debugPrint(tr2('[DB] 加载元数据失败({0}): {1}', [id, e]));
      }
      if (generation != _generations[id]) return;

      _updateSession(
        id,
        (s) => s.copyWith(
          status: DbSessionStatus.connected,
          config: config,
          serverVersion: version,
          schemas: schemas,
        ),
      );

      WorkspaceStore.saveLastConnection(config.id);
      await _restoreWorkspace(config.id, generation);
    } catch (e) {
      if (generation != _generations[id]) return;
      _updateSession(
        id,
        (s) => s.copyWith(
          status: DbSessionStatus.disconnected,
          config: config,
          connectError: _friendlyError(e),
        ),
      );
    }
  }

  /// 断开特定 ID 连接（不影响其它已连接会话）。[userInitiated] 为 true 时若为当前连接则清除自动重连
  Future<void> disconnect({String? id, bool userInitiated = false}) async {
    final targetId = id ?? state.activeId;
    if (targetId == null) return;

    if (userInitiated && targetId == state.activeId) {
      WorkspaceStore.clearLastConnection();
    }
    _generations[targetId] = (_generations[targetId] ?? 0) + 1;
    final conn = _conns.remove(targetId);
    if (conn != null) {
      try {
        await conn.close();
      } catch (_) {}
    }
    final newSessions = {...state.sessions}..remove(targetId);
    String? newActiveId = state.activeId;
    if (newActiveId == targetId) {
      newActiveId = newSessions.keys.lastOrNull;
    }
    state = state.copyWith(
      sessions: newSessions,
      activeId: newActiveId,
      clearActiveId: newActiveId == null,
    );
  }

  /// 启动时自动重连上次活动连接(best-effort;失败静默)
  Future<void> autoReconnect(List<DbConnectionConfig> connections) async {
    final lastId = await WorkspaceStore.loadLastConnection();
    if (lastId == null) return;
    final existing = state.sessionFor(lastId);
    if (existing.status != DbSessionStatus.disconnected) return;
    final config = connections.where((c) => c.id == lastId).firstOrNull;
    if (config == null) return;
    await connect(config);
  }

  /// 懒加载 schema 下的表
  Future<void> loadTables(
    String schema, {
    String? connectionId,
    bool force = false,
  }) async {
    final targetId = connectionId ?? state.activeId;
    if (targetId == null) return;
    if (_conns[targetId] == null) return;
    final session = state.sessionFor(targetId);
    if (!force && session.tables.containsKey(schema)) return;
    if (session.loadingSchemas.contains(schema)) return;

    final generation = _generations[targetId];
    _updateSession(
      targetId,
      (s) => s.copyWith(loadingSchemas: {...s.loadingSchemas, schema}),
    );
    try {
      final tables = await _exec(
        targetId,
        (conn) => DbService.listTables(conn, schema),
      );
      if (generation != _generations[targetId]) return;
      _updateSession(
        targetId,
        (s) => s.copyWith(
          tables: {...s.tables, schema: tables},
          loadingSchemas: {...s.loadingSchemas}..remove(schema),
        ),
      );
    } catch (e) {
      if (generation != _generations[targetId]) return;
      _updateSession(
        targetId,
        (s) => s.copyWith(
          loadingSchemas: {...s.loadingSchemas}..remove(schema),
        ),
      );
      debugPrint(tr2('[DB] 加载表列表失败({0}): {1}', [schema, e]));
    }
  }

  // ══════════════ Tab 管理 ══════════════

  /// 打开表:已有 Tab 则激活,否则新建 Tab 并加载第一页
  Future<void> openTable(
    String schema,
    String table, {
    bool isView = false,
    String? connectionId,
  }) async {
    final targetId = connectionId ?? state.activeId;
    if (targetId == null) return;
    selectConnection(targetId);

    final session = state.sessionFor(targetId);
    final existing = session.tabs.indexWhere(
      (t) => t.schema == schema && t.table == table,
    );
    if (existing >= 0) {
      _updateSession(targetId, (s) => s.copyWith(activeTab: existing));
      return;
    }

    final tab = DbTableTab(schema: schema, table: table, isView: isView);
    final newIndex = session.tabs.length;
    _updateSession(
      targetId,
      (s) => s.copyWith(tabs: [...s.tabs, tab], activeTab: newIndex),
    );
    _saveWorkspace(targetId);
    await _loadTab(targetId, newIndex);
    _loadStructure(targetId, newIndex);
    _refreshCount(targetId, newIndex);
  }

  void activateTab(int index, {String? connectionId}) {
    final targetId = connectionId ?? state.activeId;
    if (targetId == null) return;
    final session = state.sessionFor(targetId);
    if (index == kSqlTabIndex ||
        index == kOverviewTabIndex ||
        (index >= 0 && index < session.tabs.length)) {
      _updateSession(targetId, (s) => s.copyWith(activeTab: index));
      _saveWorkspace(targetId);
    }
  }

  void closeTab(int index, {String? connectionId}) {
    final targetId = connectionId ?? state.activeId;
    if (targetId == null) return;
    final session = state.sessionFor(targetId);
    if (index < 0 || index >= session.tabs.length) return;
    final tabs = [...session.tabs]..removeAt(index);
    var active = session.activeTab;
    if (active == index) {
      active = tabs.isEmpty ? kSqlTabIndex : index.clamp(0, tabs.length - 1);
    } else if (active > index) {
      active -= 1;
    }
    _updateSession(targetId, (s) => s.copyWith(tabs: tabs, activeTab: active));
    _saveWorkspace(targetId);
  }

  // ══════════════ 工作区恢复(会话持久化)══════════════

  Future<void> _restoreWorkspace(String connectionId, int generation) async {
    final snapshot = await WorkspaceStore.loadWorkspace(connectionId);
    if (snapshot.openTables.isEmpty) return;
    if (generation != _generations[connectionId]) return;

    _restoring = true;
    try {
      for (final t in snapshot.openTables) {
        if (generation != _generations[connectionId]) return;
        await openTable(
          t.schema,
          t.table,
          isView: t.isView,
          connectionId: connectionId,
        );
      }
      if (generation != _generations[connectionId]) return;
      final key = snapshot.activeTableKey;
      final session = state.sessionFor(connectionId);
      if (key == null) {
        _updateSession(
          connectionId,
          (s) => s.copyWith(activeTab: kOverviewTabIndex),
        );
      } else {
        final idx = session.tabs.indexWhere((t) => t.qualifiedName == key);
        _updateSession(
          connectionId,
          (s) => s.copyWith(activeTab: idx >= 0 ? idx : kOverviewTabIndex),
        );
      }
    } finally {
      _restoring = false;
    }
    _saveWorkspace(connectionId);
  }

  void _saveWorkspace([String? connectionId]) {
    if (_restoring) return;
    final connId = connectionId ?? state.activeId;
    if (connId == null) return;
    final session = state.sessionFor(connId);
    if (session.status != DbSessionStatus.connected) return;
    final active = session.activeTableTab;
    WorkspaceStore.saveWorkspace(
      connId,
      DbWorkspaceSnapshot(
        openTables: [
          for (final t in session.tabs)
            OpenTableSnapshot(
              schema: t.schema,
              table: t.table,
              isView: t.isView,
            ),
        ],
        activeTableKey: active?.qualifiedName,
      ),
    );
  }

  DbTableTab? _tabAt(String id, int index) {
    final session = state.sessionFor(id);
    return index >= 0 && index < session.tabs.length
        ? session.tabs[index]
        : null;
  }

  void _replaceTab(
    String id,
    String qualifiedName,
    DbTableTab Function(DbTableTab) fn,
  ) {
    final session = state.sessionFor(id);
    final index = session.tabs.indexWhere(
      (t) => t.qualifiedName == qualifiedName,
    );
    if (index < 0) return;
    final tabs = [...session.tabs];
    tabs[index] = fn(tabs[index]);
    _updateSession(id, (s) => s.copyWith(tabs: tabs));
  }

  Future<void> _loadTab(String id, int index) async {
    final tab = _tabAt(id, index);
    if (_conns[id] == null || tab == null) return;
    final key = tab.qualifiedName;

    final generation = _generations[id];
    _replaceTab(id, key, (t) => t.copyWith(loading: true, clearError: true));

    try {
      final (output, hasMore, editContext) = await _exec(
        id,
        (conn) => DbService.fetchTableData(
          conn,
          tab.schema,
          tab.table,
          page: tab.page,
          orderBy: tab.sortColumn,
          ascending: tab.sortAscending,
          filter: tab.filter,
          columnFilters: tab.columnFilters,
        ),
      );
      if (generation != _generations[id]) return;
      _replaceTab(
        id,
        key,
        (t) => t.copyWith(
          loading: false,
          output: output,
          hasMore: hasMore,
          editContext: editContext,
          clearError: true,
        ),
      );
    } catch (e) {
      if (generation != _generations[id]) return;
      _replaceTab(
        id,
        key,
        (t) => t.copyWith(loading: false, error: _friendlyError(e)),
      );
    }
  }

  Future<void> _refreshCount(String id, int index) async {
    final tab = _tabAt(id, index);
    if (_conns[id] == null || tab == null) return;
    final key = tab.qualifiedName;
    final generation = _generations[id];
    try {
      final total = await _exec(
        id,
        (conn) => DbService.countRows(
          conn,
          tab.schema,
          tab.table,
          filter: tab.filter,
          columnFilters: tab.columnFilters,
        ),
      );
      if (generation != _generations[id]) return;
      _replaceTab(id, key, (t) => t.copyWith(totalRows: total));
    } catch (_) {}
  }

  Future<void> goToPage(int index, int page) async {
    final id = state.activeId;
    if (id == null) return;
    final tab = _tabAt(id, index);
    if (tab == null) return;
    _replaceTab(id, tab.qualifiedName, (t) => t.copyWith(page: page));
    await _loadTab(id, index);
  }

  Future<void> sortBy(int index, String column) async {
    final id = state.activeId;
    if (id == null) return;
    final tab = _tabAt(id, index);
    if (tab == null) return;
    final ascending = tab.sortColumn == column ? !tab.sortAscending : true;
    _replaceTab(
      id,
      tab.qualifiedName,
      (t) => t.copyWith(sortColumn: column, sortAscending: ascending, page: 0),
    );
    await _loadTab(id, index);
  }

  Future<void> setFilter(int index, String filter) async {
    final id = state.activeId;
    if (id == null) return;
    final tab = _tabAt(id, index);
    if (tab == null || tab.filter == filter) return;
    _replaceTab(
      id,
      tab.qualifiedName,
      (t) => t.copyWith(filter: filter, page: 0, clearTotal: true),
    );
    await _loadTab(id, index);
    _refreshCount(id, index);
  }

  Future<void> setColumnFilters(int index, List<DbColumnFilter> filters) async {
    final id = state.activeId;
    if (id == null) return;
    final tab = _tabAt(id, index);
    if (tab == null) return;
    _replaceTab(
      id,
      tab.qualifiedName,
      (t) => t.copyWith(columnFilters: filters, page: 0, clearTotal: true),
    );
    await _loadTab(id, index);
    _refreshCount(id, index);
  }

  Future<void> refreshTab(int index) async {
    final id = state.activeId;
    if (id == null) return;
    await _loadTab(id, index);
    _refreshCount(id, index);
  }

  Future<void> _loadStructure(
    String id,
    int index, {
    bool force = false,
  }) async {
    final tab = _tabAt(id, index);
    if (_conns[id] == null || tab == null) return;
    if (!force && (tab.structure != null || tab.structureLoading)) return;
    final key = tab.qualifiedName;

    final generation = _generations[id];
    _replaceTab(id, key, (t) => t.copyWith(structureLoading: true));
    try {
      final structure = await _exec(
        id,
        (conn) => DbService.fetchTableStructure(conn, tab.schema, tab.table),
      );
      if (generation != _generations[id]) return;
      _replaceTab(
        id,
        key,
        (t) => t.copyWith(structure: structure, structureLoading: false),
      );
    } catch (e) {
      if (generation != _generations[id]) return;
      _replaceTab(
        id,
        key,
        (t) => t.copyWith(
          structureLoading: false,
          structureError: _friendlyError(e),
        ),
      );
    }
  }

  Future<void> loadStructure(int index, {bool force = false}) async {
    final id = state.activeId;
    if (id != null) {
      await _loadStructure(id, index, force: force);
    }
  }

  // ══════════════ 累积编辑(dbeaver 式:攒改动,统一提交/回滚)══════════════

  void editTabCell(
    int tabIndex, {
    required int rowIndex,
    required int columnIndex,
    Object? newValue,
  }) {
    final id = state.activeId;
    if (id == null) return;
    final tab = _tabAt(id, tabIndex);
    if (tab == null || tab.output == null) return;
    _replaceTab(
      id,
      tab.qualifiedName,
      (t) => t.copyWith(
        edits: _applyCellEdit(
          t.edits,
          t.output!.rows.length,
          rowIndex,
          columnIndex,
          newValue,
        ),
      ),
    );
  }

  void editSqlCell({
    required int rowIndex,
    required int columnIndex,
    Object? newValue,
  }) {
    final id = state.activeId;
    if (id == null) return;
    final session = state.activeSession;
    final output = session.sql.output;
    if (output == null) return;
    _updateSession(
      id,
      (s) => s.copyWith(
        sql: s.sql.copyWith(
          edits: _applyCellEdit(
            s.sql.edits,
            output.rows.length,
            rowIndex,
            columnIndex,
            newValue,
          ),
        ),
      ),
    );
  }

  DbEditSession _applyCellEdit(
    DbEditSession edits,
    int originalRowCount,
    int rowIndex,
    int columnIndex,
    Object? newValue,
  ) {
    final next = edits.clone();
    if (rowIndex >= originalRowCount) {
      final addIndex = rowIndex - originalRowCount;
      if (addIndex >= 0 && addIndex < next.addedRows.length) {
        next.addedRows[addIndex][columnIndex] = newValue;
      }
    } else {
      (next.editedCells[rowIndex] ??= {})[columnIndex] = newValue;
    }
    return next;
  }

  void addRow(int tabIndex) {
    final id = state.activeId;
    if (id == null) return;
    final tab = _tabAt(id, tabIndex);
    final output = tab?.output;
    if (tab == null || output == null) return;
    final next = tab.edits.clone();
    next.addedRows.add(
      List.filled(output.columns.length, DbEditSession.unsetValue),
    );
    _replaceTab(id, tab.qualifiedName, (t) => t.copyWith(edits: next));
  }

  void addSqlRow() {
    final id = state.activeId;
    if (id == null) return;
    final session = state.activeSession;
    final output = session.sql.output;
    if (output == null) return;
    final next = session.sql.edits.clone();
    next.addedRows.add(
      List.filled(output.columns.length, DbEditSession.unsetValue),
    );
    _updateSession(id, (s) => s.copyWith(sql: s.sql.copyWith(edits: next)));
  }

  void toggleDeleteRow(int tabIndex, int rowIndex) {
    final id = state.activeId;
    if (id == null) return;
    final tab = _tabAt(id, tabIndex);
    final output = tab?.output;
    if (tab == null || output == null) return;
    _replaceTab(
      id,
      tab.qualifiedName,
      (t) => t.copyWith(
        edits: _applyToggleDelete(t.edits, output.rows.length, rowIndex),
      ),
    );
  }

  void toggleDeleteSqlRow(int rowIndex) {
    final id = state.activeId;
    if (id == null) return;
    final session = state.activeSession;
    final output = session.sql.output;
    if (output == null) return;
    _updateSession(
      id,
      (s) => s.copyWith(
        sql: s.sql.copyWith(
          edits: _applyToggleDelete(s.sql.edits, output.rows.length, rowIndex),
        ),
      ),
    );
  }

  DbEditSession _applyToggleDelete(
    DbEditSession edits,
    int originalRowCount,
    int rowIndex,
  ) {
    final next = edits.clone();
    if (rowIndex >= originalRowCount) {
      final addIndex = rowIndex - originalRowCount;
      if (addIndex >= 0 && addIndex < next.addedRows.length) {
        next.addedRows.removeAt(addIndex);
      }
    } else if (next.removedRows.contains(rowIndex)) {
      next.removedRows.remove(rowIndex);
    } else {
      next.removedRows.add(rowIndex);
    }
    return next;
  }

  void revertTab(int tabIndex) {
    final id = state.activeId;
    if (id == null) return;
    final tab = _tabAt(id, tabIndex);
    if (tab == null) return;
    _replaceTab(id, tab.qualifiedName, (t) => t.copyWith(edits: DbEditSession()));
  }

  void revertSql() {
    final id = state.activeId;
    if (id == null) return;
    _updateSession(
      id,
      (s) => s.copyWith(sql: s.sql.copyWith(edits: DbEditSession())),
    );
  }

  Future<String?> saveTab(int tabIndex) async {
    final id = state.activeId;
    if (id == null) return tr('未连接数据库');
    final tab = _tabAt(id, tabIndex);
    if (_conns[id] == null || tab == null) return tr('连接不可用');
    final output = tab.output;
    final context = tab.editContext;
    if (output == null || context == null || !context.editable) {
      return tr('该结果集没有完整主键,无法保存');
    }
    if (!tab.edits.isDirty) return null;

    _replaceTab(id, tab.qualifiedName, (t) => t.copyWith(saving: true));
    try {
      await _exec(
        id,
        (conn) => DbService.applyChanges(
          conn,
          context: context,
          output: output,
          session: tab.edits,
        ),
      );
      _replaceTab(
        id,
        tab.qualifiedName,
        (t) => t.copyWith(saving: false, edits: DbEditSession()),
      );
      await _loadTab(id, _indexOfTab(id, tab.qualifiedName));
      _refreshCount(id, _indexOfTab(id, tab.qualifiedName));
      return null;
    } catch (e) {
      _replaceTab(id, tab.qualifiedName, (t) => t.copyWith(saving: false));
      return _friendlyError(e);
    }
  }

  Future<String?> saveSql() async {
    final id = state.activeId;
    if (id == null) return tr('未连接数据库');
    final session = state.activeSession;
    final output = session.sql.output;
    final context = session.sql.editContext;
    if (_conns[id] == null) return tr('连接不可用');
    if (output == null || context == null || !context.editable) {
      return tr('该查询结果没有完整主键,无法保存');
    }
    if (!session.sql.edits.isDirty) return null;

    _updateSession(id, (s) => s.copyWith(sql: s.sql.copyWith(saving: true)));
    try {
      await _exec(
        id,
        (conn) => DbService.applyChanges(
          conn,
          context: context,
          output: output,
          session: session.sql.edits,
        ),
      );
      _updateSession(
        id,
        (s) => s.copyWith(
          sql: s.sql.copyWith(saving: false, edits: DbEditSession()),
        ),
      );
      return null;
    } catch (e) {
      _updateSession(
        id,
        (s) => s.copyWith(sql: s.sql.copyWith(saving: false)),
      );
      return _friendlyError(e);
    }
  }

  int _indexOfTab(String id, String qualifiedName) {
    final session = state.sessionFor(id);
    return session.tabs.indexWhere((t) => t.qualifiedName == qualifiedName);
  }

  // ══════════════ SQL 执行 ══════════════

  /// SQL 编辑器自动分页的每页行数
  static const int sqlPageSize = 200;

  /// 若 [sql] 是可安全自动分页的单条纯 SELECT,返回去掉结尾分号的原句;
  /// 否则 null(尊重用户自带 LIMIT、非 SELECT、多语句、FOR UPDATE 等一律不改)。
  static String? _paginatableSelect(String sql) {
    var s = sql.trim();
    if (s.endsWith(';')) s = s.substring(0, s.length - 1).trimRight();
    if (s.isEmpty) return null;
    // 仅单条语句(分号感知拆分,正确跳过字符串/注释里的分号)
    if (PostgresService.splitStatements(s).length != 1) return null;
    final lower = s.toLowerCase();
    if (!lower.startsWith('select')) return null; // 只碰纯 SELECT
    // 用户已自带 LIMIT / 有锁定子句 → 不动
    if (RegExp(r'\blimit\b').hasMatch(lower)) return null;
    if (RegExp(r'\bfor\s+(update|share|no\s+key|key\s+share)').hasMatch(lower)) {
      return null;
    }
    return s;
  }

  /// 从 [output] 取前 [keep] 行(自动分页时多取 1 行判有无下一页,这里裁掉)
  static DbQueryOutput _takeRows(DbQueryOutput output, int keep) {
    if (output.rows.length <= keep) return output;
    return DbQueryOutput(
      columns: output.columns,
      rows: output.rows.sublist(0, keep),
      affectedRows: keep,
      elapsed: output.elapsed,
    );
  }

  Future<void> runSql(String sql) async {
    final id = state.activeId;
    if (id == null) return;
    final trimmed = sql.trim();
    final session = state.sessionFor(id);
    if (_conns[id] == null || trimmed.isEmpty || session.sql.running) return;

    ref.read(dbSqlHistoryProvider.notifier).add(trimmed);

    // 纯 SELECT 自动分页:只拉第一页(pageSize+1 探测是否还有更多),
    // 避免 `SELECT * FROM 大表` 把全表拉回来直接超时。下滑再续拉。
    final base = _paginatableSelect(trimmed);
    final execSql = base == null
        ? trimmed
        : '$base\nLIMIT ${sqlPageSize + 1} OFFSET 0';

    final generation = _generations[id];
    _updateSession(
      id,
      (s) => s.copyWith(
        sql: DbSqlState(running: true, output: s.sql.output),
      ),
    );

    try {
      final (raw, editContext) = await _exec(
        id,
        (conn) => DbService.runSql(conn, execSql),
      );
      if (generation != _generations[id]) return;
      // 自动分页且真有结果集:探测下一页 + 裁掉多取的那一行
      final paginated = base != null && raw.hasRows;
      final hasMore = paginated && raw.rows.length > sqlPageSize;
      final output = hasMore ? _takeRows(raw, sqlPageSize) : raw;
      _updateSession(
        id,
        (s) => s.copyWith(
          sql: DbSqlState(
            output: output,
            editContext: editContext,
            baseQuery: paginated ? base : null,
            hasMore: hasMore,
          ),
        ),
      );
    } catch (e) {
      if (generation != _generations[id]) return;
      _updateSession(
        id,
        (s) => s.copyWith(
          sql: DbSqlState(error: _friendlyError(e), output: session.sql.output),
        ),
      );
    }
  }

  /// 加载 SQL 结果的下一页(下滑到底触发),把新行追加到现有结果。
  /// 追加不改动已有行下标,故编辑缓冲仍然有效。
  Future<void> loadMoreSql() async {
    final id = state.activeId;
    if (id == null) return;
    final s = state.sessionFor(id).sql;
    final base = s.baseQuery;
    final current = s.output;
    if (base == null ||
        current == null ||
        !s.hasMore ||
        s.loadingMore ||
        s.running ||
        _conns[id] == null) {
      return;
    }

    _updateSession(id, (st) => st.copyWith(sql: st.sql.copyWith(loadingMore: true)));
    final generation = _generations[id];
    final offset = current.rows.length;
    try {
      final (page, _) = await _exec(
        id,
        (conn) => DbService.runSql(
          conn,
          '$base\nLIMIT ${sqlPageSize + 1} OFFSET $offset',
        ),
      );
      if (generation != _generations[id]) return;
      final more = page.rows.length > sqlPageSize;
      final newRows = more ? page.rows.sublist(0, sqlPageSize) : page.rows;
      final merged = DbQueryOutput(
        columns: current.columns,
        rows: [...current.rows, ...newRows],
        affectedRows: current.rows.length + newRows.length,
        elapsed: current.elapsed,
      );
      _updateSession(
        id,
        (st) => st.copyWith(
          sql: st.sql.copyWith(
            output: merged,
            hasMore: more,
            loadingMore: false,
          ),
        ),
      );
    } catch (e) {
      if (generation != _generations[id]) return;
      // 续拉失败不毁掉已加载结果,仅停转圈(下次滑动可再试)
      _updateSession(
        id,
        (st) => st.copyWith(sql: st.sql.copyWith(loadingMore: false)),
      );
    }
  }

  static String _friendlyError(Object e) {
    if (e is ServerException) {
      final position = e.position != null ? tr2(' (位置 {0})', [e.position]) : '';
      return '${e.severity.name}: ${e.message}$position';
    }
    return e.toString();
  }
}

final dbSessionProvider =
    NotifierProvider<DbSessionController, DbSessionsState>(
      DbSessionController.new,
    );

// ----------------------------------------------------------------------
// SQL 查询历史(最近 50 条,去重置顶,持久化)
// ----------------------------------------------------------------------

class DbSqlHistoryController extends Notifier<List<String>> {
  static const _key = 'database.sql_history.v1';
  static const _maxEntries = 50;

  @override
  List<String> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getStringList(_key) ?? const [];
  }

  Future<void> add(String sql) async {
    final next = [sql, ...state.where((s) => s != sql)];
    state = next.length > _maxEntries ? next.sublist(0, _maxEntries) : next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, state);
  }

  Future<void> clear() async {
    state = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

final dbSqlHistoryProvider = NotifierProvider<DbSqlHistoryController, List<String>>(
  DbSqlHistoryController.new,
);

// ----------------------------------------------------------------------
// SQL 脚本变量(${name} 占位符的取值,持久化)
// ----------------------------------------------------------------------

class DbVariablesController extends Notifier<Map<String, String>> {
  static const _key = 'database.sql_variables.v1';

  @override
  Map<String, String> build() {
    _load();
    return const {};
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      state = decoded.map((k, v) => MapEntry(k, '$v'));
    } catch (_) {}
  }

  Future<void> setAll(Map<String, String> variables) async {
    state = Map.unmodifiable(variables);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(state));
  }

  Future<void> merge(Map<String, String> variables) async {
    await setAll({...state, ...variables});
  }
}

final dbVariablesProvider =
    NotifierProvider<DbVariablesController, Map<String, String>>(
      DbVariablesController.new,
    );

// ----------------------------------------------------------------------
// 保存的传输任务(导出/导入/迁移 + ETL + 调度)
// ----------------------------------------------------------------------

class DbTransferTasksController extends Notifier<List<DbTransferTask>> {
  @override
  List<DbTransferTask> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    state = await DbTransferTaskStore.load();
  }

  Future<void> upsert(DbTransferTask task) async {
    final index = state.indexWhere((t) => t.id == task.id);
    state = index < 0
        ? [...state, task]
        : [
            for (final t in state)
              if (t.id == task.id) task else t,
          ];
    await DbTransferTaskStore.save(state);
  }

  Future<void> remove(String id) async {
    state = [
      for (final t in state)
        if (t.id != id) t,
    ];
    await DbTransferTaskStore.save(state);
  }

  Future<void> recordRun(
    String id, {
    required bool ok,
    required String message,
    int? atMs,
  }) async {
    final at = atMs ?? DateTime.now().millisecondsSinceEpoch;
    state = [
      for (final t in state)
        if (t.id == id)
          t.copyWith(lastRunAtMs: at, lastRunOk: ok, lastRunMessage: message)
        else
          t,
    ];
    await DbTransferTaskStore.save(state);
  }

  /// 解析连接并执行任务;成功/失败都回写 lastRun。失败会 rethrow。
  Future<DbTransferSummary> run(
    DbTransferTask task, {
    DbTransferOnProgress? onProgress,
    DbTransferCancelled? isCancelled,
  }) async {
    final conns = ref.read(dbConnectionsProvider);
    final source = conns.where((c) => c.id == task.sourceConnId).firstOrNull;
    if (source == null) {
      await recordRun(task.id, ok: false, message: '源连接不存在(可能已删除)');
      throw StateError('源连接不存在(可能已删除)');
    }
    final target = task.targetConnId == null
        ? null
        : conns.where((c) => c.id == task.targetConnId).firstOrNull;
    if (task.mode == DbTransferMode.migrate && target == null) {
      await recordRun(task.id, ok: false, message: '目标连接不存在(可能已删除)');
      throw StateError('目标连接不存在(可能已删除)');
    }

    try {
      final summary = await DbTransferService.runTask(
        task,
        source: source,
        target: target,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      final message = task.mode == DbTransferMode.importScript
          ? '已执行 ${summary.statements} 条语句'
          : '${summary.tables} 张表 / ${summary.rows} 行';
      await recordRun(task.id, ok: true, message: message);
      return summary;
    } catch (e) {
      await recordRun(task.id, ok: false, message: '$e');
      rethrow;
    }
  }
}

final dbTransferTasksProvider =
    NotifierProvider<DbTransferTasksController, List<DbTransferTask>>(
      DbTransferTasksController.new,
    );

// ----------------------------------------------------------------------
// 数据库概览指标(按连接 id 懒加载,invalidate 刷新)
// ----------------------------------------------------------------------

final dbMetricsProvider = FutureProvider.autoDispose
    .family<DbMetrics, String>((ref, connectionId) async {
      final config = ref
          .watch(dbConnectionsProvider)
          .where((c) => c.id == connectionId)
          .firstOrNull;
      if (config == null) throw StateError('连接不存在');
      return DbMetricsService.load(config);
    });
