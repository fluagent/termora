import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:termora/app/shell/page_top_bar.dart';
import 'package:re_editor/re_editor.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/services/workspace_store.dart';
import 'package:termora/core/widgets/glass_menu.dart';
import 'package:termora/features/database/controller/database_providers.dart';
import 'package:termora/features/database/data/connection_store.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/features/database/domain/db_transfer_task.dart';
import 'package:termora/features/database/domain/sql_variables.dart';
import 'package:termora/features/database/view/widgets/column_filter_popup.dart';
import 'package:termora/features/database/view/widgets/connection_dialog.dart';
import 'package:termora/features/database/view/widgets/db_data_grid.dart';
import 'package:termora/features/database/view/widgets/db_overview_panel.dart';
import 'package:termora/features/database/view/widgets/export_dialog.dart';
import 'package:termora/features/database/view/widgets/sql_editor.dart';
import 'package:termora/features/database/view/widgets/table_structure_view.dart';
import 'package:termora/features/database/view/widgets/transfer_dialog.dart';
import 'package:termora/features/database/view/widgets/transfer_tasks_dialog.dart';
import 'package:termora/features/database/view/widgets/variables_dialog.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 数据库工具主页 — DBeaver 式布局:
/// 左侧连接导航树(连接 → schema → 表),右侧 Tab 工作区(SQL 编辑器 + 每表一个 Tab)
class DatabasePage extends ConsumerStatefulWidget {
  const DatabasePage({super.key});

  @override
  ConsumerState<DatabasePage> createState() => _DatabasePageState();
}

class _DatabasePageState extends ConsumerState<DatabasePage> {
  /// 数据浏览子页签: 0 = 数据, 1 = 结构
  int _tableTab = 0;
  final Set<String> _expandedSchemas = {};
  final Set<String> _collapsedConnections = {};
  final CodeLineEditingController _sqlController = CodeLineEditingController();
  final TextEditingController _filterController = TextEditingController();

  /// 过滤输入框当前展示的 Tab(切 Tab 时同步内容)
  String? _filterTabKey;

  /// SQL 文本持久化防抖
  Timer? _sqlSaveDebounce;

  /// 上次持久化的 SQL 文本(用于判断是否真的变了)
  String _lastSavedSql = '';

  /// SQL 编辑器高度
  double _sqlEditorHeight = 150.0;

  /// 左侧导航栏宽度
  double _sidebarWidth = 250.0;

  /// 当前 SQL 编辑器绑定的连接 ID(用于分库记录 SQL 缓存)
  String? _activeConnectionIdForSql;

  @override
  void initState() {
    super.initState();
    // 选区/内容变化时刷新按钮文案并防抖持久化 SQL 文本
    _sqlController.addListener(_onSqlChanged);
    // 恢复上次/默认的 SQL 编辑器文本
    final initialId = ref.read(dbSessionProvider).activeId;
    _activeConnectionIdForSql = initialId;
    WorkspaceStore.loadSqlText(connectionId: initialId).then((text) {
      if (mounted &&
          _activeConnectionIdForSql == initialId &&
          _sqlController.text.isEmpty) {
        _sqlController.removeListener(_onSqlChanged);
        _sqlController.text = text;
        _lastSavedSql = text;
        _sqlController.addListener(_onSqlChanged);
      }
    });
    // 启动时自动重连上次活动连接(best-effort),成功后串联恢复表 Tab
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoReconnect());
  }

  Future<void> _autoReconnect() async {
    // 直接读连接存储,避开 provider 异步加载时序
    final connections = await DbConnectionStore.load();
    if (!mounted || connections.isEmpty) return;
    ref.read(dbSessionProvider.notifier).autoReconnect(connections);
  }

  void _onSqlChanged() {
    // controller 通知可能发生在 build 阶段(如子组件首帧初始化),
    // 此时 setState 非法,延到下一帧。
    if (mounted) {
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      } else {
        setState(() {});
      }
    }
    final text = _sqlController.text;
    if (text == _lastSavedSql) return;
    _sqlSaveDebounce?.cancel();
    final targetId =
        _activeConnectionIdForSql ?? ref.read(dbSessionProvider).activeId;
    _sqlSaveDebounce = Timer(const Duration(milliseconds: 600), () {
      _lastSavedSql = text;
      WorkspaceStore.saveSqlText(text, connectionId: targetId);
    });
  }

  @override
  void dispose() {
    _sqlSaveDebounce?.cancel();
    // 关闭前把未落盘的 SQL 文本立刻写入
    if (_sqlController.text != _lastSavedSql) {
      final targetId =
          _activeConnectionIdForSql ?? ref.read(dbSessionProvider).activeId;
      WorkspaceStore.saveSqlText(_sqlController.text, connectionId: targetId);
    }
    _sqlController.removeListener(_onSqlChanged);
    _sqlController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dbSessionProvider);
    ref.listen(dbSessionProvider.select((s) => s.activeId), (prev, next) {
      _switchConnectionSql(prev, next);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageTopBar(
          icon: LucideIcons.database300,
          title: AppL10n.current.database,
          subtitle: _headerSubtitle(session),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: _sidebarWidth, child: _buildNavigator(session)),
              _ResizableDivider(
                axis: Axis.horizontal,
                onDragDelta: _onSidebarResize,
              ),
              Expanded(child: _buildContent(session)),
            ],
          ),
        ),
      ],
    );
  }

  /// 页面头部副标题:当前活动连接名(带服务器版本),未连接则提示
  String _headerSubtitle(DbSessionsState session) {
    final cfg = session.config;
    if (cfg == null || cfg.name.isEmpty) return AppL10n.current.notConnected;
    final ver = session.serverVersion;
    return (ver != null && ver.isNotEmpty) ? '${cfg.name} · $ver' : cfg.name;
  }

  void _switchConnectionSql(String? prevId, String? nextId) {
    if (prevId == nextId) return;
    // 切连接前，把当前未落盘的 SQL 文本立刻写入上一个连接的分库记录中
    if (prevId != null &&
        prevId.isNotEmpty &&
        _sqlController.text != _lastSavedSql) {
      _sqlSaveDebounce?.cancel();
      _lastSavedSql = _sqlController.text;
      WorkspaceStore.saveSqlText(_sqlController.text, connectionId: prevId);
    }
    _activeConnectionIdForSql = nextId;
    // 异步加载目标连接的分库 SQL 缓存
    WorkspaceStore.loadSqlText(connectionId: nextId).then((text) {
      if (!mounted || _activeConnectionIdForSql != nextId) return;
      _sqlController.removeListener(_onSqlChanged);
      _sqlController.text = text;
      _lastSavedSql = text;
      _sqlController.addListener(_onSqlChanged);
      setState(() {});
    });
  }

  // ══════════════════════ 左侧导航 ══════════════════════

  Widget _buildNavigator(DbSessionsState session) {
    final connections = ref.watch(dbConnectionsProvider);

    return Container(
      color: AppTheme.surfaceColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
            child: Row(
              children: [
                // Flexible + ellipsis:侧栏被压窄时标题收缩,不顶出加号按钮
                Flexible(
                  child: Text(
                    tr('数据库连接'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ),
                const Spacer(),
                const _TasksButton(),
                IconButton(
                  tooltip: tr('新建连接'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    LucideIcons.plus,
                    size: 16,
                    color: AppTheme.subtleTextColor,
                  ),
                  onPressed: _createConnection,
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 0.5, color: AppTheme.borderColor),
          Expanded(
            child: connections.isEmpty
                ? _emptyNavigator()
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final config in connections)
                        ..._buildConnectionNode(config, session),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyNavigator() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.databaseZap,
              size: 30,
              color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 10),
            Text(
              '还没有连接\n点击右上角 + 新建 PostgreSQL / ClickHouse / SQLite 连接',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.subtleTextColor,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildConnectionNode(
    DbConnectionConfig config,
    DbSessionsState sessionsState,
  ) {
    final session = sessionsState.sessionFor(config.id);
    final isActive = sessionsState.activeId == config.id;
    final isConnected = session.status == DbSessionStatus.connected;
    final isConnecting = session.status == DbSessionStatus.connecting;
    final isCollapsed = _collapsedConnections.contains(config.id);

    return [
      InkWell(
        onTap: () {
          if (isConnected) {
            ref.read(dbSessionProvider.notifier).selectConnection(config.id);
            setState(() {
              if (isCollapsed) {
                _collapsedConnections.remove(config.id);
              } else {
                _collapsedConnections.add(config.id);
              }
            });
          } else if (!isConnecting) {
            ref.read(dbSessionProvider.notifier).connect(config);
          }
        },
        onDoubleTap: () => _editConnection(config),
        onSecondaryTapDown: (details) =>
            _showConnectionMenu(details.globalPosition, config, isConnected),
        child: Container(
          color: isActive
              ? AppTheme.softBrandColor.withValues(alpha: 0.5)
              : Colors.transparent,
          padding: EdgeInsets.fromLTRB(isConnected ? 8 : 12, 7, 4, 7),
          child: Row(
            children: [
              if (isConnecting)
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (isConnected) ...[
                Icon(
                  isCollapsed ? LucideIcons.chevronRight : LucideIcons.chevronDown,
                  size: 13,
                  color: AppTheme.subtleTextColor,
                ),
                const SizedBox(width: 4),
                Icon(
                  LucideIcons.plugZap,
                  size: 15,
                  color: AppTheme.successColor,
                ),
              ] else
                Icon(
                  LucideIcons.plug,
                  size: 15,
                  color: AppTheme.subtleTextColor,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _engineBadge(config.engine),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            config.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isActive || isConnected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: AppTheme.headingColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      config.engine.isFileBased
                          ? config.database
                          : '${config.host}:${config.port}/${config.database}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ],
                ),
              ),
              _connectionMenu(config, isConnected),
            ],
          ),
        ),
      ),
      // 连接失败提示
      if (isActive &&
          session.connectError != null &&
          session.status == DbSessionStatus.disconnected)
        Padding(
          padding: const EdgeInsets.fromLTRB(35, 0, 12, 6),
          child: SelectableText(
            session.connectError!,
            maxLines: 3,
            style: TextStyle(fontSize: 11, color: AppTheme.errorColor),
          ),
        ),
      // schema 树
      if (isConnected && !isCollapsed)
        for (final schema in session.schemas)
          ..._buildSchemaNode(config.id, schema, session, isActive),
    ];
  }

  /// 引擎类型徽标(PG / CH),多连接时快速区分
  Widget _engineBadge(DbEngine engine) {
    final (label, color) = switch (engine) {
      DbEngine.postgres => ('PG', const Color(0xFF3B6EA5)),
      DbEngine.clickhouse => ('CH', const Color(0xFFD9A441)),
      DbEngine.sqlite => ('SQ', const Color(0xFF4E9A8F)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _connectionMenu(DbConnectionConfig config, bool isConnected) {
    return Builder(
      builder: (btnContext) => IconButton(
        tooltip: tr('操作'),
        visualDensity: VisualDensity.compact,
        icon: Icon(
          LucideIcons.ellipsisVertical,
          size: 14,
          color: AppTheme.subtleTextColor,
        ),
        onPressed: () {
          final box = btnContext.findRenderObject() as RenderBox?;
          final offset = box == null
              ? Offset.zero
              : box.localToGlobal(box.size.bottomLeft(Offset.zero));
          _showConnectionMenu(offset, config, isConnected);
        },
      ),
    );
  }

  /// 连接右键/操作菜单
  void _showConnectionMenu(
    Offset position,
    DbConnectionConfig config,
    bool isConnected,
  ) {
    _showContextMenu(position, [
      (
        'toggle',
        isConnected ? tr('断开连接') : tr('连接'),
        isConnected ? LucideIcons.unplug : LucideIcons.plug,
      ),
      ('refresh', tr('刷新元数据'), LucideIcons.refreshCw),
      ('export', tr('导出 SQL 脚本'), LucideIcons.fileDown),
      ('import', tr('导入 SQL 脚本'), LucideIcons.fileUp),
      ('dump', tr('导出便携归档'), LucideIcons.package),
      ('store', tr('从归档导入'), LucideIcons.packageOpen),
      ('migrate', tr('迁移到其它连接'), LucideIcons.arrowRightLeft),
      ('backup', tr('备份整库'), LucideIcons.databaseBackup),
      ('edit', tr('编辑连接'), LucideIcons.pencilLine),
      ('delete', tr('删除连接'), LucideIcons.trash2),
    ]).then((action) async {
      if (action == null || !mounted) return;
      final notifier = ref.read(dbSessionProvider.notifier);
      switch (action) {
        case 'toggle':
          isConnected
              ? notifier.disconnect(id: config.id, userInitiated: true)
              : notifier.connect(config);
        case 'refresh':
          if (isConnected) {
            notifier.connect(config, forceReconnect: true);
          }
        case 'export':
          showTransferDialog(
            context,
            source: config,
            mode: DbTransferMode.export,
          );
        case 'import':
          showTransferDialog(
            context,
            source: config,
            mode: DbTransferMode.importScript,
          );
        case 'dump':
          showTransferDialog(
            context,
            source: config,
            mode: DbTransferMode.exportDump,
          );
        case 'store':
          showTransferDialog(
            context,
            source: config,
            mode: DbTransferMode.importDump,
          );
        case 'migrate':
          showTransferDialog(
            context,
            source: config,
            mode: DbTransferMode.migrate,
          );
        case 'backup':
          showTransferDialog(
            context,
            source: config,
            mode: DbTransferMode.export,
            presetWholeDatabase: true,
          );
        case 'edit':
          _editConnection(config);
        case 'delete':
          await notifier.disconnect(id: config.id, userInitiated: true);
          ref.read(dbConnectionsProvider.notifier).remove(config.id);
      }
    });
  }

  /// 通用上下文菜单:项为 (value, label, icon)
  Future<String?> _showContextMenu(
    Offset position,
    List<(String, String, IconData)> items,
  ) {
    return showGlassMenu<String>(
      context: context,
      position: position,
      items: [
        for (final (value, label, icon) in items)
          PopupMenuItem(
            value: value,
            height: 38,
            child: Row(
              children: [
                Icon(icon, size: 14, color: AppTheme.subtleTextColor),
                const SizedBox(width: 10),
                Text(label, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _buildSchemaNode(
    String connectionId,
    String schema,
    DbSessionState session,
    bool isConnectionActive,
  ) {
    final schemaKey = '$connectionId:$schema';
    final expanded = _expandedSchemas.contains(schemaKey);
    final loading = session.loadingSchemas.contains(schema);
    final tables = session.tables[schema];

    return [
      InkWell(
        onTap: () {
          setState(() {
            if (expanded) {
              _expandedSchemas.remove(schemaKey);
            } else {
              _expandedSchemas.add(schemaKey);
            }
          });
          if (!expanded) {
            ref
                .read(dbSessionProvider.notifier)
                .loadTables(schema, connectionId: connectionId);
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(25, 5, 8, 5),
          child: Row(
            children: [
              Icon(
                expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: 13,
                color: AppTheme.subtleTextColor,
              ),
              const SizedBox(width: 4),
              Icon(
                LucideIcons.folderTree,
                size: 13,
                color: AppTheme.brandColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  schema,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.headingColor,
                  ),
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
            ],
          ),
        ),
      ),
      if (expanded && tables != null)
        if (tables.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(58, 2, 8, 4),
            child: Text(
              tr('(空)'),
              style: TextStyle(fontSize: 11.5, color: AppTheme.subtleTextColor),
            ),
          )
        else
          for (final table in tables)
            _buildTableNode(
              connectionId,
              schema,
              table,
              session,
              isConnectionActive,
            ),
    ];
  }

  Widget _buildTableNode(
    String connectionId,
    String schema,
    DbTableInfo table,
    DbSessionState session,
    bool isConnectionActive,
  ) {
    final active = session.activeTableTab;
    final selected =
        isConnectionActive &&
        active != null &&
        active.schema == schema &&
        active.table == table.name;

    return InkWell(
      onTap: () => ref
          .read(dbSessionProvider.notifier)
          .openTable(
            schema,
            table.name,
            isView: table.isView,
            connectionId: connectionId,
          ),
      onSecondaryTapDown: (details) =>
          _showTableMenu(details.globalPosition, schema, table),
      child: Container(
        color: selected
            ? AppTheme.softBrandColor.withValues(alpha: 0.32)
            : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(42, 4.5, 8, 4.5),
        child: Row(
          children: [
            Icon(
              table.isView ? LucideIcons.scanEye : LucideIcons.table2,
              size: 13,
              color: selected ? AppTheme.brandColor : AppTheme.subtleTextColor,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                table.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: selected ? AppTheme.brandColor : AppTheme.bodyColor,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 表右键菜单
  void _showTableMenu(Offset position, String schema, DbTableInfo table) {
    _showContextMenu(position, [
      ('browse', tr('浏览数据'), LucideIcons.table2),
      ('structure', tr('查看结构'), LucideIcons.columns3),
      ('select', tr('生成 SELECT 到编辑器'), LucideIcons.squareCode),
      ('copy', tr('复制表名'), LucideIcons.clipboardCopy),
    ]).then((action) {
      if (action == null || !mounted) return;
      final notifier = ref.read(dbSessionProvider.notifier);
      switch (action) {
        case 'browse':
          setState(() => _tableTab = 0);
          notifier.openTable(schema, table.name, isView: table.isView);
        case 'structure':
          setState(() => _tableTab = 1);
          notifier.openTable(schema, table.name, isView: table.isView);
        case 'select':
          final qualified = '"$schema"."${table.name}"';
          _sqlController.text = 'SELECT * FROM $qualified LIMIT 100;';
          notifier.activateTab(kSqlTabIndex);
        case 'copy':
          Clipboard.setData(ClipboardData(text: table.name));
      }
    });
  }

  // ══════════════════════ 右侧内容 ══════════════════════

  Widget _buildContent(DbSessionsState session) {
    if (session.status != DbSessionStatus.connected) {
      return _buildDisconnectedHint(session);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _saveActive,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            _saveActive,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(session),
          _buildTabBar(session),
          Divider(height: 1, thickness: 0.5, color: AppTheme.borderColor),
          Expanded(
            child: switch (session.activeTab) {
              kOverviewTabIndex => DbOverviewPanel(
                key: ValueKey('overview-${session.config!.id}'),
                connectionId: session.config!.id,
              ),
              kSqlTabIndex => _buildSqlView(session),
              _ => _buildTableView(session),
            },
          ),
        ],
      ),
    );
  }

  /// Cmd/Ctrl+S 保存当前活动结果集的待提交改动
  Future<void> _saveActive() async {
    final session = ref.read(dbSessionProvider);
    final notifier = ref.read(dbSessionProvider.notifier);
    if (session.activeTab == kSqlTabIndex) {
      if (session.sql.edits.isDirty && !session.sql.saving) {
        _showEditResult(await notifier.saveSql(), tr('改动'));
      }
    } else {
      final tab = session.activeTableTab;
      if (tab != null && tab.edits.isDirty && !tab.saving) {
        _showEditResult(await notifier.saveTab(session.activeTab), tr('改动'));
      }
    }
  }

  Widget _buildDisconnectedHint(DbSessionsState session) {
    final connecting = session.status == DbSessionStatus.connecting;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (connecting) ...[
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 14),
            Text(
              '正在连接 ${session.config?.name ?? ''}…',
              style: TextStyle(fontSize: 13, color: AppTheme.bodyColor),
            ),
          ] else ...[
            Icon(
              LucideIcons.database,
              size: 44,
              color: AppTheme.subtleTextColor,
            ),
            const SizedBox(height: 14),
            Text(
              tr('数据库连接'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.headingColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              tr('在左侧选择一个连接,或新建连接开始使用'),
              style: TextStyle(fontSize: 12.5, color: AppTheme.subtleTextColor),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _createConnection,
              icon: const Icon(LucideIcons.plus, size: 15),
              label: Text(tr('新建连接')),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildToolbar(DbSessionsState session) {
    final config = session.config!;
    return Container(
      height: 38,
      color: AppTheme.surfaceColor,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.plugZap,
                      size: 14,
                      color: AppTheme.successColor,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      config.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.headingColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (session.serverVersion != null)
                      Text(
                        '${session.config?.engine.label ?? ''} ${session.serverVersion}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppTheme.subtleTextColor,
                        ),
                      ),
                  ],
                ),
                IconButton(
                  tooltip: tr('断开连接'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    LucideIcons.unplug,
                    size: 15,
                    color: AppTheme.errorColor,
                  ),
                  onPressed: () => ref
                      .read(dbSessionProvider.notifier)
                      .disconnect(id: config.id, userInitiated: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Tab 栏:固定的 SQL Tab + 每个打开的表一个可关闭 Tab
  Widget _buildTabBar(DbSessionsState session) {
    return Container(
      height: 34,
      color: AppTheme.surfaceColor,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _tabChip(
              icon: LucideIcons.chartColumnBig,
              label: tr('概览'),
              active: session.activeTab == kOverviewTabIndex,
              onTap: () => ref
                  .read(dbSessionProvider.notifier)
                  .activateTab(kOverviewTabIndex),
            ),
            _tabChip(
              icon: LucideIcons.squareCode,
              label: 'SQL',
              active: session.activeTab == kSqlTabIndex,
              onTap: () => ref
                  .read(dbSessionProvider.notifier)
                  .activateTab(kSqlTabIndex),
            ),
            for (var i = 0; i < session.tabs.length; i++)
              _tabChip(
                icon: session.tabs[i].isView
                    ? LucideIcons.scanEye
                    : LucideIcons.table2,
                label: session.tabs[i].table,
                tooltip: session.tabs[i].qualifiedName,
                active: session.activeTab == i,
                onTap: () =>
                    ref.read(dbSessionProvider.notifier).activateTab(i),
                onClose: () => ref.read(dbSessionProvider.notifier).closeTab(i),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tabChip({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
    VoidCallback? onClose,
    String? tooltip,
  }) {
    final child = InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.fromLTRB(12, 0, onClose == null ? 12 : 6, 0),
        decoration: BoxDecoration(
          color: active ? AppTheme.backgroundColor : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: active ? AppTheme.brandColor : Colors.transparent,
              width: 2,
            ),
            right: BorderSide(
              color: AppTheme.borderColor.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: active ? AppTheme.brandColor : AppTheme.subtleTextColor,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? AppTheme.headingColor : AppTheme.bodyColor,
                ),
              ),
            ),
            if (onClose != null) ...[
              const SizedBox(width: 4),
              InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    LucideIcons.x,
                    size: 11,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (tooltip == null) return child;
    return Tooltip(message: tooltip, child: child);
  }

  // ── 表 Tab 视图(数据 / 结构) ──

  Widget _buildTableView(DbSessionsState session) {
    final index = session.activeTab;
    final tab = session.activeTableTab;
    if (tab == null) {
      return Center(
        child: Text(
          tr('在左侧展开 schema,点击表名浏览数据'),
          style: TextStyle(fontSize: 12.5, color: AppTheme.subtleTextColor),
        ),
      );
    }

    // 过滤输入框跟随 Tab 切换
    if (_filterTabKey != tab.qualifiedName) {
      _filterTabKey = tab.qualifiedName;
      _filterController.text = tab.filter;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTableInfoBar(index, tab),
        Divider(height: 1, thickness: 0.5, color: AppTheme.borderColor),
        Expanded(
          child: _tableTab == 0
              ? _buildDataBody(index, tab)
              : _buildStructureBody(index, tab),
        ),
      ],
    );
  }

  Widget _buildTableInfoBar(int index, DbTableTab tab) {
    final notifier = ref.read(dbSessionProvider.notifier);
    final output = tab.output;

    String pageInfo() {
      if (output == null) return '';
      final total = tab.totalRows;
      final totalText = total == null ? '' : tr2(' / 共 {0} 行', [total]);
      return '第 ${tab.page + 1} 页 · ${output.rows.length} 行$totalText'
          ' · ${output.elapsed.inMilliseconds}ms';
    }

    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tab.loading)
                      const SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    else if (_tableTab == 0)
                      Text(
                        pageInfo(),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.subtleTextColor,
                        ),
                      ),
                    const SizedBox(width: 10),
                    // 全行过滤(BigQuery 式快速过滤,Enter 提交)
                    if (_tableTab == 0)
                      SizedBox(
                        width: 190,
                        height: 26,
                        child: TextField(
                          controller: _filterController,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.headingColor,
                          ),
                          decoration: InputDecoration(
                            hintText: tr('过滤(全行匹配,Enter)'),
                            hintStyle: TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.subtleTextColor.withValues(
                                alpha: 0.7,
                              ),
                            ),
                            prefixIcon: Icon(
                              LucideIcons.listFilter,
                              size: 13,
                              color: AppTheme.subtleTextColor,
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 28,
                            ),
                            suffixIcon: tab.filter.isEmpty
                                ? null
                                : InkWell(
                                    onTap: () {
                                      _filterController.clear();
                                      notifier.setFilter(index, '');
                                    },
                                    child: Icon(
                                      LucideIcons.x,
                                      size: 12,
                                      color: AppTheme.subtleTextColor,
                                    ),
                                  ),
                            suffixIconConstraints: const BoxConstraints(
                              minWidth: 24,
                            ),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 6,
                            ),
                            filled: true,
                            fillColor: AppTheme.mutedSurfaceColor,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(13),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onSubmitted: (value) =>
                              notifier.setFilter(index, value.trim()),
                        ),
                      ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _subTabToggle(),
                    const SizedBox(width: 8),
                    if (_tableTab == 0) ...[
                      IconButton(
                        tooltip: tr('导出(CSV/JSON/SQL/Markdown)'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(LucideIcons.download, size: 14),
                        onPressed: output == null || output.rows.isEmpty
                            ? null
                            : () => showExportDialog(
                                context,
                                output: output,
                                tableName: tab.table,
                              ),
                      ),
                      IconButton(
                        tooltip: tr('上一页'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(LucideIcons.chevronLeft, size: 15),
                        onPressed: tab.page > 0 && !tab.loading
                            ? () => notifier.goToPage(index, tab.page - 1)
                            : null,
                      ),
                      IconButton(
                        tooltip: tr('下一页'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(LucideIcons.chevronRight, size: 15),
                        onPressed: tab.hasMore && !tab.loading
                            ? () => notifier.goToPage(index, tab.page + 1)
                            : null,
                      ),
                      IconButton(
                        tooltip: tr('刷新'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(LucideIcons.refreshCw, size: 13),
                        onPressed: tab.loading
                            ? null
                            : () => notifier.refreshTab(index),
                      ),
                    ] else
                      IconButton(
                        tooltip: tr('刷新结构'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(LucideIcons.refreshCw, size: 13),
                        onPressed: () =>
                            notifier.loadStructure(index, force: true),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「数据 | 结构」子页签
  Widget _subTabToggle() {
    Widget seg(String label, int value) {
      final active = _tableTab == value;
      return InkWell(
        onTap: () {
          setState(() => _tableTab = value);
          if (value == 1) {
            final session = ref.read(dbSessionProvider);
            if (session.activeTab >= 0) {
              ref
                  .read(dbSessionProvider.notifier)
                  .loadStructure(session.activeTab);
            }
          }
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active ? AppTheme.softBrandColor : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? AppTheme.brandColor : AppTheme.subtleTextColor,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [seg(tr('数据'), 0), SizedBox(width: 2), seg(tr('结构'), 1)],
    );
  }

  /// 打开列过滤面板,应用/清除后更新该列过滤条件
  Future<void> _openColumnFilter(
    int index,
    DbTableTab tab,
    String column,
    Offset position,
  ) async {
    final existing = tab.columnFilters
        .where((f) => f.column == column)
        .firstOrNull;
    final result = await showColumnFilterPopup(
      context,
      column: column,
      existing: existing,
      position: position,
    );
    if (result == null || !mounted) return;

    // 空 column = 清除该列;否则替换/新增
    final others = [
      for (final f in tab.columnFilters)
        if (f.column != column) f,
    ];
    final next = result.column.isEmpty ? others : [...others, result];
    ref.read(dbSessionProvider.notifier).setColumnFilters(index, next);
  }

  Widget _buildDataBody(int index, DbTableTab tab) {
    if (tab.error != null) {
      return _errorPane(tab.error!);
    }
    final output = tab.output;
    if (output == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    final notifier = ref.read(dbSessionProvider.notifier);
    final empty = output.rows.isEmpty && tab.edits.addedRows.isEmpty;

    // 空表也保留列头:结果集带列描述时始终渲染网格(表头 + 空表体),
    // 只在表体区叠一条轻提示;仅当连列信息都没有时才用居中占位。
    final Widget body;
    if (!output.hasRows) {
      body = Center(
        child: Text(
          tr('表中没有数据'),
          style: TextStyle(fontSize: 12.5, color: AppTheme.subtleTextColor),
        ),
      );
    } else {
      final grid = DbDataGrid(
        output: output,
        editable: tab.editable,
        edits: tab.edits,
        sortColumn: tab.sortColumn,
        sortAscending: tab.sortAscending,
        filteredColumns: {for (final f in tab.columnFilters) f.column},
        onHeaderTap: (column) => notifier.sortBy(index, column),
        onHeaderFilter: (column, pos) =>
            _openColumnFilter(index, tab, column, pos),
        onCellEdit: (r, c, value, setNull) => notifier.editTabCell(
          index,
          rowIndex: r,
          columnIndex: c,
          newValue: setNull ? null : value,
        ),
        onToggleDelete: (r) => notifier.toggleDeleteRow(index, r),
      );
      body = empty
          ? Stack(
              children: [
                grid,
                // 叠在空表体上的轻提示(避开顶部列头,不拦截交互)
                Positioned(
                  top: 40,
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: Text(
                        tab.filter.isEmpty
                            ? tr('表中没有数据')
                            : tr2('没有匹配「{0}」的行', [tab.filter]),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.subtleTextColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : grid;
    }

    return Column(
      children: [
        Expanded(child: body),
        if (tab.editable)
          _editActionBar(
            edits: tab.edits,
            saving: tab.saving,
            onAddRow: () => notifier.addRow(index),
            onRevert: () => notifier.revertTab(index),
            onSave: () async {
              final error = await notifier.saveTab(index);
              _showEditResult(error, tr('改动'));
            },
          ),
      ],
    );
  }

  /// dbeaver 式底部编辑工具条:新增行 / N 处改动 / 撤销 / 保存
  Widget _editActionBar({
    required DbEditSession edits,
    required bool saving,
    required VoidCallback onAddRow,
    required VoidCallback onRevert,
    required Future<void> Function() onSave,
  }) {
    final dirty = edits.isDirty;
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: dirty
            ? AppTheme.warningColor.withValues(alpha: 0.10)
            : AppTheme.surfaceColor,
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: saving ? null : onAddRow,
                      icon: const Icon(LucideIcons.plus, size: 14),
                      label: Text(tr('新增行'), style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    if (!dirty) ...[
                      const SizedBox(width: 8),
                      Text(
                        tr('双击编辑 · Tab/Enter 移动 · Esc 取消'),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.subtleTextColor,
                        ),
                      ),
                    ],
                  ],
                ),
                if (dirty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.pencil,
                        size: 12,
                        color: AppTheme.warningColor,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        tr2('{0} 处未保存', [edits.changeCount]),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.warningColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      TextButton(
                        onPressed: saving ? null : onRevert,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text(
                          tr('撤销全部'),
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.subtleTextColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      FilledButton.icon(
                        onPressed: saving ? null : () => onSave(),
                        icon: saving
                            ? const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(LucideIcons.save, size: 13),
                        label: Text(
                          tr('保存 ⌘S'),
                          style: TextStyle(fontSize: 12),
                        ),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 结构面板正文
  Widget _buildStructureBody(int index, DbTableTab tab) {
    if (tab.structureError != null) {
      return _errorPane(tab.structureError!);
    }
    final structure = tab.structure;
    if (structure == null) {
      // 未加载则触发(有缓存,重复调用零开销)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _tableTab != 1) return;
        ref.read(dbSessionProvider.notifier).loadStructure(index);
      });
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return TableStructureView(structure: structure);
  }

  /// 批量提交结果反馈
  void _showEditResult(String? error, String what) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? tr2('已保存{0}', [what])),
        backgroundColor: error != null ? AppTheme.errorColor : null,
        duration: Duration(seconds: error != null ? 5 : 1),
      ),
    );
  }

  // ── SQL 编辑器 ──

  Widget _buildSqlView(DbSessionsState session) {
    final sql = session.sql;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: SqlEditor(
            controller: _sqlController,
            height: _sqlEditorHeight,
            metadataPrompts: _buildMetadataPrompts(),
            variableNames: ref.watch(dbVariablesProvider).keys.toList(),
            onRun: _runSql,
            onVerticalDragUpdate: _onSqlEditorResize,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: sql.running ? null : _runSql,
                icon: sql.running
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.play, size: 14),
                label: Text(
                  _sqlController.selectedText.trim().isEmpty
                      ? tr('执行 ⌘↩')
                      : tr('执行选中 ⌘↩'),
                ),
              ),
              const SizedBox(width: 6),
              _historyButton(),
              _variablesButton(),
              const SizedBox(width: 6),
              if (sql.output != null && sql.error == null) ...[
                Text(
                  sql.output!.hasRows
                      ? tr2('{0} 行 · {1}ms{2}', [
                          sql.output!.rows.length,
                          sql.output!.elapsed.inMilliseconds,
                          sql.editable ? tr(' · 双击编辑') : '',
                        ])
                      : tr2('完成 · 影响 {0} 行 · {1}ms', [
                          sql.output!.affectedRows,
                          sql.output!.elapsed.inMilliseconds,
                        ]),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
                if (sql.output!.rows.isNotEmpty)
                  IconButton(
                    tooltip: tr('导出(CSV/JSON/SQL/Markdown)'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(LucideIcons.download, size: 13),
                    onPressed: () => showExportDialog(
                      context,
                      output: sql.output!,
                      tableName: 'query_result',
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        _ResizableDivider(
          axis: Axis.vertical,
          onDragDelta: _onSqlEditorResize,
        ),
        Expanded(child: _buildSqlResult(sql)),
      ],
    );
  }

  void _onSqlEditorResize(double delta) {
    if (!mounted) return;
    final maxHeight = MediaQuery.of(context).size.height - 200;
    setState(() {
      _sqlEditorHeight =
          (_sqlEditorHeight + delta).clamp(60.0, maxHeight.clamp(60.0, 1200.0));
    });
  }

  void _onSidebarResize(double delta) {
    if (!mounted) return;
    final maxWidth = MediaQuery.of(context).size.width - 300;
    setState(() {
      _sidebarWidth =
          (_sidebarWidth + delta).clamp(160.0, maxWidth.clamp(160.0, 800.0));
    });
  }

  Widget _buildSqlResult(DbSqlState sql) {
    if (sql.error != null) {
      return _errorPane(sql.error!);
    }
    final output = sql.output;
    if (output == null) {
      return Center(
        child: Text(
          tr('执行结果将显示在这里'),
          style: TextStyle(fontSize: 12.5, color: AppTheme.subtleTextColor),
        ),
      );
    }
    // 无结果集(DML 等):没有列描述 → 居中提示
    if (!output.hasRows) {
      return Center(
        child: Text(
          tr('语句执行成功,无返回结果集'),
          style: TextStyle(fontSize: 12.5, color: AppTheme.subtleTextColor),
        ),
      );
    }
    final notifier = ref.read(dbSessionProvider.notifier);
    // 有列但 0 行(如 WHERE 无匹配):保留列头,表体叠轻提示
    final empty = output.rows.isEmpty && sql.edits.addedRows.isEmpty;
    final grid = DbDataGrid(
      output: output,
      editable: sql.editable,
      edits: sql.edits,
      hasMore: sql.hasMore,
      loadingMore: sql.loadingMore,
      onLoadMore: sql.hasMore ? notifier.loadMoreSql : null,
      onCellEdit: (r, c, value, setNull) => notifier.editSqlCell(
        rowIndex: r,
        columnIndex: c,
        newValue: setNull ? null : value,
      ),
      onToggleDelete: (r) => notifier.toggleDeleteSqlRow(r),
    );
    return Column(
      children: [
        Expanded(
          child: empty
              ? Stack(
                  children: [
                    grid,
                    Positioned(
                      top: 40,
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: Text(
                            tr('查询没有返回数据'),
                            style: TextStyle(
                              fontSize: 12.5,
                              color: AppTheme.subtleTextColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : grid,
        ),
        if (sql.editable)
          _editActionBar(
            edits: sql.edits,
            saving: sql.saving,
            onAddRow: notifier.addSqlRow,
            onRevert: notifier.revertSql,
            onSave: () async {
              final error = await notifier.saveSql();
              _showEditResult(error, tr('改动'));
            },
          ),
      ],
    );
  }

  Widget _errorPane(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.circleAlert, size: 30, color: AppTheme.errorColor),
            const SizedBox(height: 10),
            SelectableText(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: AppTheme.errorColor,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// SQL 查询历史下拉(最近 50 条,选中回填编辑器)
  Widget _historyButton() {
    final history = ref.watch(dbSqlHistoryProvider);
    return GlassPopupMenuButton<String>(
      tooltip: tr('查询历史'),
      enabled: history.isNotEmpty,
      icon: Icon(
        LucideIcons.history,
        size: 15,
        color: history.isEmpty
            ? AppTheme.subtleTextColor.withValues(alpha: 0.4)
            : AppTheme.subtleTextColor,
      ),
      constraints: const BoxConstraints(maxWidth: 480),
      onSelected: (value) {
        if (value == '__clear__') {
          ref.read(dbSqlHistoryProvider.notifier).clear();
          return;
        }
        _sqlController.text = value;
      },
      itemBuilder: (context) => [
        for (final sql in history)
          PopupMenuItem(
            value: sql,
            height: 34,
            child: Text(
              sql.replaceAll(RegExp(r'\s+'), ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'Menlo',
                fontFamilyFallback: const ['Consolas', 'monospace'],
                color: AppTheme.headingColor,
              ),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: '__clear__',
          height: 34,
          child: Text(
            tr('清空历史'),
            style: TextStyle(fontSize: 12, color: AppTheme.errorColor),
          ),
        ),
      ],
    );
  }

  /// SQL 变量管理按钮(角标显示已定义数量)
  Widget _variablesButton() {
    final variables = ref.watch(dbVariablesProvider);
    return IconButton(
      tooltip: 'SQL 变量(\${name} 占位符)',
      visualDensity: VisualDensity.compact,
      icon: Badge(
        isLabelVisible: variables.isNotEmpty,
        label: Text('${variables.length}'),
        textStyle: const TextStyle(fontSize: 9),
        backgroundColor: AppTheme.brandColor,
        child: Icon(
          LucideIcons.variable,
          size: 16,
          color: AppTheme.subtleTextColor,
        ),
      ),
      onPressed: () async {
        final result = await showVariablesDialog(
          context,
          variables: ref.read(dbVariablesProvider),
        );
        if (result != null) {
          await ref.read(dbVariablesProvider.notifier).setAll(result);
        }
      },
    );
  }

  /// 由连接元数据构造补全项:schema、已加载的表/视图、活动表的列
  /// (变量走 SqlEditor 的 `${` 上下文专用补全,不在此列)
  List<CodePrompt> _buildMetadataPrompts() {
    final session = ref.watch(dbSessionProvider);
    final prompts = <CodePrompt>[];
    final seen = <String>{};

    void add(String word, String type) {
      if (word.isEmpty || !seen.add(word)) return;
      prompts.add(CodeFieldPrompt(word: word, type: type));
    }

    for (final schema in session.schemas) {
      add(schema, 'schema');
    }
    for (final entry in session.tables.entries) {
      for (final table in entry.value) {
        add(table.name, table.isView ? 'view' : 'table');
      }
    }
    // 所有打开 Tab 的列(结构已加载用真实类型,否则用结果列名)
    for (final tab in session.tabs) {
      final columns = tab.structure?.columns;
      if (columns != null) {
        for (final col in columns) {
          add(col.name, col.dataType);
        }
      } else if (tab.output != null) {
        for (final col in tab.output!.columns) {
          add(col, 'column');
        }
      }
    }
    return prompts;
  }

  // ══════════════════════ 动作 ══════════════════════

  Future<void> _runSql() async {
    // 有选区则只执行选中的部分(DBeaver/pgAdmin 行为)
    final selected = _sqlController.selectedText.trim();
    var sql = selected.isEmpty ? _sqlController.text : selected;
    final variables = ref.read(dbVariablesProvider);

    // ${name} 变量替换;引用了未定义变量时先弹窗补填
    final referenced = SqlVariables.extract(sql);
    if (referenced.isNotEmpty) {
      final missing = [
        for (final name in referenced)
          if (!variables.containsKey(name)) name,
      ];
      var values = variables;
      if (missing.isNotEmpty) {
        final filled = await promptMissingVariables(context, names: missing);
        if (filled == null) return; // 用户取消执行
        await ref.read(dbVariablesProvider.notifier).merge(filled);
        values = {...variables, ...filled};
      }
      sql = SqlVariables.substitute(sql, values);
    }

    // $1 $2 位置参数 → 弹窗补填后内联为字面量(避免 "no parameter $1")
    final positional = SqlVariables.extractPositional(sql);
    if (positional.isNotEmpty) {
      if (!mounted) return;
      final filled = await promptMissingVariables(
        context,
        names: positional,
        title: tr('填写查询参数'),
        hint: tr('为位置参数赋值,按 SQL 字面量内联(数字原样,文本自动加引号)'),
      );
      if (filled == null) return;
      sql = SqlVariables.substitutePositional(sql, filled);
    }

    ref.read(dbSessionProvider.notifier).runSql(sql);
  }

  Future<void> _createConnection() async {
    final config = await showConnectionDialog(context);
    if (config == null) return;
    await ref.read(dbConnectionsProvider.notifier).upsert(config);
    // 新建后直接尝试连接
    ref.read(dbSessionProvider.notifier).connect(config);
  }

  Future<void> _editConnection(DbConnectionConfig existing) async {
    final config = await showConnectionDialog(context, existing: existing);
    if (config == null) return;
    await ref.read(dbConnectionsProvider.notifier).upsert(config);
  }
}

/// 侧栏头部「传输任务」入口(带任务数徽标)
class _TasksButton extends ConsumerWidget {
  const _TasksButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(dbTransferTasksProvider).length;
    return IconButton(
      tooltip: tr('传输任务'),
      visualDensity: VisualDensity.compact,
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        backgroundColor: AppTheme.brandColor,
        child: Icon(
          LucideIcons.listChecks,
          size: 16,
          color: AppTheme.subtleTextColor,
        ),
      ),
      onPressed: () => showTransferTasksDialog(context),
    );
  }
}

/// 通用拖拽分割条(用于左右调整侧边栏宽度及上下调整 SQL 输入框高度)
class _ResizableDivider extends StatefulWidget {
  const _ResizableDivider({required this.axis, required this.onDragDelta});

  final Axis axis;
  final ValueChanged<double> onDragDelta;

  @override
  State<_ResizableDivider> createState() => _ResizableDividerState();
}

class _ResizableDividerState extends State<_ResizableDivider> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final lineColor = _hovered
        ? AppTheme.brandColor.withValues(alpha: 0.7)
        : AppTheme.borderColor;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: horizontal
            ? (details) => widget.onDragDelta(details.delta.dx)
            : null,
        onVerticalDragUpdate: horizontal
            ? null
            : (details) => widget.onDragDelta(details.delta.dy),
        child: SizedBox(
          width: horizontal ? 8 : null,
          height: horizontal ? null : 8,
          child: Center(
            child: Container(
              width: horizontal ? (_hovered ? 1.5 : 0.5) : double.infinity,
              height: horizontal ? double.infinity : (_hovered ? 1.5 : 0.5),
              color: lineColor,
            ),
          ),
        ),
      ),
    );
  }
}
