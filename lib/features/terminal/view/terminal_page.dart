import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderMetaData, RendererBinding;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_clipboard/super_clipboard.dart' as scb;
import 'package:super_drag_and_drop/super_drag_and_drop.dart' as sdd;
import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/utils/file_picker_helper.dart';
import 'package:termora/core/services/macos_file_access_service.dart';
import 'package:termora/core/data/command_history_store.dart';
import 'package:termora/core/widgets/file_preview.dart';
import 'package:termora/core/widgets/glass_menu.dart';
import 'package:termora/core/widgets/slide_select.dart';
import 'package:termora/features/terminal/controller/terminal_engine.dart';
import 'package:termora/features/terminal/controller/terminal_image.dart';
import 'package:termora/features/terminal/controller/terminal_model.dart';
import 'package:termora/features/terminal/controller/terminal_reflow.dart';
import 'package:termora/features/terminal/controller/terminal_ui_controller.dart';
import 'package:termora/features/terminal/data/highlight_store.dart';
import 'package:termora/features/terminal/data/link_matcher_store.dart';
import 'package:termora/features/terminal/data/session_logger.dart';
import 'package:termora/features/terminal/data/snippet_store.dart';
import 'package:termora/features/terminal/data/terminal_theme.dart';
import 'package:termora/features/terminal/view/widgets/link_matcher_manager.dart';
import 'package:termora/features/terminal/view/widgets/highlight_manager.dart';
import 'package:termora/core/widgets/app_toast.dart';
import 'package:toastification/toastification.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/app/shell/page_top_bar.dart';

part '../domain/terminal_models.dart';
part 'terminal_emulator.dart';
part 'widgets/terminal_widgets.dart';

/// 远程页内嵌终端工作区的控制器 — 让宿主(RemotePage)直接开 SSH 会话,
/// 不经任何全局总线;模式仿 TextEditingController(State 挂载时自绑定)。
class TerminalWorkspaceController {
  _TerminalPageState? _state;

  /// 打开一个自动连接的 SSH 会话(工作区实例未挂载时静默忽略)。
  /// 传 [remoteKey](主机 id)时:该主机已有会话就聚焦它、掉线则原地重连,
  /// 不再每次点击都新开一个窗格。
  void openRemoteSession({
    required String title,
    required String command,
    String? remoteKey,
  }) {
    _state?._openRemoteSession(
      title: title,
      command: command,
      remoteKey: remoteKey,
    );
  }

  /// 该主机运行中 SSH 会话里探测到的远端工作目录
  /// (OSC 7 优先,退而求其次解析窗口标题);拿不到返回 null。
  String? remoteCwdFor(String remoteKey) => _state?._remoteCwdFor(remoteKey);
}

/// 详情面板「文件」标签的一个目录项(本地/远端通用)。
class TerminalDirEntry {
  const TerminalDirEntry({
    required this.path,
    required this.name,
    required this.isDir,
    this.size = 0,
    this.modified = '',
  });

  /// 绝对路径(远端为 SFTP 路径)
  final String path;
  final String name;
  final bool isDir;

  /// 文件字节数(目录为 0)
  final int size;

  /// 修改时间(原样展示的字符串,如 sftp 的 "Jul  8 14:02")
  final String modified;
}

/// 列一个远端目录:remoteKey=主机 id,path 为空表示远端家目录。
/// 返回项的 path 需为绝对路径。
typedef TerminalRemoteDirLister =
    Future<List<TerminalDirEntry>> Function(String remoteKey, String path);

/// 上传本地文件到远端目录,返回 0..1 进度流(正常结束=完成,错误=失败);
/// remoteDir 为空表示远端家目录。
typedef TerminalRemoteUploader =
    Stream<double> Function(
      String remoteKey,
      String localPath,
      String remoteDir,
    );

/// 下载远端文件/目录到本地路径,返回 0..1 进度流。
typedef TerminalRemoteDownloader =
    Stream<double> Function(
      String remoteKey,
      String remotePath,
      String localPath,
      bool isDir,
    );

/// 远端文件的增改删(详情面板「文件」标签用);path 均为绝对 SFTP 路径,
/// 抛异常表示失败。
class TerminalRemoteFileActions {
  const TerminalRemoteFileActions({
    required this.rename,
    required this.delete,
    required this.makeDir,
  });

  /// 同目录改名
  final Future<void> Function(String remoteKey, String path, String newName)
  rename;

  /// 删除文件 / 空目录
  final Future<void> Function(String remoteKey, String path, bool isDir) delete;

  /// 在 parentDir 下新建目录
  final Future<void> Function(String remoteKey, String parentDir, String name)
  makeDir;
}

/// 在远端目录跑 git(经 ssh 复用 ControlMaster);返回进程结果(失败为 null)。
typedef TerminalRemoteGitRunner =
    Future<ProcessResult?> Function(
      String remoteKey,
      String remoteDir,
      List<String> args,
    );

class TerminalPage extends ConsumerStatefulWidget {
  /// 本地终端页(左侧「终端」导航):始终至少一个本地 shell 会话
  const TerminalPage({super.key})
    : controller = null,
      remoteWorkspace = false,
      sessionPrefix = 'terminal',
      sessionsPrefKey = 'workbench_terminal_sessions_v1',
      emptyHint = '',
      onOpenRemoteFiles = null,
      listRemoteDir = null,
      uploadToRemote = null,
      uploadDirToRemote = null,
      downloadFromRemote = null,
      remoteFileActions = null,
      runRemoteGit = null,
      isRemoteElevated = null,
      elevateRemote = null,
      dropRemoteElevation = null;

  /// 远程页内嵌工作区:只承载 SSH 会话,允许空态(独立持久化命名空间,
  /// 与本地终端页互不可见)
  const TerminalPage.remoteWorkspace({
    super.key,
    required this.controller,
    this.onOpenRemoteFiles,
    this.listRemoteDir,
    this.uploadToRemote,
    this.uploadDirToRemote,
    this.downloadFromRemote,
    this.remoteFileActions,
    this.runRemoteGit,
    this.isRemoteElevated,
    this.elevateRemote,
    this.dropRemoteElevation,
  }) : remoteWorkspace = true,
       sessionPrefix = 'remote_term',
       sessionsPrefKey = 'remote_terminal_sessions_v1',
       emptyHint = '从左侧主机列表选择一台主机连接';

  final TerminalWorkspaceController? controller;
  final bool remoteWorkspace;

  /// 会话工具栏「文件(SFTP)」被点时回调,参数是该会话的主机 id;
  /// null 则不显示该按钮
  final void Function(String remoteKey)? onOpenRemoteFiles;

  /// 远端目录列举器;非空时详情面板「文件」标签走远端 SFTP,
  /// 默认打开到该会话的远端命令行目录
  final TerminalRemoteDirLister? listRemoteDir;

  /// 详情面板「文件」标签的上传/下载(带进度);null 则不显示传输入口
  final TerminalRemoteUploader? uploadToRemote;

  /// 上传整个本地目录(递归);进度不定
  final TerminalRemoteUploader? uploadDirToRemote;
  final TerminalRemoteDownloader? downloadFromRemote;

  /// 详情面板「文件」标签的重命名/删除/新建目录;null 则不显示这些操作
  final TerminalRemoteFileActions? remoteFileActions;

  /// 远端 git 运行器;非空时 SSH 会话显示 Git 标签(走远端仓库)
  final TerminalRemoteGitRunner? runRemoteGit;

  /// 详情面板文件区的提权:是否已提权 / 触发提权(弹框校验,成功返回 true)/ 退出提权
  final bool Function(String remoteKey)? isRemoteElevated;
  final Future<bool> Function(String remoteKey)? elevateRemote;
  final void Function(String remoteKey)? dropRemoteElevation;

  /// 会话 provider key 前缀 — 两个工作区实例的 riverpod family 不串号
  final String sessionPrefix;

  /// 会话快照的 shared_preferences key — 两个工作区各自恢复
  final String sessionsPrefKey;

  /// 空态提示(仅 remoteWorkspace 会出现空态)
  final String emptyHint;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  List<_TerminalSessionDescriptor> _sessions = [];

  int _nextSessionId = 1;
  int _nextPaneId = 2;
  late _PaneNode _root;
  int _activePaneId = 1;
  double _fontScale = 1.0;

  /// 最小化到底部标签的会话(providerKey):不占分屏,但以 Offstage
  /// 挂在树里保活(pty/滚动缓冲不断),点标签放回分屏。
  final Set<String> _minimizedKeys = <String>{};

  /// 正在「摆放」的最小化会话:点标签拿起,影子跟随鼠标,
  /// 悬停分屏高亮落点(上下左右/中),点击放下;右键/Esc 取消
  String? _placingKey;
  Offset? _placingCursor;
  final FocusNode _placingFocus = FocusNode(debugLabel: 'pane-placing');

  /// 命令广播(sync input):开启后任一分屏的输入同时发给所有会话
  bool _broadcastInput = false;

  /// 分屏同步滚动:开启后任一分屏滚动,其余会话按比例跟随
  bool _syncScroll = false;

  /// 把一段原始输入发给工作区内所有会话的 pty(命令广播用)
  void _broadcastRawInput(String payload) {
    for (final session in _sessions) {
      final state = session.viewKey.currentState;
      if (state is _TerminalSessionViewState) {
        state.injectRawInput(payload);
      }
    }
  }

  /// 把滚动比例同步给除 [source] 外的所有会话(同步滚动用)
  void _propagateScrollRatio(double ratio, Object source) {
    for (final session in _sessions) {
      final state = session.viewKey.currentState;
      if (state is _TerminalSessionViewState && !identical(state, source)) {
        state.applySyncedScroll(ratio);
      }
    }
  }

  /// 分屏比例拖拽是逐像素回调,持久化防抖合并,避免每帧 JSON+写盘
  Timer? _saveSessionsDebounce;

  static const _fontScalePrefKey = 'workbench_terminal_font_scale_v1';
  static const _minFontScale = 0.7;
  static const _maxFontScale = 2.0;
  static const _fontScaleStep = 0.1;
  static const _minPaneExtent = 140.0;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    // 本地终端页保底一个 shell 会话;远程工作区允许空态,等宿主发起连接
    if (!widget.remoteWorkspace) {
      _sessions = [
        _TerminalSessionDescriptor(id: 1, keyPrefix: widget.sessionPrefix),
      ];
      _nextSessionId = 2;
    }
    _root = _PaneLeaf(
      id: 1,
      sessionKey: _sessions.isEmpty ? '' : _sessions.first.providerKey,
    );
    unawaited(_loadFontScale());
    unawaited(_loadSessions());
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) {
      widget.controller?._state = null;
    }
    // 有待写入的会话快照就同步冲掉,避免拖拽后立刻退出丢最后一次布局
    if (_saveSessionsDebounce?.isActive ?? false) {
      _saveSessionsDebounce!.cancel();
      unawaited(_saveSessions());
    }
    _placingFocus.dispose();
    super.dispose();
  }

  void _scheduleSaveSessions() {
    _saveSessionsDebounce?.cancel();
    _saveSessionsDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_saveSessions());
    });
  }

  // ---------------------------------------------------------------------------
  // Session persistence
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _paneNodeToJson(_PaneNode node) {
    if (node is _PaneLeaf) {
      return {'type': 'leaf', 'id': node.id, 'sessionKey': node.sessionKey};
    }
    final branch = node as _PaneBranch;
    return {
      'type': 'branch',
      'axis': branch.axis == Axis.horizontal ? 'h' : 'v',
      'ratio': branch.ratio,
      'first': _paneNodeToJson(branch.first),
      'second': _paneNodeToJson(branch.second),
    };
  }

  _PaneNode? _paneNodeFromJson(Map<String, dynamic>? map) {
    if (map == null) return null;
    final type = map['type'] as String?;
    if (type == 'leaf') {
      final id = map['id'] as int?;
      final sessionKey = map['sessionKey'] as String?;
      if (id == null || sessionKey == null) return null;
      return _PaneLeaf(id: id, sessionKey: sessionKey);
    } else if (type == 'branch') {
      final axisStr = map['axis'] as String?;
      final ratio = (map['ratio'] as num?)?.toDouble() ?? 0.5;
      final first = _paneNodeFromJson(map['first'] as Map<String, dynamic>?);
      final second = _paneNodeFromJson(map['second'] as Map<String, dynamic>?);
      if (first == null || second == null) return null;
      final branch = _PaneBranch(
        axis: axisStr == 'v' ? Axis.vertical : Axis.horizontal,
        first: first,
        second: second,
      );
      branch.ratio = ratio.clamp(0.1, 0.9);
      return branch;
    }
    return null;
  }

  Future<void> _loadSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(widget.sessionsPrefKey);
      if (raw == null || raw.isEmpty || !mounted) return;
      final map = json.decode(raw) as Map<String, dynamic>;
      final sessionList = (map['sessions'] as List<dynamic>?) ?? [];
      if (sessionList.isEmpty) return;
      final nextId = (map['nextSessionId'] as int?) ?? 2;
      final activeId = (map['activeSessionId'] as int?) ?? 1;
      final nextPaneId = (map['nextPaneId'] as int?) ?? 2;
      final restored = <_TerminalSessionDescriptor>[];
      for (final entry in sessionList) {
        final id = entry['id'] as int?;
        final cwd = entry['cwd'] as String?;
        if (id == null) continue;
        restored.add(
          _TerminalSessionDescriptor(
            id: id,
            keyPrefix: widget.sessionPrefix,
            initialCwd: cwd,
            remoteKey: entry['remoteKey'] as String?,
            remoteTitle: entry['remoteTitle'] as String?,
            remoteCommand: entry['remoteCommand'] as String?,
            // 恢复的 SSH 会话自动试拨一次(ControlMaster/密钥下无感;
            // 连不上会打「已断开,回车重连」),不再落成本地终端
            autoConnect: ((entry['remoteCommand'] as String?) ?? '').isNotEmpty,
          )..customTitle = entry['customTitle'] as String?,
        );
      }
      if (restored.isEmpty) return;
      final minimizedIds = ((map['minimizedIds'] as List<dynamic>?) ?? [])
          .whereType<int>()
          .toSet();
      setState(() {
        _sessions = restored;
        _nextSessionId = nextId;
        _nextPaneId = nextPaneId;
        _minimizedKeys
          ..clear()
          ..addAll([
            for (final s in restored)
              if (minimizedIds.contains(s.id)) s.providerKey,
          ]);
        // 分屏树只承载未最小化的会话
        final visible = [
          for (final s in restored)
            if (!_minimizedKeys.contains(s.providerKey)) s,
        ];

        final restoredRoot = _paneNodeFromJson(
          map['root'] as Map<String, dynamic>?,
        );
        final restoredLeafKeys = <String>{};
        void collectKeys(_PaneNode? n) {
          if (n is _PaneLeaf) {
            restoredLeafKeys.add(n.sessionKey);
          } else if (n is _PaneBranch) {
            collectKeys(n.first);
            collectKeys(n.second);
          }
        }

        collectKeys(restoredRoot);
        final allSessionsMatched =
            visible.length == restoredLeafKeys.length &&
            visible.every((s) => restoredLeafKeys.contains(s.providerKey));

        if (restoredRoot != null && allSessionsMatched) {
          _root = restoredRoot;
        } else if (visible.isEmpty) {
          // 全部最小化:空占位分屏,等标签点击恢复
          _root = _PaneLeaf(id: 1, sessionKey: '');
        } else {
          // Rebuild pane tree with equal ratio distribution so all tabs have uniform width.
          _root = _PaneLeaf(id: 1, sessionKey: visible.first.providerKey);
          var paneId = 2;
          for (var i = 1; i < visible.length; i++) {
            final newLeaf = _PaneLeaf(
              id: paneId,
              sessionKey: visible[i].providerKey,
            );
            final branch = _PaneBranch(
              axis: Axis.horizontal,
              first: _root,
              second: newLeaf,
            );
            branch.ratio = i / (i + 1);
            _root = branch;
            paneId++;
          }
          _nextPaneId = paneId;
        }

        // Restore active pane: find the leaf whose session matches activeId.
        final activeDesc = _sessions.where((s) => s.id == activeId);
        if (activeDesc.isNotEmpty) {
          final leaf = _leafShowing(activeDesc.first.providerKey);
          if (leaf != null) _activePaneId = leaf.id;
        }
      });
    } catch (_) {
      // Session restore is best-effort; failures should not block terminal use.
    }
  }

  Future<void> _saveSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final activeLeaf = _activeLeaf();
      final activeDesc = activeLeaf != null
          ? _descriptorFor(activeLeaf.sessionKey)
          : null;
      final map = <String, dynamic>{
        'sessions': [
          for (final s in _sessions)
            {
              'id': s.id,
              'cwd': s.lastKnownCwd ?? '',
              if (s.remoteKey != null) 'remoteKey': s.remoteKey,
              if (s.remoteTitle != null) 'remoteTitle': s.remoteTitle,
              if (s.remoteCommand != null) 'remoteCommand': s.remoteCommand,
              if (s.customTitle != null && s.customTitle!.isNotEmpty)
                'customTitle': s.customTitle,
            },
        ],
        'root': _paneNodeToJson(_root),
        'minimizedIds': [
          for (final s in _sessions)
            if (_minimizedKeys.contains(s.providerKey)) s.id,
        ],
        'activeSessionId': activeDesc?.id ?? 1,
        'nextSessionId': _nextSessionId,
        'nextPaneId': _nextPaneId,
      };
      await prefs.setString(widget.sessionsPrefKey, json.encode(map));
    } catch (_) {
      // Persistence errors should not disrupt terminal usage.
    }
  }

  void _handleSessionCwdChanged(String providerKey, String cwd) {
    final desc = _descriptorFor(providerKey);
    if (desc == null || desc.lastKnownCwd == cwd) return;
    desc.lastKnownCwd = cwd;
    _scheduleSaveSessions();
  }

  // ---------------------------------------------------------------------------
  // Font zoom (persisted globally across sessions)
  // ---------------------------------------------------------------------------

  Future<void> _loadFontScale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getDouble(_fontScalePrefKey);
      if (stored == null || !mounted) return;
      final clamped = stored.clamp(_minFontScale, _maxFontScale).toDouble();
      if (clamped == _fontScale) return;
      setState(() => _fontScale = clamped);
    } catch (_) {}
  }

  Future<void> _persistFontScale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_fontScalePrefKey, _fontScale);
    } catch (_) {}
  }

  void _zoomBy(int steps) {
    final next = (_fontScale + steps * _fontScaleStep)
        .clamp(_minFontScale, _maxFontScale)
        .toDouble();
    if (next == _fontScale) return;
    setState(() => _fontScale = next);
    unawaited(_persistFontScale());
  }

  void _resetZoom() {
    if (_fontScale == 1.0) return;
    setState(() => _fontScale = 1.0);
    unawaited(_persistFontScale());
  }

  // ---------------------------------------------------------------------------
  // Pane tree helpers
  // ---------------------------------------------------------------------------

  _TerminalSessionDescriptor? _descriptorFor(String providerKey) {
    for (final session in _sessions) {
      if (session.providerKey == providerKey) return session;
    }
    return null;
  }

  List<int> _leafIds() {
    final ids = <int>[];
    void walk(_PaneNode node) {
      if (node is _PaneLeaf) {
        ids.add(node.id);
      } else if (node is _PaneBranch) {
        walk(node.first);
        walk(node.second);
      }
    }

    walk(_root);
    return ids;
  }

  int get _paneCount => _leafIds().length;

  _PaneLeaf? _leafById(int paneId) {
    _PaneLeaf? found;
    void walk(_PaneNode node) {
      if (found != null) return;
      if (node is _PaneLeaf) {
        if (node.id == paneId) found = node;
      } else if (node is _PaneBranch) {
        walk(node.first);
        walk(node.second);
      }
    }

    walk(_root);
    return found;
  }

  _PaneLeaf? _leafShowing(String providerKey) {
    _PaneLeaf? found;
    void walk(_PaneNode node) {
      if (found != null) return;
      if (node is _PaneLeaf) {
        if (node.sessionKey == providerKey) found = node;
      } else if (node is _PaneBranch) {
        walk(node.first);
        walk(node.second);
      }
    }

    walk(_root);
    return found;
  }

  _PaneLeaf? _activeLeaf() {
    final leaf = _leafById(_activePaneId);
    if (leaf != null) return leaf;
    final ids = _leafIds();
    if (ids.isEmpty) return null;
    _activePaneId = ids.first;
    return _leafById(_activePaneId);
  }

  String? get _activeSessionKey => _activeLeaf()?.sessionKey;

  void _ensureActiveLeaf() {
    final ids = _leafIds();
    if (!ids.contains(_activePaneId)) {
      _activePaneId = ids.isEmpty ? 1 : ids.first;
    }
  }

  _PaneNode _replaceLeafWithBranch(
    _PaneNode node,
    int paneId,
    Axis axis,
    _PaneLeaf newLeaf,
  ) {
    if (node is _PaneLeaf) {
      if (node.id != paneId) return node;
      return _PaneBranch(axis: axis, first: node, second: newLeaf);
    }
    final branch = node as _PaneBranch;
    branch.first = _replaceLeafWithBranch(branch.first, paneId, axis, newLeaf);
    branch.second = _replaceLeafWithBranch(
      branch.second,
      paneId,
      axis,
      newLeaf,
    );
    return branch;
  }

  _PaneNode? _removeLeaf(_PaneNode node, int paneId) {
    if (node is _PaneLeaf) {
      return node.id == paneId ? null : node;
    }
    final branch = node as _PaneBranch;
    final first = _removeLeaf(branch.first, paneId);
    final second = _removeLeaf(branch.second, paneId);
    if (first == null && second == null) return null;
    if (first == null) return second;
    if (second == null) return first;
    branch.first = first;
    branch.second = second;
    return branch;
  }

  // ---------------------------------------------------------------------------
  // Session / pane operations
  // ---------------------------------------------------------------------------

  void _activatePane(int paneId) {
    if (_activePaneId == paneId) return;
    setState(() => _activePaneId = paneId);
  }

  /// 会话标签改名:弹框输入,空则清除自定义名回落默认标题
  Future<void> _renameSession(_TerminalSessionDescriptor descriptor) async {
    final controller = TextEditingController(text: descriptor.title);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    final result = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => AlertDialog(
        title: Text(tr('重命名标签')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: descriptor.remoteTitle ?? tr2('终端 {0}', [descriptor.id]),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(' '), // 清除标记
            child: Text(tr('恢复默认')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(tr('确定')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    setState(() {
      // ' ' = 恢复默认;其余按输入(去首尾空白,空串也视为清除)
      descriptor.customTitle = result == ' ' ? null : result.trim();
    });
    unawaited(_saveSessions());
  }

  void _selectSession(String providerKey) {
    // 最小化的会话:点标签「拿起」进入摆放模式,再点目标分屏放下
    // (再点一次同标签取消;摆放中点其它最小化标签则换目标)
    if (_minimizedKeys.contains(providerKey)) {
      if (_placingKey == providerKey) {
        _cancelPlacing();
      } else {
        _beginPlacing(providerKey);
      }
      return;
    }
    // Sessions map 1:1 to visible panes, so selecting simply focuses the
    // matching pane — it never evicts the terminal already shown elsewhere.
    final existing = _leafShowing(providerKey);
    if (existing != null) _activatePane(existing.id);
  }

  /// 把分屏最小化到底部标签:会话保活(Offstage 继续挂着 pty),
  /// 只从分屏树里摘掉;点标签恢复。
  void _minimizePane(int paneId) {
    final leaf = _leafById(paneId);
    if (leaf == null || leaf.sessionKey.isEmpty) return;
    setState(() {
      _minimizedKeys.add(leaf.sessionKey);
      final next = _removeLeaf(_root, paneId);
      // 最后一个分屏也可以最小化:留一个空占位,等标签点击恢复
      _root = next ?? _PaneLeaf(id: _nextPaneId++, sessionKey: '');
      _ensureActiveLeaf();
    });
    unawaited(_saveSessions());
  }

  void _beginPlacing(String providerKey) {
    setState(() {
      _placingKey = providerKey;
      _placingCursor = null;
    });
    _placingFocus.requestFocus();
  }

  void _cancelPlacing() {
    if (_placingKey == null) return;
    setState(() {
      _placingKey = null;
      _placingCursor = null;
    });
  }

  /// 摆放落位:把拿起的最小化会话放到目标分屏的指定区域
  void _completePlacing(int paneId, _DropRegion region) {
    final key = _placingKey;
    if (key == null) return;
    setState(() {
      _placingKey = null;
      _placingCursor = null;
    });
    // 会话可能在摆放途中被关闭,只有仍在最小化集合里才落位
    if (_minimizedKeys.contains(key)) {
      _handlePaneDrop(paneId, region, key);
    }
  }

  void _addSession({_TerminalSessionDescriptor? descriptor}) {
    // A new session always opens as its own card (a split of the active pane),
    // so it never displaces an existing terminal.
    final leaf = _sessions.isEmpty ? null : _activeLeaf();
    if (leaf == null || _sessions.isEmpty || leaf.sessionKey.isEmpty) {
      final activeDesc = _descriptorFor(_activeSessionKey ?? '');
      final inheritedCwd = activeDesc?.lastKnownCwd ?? activeDesc?.initialCwd;
      final newDescriptor =
          descriptor ??
          _TerminalSessionDescriptor(
            id: _nextSessionId++,
            keyPrefix: widget.sessionPrefix,
            initialCwd: inheritedCwd,
          );
      setState(() {
        _sessions.add(newDescriptor);
        if (leaf != null && leaf.sessionKey.isEmpty) {
          // 活动分屏是空占位(其余会话都最小化了):直接占用
          leaf.sessionKey = newDescriptor.providerKey;
          _activePaneId = leaf.id;
        } else {
          final newLeaf = _PaneLeaf(
            id: _nextPaneId++,
            sessionKey: newDescriptor.providerKey,
          );
          _root = newLeaf;
          _activePaneId = newLeaf.id;
        }
      });
      unawaited(_saveSessions());
      return;
    }
    _splitPane(leaf.id, Axis.horizontal, descriptor: descriptor);
  }

  /// 宿主(远程页)发起的「连接主机」:该主机已有会话就聚焦/原地重连
  /// (重连对运行中的会话是 no-op),没有才新开一个自动连接的会话
  void _openRemoteSession({
    required String title,
    required String command,
    String? remoteKey,
  }) {
    final existing = remoteKey == null ? null : _remoteSessionFor(remoteKey);
    if (existing != null) {
      _selectSession(existing.providerKey);
      final view = existing.viewKey.currentState;
      if (view is _TerminalSessionViewState) view._reconnectRemote();
      return;
    }
    _addSession(
      descriptor: _TerminalSessionDescriptor(
        id: _nextSessionId++,
        keyPrefix: widget.sessionPrefix,
        remoteKey: remoteKey,
        remoteTitle: title,
        remoteCommand: command,
        autoConnect: true,
      ),
    );
  }

  /// 该主机的既有 SSH 会话;分屏出多个时优先还在运行的那个
  _TerminalSessionDescriptor? _remoteSessionFor(String remoteKey) {
    _TerminalSessionDescriptor? found;
    for (final session in _sessions) {
      if (session.remoteKey != remoteKey) continue;
      found ??= session;
      final view = session.viewKey.currentState;
      if (view is _TerminalSessionViewState && view._isRunning) return session;
    }
    return found;
  }

  String? _remoteCwdFor(String remoteKey) {
    final view = _remoteSessionFor(remoteKey)?.viewKey.currentState;
    return view is _TerminalSessionViewState ? view._remoteCwdGuess : null;
  }

  /// 会话被永久关闭后清掉它的专属命令历史,不留孤儿存储
  Future<void> _removeSessionHistory(String providerKey) async {
    try {
      await CommandHistoryStore.removeSession(providerKey);
    } catch (_) {
      // 清理失败只是多占一条历史记录,不影响使用
    }
  }

  void _closeSession(String providerKey) {
    // 本地终端页保底一个会话;远程工作区允许全部关掉回到空态
    if (_sessions.length <= 1 && !widget.remoteWorkspace) return;
    if (_descriptorFor(providerKey) == null) return;
    unawaited(_removeSessionHistory(providerKey));
    setState(() {
      _minimizedKeys.remove(providerKey);
      _sessions.removeWhere((session) => session.providerKey == providerKey);
      if (_sessions.isEmpty) {
        _root = _PaneLeaf(id: 1, sessionKey: '');
        _activePaneId = 1;
        return;
      }
      final leaf = _leafShowing(providerKey);
      if (leaf != null) {
        if (_root is _PaneLeaf) {
          // 剩下的会话可能都在最小化:只把未最小化的填回分屏,
          // 否则留空占位(最小化的仍以 Offstage 保活)
          final visible = _sessions.where(
            (s) => !_minimizedKeys.contains(s.providerKey),
          );
          leaf.sessionKey = visible.isEmpty ? '' : visible.first.providerKey;
        } else {
          final next = _removeLeaf(_root, leaf.id);
          if (next != null) _root = next;
        }
      }
      _ensureActiveLeaf();
    });
    unawaited(_saveSessions());
  }

  void _splitPane(
    int paneId,
    Axis axis, {
    _TerminalSessionDescriptor? descriptor,
  }) {
    final sourceLeaf = _leafById(paneId);
    final sourceDesc = sourceLeaf != null
        ? _descriptorFor(sourceLeaf.sessionKey)
        : null;
    final inheritedCwd = sourceDesc?.lastKnownCwd ?? sourceDesc?.initialCwd;
    // 分屏一个 SSH 会话 = 到同主机再开一条连接(ControlMaster 复用免认证);
    // 本地会话照旧只继承 cwd。
    final newDescriptor =
        descriptor ??
        _TerminalSessionDescriptor(
          id: _nextSessionId++,
          keyPrefix: widget.sessionPrefix,
          initialCwd: inheritedCwd,
          remoteKey: sourceDesc?.remoteKey,
          remoteTitle: sourceDesc?.remoteTitle,
          remoteCommand: sourceDesc?.remoteCommand,
          autoConnect: sourceDesc?.isRemote ?? false,
        );
    final newLeaf = _PaneLeaf(
      id: _nextPaneId++,
      sessionKey: newDescriptor.providerKey,
    );
    setState(() {
      _sessions.add(newDescriptor);
      _root = _replaceLeafWithBranch(_root, paneId, axis, newLeaf);
      _activePaneId = newLeaf.id;
    });
    unawaited(_saveSessions());
  }

  void _closePane(int paneId) {
    // 仅剩一个分屏且没有最小化的会话可退路时,本地终端页保底不关
    if (_root is _PaneLeaf &&
        _sessions.length <= 1 &&
        !widget.remoteWorkspace) {
      return;
    }
    final leaf = _leafById(paneId);
    if (leaf != null) {
      unawaited(_removeSessionHistory(leaf.sessionKey));
    }
    setState(() {
      if (leaf != null) {
        // 1:1 model: closing a card also closes (disposes) its terminal.
        _sessions.removeWhere((s) => s.providerKey == leaf.sessionKey);
      }
      if (_sessions.isEmpty) {
        _root = _PaneLeaf(id: 1, sessionKey: '');
        _activePaneId = 1;
        return;
      }
      final next = _removeLeaf(_root, paneId);
      // 树被摘空(其余会话都在最小化):留空占位
      _root = next ?? _PaneLeaf(id: _nextPaneId++, sessionKey: '');
      _ensureActiveLeaf();
    });
    unawaited(_saveSessions());
  }

  _PaneNode _insertSplit(
    _PaneNode node,
    int paneId,
    Axis axis,
    _PaneLeaf newLeaf,
    bool newLeafFirst,
  ) {
    if (node is _PaneLeaf) {
      if (node.id != paneId) return node;
      return _PaneBranch(
        axis: axis,
        first: newLeafFirst ? newLeaf : node,
        second: newLeafFirst ? node : newLeaf,
      );
    }
    final branch = node as _PaneBranch;
    branch.first = _insertSplit(
      branch.first,
      paneId,
      axis,
      newLeaf,
      newLeafFirst,
    );
    branch.second = _insertSplit(
      branch.second,
      paneId,
      axis,
      newLeaf,
      newLeafFirst,
    );
    return branch;
  }

  /// Handles dropping a dragged session (from a pane handle or the sidebar)
  /// onto [targetPaneId] in the given [region], rearranging the split layout.
  void _handlePaneDrop(
    int targetPaneId,
    _DropRegion region,
    String sessionKey,
  ) {
    final sourceLeaf = _leafShowing(sessionKey);
    final sourcePaneId = sourceLeaf?.id;
    if (sourcePaneId == targetPaneId) return;
    final targetLeaf = _leafById(targetPaneId);
    if (targetLeaf == null) return;

    if (region == _DropRegion.center) {
      setState(() {
        if (sourceLeaf != null) {
          final swapped = targetLeaf.sessionKey;
          targetLeaf.sessionKey = sourceLeaf.sessionKey;
          sourceLeaf.sessionKey = swapped;
        } else {
          // 拖的是最小化的会话:它放大到目标分屏,原会话退到标签保活
          if (targetLeaf.sessionKey.isNotEmpty) {
            _minimizedKeys.add(targetLeaf.sessionKey);
          }
          _minimizedKeys.remove(sessionKey);
          targetLeaf.sessionKey = sessionKey;
        }
        _activePaneId = targetPaneId;
      });
      unawaited(_saveSessions());
      return;
    }

    final axis = region == _DropRegion.left || region == _DropRegion.right
        ? Axis.horizontal
        : Axis.vertical;
    final newLeafFirst =
        region == _DropRegion.left || region == _DropRegion.top;
    setState(() {
      if (sourcePaneId != null) {
        final next = _removeLeaf(_root, sourcePaneId);
        if (next != null) _root = next;
      }
      // 最小化的会话被拖成新分屏 = 恢复
      _minimizedKeys.remove(sessionKey);
      final newLeaf = _PaneLeaf(id: _nextPaneId++, sessionKey: sessionKey);
      _root = _insertSplit(_root, targetPaneId, axis, newLeaf, newLeafFirst);
      _activePaneId = newLeaf.id;
      _ensureActiveLeaf();
    });
    unawaited(_saveSessions());
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  /// 页面头部副标题:当前活动会话的名称(远程工作区不显示本页头)
  String? get _headerSubtitle {
    final key = _activeSessionKey;
    if (key == null) return null;
    return _descriptorFor(key)?.title;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 远程工作区复用本页,由 RemotePage 提供自己的头部,这里只在独立终端页显示
          if (!widget.remoteWorkspace)
            PageTopBar(
              icon: LucideIcons.squareTerminal300,
              title: AppL10n.current.terminal,
              subtitle: _headerSubtitle,
            ),
          Expanded(child: _buildPaneArea(context)),
          _buildSessionTabBar(context),
        ],
      ),
    );
  }

  Widget _buildSessionTabBar(BuildContext context) {
    final activeKey = _activeSessionKey;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      child: Row(
        children: [
          Icon(
            widget.remoteWorkspace
                ? LucideIcons.server300
                : LucideIcons.terminal300,
            size: 16,
            color: AppTheme.brandColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final descriptor in _sessions)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _TerminalSessionTab(
                        sessionKey: descriptor.providerKey,
                        title: descriptor.title,
                        isActive: descriptor.providerKey == activeKey,
                        canClose:
                            widget.remoteWorkspace || _sessions.length > 1,
                        isRemote: descriptor.isRemote,
                        isMinimized: _minimizedKeys.contains(
                          descriptor.providerKey,
                        ),
                        onSelect: () => _selectSession(descriptor.providerKey),
                        onClose: () => _closeSession(descriptor.providerKey),
                        onRename: () => _renameSession(descriptor),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 远程工作区的新会话只能从主机列表发起,不提供裸加号(会开成本地 shell)
          if (!widget.remoteWorkspace)
            _TerminalIconButton(
              tooltip: tr('新建会话'),
              icon: LucideIcons.plus300,
              size: 30,
              iconSize: 16,
              ghost: true,
              onPressed: _addSession,
            ),
        ],
      ),
    );
  }

  Widget _buildPaneArea(BuildContext context) {
    // 远程工作区空态:还没有任何 SSH 会话
    if (_sessions.isEmpty) {
      return Container(
        color: AppTheme.surfaceColor,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.squareTerminal300,
                size: 40,
                color: AppTheme.subtleTextColor.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                widget.emptyHint.isEmpty ? tr('暂无会话') : widget.emptyHint,
                style: TextStyle(fontSize: 13, color: AppTheme.subtleTextColor),
              ),
            ],
          ),
        ),
      );
    }
    // Every non-minimized session maps 1:1 to a visible pane. Minimized
    // sessions stay mounted offstage (same GlobalKey) so their pty keeps
    // running; restoring simply reparents the live state back into the tree.
    final paneStack = Stack(
      fit: StackFit.expand,
      children: [
        _buildPaneNode(_root),
        for (final descriptor in _sessions)
          if (_minimizedKeys.contains(descriptor.providerKey))
            Offstage(
              child: TickerMode(
                enabled: false,
                child: _buildSessionHost(
                  descriptor,
                  isActive: false,
                  leaf: null,
                ),
              ),
            ),
      ],
    );
    if (_placingKey == null) {
      return Container(color: AppTheme.surfaceColor, child: paneStack);
    }
    // 摆放模式:提示条 + 会话影子跟随鼠标,Esc 取消
    final placingTitle = _descriptorFor(_placingKey!)?.title ?? '';
    final cursor = _placingCursor;
    return Container(
      color: AppTheme.surfaceColor,
      child: Focus(
        focusNode: _placingFocus,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _cancelPlacing();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          onHover: (e) => setState(() => _placingCursor = e.localPosition),
          child: Stack(
            fit: StackFit.expand,
            children: [
              paneStack,
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceColor,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppTheme.brandColor.withValues(alpha: 0.5),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Text(
                        tr2('点击目标分屏放置「{0}」· 右键或 Esc 取消', [placingTitle]),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.headingColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (cursor != null)
                Positioned(
                  left: cursor.dx + 14,
                  top: cursor.dy + 14,
                  child: IgnorePointer(
                    child: _TerminalDragFeedback(title: placingTitle),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaneNode(_PaneNode node) {
    if (node is _PaneLeaf) return _buildPaneLeaf(node);
    final branch = node as _PaneBranch;
    final horizontal = branch.axis == Axis.horizontal;
    return LayoutBuilder(
      builder: (context, constraints) {
        const dividerThickness = 6.0;
        final total = horizontal ? constraints.maxWidth : constraints.maxHeight;
        final available = math.max(0.0, total - dividerThickness);
        final minExtent = math.min(_minPaneExtent, available / 2);
        final maxExtent = math.max(minExtent, available - minExtent);
        final firstExtent = (available * branch.ratio).clamp(
          minExtent,
          maxExtent,
        );
        final secondExtent = math.max(0.0, available - firstExtent);
        final first = SizedBox(
          width: horizontal ? firstExtent : null,
          height: horizontal ? null : firstExtent,
          child: _buildPaneNode(branch.first),
        );
        final second = SizedBox(
          width: horizontal ? secondExtent : null,
          height: horizontal ? null : secondExtent,
          child: _buildPaneNode(branch.second),
        );
        final divider = _PaneDivider(
          axis: branch.axis,
          onDragDelta: (delta) {
            if (available <= 0) return;
            setState(() {
              branch.ratio = ((firstExtent + delta) / available).clamp(
                0.1,
                0.9,
              );
            });
            _scheduleSaveSessions();
          },
        );
        final children = <Widget>[first, divider, second];
        return horizontal
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              );
      },
    );
  }

  Widget _buildPaneLeaf(_PaneLeaf leaf) {
    final descriptor = _descriptorFor(leaf.sessionKey);
    if (descriptor == null) {
      // 空占位分屏(会话都最小化了):提示从底部标签恢复
      if (_minimizedKeys.isNotEmpty) {
        return _PaneDropTarget(
          paneId: leaf.id,
          onDrop: _handlePaneDrop,
          placingKey: _placingKey,
          onPlace: _completePlacing,
          onCancelPlace: _cancelPlacing,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.minimize2300,
                  size: 36,
                  color: AppTheme.subtleTextColor.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                Text(
                  tr('会话已最小化,点击下方标签恢复'),
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }
    final isActive = leaf.id == _activePaneId;
    return _PaneDropTarget(
      paneId: leaf.id,
      onDrop: _handlePaneDrop,
      placingKey: _placingKey,
      onPlace: _completePlacing,
      onCancelPlace: _cancelPlacing,
      child: _buildSessionHost(descriptor, isActive: isActive, leaf: leaf),
    );
  }

  Widget _buildSessionHost(
    _TerminalSessionDescriptor descriptor, {
    required bool isActive,
    required _PaneLeaf? leaf,
  }) {
    final canClosePane =
        leaf != null &&
        (_paneCount > 1 || _sessions.length > 1 || widget.remoteWorkspace);
    return _TerminalSessionView(
      key: descriptor.viewKey,
      sessionId: descriptor.providerKey,
      title: descriptor.title,
      initialCwd: descriptor.initialCwd,
      remoteKey: descriptor.remoteKey,
      remoteCommand: descriptor.remoteCommand,
      autoConnect: descriptor.autoConnect,
      onAutoConnectConsumed: () => descriptor.autoConnect = false,
      onOpenRemoteFiles:
          widget.onOpenRemoteFiles == null || descriptor.remoteKey == null
          ? null
          : () => widget.onOpenRemoteFiles!(descriptor.remoteKey!),
      listRemoteDir: widget.listRemoteDir,
      uploadToRemote: widget.uploadToRemote,
      uploadDirToRemote: widget.uploadDirToRemote,
      downloadFromRemote: widget.downloadFromRemote,
      remoteFileActions: widget.remoteFileActions,
      runRemoteGit: widget.runRemoteGit,
      isRemoteElevated: widget.isRemoteElevated,
      elevateRemote: widget.elevateRemote,
      dropRemoteElevation: widget.dropRemoteElevation,
      broadcastAvailable: _sessions.length > 1,
      broadcastEnabled: _broadcastInput && _sessions.length > 1,
      onToggleBroadcast: () =>
          setState(() => _broadcastInput = !_broadcastInput),
      onBroadcastInput: _broadcastRawInput,
      syncScrollEnabled: _syncScroll && _sessions.length > 1,
      onToggleSyncScroll: () => setState(() => _syncScroll = !_syncScroll),
      onSyncScroll: _propagateScrollRatio,
      fontScale: _fontScale,
      isActive: isActive,
      isVisible: leaf != null,
      onRequestActivate: leaf == null ? null : () => _activatePane(leaf.id),
      onSplitHorizontal: leaf == null
          ? null
          : () => _splitPane(leaf.id, Axis.horizontal),
      onSplitVertical: leaf == null
          ? null
          : () => _splitPane(leaf.id, Axis.vertical),
      canClosePane: canClosePane,
      onClosePane: canClosePane ? () => _closePane(leaf.id) : null,
      onMinimizePane: leaf == null ? null : () => _minimizePane(leaf.id),
      onZoomIn: () => _zoomBy(1),
      onZoomOut: () => _zoomBy(-1),
      onZoomReset: _resetZoom,
      onCwdChanged: (cwd) =>
          _handleSessionCwdChanged(descriptor.providerKey, cwd),
    );
  }
}

/// 输出区一行的命中标记(格子选择:hitTest 精确定位行,行高可变也不怕)
class _TerminalRowTag {
  const _TerminalRowTag(this.index);

  final int index;
}

/// A node in the terminal split-pane layout tree.
sealed class _PaneNode {}

class _PaneLeaf extends _PaneNode {
  _PaneLeaf({required this.id, required this.sessionKey});

  final int id;
  String sessionKey;
}

class _PaneBranch extends _PaneNode {
  _PaneBranch({required this.axis, required this.first, required this.second});

  final Axis axis;
  _PaneNode first;
  _PaneNode second;
  double ratio = 0.5;
}

/// 搜索命中滚动条标记的画笔:轨道 + 每个命中的短横,当前命中更亮更宽。
class _SearchRulerPainter extends CustomPainter {
  _SearchRulerPainter({
    required this.matches,
    required this.activeIndex,
    required this.totalLines,
    required this.matchColor,
    required this.activeColor,
    required this.trackColor,
  });

  final List<int> matches;
  final int activeIndex;
  final int totalLines;
  final Color matchColor;
  final Color activeColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    // 轨道背景
    final track = Paint()..color = trackColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width / 2 - 1, 0, 2, size.height),
        const Radius.circular(1),
      ),
      track,
    );
    final denom = math.max(1, totalLines - 1);
    final paint = Paint()..color = matchColor;
    for (var i = 0; i < matches.length; i++) {
      final y = (matches[i] / denom).clamp(0.0, 1.0) * size.height;
      final active = i == activeIndex;
      paint.color = active ? activeColor : matchColor;
      final tickWidth = active ? size.width : size.width * 0.7;
      final tickHeight = active ? 3.0 : 2.0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            (size.width - tickWidth) / 2,
            (y - tickHeight / 2).clamp(0.0, size.height - tickHeight),
            tickWidth,
            tickHeight,
          ),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SearchRulerPainter old) =>
      old.matches != matches ||
      old.activeIndex != activeIndex ||
      old.totalLines != totalLines;
}

/// overview minimap 画笔:每条缓冲区行画一道墨迹条(宽度∝内容长度),
/// 命令边界(OSC 133)用状态色、搜索命中用警示色标出;顶上叠视口框。
class _MinimapPainter extends CustomPainter {
  _MinimapPainter({
    required this.lines,
    required this.scroll,
    required this.searchMatches,
    required this.inkColor,
    required this.matchColor,
    required this.successColor,
    required this.errorColor,
    required this.promptColor,
    required this.viewportColor,
    required this.viewportBorder,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<TerminalLine> lines;
  final ScrollPosition? scroll;
  final Set<int> searchMatches;
  final Color inkColor;
  final Color matchColor;
  final Color successColor;
  final Color errorColor;
  final Color promptColor;
  final Color viewportColor;
  final Color viewportBorder;

  @override
  void paint(Canvas canvas, Size size) {
    final n = lines.length;
    if (n == 0) return;
    const pad = 4.0;
    final usableW = size.width - pad * 2;
    // 每行占的像素高度(至少 0.5px);行多于像素则多行叠在同一像素带
    final rowH = size.height / n;
    final paint = Paint();
    for (var i = 0; i < n; i++) {
      final line = lines[i];
      final y = i * rowH;
      final len = line.length;
      Color color;
      double w;
      if (line.isPromptStart) {
        color = line.commandExitCode == null
            ? promptColor
            : line.commandExitCode == 0
            ? successColor
            : errorColor;
        w = usableW; // 命令边界画满宽,便于定位
      } else if (searchMatches.contains(i)) {
        color = matchColor;
        w = usableW;
      } else if (len == 0) {
        continue; // 空行不画
      } else {
        color = inkColor;
        // 内容越长条越宽(封顶满宽);80 列作参考基准
        w = (usableW * (len / 80).clamp(0.06, 1.0));
      }
      paint.color = color;
      canvas.drawRect(
        Rect.fromLTWH(pad, y, w, math.max(0.6, rowH * 0.8)),
        paint,
      );
    }

    // 视口框
    final p = scroll;
    if (p != null && p.hasContentDimensions) {
      final totalExtent = p.maxScrollExtent + p.viewportDimension;
      if (totalExtent > 0) {
        final top = (p.pixels / totalExtent).clamp(0.0, 1.0) * size.height;
        final h =
            (p.viewportDimension / totalExtent).clamp(0.0, 1.0) * size.height;
        final rect = Rect.fromLTWH(0.5, top, size.width - 1, math.max(6, h));
        canvas.drawRect(rect, Paint()..color = viewportColor);
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = viewportBorder,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_MinimapPainter old) => true;
}

/// Payload carried while dragging a session (from a pane handle or the sidebar)
/// to rearrange the split layout.
class _TerminalDragData {
  const _TerminalDragData(this.sessionKey);

  final String sessionKey;
}

class _TerminalSessionDescriptor {
  _TerminalSessionDescriptor({
    required this.id,
    this.keyPrefix = 'terminal',
    this.initialCwd,
    this.remoteKey,
    this.remoteTitle,
    this.remoteCommand,
    this.autoConnect = false,
  }) : viewKey = GlobalKey(
         debugLabel: 'terminal_session_view_${keyPrefix}_$id',
       );

  final int id;

  /// provider key 前缀 — 本地页与远程工作区两套会话的 riverpod family 隔离
  final String keyPrefix;
  final String? initialCwd;

  /// 远程会话对应的主机 id — 点主机列表时按它找到既有会话聚焦/重连,
  /// 而不是每次都新开
  final String? remoteKey;
  final GlobalKey viewKey;

  /// 远程(SSH)会话:标题与连接命令。命令通过现有 pty 跑系统 ssh,
  /// 终端引擎/渲染与本地会话完全共用——传输层的差异只有这一条命令。
  final String? remoteTitle;
  final String? remoteCommand;

  /// 新建/重启恢复的远程会话都会自动拨一次;断开后由回车或
  /// 工具栏「重连」按钮再拨。
  bool autoConnect;

  bool get isRemote => remoteCommand != null && remoteCommand!.isNotEmpty;

  /// Tracks the latest known CWD for session persistence.
  String? lastKnownCwd;

  /// 用户为标签自定义的名字(双击/右键改名);为空时回落默认标题
  String? customTitle;

  String get title => (customTitle != null && customTitle!.isNotEmpty)
      ? customTitle!
      : (remoteTitle ?? tr2('终端 {0}', [id]));
  String get providerKey => '${keyPrefix}_$id';
}

class _TerminalSessionView extends ConsumerStatefulWidget {
  const _TerminalSessionView({
    super.key,
    required this.sessionId,
    required this.title,
    this.initialCwd,
    this.remoteKey,
    this.remoteCommand,
    this.autoConnect = false,
    this.onAutoConnectConsumed,
    this.onOpenRemoteFiles,
    this.listRemoteDir,
    this.uploadToRemote,
    this.uploadDirToRemote,
    this.downloadFromRemote,
    this.remoteFileActions,
    this.runRemoteGit,
    this.isRemoteElevated,
    this.elevateRemote,
    this.dropRemoteElevation,
    this.broadcastAvailable = false,
    this.broadcastEnabled = false,
    this.onToggleBroadcast,
    this.onBroadcastInput,
    this.syncScrollEnabled = false,
    this.onToggleSyncScroll,
    this.onSyncScroll,
    required this.fontScale,
    required this.isActive,
    required this.isVisible,
    required this.onRequestActivate,
    required this.onSplitHorizontal,
    required this.onSplitVertical,
    required this.canClosePane,
    required this.onClosePane,
    this.onMinimizePane,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onZoomReset,
    this.onCwdChanged,
  });

  final String sessionId;
  final String title;
  final String? initialCwd;

  /// 远程会话对应的主机 id(详情面板远端文件列举用)
  final String? remoteKey;

  /// 远程(SSH)会话的连接命令;非空时这是一个远程会话:
  /// 新建时自动运行,断开后工具栏提供「重连」。
  final String? remoteCommand;
  final bool autoConnect;
  final VoidCallback? onAutoConnectConsumed;

  /// 远程会话工具栏「文件(SFTP)」入口;null 不显示
  final VoidCallback? onOpenRemoteFiles;

  /// 远端目录列举器;非空且为远程会话时,详情面板「文件」标签走 SFTP
  final TerminalRemoteDirLister? listRemoteDir;

  /// 详情面板「文件」标签的上传/下载(带进度)
  final TerminalRemoteUploader? uploadToRemote;
  final TerminalRemoteUploader? uploadDirToRemote;
  final TerminalRemoteDownloader? downloadFromRemote;

  /// 详情面板「文件」标签的重命名/删除/新建目录
  final TerminalRemoteFileActions? remoteFileActions;

  /// 远端 git 运行器
  final TerminalRemoteGitRunner? runRemoteGit;

  /// 详情面板文件区提权
  final bool Function(String remoteKey)? isRemoteElevated;
  final Future<bool> Function(String remoteKey)? elevateRemote;
  final void Function(String remoteKey)? dropRemoteElevation;

  /// 命令广播:是否有多会话可广播 / 当前是否开启 / 切换 / 把输入发给所有会话
  final bool broadcastAvailable;
  final bool broadcastEnabled;
  final VoidCallback? onToggleBroadcast;
  final void Function(String payload)? onBroadcastInput;

  /// 分屏同步滚动:是否开启 / 切换 / 把滚动比例广播给其余会话
  final bool syncScrollEnabled;
  final VoidCallback? onToggleSyncScroll;
  final void Function(double ratio, Object source)? onSyncScroll;
  final double fontScale;
  final bool isActive;
  final bool isVisible;
  final VoidCallback? onRequestActivate;
  final VoidCallback? onSplitHorizontal;
  final VoidCallback? onSplitVertical;
  final bool canClosePane;
  final VoidCallback? onClosePane;

  /// 最小化到底部标签(会话保活);null 表示该视图当前不在分屏树里
  final VoidCallback? onMinimizePane;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomReset;
  final ValueChanged<String>? onCwdChanged;

  @override
  ConsumerState<_TerminalSessionView> createState() =>
      _TerminalSessionViewState();
}

class _TerminalSessionViewState extends ConsumerState<_TerminalSessionView>
    with _TerminalEmulator {
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode(debugLabel: 'termInput');
  final FocusNode _ptyFocusNode = FocusNode(debugLabel: 'termPty');
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'termSearch');
  final ValueNotifier<int> _terminalOutputVersion = ValueNotifier<int>(0);
  final GlobalKey _interactiveLineKey = GlobalKey(
    debugLabel: 'terminal_interactive_line',
  );
  final List<String> _history = [];

  // ── 命令历史下拉补全 ──
  final LayerLink _historyLink = LayerLink();
  OverlayEntry? _historyOverlay;
  List<String> _historySuggestions = const [];
  int _historySuggestIndex = -1;
  bool _suppressHistoryFilter = false;
  bool get _historyDropdownOpen => _historyOverlay != null;
  final Map<int, List<Map<dynamic, dynamic>>> _pendingNativePtyEvents = {};
  final Set<String> _systemCommandsCache = {};

  /// 输出合帧缓冲(见 _enqueueOutput):洪峰期积压的未解析 pty 数据
  final StringBuffer _outputBacklog = StringBuffer();
  TerminalLineType? _outputBacklogType;
  Timer? _outputFlushTimer;

  /// 会话日志录制(WindTerm 式):开启后所有输出剥转义后落盘。
  final SessionLogger _sessionLogger = SessionLogger();

  // ── SGR 5/6 闪烁时钟 ──
  // 首次出现闪烁内容前不启动时钟(零开销);之后 ~2Hz 切换相位重绘,
  // _textStyleForSpan 在相位为暗时把闪烁文字调淡,形成闪烁。
  // 缓冲区里不再有闪烁内容时自动停钟(否则一条 \e[5m 之后每秒白白
  // 重绘两次直到会话销毁),下次再写入闪烁内容会重新启动。
  Timer? _blinkTimer;
  bool _blinkPhaseOn = true;
  bool _anyBlinkSeen = false;

  @override
  void _noteBlinkContent() {
    if (_anyBlinkSeen) return;
    _anyBlinkSeen = true;
    _blinkTimer ??= Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (!mounted) return;
      if (!_bufferHasBlinkContent()) {
        _blinkTimer?.cancel();
        _blinkTimer = null;
        _anyBlinkSeen = false;
        // 相位归位为亮,避免残留半透明
        if (!_blinkPhaseOn) {
          _blinkPhaseOn = true;
          _terminalOutputVersion.value++;
        }
        return;
      }
      _blinkPhaseOn = !_blinkPhaseOn;
      _terminalOutputVersion.value++;
    });
  }

  /// 当前缓冲区(含备用屏身后保存的普通缓冲区)是否还有闪烁文字。
  /// 2Hz 调用、纯内存遍历,1200 行上限下开销可忽略。
  bool _bufferHasBlinkContent() {
    bool scan(List<TerminalLine> lines) {
      for (final line in lines) {
        for (final span in line.spans) {
          if (span.style.blink && span.text.trim().isNotEmpty) return true;
        }
      }
      return false;
    }

    return scan(_lines) || (_isAltBufferActive && scan(_normalLines));
  }

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  StreamSubscription<dynamic>? _nativePtySubscription;
  late String _cwd;
  String? _previousCwd;

  /// 最近一次通过可用性探测的目录 — 命中时跳过每条命令前的 probe 进程
  String? _verifiedCwd;
  int? _nativePtySessionId;
  int _historyIndex = 0;
  int _sessionId = 0;
  bool _isRunning = false;
  bool _isPreparingDirectory = false;
  bool _didCheckFullDiskAccess = false;
  bool _nativePtyUnavailable = false;
  bool _autoFollowOutput = true;
  bool _isSearchVisible = false;
  bool _detailsPanelVisible = false;
  double _detailsPanelWidth = _defaultDetailsWidth;
  bool _minimapVisible = false;

  static const _detailsWidthPrefKey = 'workbench_terminal_details_width_v1';
  static const _defaultDetailsWidth = 320.0;
  static const _minDetailsWidth = 240.0;
  static const _maxDetailsWidth = 640.0;
  _TerminalPanelTab _activePanelTab = _TerminalPanelTab.files;
  String? _runningCommand;
  String _searchQuery = '';
  int _activeSearchMatch = -1;
  List<int> _searchMatches = const [];

  // 搜索选项(对标 xterm SearchAddon):正则 / 区分大小写 / 全词
  bool _searchRegex = false;
  bool _searchCaseSensitive = false;
  bool _searchWholeWord = false;

  /// 正则模式下 pattern 非法时置真,用于输入框标红
  bool _searchError = false;

  /// 与 [_searchMatches] 同步的行号集合 — 渲染每行时 O(1) 判断是否命中
  Set<int> _searchMatchSet = const {};
  @override
  double _lastCellWidth = 8;
  @override
  double _lastLineHeight = 16;
  bool _uiStatePublishQueued = false;

  static const _maxHistoryEntries = 200;
  static const _nativePtyMethodChannel = MethodChannel(
    'com.hxlive.termora/terminal_pty',
  );
  static const _nativePtyEventChannel = EventChannel(
    'com.hxlive.termora/terminal_pty/events',
  );

  // The native PTY EventChannel only supports one live listener. With multiple
  // terminal sessions each subscribing directly, the last subscriber would
  // steal the native sink and break the others. So subscribe to the channel
  // exactly once here and fan events out to every session via a Dart broadcast
  // stream; each session filters by its own sessionId.
  static StreamSubscription<dynamic>? _sharedNativePtySubscription;
  static final StreamController<dynamic> _sharedNativePtyEvents =
      StreamController<dynamic>.broadcast();

  static void _ensureSharedNativePtySubscription() {
    if (_sharedNativePtySubscription != null) return;
    _sharedNativePtySubscription = _nativePtyEventChannel
        .receiveBroadcastStream()
        .listen(
          _sharedNativePtyEvents.add,
          onError: _sharedNativePtyEvents.addError,
        );
  }

  static bool _didCheckFullDiskAccessInPage = false;
  static final _terminalLinkPattern = RegExp(
    r'''((?:https?:\/\/|file:\/\/)[^\s<>"']+|www\.[^\s<>"']+)''',
  );

  static String get _initialWorkingDirectory {
    final candidates = <String?>[
      if (Platform.isMacOS) _downloadsDirectoryPath,
      if (!Platform.isMacOS) Platform.environment['PWD'],
      if (!Platform.isMacOS) _homeDirectoryPath,
      Directory.systemTemp.path,
      Directory.current.path,
    ];
    for (final candidate in candidates) {
      if (_directoryLooksReadableSync(candidate)) {
        return candidate!;
      }
    }
    return Directory.systemTemp.path;
  }

  static String? get _homeDirectoryPath {
    final home =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    return home == null || home.isEmpty ? null : home;
  }

  static String? get _downloadsDirectoryPath {
    final home = _homeDirectoryPath;
    if (home == null || home.isEmpty) return null;
    return '$home${Platform.pathSeparator}Downloads';
  }

  static bool _directoryLooksReadableSync(String? path) {
    if (path == null || path.isEmpty) return false;
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) return false;
      dir.listSync(followLinks: false).take(1).toList();
      return true;
    } catch (_) {
      return false;
    }
  }

  TerminalUiState get _uiStateSnapshot {
    return TerminalUiState(
      cwd: _cwd,
      backendLabel: _terminalBackendLabel,
      terminalTitle: _titleStack.current,
      isRunning: _isRunning,
      runningCommand: _runningCommand,
      isPreparingDirectory: _isPreparingDirectory,
      nativePtyUnavailable: _nativePtyUnavailable,
      isAltBufferActive: _isAltBufferActive,
      bracketedPasteMode: _bracketedPasteMode,
      autoWrapMode: _autoWrapMode,
      showCursor: _showCursor,
      autoFollowOutput: _autoFollowOutput,
      isSearchVisible: _isSearchVisible,
      hasOutput: _lines.isNotEmpty,
      searchMatchCount: _searchMatches.length,
      activeSearchMatch: _activeSearchMatch,
    );
  }

  @override
  void _publishUiState() {
    if (!mounted) return;
    if (_uiStatePublishQueued) return;
    _uiStatePublishQueued = true;
    Future<void>.delayed(Duration.zero, () {
      _uiStatePublishQueued = false;
      if (!mounted) return;
      ref
          .read(terminalUiControllerProvider(widget.sessionId).notifier)
          .replace(_uiStateSnapshot);
    });
  }

  /// pty 输出按块到达,vim 一次全屏重绘能拆成几十块;首块立即上屏
  /// 保住回显手感,8ms 窗口内的后续块合并成一次重建,消掉闪烁。
  Timer? _outputNotifyThrottle;
  bool _outputNotifyPending = false;

  @override
  void _notifyTerminalOutputChanged() {
    if (_outputNotifyThrottle != null) {
      _outputNotifyPending = true;
      return;
    }
    _terminalOutputVersion.value++;
    _publishUiState();
    _outputNotifyThrottle = Timer(const Duration(milliseconds: 8), () {
      _outputNotifyThrottle = null;
      if (!mounted || !_outputNotifyPending) return;
      _outputNotifyPending = false;
      _notifyTerminalOutputChanged();
    });
  }

  @override
  void _deferSynchronizedOutputRefresh() {
    _synchronizedOutputRefreshPending = true;
    if (_synchronizedOutputSafetyTimer?.isActive ?? false) return;
    _synchronizedOutputSafetyTimer = Timer(
      const Duration(milliseconds: 160),
      _flushSynchronizedOutputRefresh,
    );
  }

  void _flushSynchronizedOutputRefresh() {
    _synchronizedOutputSafetyTimer?.cancel();
    _synchronizedOutputSafetyTimer = null;
    if (!_synchronizedOutputRefreshPending || !mounted) return;
    _synchronizedOutputRefreshPending = false;
    _refreshSearchMatches();
    _notifyTerminalOutputChanged();
    _scrollToBottom();
  }

  @override
  void _setSynchronizedOutputMode(bool enable) {
    if (_synchronizedOutputMode == enable) {
      if (!enable) _flushSynchronizedOutputRefresh();
      return;
    }
    _synchronizedOutputMode = enable;
    if (!enable) {
      _flushSynchronizedOutputRefresh();
    }
  }

  @override
  void initState() {
    super.initState();
    // Restore persisted CWD or fall back to the default.
    final restored = widget.initialCwd;
    _cwd = (restored != null && restored.isNotEmpty)
        ? restored
        : _initialWorkingDirectory;
    _scrollController.addListener(_handleScrollChanged);
    FocusManager.instance.addListener(_handleGlobalFocusChange);
    unawaited(_loadDetailsWidth());
    unawaited(_resolveLoginShellPath());
    _resetSession();
    _publishUiState();
    unawaited(_loadHistory());
    unawaited(_loadSystemCommands());
    if (Platform.isMacOS || Platform.isWindows) {
      unawaited(_ensureNativePtySubscription());
    }
    unawaited(_initializeWorkingDirectory().then((_) => _maybeAutoConnect()));
    _inputFocusNode.onKeyEvent = (node, event) {
      if (_isNativePtyActive) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.tab) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          _handleTabPressed();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.isActive && !_externalWidgetHasFocus()) {
        _activeInputNode.requestFocus();
      }
      unawaited(_checkFullDiskAccessOnEntry());
      unawaited(SnippetStore.ensureLoaded());
      unawaited(HighlightStore.ensureLoaded());
      unawaited(LinkMatcherStore.ensureLoaded());
      unawaited(
        TerminalThemeStore.ensureLoaded().then((_) {
          if (mounted) _onTerminalThemeChanged();
        }),
      );
    });
    HighlightStore.rules.addListener(_onHighlightRulesChanged);
    LinkMatcherStore.matchers.addListener(_onHighlightRulesChanged);
    TerminalThemeStore.current.addListener(_onTerminalThemeChanged);
    _applyTerminalTheme(TerminalThemeStore.current.value);
  }

  /// 高亮规则增删改后,重绘输出(触发 SliverList 重建,重跑 apply)。
  void _onHighlightRulesChanged() {
    if (mounted) _terminalOutputVersion.value++;
  }

  /// 应用配色方案:主题的 16 ANSI 色作为调色板基色,前景/背景/光标作默认。
  void _applyTerminalTheme(TerminalTheme theme) {
    _palette.applyThemeAnsi(theme.ansi);
    _themeForeground = theme.foreground;
    _themeBackground = theme.background;
    _themeCursor = theme.cursor;
  }

  void _onTerminalThemeChanged() {
    if (!mounted) return;
    setState(() => _applyTerminalTheme(TerminalThemeStore.current.value));
    _terminalOutputVersion.value++;
  }

  @override
  void didUpdateWidget(covariant _TerminalSessionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _externalWidgetHasFocus()) return;
        _activeInputNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _stopProcess(quiet: true);
    unawaited(_sessionLogger.stop());
    HighlightStore.rules.removeListener(_onHighlightRulesChanged);
    LinkMatcherStore.matchers.removeListener(_onHighlightRulesChanged);
    TerminalThemeStore.current.removeListener(_onTerminalThemeChanged);
    _hideHistoryDropdown();
    _blinkTimer?.cancel();
    _searchRefreshCooldown?.cancel();
    _outputFlushTimer?.cancel();
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _nativePtySubscription?.cancel();
    _synchronizedOutputSafetyTimer?.cancel();
    _outputNotifyThrottle?.cancel();
    _terminalOutputVersion.dispose();
    _inputController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    FocusManager.instance.removeListener(_handleGlobalFocusChange);
    _inputFocusNode.dispose();
    _ptyFocusNode.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// 远程会话创建/恢复时自动运行 ssh 连接命令
  void _maybeAutoConnect() {
    if (!mounted || _isRunning) return;
    final command = widget.remoteCommand;
    if (command == null || command.isEmpty) return;
    if (!widget.autoConnect) {
      _appendLine(tr('未连接。按回车重新连接。'), TerminalLineType.system);
      return;
    }
    widget.onAutoConnectConsumed?.call();
    unawaited(_runCommand(command));
  }

  /// 远程会话断开后重连(工具栏按钮/断开后回车)
  void _reconnectRemote() {
    if (_isRunning) return;
    final command = widget.remoteCommand;
    if (command == null || command.isEmpty) return;
    unawaited(_runCommand(command));
  }

  /// 进程结束提示:远端会话给「断开 + 回车重连」,本地会话保持原样
  void _appendExitLine(int exitCode) {
    if (_isRemoteSession) {
      _appendLine(
        exitCode == 0
            ? tr('连接已断开。按回车重新连接。')
            : tr2('连接已断开(状态码 {0})。按回车重新连接。', [exitCode]),
        exitCode == 0 ? TerminalLineType.system : TerminalLineType.stderr,
      );
      return;
    }
    _appendLine(
      exitCode == 0 ? tr('完成') : tr2('进程退出，状态码 {0}', [exitCode]),
      exitCode == 0 ? TerminalLineType.system : TerminalLineType.stderr,
    );
  }

  Future<void> _runCommand(String rawCommand) async {
    _hideHistoryDropdown();
    final command = rawCommand.trim();
    if (_isRunning) {
      _sendInputToRunningProcess(rawCommand);
      return;
    }
    // 远端会话断开后不落回本地 shell:回车(或任何输入)都当作「重新连接」。
    // command == remoteCommand 时放行,那是拨号本身。
    final remoteCommand = widget.remoteCommand;
    if (remoteCommand != null &&
        remoteCommand.isNotEmpty &&
        command != remoteCommand) {
      _inputController.clear();
      unawaited(_runCommand(remoteCommand));
      return;
    }
    if (command.isEmpty) {
      _inputController.clear();
      _appendLine(_promptText(), TerminalLineType.prompt);
      _restoreInputFocus();
      return;
    }

    final canUseCwd = await _ensureWorkingDirectoryUsable();
    if (!canUseCwd) {
      _restoreInputFocus();
      return;
    }

    _inputController.clear();
    _rememberCommand(command);
    _appendLine('${_promptText()} $command', TerminalLineType.prompt);

    if (command == 'clear') {
      _clearLines();
      _restoreInputFocus();
      return;
    }
    if (command == 'exit') {
      _appendLine(tr('当前内置终端会话已保留。使用“重置”可以开启新的视图。'), TerminalLineType.system);
      _restoreInputFocus();
      return;
    }
    // history 是交互 shell 的内建命令,非交互 `zsh -c history` 会报
    // 「fc: no such event」;这里直接内建:打印本会话自己的命令历史。
    final historyLimit = _parseHistoryCommand(command);
    if (historyLimit != null) {
      final start = math.max(0, _history.length - historyLimit);
      for (var i = start; i < _history.length; i++) {
        _appendLine(
          '${(i + 1).toString().padLeft(5)}  ${_history[i]}',
          TerminalLineType.stdout,
        );
      }
      if (_history.isEmpty) {
        _appendLine(tr('(还没有历史命令)'), TerminalLineType.system);
      }
      _restoreInputFocus();
      return;
    }
    final cdTarget = _parseCdCommand(command);
    if (cdTarget != null) {
      await _changeDirectory(cdTarget);
      _restoreInputFocus();
      return;
    }

    setState(() {
      _isRunning = true;
      _runningCommand = command;
    });
    _remoteReportedCwd = null;
    _publishUiState();
    final commandSessionId = _sessionId;

    if (await _startNativePtyCommand(command, commandSessionId)) {
      return;
    }
    await _startProcessCommand(command, commandSessionId);
  }

  Future<bool> _startNativePtyCommand(
    String command,
    int commandSessionId,
  ) async {
    if (!(Platform.isMacOS || Platform.isWindows) || _nativePtyUnavailable) return false;
    try {
      await _ensureNativePtySubscription();
      final sessionId = await _nativePtyMethodChannel
          .invokeMethod<int>('start', {
            'executable': _shellExecutable,
            'arguments': _shellArguments(command),
            'workingDirectory': _cwd,
            'environment': _processEnvironment,
            'columns': _ptyColumns,
            'rows': _ptyRows,
          });
      if (sessionId == null) return false;
      if (!mounted || commandSessionId != _sessionId) {
        unawaited(_killNativePtySession(sessionId, signal: 'kill'));
        return true;
      }
      _nativePtySessionId = sessionId;
      _flushPendingNativePtyEvents(sessionId);
      _publishUiState();
      // The input row swaps to the invisible PTY focus catcher; make sure it
      // holds focus so keystrokes reach the running process.
      _restoreInputFocus();
      return true;
    } on MissingPluginException {
      _nativePtyUnavailable = true;
      _publishUiState();
      return false;
    } catch (error) {
      _nativePtyUnavailable = true;
      _publishUiState();
      if (mounted && commandSessionId == _sessionId) {
        _appendLine(
          tr2('PTY 启动失败，已回退到普通进程: {0}', [error]),
          TerminalLineType.stderr,
        );
      }
      return false;
    }
  }

  Future<void> _startProcessCommand(
    String command,
    int commandSessionId,
  ) async {
    try {
      final process = await Process.start(
        _shellExecutable,
        _shellArguments(command),
        workingDirectory: _cwd,
        environment: _processEnvironment,
        includeParentEnvironment: true,
      );
      _process = process;
      _stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .listen((data) => _enqueueOutput(data, TerminalLineType.stdout));
      _stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .listen((data) => _enqueueOutput(data, TerminalLineType.stderr));

      final exitCode = await process.exitCode;
      if (!mounted || commandSessionId != _sessionId) return;
      _flushOutputBacklog();
      await _stdoutSubscription?.cancel();
      await _stderrSubscription?.cancel();
      _stdoutSubscription = null;
      _stderrSubscription = null;
      _process = null;
      setState(() {
        _isRunning = false;
        _runningCommand = null;
      });
      _publishUiState();
      _appendExitLine(exitCode);
      _restoreInputFocus();
    } catch (error) {
      if (!mounted || commandSessionId != _sessionId) return;
      setState(() {
        _isRunning = false;
        _runningCommand = null;
        _process = null;
      });
      _publishUiState();
      _appendLine(tr2('启动命令失败: {0}', [error]), TerminalLineType.stderr);
      _restoreInputFocus();
    }
  }

  Future<void> _ensureNativePtySubscription() async {
    if (_nativePtySubscription != null) return;
    _ensureSharedNativePtySubscription();
    _nativePtySubscription = _sharedNativePtyEvents.stream.listen(
      _handleNativePtyEvent,
      onError: (Object error) {
        if (!mounted) return;
        _appendLine(tr2('PTY 事件通道异常: {0}', [error]), TerminalLineType.stderr);
      },
    );
  }

  void _handleNativePtyEvent(dynamic event) {
    if (!mounted || event is! Map) return;
    final sessionId = event['sessionId'];
    if (sessionId is! int) return;
    if (sessionId != _nativePtySessionId) {
      if (_isRunning && _nativePtySessionId == null) {
        final pending = _pendingNativePtyEvents.putIfAbsent(
          sessionId,
          () => <Map<dynamic, dynamic>>[],
        );
        pending.add(Map<dynamic, dynamic>.of(event));
        if (pending.length > 200) {
          pending.removeRange(0, pending.length - 200);
        }
      } else {
        // 不在「等待 start 返回」窗口期,这个 id 一定不属于本会话——
        // 顺手清掉此前误缓存的事件,避免别的会话的输出常驻内存。
        _pendingNativePtyEvents.remove(sessionId);
      }
      return;
    }
    _applyNativePtyEvent(event);
  }

  void _flushPendingNativePtyEvents(int sessionId) {
    final pending = _pendingNativePtyEvents.remove(sessionId);
    if (pending == null || pending.isEmpty) return;
    for (final event in pending) {
      if (_nativePtySessionId != sessionId) break;
      _applyNativePtyEvent(event);
    }
  }

  void _applyNativePtyEvent(Map<dynamic, dynamic> event) {
    switch (event['type']) {
      case 'data':
        final data = event['data'];
        if (data is String && data.isNotEmpty) {
          _enqueueOutput(data, TerminalLineType.stdout);
        }
        break;
      case 'exit':
        // 先冲掉积压输出,保证退出提示排在所有输出之后
        _flushOutputBacklog();
        final exitCode = event['exitCode'] is int
            ? event['exitCode'] as int
            : 0;
        _nativePtySessionId = null;
        _resetTerminalModes();
        setState(() {
          _isRunning = false;
          _runningCommand = null;
        });
        _publishUiState();
        _appendExitLine(exitCode);
        _restoreInputFocus();
        break;
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // 输出合帧:高吞吐命令(flutter run/编译/日志洪峰)每秒可来几百个 pty chunk,
  // 逐 chunk「解析→重建列表→滚动→发布状态」会把 UI 线程打满,表现为整个应用
  // 卡死、hot restart 后也不出帧。这里做令牌桶式合并:空闲时首个 chunk 立即
  // 解析(交互回显零延迟),冷却窗口内到达的数据积压,窗口到期一次性解析。
  // 解析总量不变(O(n)),但 rebuild 频率从每 chunk 一次降到每窗口一次。
  // ---------------------------------------------------------------------------

  static const _outputFlushInterval = Duration(milliseconds: 8);

  void _enqueueOutput(String data, TerminalLineType type) {
    if (_sessionLogger.isActive) _sessionLogger.write(data);
    if (_outputBacklogType != null && _outputBacklogType != type) {
      // 类型切换(stdout/stderr 混流)时先冲掉,保持顺序与颜色正确
      _flushOutputBacklog();
    }
    if (_outputFlushTimer == null) {
      // 空闲:立即解析本 chunk,并开一个冷却窗口兜住紧随其后的洪峰
      _appendOutput(data, type);
      _outputFlushTimer = Timer(_outputFlushInterval, _onOutputFlushTick);
      return;
    }
    _outputBacklog.write(data);
    _outputBacklogType = type;
  }

  void _onOutputFlushTick() {
    _outputFlushTimer = null;
    if (_outputBacklog.isEmpty) return;
    final data = _outputBacklog.toString();
    final type = _outputBacklogType ?? TerminalLineType.stdout;
    _outputBacklog.clear();
    _outputBacklogType = null;
    if (!mounted) return;
    _appendOutput(data, type);
    // 冷却窗口顺延,持续洪峰期间保持 ≤125 次解析/秒
    _outputFlushTimer = Timer(_outputFlushInterval, _onOutputFlushTick);
  }

  void _flushOutputBacklog() {
    _outputFlushTimer?.cancel();
    _outputFlushTimer = null;
    if (_outputBacklog.isEmpty) return;
    final data = _outputBacklog.toString();
    final type = _outputBacklogType ?? TerminalLineType.stdout;
    _outputBacklog.clear();
    _outputBacklogType = null;
    if (mounted) _appendOutput(data, type);
  }

  void _sendInputToRunningProcess(String rawInput) {
    _inputController.clear();
    final input = rawInput.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final payload = input.endsWith('\n') ? input : '$input\n';
    if (_nativePtySessionId != null) {
      unawaited(_writeNativePtyInput(payload));
      return;
    }
    _writeInputToRunningProcess(
      payload,
      confirmation: input.trim().isEmpty ? null : 'stdin> $input',
    );
  }

  void _writeInputToRunningProcess(String payload, {String? confirmation}) {
    final process = _process;
    if (process == null || payload.isEmpty) return;
    try {
      process.stdin.write(payload);
      if (confirmation != null && confirmation.isNotEmpty) {
        _appendLine(confirmation, TerminalLineType.prompt);
      }
    } catch (error) {
      _appendLine(tr2('发送输入失败: {0}', [error]), TerminalLineType.stderr);
    }
  }

  Future<void> _closeRunningProcessStdin() async {
    if (_nativePtySessionId != null) {
      await _writeNativePtyInput('\u0004');
      _appendLine(tr('已发送 EOF。'), TerminalLineType.system);
      return;
    }
    final process = _process;
    if (process == null) return;
    try {
      await process.stdin.close();
      _appendLine(tr('已关闭进程输入。'), TerminalLineType.system);
    } catch (error) {
      _appendLine(tr2('关闭进程输入失败: {0}', [error]), TerminalLineType.stderr);
    }
  }

  Future<void> _writeNativePtyInput(String payload) async {
    final sessionId = _nativePtySessionId;
    if (sessionId == null || payload.isEmpty) return;
    try {
      await _nativePtyMethodChannel.invokeMethod<void>('write', {
        'sessionId': sessionId,
        'input': payload,
      });
    } on PlatformException catch (error) {
      if (error.code == 'SESSION_NOT_FOUND') {
        // The native PTY session is gone but we never got an exit event —
        // recover to an idle prompt instead of failing every keystroke.
        _recoverFromLostPtySession(sessionId);
        return;
      }
      if (mounted) {
        _appendLine(tr2('发送 PTY 输入失败: {0}', [error]), TerminalLineType.stderr);
      }
    } catch (error) {
      if (mounted) {
        _appendLine(tr2('发送 PTY 输入失败: {0}', [error]), TerminalLineType.stderr);
      }
    }
  }

  /// Called when the native side reports the PTY session no longer exists.
  /// Clears the stale running state so typing goes back to the command input.
  void _recoverFromLostPtySession(int sessionId) {
    if (_nativePtySessionId != sessionId) return;
    _nativePtySessionId = null;
    _resetTerminalModes();
    if (mounted) {
      setState(() {
        _isRunning = false;
        _runningCommand = null;
      });
      _publishUiState();
      _appendLine(tr('PTY 会话已结束，已回到命令输入。'), TerminalLineType.system);
      _restoreInputFocus();
    } else {
      _isRunning = false;
      _runningCommand = null;
    }
  }

  bool get _isNativePtyActive => _isRunning && _nativePtySessionId != null;

  Future<void> _killNativePtySession(
    int sessionId, {
    String signal = 'int',
  }) async {
    try {
      await _nativePtyMethodChannel.invokeMethod<void>('kill', {
        'sessionId': sessionId,
        'signal': signal,
      });
    } catch (_) {
      // A stale native session should not block reset or dispose.
    }
  }

  Future<void> _resizeNativePtySession(
    int sessionId, {
    required int columns,
    required int rows,
  }) async {
    try {
      await _nativePtyMethodChannel.invokeMethod<void>('resize', {
        'sessionId': sessionId,
        'columns': columns,
        'rows': rows,
      });
    } catch (_) {
      // Resize is best effort; output streaming should keep working.
    }
  }

  Future<void> _changeDirectory(String target) async {
    final resolvedTarget = _resolveCdTarget(target);
    final result = await Process.run(
      _shellExecutable,
      _shellArguments(_cdCommand(resolvedTarget)),
      workingDirectory: _cwd,
      environment: _processEnvironment,
      includeParentEnvironment: true,
    );
    if (!mounted) return;
    if (result.exitCode == 0) {
      final output = result.stdout.toString().trim();
      if (output.isNotEmpty) {
        final nextCwd = output.split('\n').last;
        final canUseDirectory = await _canRunInDirectory(nextCwd);
        if (!canUseDirectory) {
          _appendLine(
            tr2('无权访问目录: {0}。可点击右上角“选择目录”授权后再进入。', [nextCwd]),
            TerminalLineType.stderr,
          );
          return;
        }
        setState(() {
          _previousCwd = _cwd;
          _cwd = nextCwd;
        });
        _verifiedCwd = nextCwd;
        _publishUiState();
        widget.onCwdChanged?.call(_cwd);
        _appendLine(_cwd, TerminalLineType.system);
      }
    } else {
      final message = result.stderr.toString().trim();
      _appendLine(
        message.isEmpty ? tr2('目录不存在: {0}', [resolvedTarget]) : message,
        TerminalLineType.stderr,
      );
    }
  }

  Future<void> _initializeWorkingDirectory() async {
    final selected = await _findUsableWorkingDirectory(preferred: _cwd);
    if (selected != null) _verifiedCwd = selected;
    if (!mounted || selected == null || selected == _cwd) {
      // Even if cwd didn't change, notify parent so it can persist the initial value.
      widget.onCwdChanged?.call(_cwd);
      return;
    }
    setState(() => _cwd = selected);
    _publishUiState();
    widget.onCwdChanged?.call(_cwd);
    _replaceWelcomeLine();
    _appendLine(tr2('已切换到可访问目录: {0}', [selected]), TerminalLineType.system);
  }

  Future<bool> _ensureWorkingDirectoryUsable() async {
    // 同一目录验证过一次就不再 spawn 探测进程(probe 是整个 shell 启动,
    // 每条命令都探一次会白付 10ms+ 的启动税);目录变化时缓存自然失效。
    if (_cwd == _verifiedCwd) return true;
    if (await _canRunInDirectory(_cwd)) {
      _verifiedCwd = _cwd;
      return true;
    }
    final fallback = await _findUsableWorkingDirectory(preferred: _cwd);
    if (!mounted) return false;
    if (fallback == null) {
      _appendLine(
        tr('当前目录不可访问，且没有找到可用的默认目录。请点击右上角“选择目录”授权一个目录。'),
        TerminalLineType.stderr,
      );
      return false;
    }
    setState(() {
      _previousCwd = _cwd;
      _cwd = fallback;
    });
    _verifiedCwd = fallback;
    _publishUiState();
    _appendLine(tr2('当前目录不可访问，已切换到: {0}', [fallback]), TerminalLineType.system);
    return true;
  }

  Future<String?> _findUsableWorkingDirectory({String? preferred}) async {
    final seen = <String>{};
    for (final candidate in _workingDirectoryCandidates(preferred: preferred)) {
      if (!seen.add(candidate)) continue;
      if (await _canRunInDirectory(candidate)) return candidate;
    }
    return null;
  }

  List<String> _workingDirectoryCandidates({String? preferred}) {
    final downloadsPath = _downloadsDirectoryPath;
    final homePath = _homeDirectoryPath;
    return [
      if (preferred != null && preferred.isNotEmpty) preferred,
      if (!Platform.isMacOS && (Platform.environment['PWD'] ?? '').isNotEmpty)
        Platform.environment['PWD']!,
      ?downloadsPath,
      Directory.systemTemp.path,
      ?homePath,
      Directory.current.path,
    ];
  }

  Future<bool> _canRunInDirectory(String path) async {
    if (!_directoryLooksReadableSync(path)) return false;
    try {
      final result = await Process.run(
        _shellExecutable,
        _shellArguments(_directoryProbeCommand),
        workingDirectory: path,
        environment: _processEnvironment,
        includeParentEnvironment: true,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  String get _directoryProbeCommand {
    if (Platform.isWindows) return 'dir . >NUL';
    return 'ls . >/dev/null';
  }

  Future<void> _pickWorkingDirectory() async {
    if (_isRunning || _isPreparingDirectory) return;
    setState(() => _isPreparingDirectory = true);
    _publishUiState();
    try {
      final initialDirectory = await FilePickerHelper.getInitialDirectory();
      final selectedPath = await FilePicker.getDirectoryPath(
        dialogTitle: tr('选择终端工作目录'),
        initialDirectory: _directoryLooksReadableSync(_cwd)
            ? _cwd
            : initialDirectory,
      );
      if (!mounted || selectedPath == null || selectedPath.isEmpty) return;

      if (Platform.isMacOS) {
        await MacosFileAccessService.persistAccess(selectedPath);
      }
      if (!await _canRunInDirectory(selectedPath)) {
        _appendLine(
          tr2('目录仍不可访问: {0}', [selectedPath]),
          TerminalLineType.stderr,
        );
        return;
      }
      FilePickerHelper.updateLastDirectoryFromPath(selectedPath);
      setState(() {
        _previousCwd = _cwd;
        _cwd = selectedPath;
      });
      _verifiedCwd = selectedPath;
      _publishUiState();
      widget.onCwdChanged?.call(_cwd);
      _appendLine(tr2('当前目录: {0}', [selectedPath]), TerminalLineType.system);
    } catch (error) {
      _appendLine(tr2('选择目录失败: {0}', [error]), TerminalLineType.stderr);
    } finally {
      if (mounted) {
        setState(() => _isPreparingDirectory = false);
        _publishUiState();
      }
    }
  }

  Future<void> _openFullDiskAccessSettings() async {
    if (!Platform.isMacOS) return;
    try {
      final result = await Process.run('/usr/bin/open', [
        'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles',
      ]);
      if (result.exitCode == 0) {
        _appendLine(tr('已打开系统设置：隐私与安全性 > 完全磁盘访问。'), TerminalLineType.system);
        await _revealCurrentAppBundleInFinder();
      } else {
        _appendLine(
          result.stderr.toString().trim().isEmpty
              ? tr('打开完全磁盘访问设置失败。')
              : result.stderr.toString().trim(),
          TerminalLineType.stderr,
        );
      }
    } catch (error) {
      _appendLine(tr2('打开完全磁盘访问设置失败: {0}', [error]), TerminalLineType.stderr);
    }
  }

  Future<void> _revealCurrentAppBundleInFinder() async {
    final appPath = _currentAppBundlePath;
    if (appPath == null) {
      _appendLine(tr('未能定位当前应用包，请点击左下角“+”后手动选择应用。'), TerminalLineType.system);
      return;
    }
    final appExists = await Directory(appPath).exists();
    if (!appExists) {
      _appendLine(tr2('当前应用包不存在: {0}', [appPath]), TerminalLineType.stderr);
      return;
    }
    final result = await Process.run('/usr/bin/open', ['-R', appPath]);
    if (result.exitCode == 0) {
      _appendLine(
        tr2('如果列表里没有本应用，请点击左下角“+”，选择 Finder 中高亮的应用: {0}', [appPath]),
        TerminalLineType.system,
      );
    } else {
      _appendLine(
        tr2('请点击左下角“+”后选择应用: {0}', [appPath]),
        TerminalLineType.system,
      );
    }
  }

  String? get _currentAppBundlePath {
    final executable = Platform.executable;
    final match = RegExp(r'^(.+?\.app)(?:/.*)?$').firstMatch(executable);
    return match?.group(1);
  }

  Future<void> _checkFullDiskAccessOnEntry() async {
    if (!Platform.isMacOS ||
        _didCheckFullDiskAccess ||
        _didCheckFullDiskAccessInPage) {
      return;
    }
    _didCheckFullDiskAccess = true;
    _didCheckFullDiskAccessInPage = true;
    final hasAccess = await _hasFullDiskAccess();
    if (!mounted || hasAccess) return;
    _appendLine(tr('未检测到完全磁盘访问权限，正在打开系统设置。授权后请重启应用。'), TerminalLineType.stderr);
    await _openFullDiskAccessSettings();
  }

  Future<bool> _hasFullDiskAccess() async {
    var hasProbeTarget = false;
    for (final path in _fullDiskAccessProbePaths) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      hasProbeTarget = true;
      if (await _canReadFileSystemEntity(path, type)) {
        return true;
      }
    }
    return !hasProbeTarget;
  }

  List<String> get _fullDiskAccessProbePaths {
    final home = _homeDirectoryPath;
    if (home == null || home.isEmpty) return const [];
    return [
      '$home/Library/Application Support/com.apple.TCC/TCC.db',
      '$home/Library/Safari/History.db',
      '$home/Library/Messages/chat.db',
      '$home/Library/Mail',
    ];
  }

  Future<bool> _canReadFileSystemEntity(
    String path,
    FileSystemEntityType type,
  ) async {
    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(path).list(followLinks: false).take(1).drain<void>();
      } else {
        final file = await File(path).open();
        try {
          await file.read(1);
        } finally {
          await file.close();
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  String _resolvePath(String target) {
    if (target.isEmpty) return _cwd;
    if (target == '-' && _previousCwd != null) return _previousCwd!;
    var resolved = target;
    final home = _homeDirectory;
    if (home != null) {
      if (resolved == '~') return home;
      if (resolved.startsWith('~/')) {
        resolved = '$home${resolved.substring(1)}';
      }
    }
    final separator = Platform.pathSeparator;
    final isAbsolute = Platform.isWindows
        ? RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(resolved) ||
              resolved.startsWith(separator)
        : resolved.startsWith('/');
    if (!isAbsolute) {
      resolved = '$_cwd$separator$resolved';
    }
    try {
      return Uri.file(resolved).normalizePath().toFilePath();
    } catch (_) {
      return resolved;
    }
  }

  String _resolveCdTarget(String target) {
    if (target.isEmpty) return _homeDirectory ?? _cwd;
    return _resolvePath(target);
  }

  String _cdCommand(String target) {
    final quotedTarget = _shellQuote(target);
    if (Platform.isWindows) return 'cd /D $quotedTarget && cd';
    return 'cd $quotedTarget && pwd';
  }

  String? _parseCdCommand(String command) {
    if (command == 'cd') return '';
    final match = RegExp(r'^cd\s+(.+)$').firstMatch(command);
    if (match == null) return null;
    final target = match.group(1)!.trim();
    if (target.contains('&&') || target.contains(';') || target.contains('|')) {
      return null;
    }
    return _stripMatchingQuotes(target);
  }

  /// `history` / `history N` → 要显示的条数;不是 history 命令返回 null。
  int? _parseHistoryCommand(String command) {
    if (command == 'history') return _history.length;
    final match = RegExp(r'^history\s+(\d+)$').firstMatch(command);
    if (match == null) return null;
    return int.tryParse(match.group(1)!) ?? _history.length;
  }

  void _clearLines() {
    setState(() {
      _lines.clear();
      _clearGridSelection();
      _ansiStyle = const AnsiStyle();
      _cursorX = 0;
      _cursorY = 0;
      _wrapPending = false;
      _savedWrapPending = false;
      _isLastOutputLineOpen = false;
      if (_isAltBufferActive) {
        _isAltBufferActive = false;
        _normalLines.clear();
      }
      _scrollTopMargin = 0;
      _scrollBottomMargin = math.max(0, _ptyRows - 1);
      _refreshSearchMatches();
    });
    _publishUiState();
    _appendLine(tr2('已清空输出。当前目录 {0}', [_cwd]), TerminalLineType.system);
  }

  void _resetSession() {
    _stopProcess(quiet: true);
    // 重置就是要丢弃旧会话的一切输出:积压缓冲直接清掉,不解析
    _outputFlushTimer?.cancel();
    _outputFlushTimer = null;
    _outputBacklog.clear();
    _outputBacklogType = null;
    setState(() {
      _sessionId++;
      _process = null;
      _nativePtySessionId = null;
      _pendingNativePtyEvents.clear();
      _isRunning = false;
      _runningCommand = null;
      _ansiStyle = const AnsiStyle();
      _cursorX = 0;
      _cursorY = 0;
      _savedCursorX = 0;
      _savedCursorY = 0;
      _savedAnsiStyle = const AnsiStyle();
      _wrapPending = false;
      _savedWrapPending = false;
      _savedG0LineDrawing = false;
      _savedG1LineDrawing = false;
      _savedUseG1Charset = false;
      _activeOsc8Url = null;
      _isLastOutputLineOpen = false;
      _autoFollowOutput = true;
      _isAltBufferActive = false;
      _normalLines.clear();
      _normalCursorX = 0;
      _normalCursorY = 0;
      _normalSavedCursorX = 0;
      _normalSavedCursorY = 0;
      _normalAnsiStyle = const AnsiStyle();
      _normalSavedAnsiStyle = const AnsiStyle();
      _normalWrapPending = false;
      _normalSavedWrapPending = false;
      _normalG0LineDrawing = false;
      _normalG1LineDrawing = false;
      _normalUseG1Charset = false;
      _normalSavedG0LineDrawing = false;
      _normalSavedG1LineDrawing = false;
      _normalSavedUseG1Charset = false;
      _scrollTopMargin = 0;
      _scrollBottomMargin = math.max(0, _ptyRows - 1);
      _resetTerminalModes();
      _pendingEscapeSequence = '';
      _clearGridSelection();
      _titleStack.reset();
      _palette.clear();
      _dynamicForegroundColor = null;
      _dynamicBackgroundColor = null;
      _dynamicCursorColor = null;
      _lines
        ..clear()
        ..add(
          TerminalLine.plain(
            'Termora Terminal · $_terminalBackendLabel · $_cwd',
            TerminalLineType.system,
          ),
        );
      _inputController.clear();
      _historyIndex = _history.length;
      _refreshSearchMatches();
    });
    _notifyTerminalOutputChanged();
    _scrollToBottom();
  }

  void _replaceWelcomeLine() {
    if (_lines.isEmpty) return;
    setState(() {
      _lines[0] = TerminalLine.plain(
        'Termora Terminal · $_terminalBackendLabel · $_cwd',
        TerminalLineType.system,
      );
    });
    _notifyTerminalOutputChanged();
  }

  void _stopProcess({bool quiet = false}) {
    final nativeSessionId = _nativePtySessionId;
    if (nativeSessionId != null) {
      unawaited(
        _killNativePtySession(nativeSessionId, signal: quiet ? 'kill' : 'int'),
      );
      if (!quiet) {
        _appendLine(tr('已发送中断信号。'), TerminalLineType.system);
      }
      return;
    }
    final process = _process;
    if (process == null) return;
    process.kill(ProcessSignal.sigint);
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      process.kill();
    });
    if (!quiet) {
      _appendLine(tr('已发送中断信号。'), TerminalLineType.system);
    }
  }

  @override
  void _sendRawInputToProcess(String payload) {
    if (_nativePtySessionId != null) {
      unawaited(_writeNativePtyInput(payload));
      return;
    }
    _writeInputToRunningProcess(payload);
  }

  /// 命令广播:由工作区调用,把别处的输入注入本会话(不再二次广播)
  void injectRawInput(String payload) {
    if (payload.isEmpty) return;
    if (_nativePtySessionId != null) {
      unawaited(_writeNativePtyInput(payload));
    } else if (_isRunning) {
      _sendInputToRunningProcess(payload);
    }
  }

  // ── 快捷命令 / 片段 ──

  /// 发送一条片段到当前会话并执行(补尾换行);广播开启时发给所有会话
  void _sendSnippet(String command) {
    if (command.isEmpty) return;
    final payload = command.endsWith('\n') ? command : '$command\n';
    if (widget.broadcastEnabled && widget.onBroadcastInput != null) {
      widget.onBroadcastInput!(payload);
    } else if (_nativePtySessionId != null) {
      unawaited(_writeNativePtyInput(payload));
    } else {
      // 本地命令行:塞进输入框并执行
      _inputController.text = command;
      unawaited(_runCommand(command));
    }
    _restoreInputFocus();
  }

  /// 切换会话日志录制:开启时落盘并 toast 路径,关闭时 toast 已停止。
  Future<void> _toggleSessionLog() async {
    if (_sessionLogger.isActive) {
      final path = _sessionLogger.path;
      await _sessionLogger.stop();
      if (!mounted) return;
      setState(() {});
      _logToast(tr2('已停止录制 · {0}', [path]), ToastificationType.info);
      return;
    }
    try {
      final path = await _sessionLogger.start(
        sessionLabel: widget.title,
        now: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {});
      _logToast(tr2('开始录制 → {0}', [path]), ToastificationType.success);
    } catch (e) {
      if (!mounted) return;
      _logToast(tr2('无法录制日志:{0}', [e]), ToastificationType.error);
    }
  }

  void _logToast(String message, ToastificationType type) {
    if (!mounted) return;
    AppToast.show(
      context: context,
      style: ToastificationStyle.flat,
      applyBlurEffect: true,
      type: type,
      autoCloseDuration: const Duration(seconds: 4),
      title: Text(
        message,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400),
      ),
    );
  }

  /// 配色方案菜单:每项带 5 色预览 + 名称,当前项打勾;选中即应用+持久化。
  Future<void> _showThemeMenu(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final current = TerminalThemeStore.current.value;
    final chosen = await showMenu<TerminalTheme>(
      context: context,
      color: AppTheme.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppTheme.borderColor),
      ),
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final theme in kTerminalThemes)
          PopupMenuItem<TerminalTheme>(
            value: theme,
            height: 38,
            child: Row(
              children: [
                Icon(
                  theme.name == current.name
                      ? LucideIcons.check300
                      : LucideIcons.palette300,
                  size: 14,
                  color: theme.name == current.name
                      ? AppTheme.brandColor
                      : AppTheme.subtleTextColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr(theme.name),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _themeSwatch(theme),
              ],
            ),
          ),
      ],
    );
    if (chosen != null) await TerminalThemeStore.select(chosen);
  }

  /// 主题预览小色块:背景底 + 5 个代表色。
  Widget _themeSwatch(TerminalTheme theme) {
    final ansi = theme.ansi;
    final preview = ansi == null
        ? <Color>[
            AppTheme.errorColor,
            AppTheme.successColor,
            AppTheme.warningColor,
            AppTheme.brandColor,
            AppTheme.headingColor,
          ]
        : <Color>[ansi[1], ansi[2], ansi[3], ansi[4], ansi[5]];
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.background ?? AppTheme.backgroundColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in preview)
            Container(
              width: 7,
              height: 12,
              margin: const EdgeInsets.symmetric(horizontal: 0.5),
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showSnippetMenu(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final list = SnippetStore.snippets.value;
    final action = await showMenu<String>(
      context: context,
      color: AppTheme.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppTheme.borderColor),
      ),
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final s in list)
          PopupMenuItem<String>(
            value: 'send:${s.id}',
            height: 34,
            child: Row(
              children: [
                Icon(
                  LucideIcons.chevronRight300,
                  size: 13,
                  color: AppTheme.subtleTextColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.name.isEmpty ? s.command : s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (list.isNotEmpty) const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'new',
          height: 34,
          child: Row(
            children: [
              Icon(LucideIcons.plus300, size: 13, color: AppTheme.brandColor),
              const SizedBox(width: 8),
              Text(
                tr('新建片段…'),
                style: TextStyle(fontSize: 13, color: AppTheme.brandColor),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'manage',
          height: 34,
          child: Row(
            children: [
              Icon(
                LucideIcons.settings300,
                size: 13,
                color: AppTheme.subtleTextColor,
              ),
              const SizedBox(width: 8),
              Text(
                tr('管理片段…'),
                style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
              ),
            ],
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'new') {
      unawaited(_editSnippet(null));
    } else if (action == 'manage') {
      unawaited(_manageSnippets());
    } else if (action.startsWith('send:')) {
      final id = action.substring(5);
      final s = SnippetStore.snippets.value
          .where((e) => e.id == id)
          .firstOrNull;
      if (s != null) _sendSnippet(s.command);
    }
  }

  /// 新建/编辑片段
  Future<void> _editSnippet(Snippet? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final cmdCtrl = TextEditingController(text: existing?.command ?? '');
    final result = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => AlertDialog(
        title: Text(existing == null ? tr('新建片段') : tr('编辑片段')),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: cmdCtrl,
                minLines: 2,
                maxLines: 6,
                style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'Menlo',
                  color: AppTheme.headingColor,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: tr('命令'),
                  hintText: tr('发送时自动执行(末尾补换行)'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.brandColor),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('保存')),
          ),
        ],
      ),
    );
    if (result != true) return;
    final command = cmdCtrl.text.trimRight();
    if (command.isEmpty) return;
    final name = nameCtrl.text.trim();
    await SnippetStore.upsert(
      existing == null
          ? Snippet(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              name: name,
              command: command,
            )
          : existing.copyWith(name: name, command: command),
    );
  }

  Future<void> _manageSnippets() async {
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => AlertDialog(
        title: Text(tr('管理片段')),
        content: SizedBox(
          width: 400,
          height: 360,
          child: ValueListenableBuilder<List<Snippet>>(
            valueListenable: SnippetStore.snippets,
            builder: (context, list, _) {
              if (list.isEmpty) {
                return Center(
                  child: Text(
                    tr('还没有片段,点「新建」添加常用命令'),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.subtleTextColor,
                    ),
                  ),
                );
              }
              return ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: AppTheme.borderColor),
                itemBuilder: (context, i) {
                  final s = list[i];
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: Text(
                      s.name.isEmpty ? s.command : s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.headingColor,
                      ),
                    ),
                    subtitle: Text(
                      s.command,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'Menlo',
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: tr('编辑'),
                          icon: Icon(LucideIcons.penLine300, size: 15),
                          onPressed: () => unawaited(_editSnippet(s)),
                        ),
                        IconButton(
                          tooltip: tr('删除'),
                          icon: Icon(
                            LucideIcons.trash300,
                            size: 15,
                            color: AppTheme.errorColor,
                          ),
                          onPressed: () => unawaited(SnippetStore.remove(s.id)),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => unawaited(_editSnippet(null)),
            child: Text(tr('新建')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.brandColor),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('完成')),
          ),
        ],
      ),
    );
  }

  @override
  void _setReportedCwd(String path) {
    // 远端会话运行中收到的 OSC 7 说的是远端路径,记下来给 SFTP 用,
    // 不能污染本地 cwd
    if (_isRemoteSession && _isRunning) {
      final changed = _remoteReportedCwd != path;
      _remoteReportedCwd = path;
      // 详情面板建在主 build 里(输出变更只重建输出区,不重建面板),
      // 远端目录变了且面板开着时,主动重建让文件树跟随
      if (changed && _detailsPanelVisible && mounted) {
        setState(() {});
      }
      return;
    }
    _cwd = path;
    widget.onCwdChanged?.call(_cwd);
  }

  /// 远端 shell 通过 OSC 7 上报的工作目录(每次拨号清零)
  String? _remoteReportedCwd;

  bool get _isRemoteSession =>
      widget.remoteCommand != null && widget.remoteCommand!.isNotEmpty;

  /// 远端 shell 当前目录的最优推测:OSC 7 优先,退而求其次解析窗口标题
  /// (Debian/Ubuntu 等默认 PS1 会把 user@host: ~/dir 写进标题)。
  /// 只对运行中的远端会话有值。
  String? get _remoteCwdGuess {
    if (!_isRemoteSession || !_isRunning) return null;
    return _remoteReportedCwd ??
        _parseCwdFromTitle(_titleStack.current) ??
        _parseCwdFromPrompt();
  }

  /// 再兜底:从屏幕最后一个非空行的提示符里抠路径
  /// (Debian 风格 `user@host:/path$`、zsh `user@host /path %` 等;
  /// RHEL 默认提示符只显示目录名,抠不出来,回落家目录)。
  String? _parseCwdFromPrompt() {
    // 从底部往上找最近一条能提取路径的提示符;只认绝对路径(/ 开头)——
    // ~ 相对路径的 home 语境是"这个交互 shell 的",跨会话(SFTP)可能是
    // 另一个用户的 home,展开会指错(如 su 后),故不采纳。
    final pattern = RegExp(r'[\w.-]+@[\w.-]+[: ]+(/[^#$%>]*?)\s*[#$%>]\s*$');
    var scanned = 0;
    for (var i = _lines.length - 1; i >= 0 && scanned < 40; i--) {
      final text = _lines[i].text.trimRight();
      if (text.trim().isEmpty) continue;
      scanned++;
      final match = pattern.firstMatch(text);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// 从标题里抠出结尾的 ~ / ~/xxx / /xxx 路径段;抠不出返回 null
  static String? _parseCwdFromTitle(String? title) {
    if (title == null || title.isEmpty) return null;
    final match = RegExp(
      r'(?:^|[\s:])((?:~(?:/[^:]*)?|/[^:]*))\s*$',
    ).firstMatch(title);
    final path = match?.group(1)?.trim();
    return (path == null || path.isEmpty) ? null : path;
  }

  @override
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_autoFollowOutput && !_isAltBufferActive) return;
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      _scrollController.jumpTo(
        position.maxScrollExtent.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  void _forceScrollToBottom() {
    if (!_scrollController.hasClients) return;
    _autoFollowOutput = true;
    _publishUiState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _keepInputFocused();
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  /// 正在应用来自其他分屏的同步滚动 —— 防回声(收到→jumpTo→又广播)。
  bool _applyingSyncedScroll = false;

  void _handleScrollChanged() {
    if (!_scrollController.hasClients) return;
    // 同步滚动:本地滚动(非回声)时把比例广播给其余分屏
    if (widget.syncScrollEnabled &&
        !_applyingSyncedScroll &&
        widget.onSyncScroll != null) {
      final p = _scrollController.position;
      if (p.hasContentDimensions) {
        final ratio = p.maxScrollExtent <= 0
            ? 1.0
            : (p.pixels / p.maxScrollExtent).clamp(0.0, 1.0);
        widget.onSyncScroll!(ratio, this);
      }
    }
    // Alt buffer (vim/htop/less) is a fixed grid pinned to the bottom: even if
    // some other gesture drags the viewport off the end, auto-follow must stay
    // on, or the last row never comes back into view.
    final shouldFollow =
        _isAltBufferActive || _scrollController.position.extentAfter <= 4;
    if (shouldFollow == _autoFollowOutput) return;
    _autoFollowOutput = shouldFollow;
    _publishUiState();
  }

  /// 接受来自其他分屏的滚动比例并跳转(不再向外广播)。
  void applySyncedScroll(double ratio) {
    if (!_scrollController.hasClients) return;
    final p = _scrollController.position;
    if (!p.hasContentDimensions) return;
    final target = (p.maxScrollExtent * ratio).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    if ((target - p.pixels).abs() < 0.5) return;
    _applyingSyncedScroll = true;
    _scrollController.jumpTo(target);
    _applyingSyncedScroll = false;
  }

  /// The focus node that should hold focus for the current input mode: the
  /// invisible raw-key catcher while a PTY command runs, otherwise the visible
  /// command [TextField]. They are separate nodes so the mode swap doesn't
  /// reuse one node across two widget types (which dropped focus unreliably).
  FocusNode get _activeInputNode =>
      _isNativePtyActive ? _ptyFocusNode : _inputFocusNode;

  bool get _terminalInputHasFocus =>
      _inputFocusNode.hasFocus || _ptyFocusNode.hasFocus;

  /// Global safety net: whenever the terminal input loses focus *to nowhere*
  /// (a scope/null — which is what a rebuild's element deactivation does),
  /// re-grab it. If a real widget took focus (the search box, a text
  /// selection, another pane's control), we respect it and do nothing.
  void _handleGlobalFocusChange() {
    if (!mounted || !widget.isActive) return;
    if (_isSearchVisible) return;
    if (_terminalInputHasFocus) return;
    // Don't yank focus back when the terminal route isn't the visible one.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary is! FocusScopeNode) {
      // A real widget took focus (search box, text selection, a button …).
      // Respect it; only log so we can see the culprit if focus feels stuck.
      assert(() {
        debugPrint(
          '[TF ${widget.sessionId}] input lost focus to '
          '${primary.debugLabel ?? primary.runtimeType} (respected)',
        );
        return true;
      }());
      return;
    }
    // Focus was dropped to a scope/null by a rebuild — take it back.
    _activeInputNode.requestFocus();
  }

  void _keepInputFocused() {
    if (!mounted) return;
    if (_isSearchVisible && _searchFocusNode.hasFocus) return;
    if (_externalWidgetHasFocus()) return;
    if (!_terminalInputHasFocus) {
      _activeInputNode.requestFocus();
    }
  }

  /// Restores input focus after a command finishes. When a PTY command exits,
  /// the interactive row swaps from an invisible [Focus] to the real
  /// [TextField], which can drop focus — and the surrounding [SelectionArea]
  /// may also reclaim focus a beat later. We re-grab it on the next frame and
  /// again shortly after, but only for the active pane and never stealing from
  /// an open search box.
  /// 终端外的真实控件(详情面板地址栏 / Find / 弹窗等)当前持有焦点时,
  /// 终端不该把焦点抢回来——否则这些输入框根本没法输入。
  bool _externalWidgetHasFocus() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary is FocusScopeNode) return false;
    return !identical(primary, _inputFocusNode) &&
        !identical(primary, _ptyFocusNode) &&
        !identical(primary, _searchFocusNode);
  }

  void _restoreInputFocus() {
    void grab() {
      if (!mounted || !widget.isActive) return;
      if (_isSearchVisible && _searchFocusNode.hasFocus) return;
      if (_externalWidgetHasFocus()) return;
      if (!_terminalInputHasFocus) {
        _activeInputNode.requestFocus();
      }
    }

    if (!widget.isActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      grab();
      Future<void>.delayed(const Duration(milliseconds: 60), grab);
    });
  }

  bool _maybeHandleZoomShortcut(LogicalKeyboardKey key, bool active) {
    if (!active) return false;
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      widget.onZoomIn();
      return true;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      widget.onZoomOut();
      return true;
    }
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      widget.onZoomReset();
      return true;
    }
    return false;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _keepInputFocused();
    final key = event.logicalKey;
    final isControlPressed = HardwareKeyboard.instance.isControlPressed;
    final isMetaPressed = HardwareKeyboard.instance.isMetaPressed;
    final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;

    // 有格子选区时 ⌘C = 复制选区(优先于 pty 转发;⌃C 中断不受影响)
    if (isMetaPressed &&
        !isShiftPressed &&
        key == LogicalKeyboardKey.keyC &&
        _hasGridSelection) {
      unawaited(_copyGridSelection());
      return KeyEventResult.handled;
    }

    if (_isNativePtyActive) {
      return _handleNativePtyKeyEvent(
        event,
        isControlPressed: isControlPressed,
        isMetaPressed: isMetaPressed,
        isShiftPressed: isShiftPressed,
      );
    }

    final isShortcutPressed = isControlPressed || isMetaPressed;

    if (key == LogicalKeyboardKey.escape) {
      if (_isSearchVisible) {
        _hideSearch();
        return KeyEventResult.handled;
      }
      _activeInputNode.requestFocus();
      return KeyEventResult.handled;
    }

    if (_maybeHandleZoomShortcut(key, isShortcutPressed)) {
      return KeyEventResult.handled;
    }

    if (isShortcutPressed && key == LogicalKeyboardKey.keyF) {
      _showSearch();
      return KeyEventResult.handled;
    }

    // ⌃R:全局命令历史搜索(仅空闲提示符;pty 运行中 ⌃R 属于远端 shell)
    if (isControlPressed && key == LogicalKeyboardKey.keyR) {
      unawaited(_showHistorySearchDialog());
      return KeyEventResult.handled;
    }

    if (isShortcutPressed && key == LogicalKeyboardKey.keyV) {
      unawaited(_pasteClipboard());
      return KeyEventResult.handled;
    }

    if (isShortcutPressed && isShiftPressed && key == LogicalKeyboardKey.keyC) {
      unawaited(_copyAllOutput());
      return KeyEventResult.handled;
    }

    if (isControlPressed && key == LogicalKeyboardKey.keyC && _isRunning) {
      _stopProcess();
      return KeyEventResult.handled;
    }
    if (isControlPressed && key == LogicalKeyboardKey.keyD && _isRunning) {
      unawaited(_closeRunningProcessStdin());
      return KeyEventResult.handled;
    }
    // 历史下拉打开时:↑/↓ 选择、Esc 关闭(优先于普通历史/跳转)
    if (_historyDropdownOpen && !isMetaPressed) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveHistorySuggestion(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveHistorySuggestion(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _hideHistoryDropdown();
        return KeyEventResult.handled;
      }
    }
    // ⌘↑/⌘↓:跳到上/下一条命令的提示符(Shell 集成 OSC 133)
    if (isMetaPressed && key == LogicalKeyboardKey.arrowUp) {
      _jumpToPrompt(-1);
      return KeyEventResult.handled;
    }
    if (isMetaPressed && key == LogicalKeyboardKey.arrowDown) {
      _jumpToPrompt(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _showPreviousHistory();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _showNextHistory();
      return KeyEventResult.handled;
    }
    if (isControlPressed && key == LogicalKeyboardKey.keyL) {
      _clearLines();
      return KeyEventResult.handled;
    }
    if (isControlPressed && key == LogicalKeyboardKey.keyA) {
      _moveInputCursor(0);
      return KeyEventResult.handled;
    }
    if (isControlPressed && key == LogicalKeyboardKey.keyE) {
      _moveInputCursor(_inputController.text.length);
      return KeyEventResult.handled;
    }
    if (isControlPressed && key == LogicalKeyboardKey.keyU) {
      _replaceInputRange(0, _inputCursorOffset, '');
      return KeyEventResult.handled;
    }
    if (isControlPressed && key == LogicalKeyboardKey.keyK) {
      _replaceInputRange(_inputCursorOffset, _inputController.text.length, '');
      return KeyEventResult.handled;
    }
    if (isControlPressed && key == LogicalKeyboardKey.keyW) {
      _deletePreviousInputWord();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      _handleTabPressed();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleNativePtyKeyEvent(
    KeyEvent event, {
    required bool isControlPressed,
    required bool isMetaPressed,
    required bool isShiftPressed,
  }) {
    final key = event.logicalKey;
    if (_isSearchVisible) {
      if (key == LogicalKeyboardKey.escape) {
        _hideSearch();
        return KeyEventResult.handled;
      }
      if (_searchFocusNode.hasFocus) return KeyEventResult.ignored;
    }

    if (_maybeHandleZoomShortcut(key, isMetaPressed)) {
      return KeyEventResult.handled;
    }
    if (isMetaPressed && key == LogicalKeyboardKey.keyF) {
      _showSearch();
      return KeyEventResult.handled;
    }
    if (isMetaPressed && key == LogicalKeyboardKey.keyV) {
      unawaited(_pasteClipboard());
      return KeyEventResult.handled;
    }
    if (isMetaPressed && isShiftPressed && key == LogicalKeyboardKey.keyC) {
      unawaited(_copyAllOutput());
      return KeyEventResult.handled;
    }

    final payload = _inputEncoder.payloadForKey(
      event,
      control: isControlPressed,
      meta: isMetaPressed,
      shift: isShiftPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
    );
    if (payload == null || payload.isEmpty) return KeyEventResult.ignored;
    // 命令广播开启:发给工作区所有会话(含自己),否则只发本会话
    if (widget.broadcastEnabled && widget.onBroadcastInput != null) {
      widget.onBroadcastInput!(payload);
    } else {
      unawaited(_writeNativePtyInput(payload));
    }
    return KeyEventResult.handled;
  }

  TerminalInputEncoder get _inputEncoder => TerminalInputEncoder(
    applicationCursorMode: _applicationCursorMode,
    applicationKeypadMode: _applicationKeypadMode,
    modifyOtherKeysMode: _modifyOtherKeysMode,
  );

  int get _inputCursorOffset {
    final selection = _inputController.selection;
    if (!selection.isValid) return _inputController.text.length;
    return selection.extentOffset.clamp(0, _inputController.text.length);
  }

  void _moveInputCursor(int offset) {
    _inputController.selection = TextSelection.collapsed(
      offset: offset.clamp(0, _inputController.text.length),
    );
  }

  void _replaceInputRange(int start, int end, String replacement) {
    final text = _inputController.text;
    final safeStart = start.clamp(0, text.length);
    final safeEnd = end.clamp(safeStart, text.length);
    final nextText = text.replaceRange(safeStart, safeEnd, replacement);
    _inputController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(
        offset: safeStart + replacement.length,
      ),
    );
  }

  void _deletePreviousInputWord() {
    final text = _inputController.text;
    var cursor = _inputCursorOffset;
    while (cursor > 0 && text[cursor - 1].trim().isEmpty) {
      cursor--;
    }
    while (cursor > 0 && text[cursor - 1].trim().isNotEmpty) {
      cursor--;
    }
    _replaceInputRange(cursor, _inputCursorOffset, '');
  }

  /// 命令行 Enter 提交(多行输入框里 Enter 默认是换行,由快捷键接管);
  /// 输入法组词中的 Enter 是确认候选词,不能当提交
  void _submitInput() {
    final value = _inputController.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    _hideHistoryDropdown();
    unawaited(_runCommand(value.text));
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    if (_isRunning) {
      var payload = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      if (_bracketedPasteMode) {
        payload = '\x1b[200~$payload\x1b[201~';
      }
      // 命令广播:粘贴也发给所有会话
      if (widget.broadcastEnabled && widget.onBroadcastInput != null) {
        widget.onBroadcastInput!(payload);
        _activeInputNode.requestFocus();
        return;
      }
      if (_nativePtySessionId != null) {
        await _writeNativePtyInput(payload);
        _activeInputNode.requestFocus();
        return;
      }
      _writeInputToRunningProcess(
        payload,
        confirmation: tr2('已粘贴 {0} 个字符到进程输入。', [payload.length]),
      );
      _activeInputNode.requestFocus();
      return;
    }
    // 保留换行原样进输入框(输入框支持多行,Enter 提交、Shift+Enter 换行);
    // 之前替换成 '; ' 会悄悄改写用户粘贴的脚本
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final selection = _inputController.selection;
    if (selection.isValid && !selection.isCollapsed) {
      _replaceInputRange(selection.start, selection.end, normalized);
    } else {
      _replaceInputRange(_inputCursorOffset, _inputCursorOffset, normalized);
    }
    _activeInputNode.requestFocus();
  }

  Future<void> _copyAllOutput() async {
    final text = _lines.map((line) => line.text).join('\n');
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _appendLine(tr('已复制全部输出。'), TerminalLineType.system);
  }

  Future<void> _saveOutputToFile() async {
    final text = _lines.map((line) => line.text).join('\n');
    if (text.isEmpty) return;
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: tr('保存终端输出'),
        fileName:
            'termora-terminal-${DateTime.now().millisecondsSinceEpoch}.log',
        initialDirectory: _directoryLooksReadableSync(_cwd) ? _cwd : null,
      );
      if (path == null || path.isEmpty) return;
      await File(path).writeAsString(text, flush: true);
      _appendLine(tr2('已保存输出: {0}', [path]), TerminalLineType.system);
    } catch (error) {
      _appendLine(tr2('保存输出失败: {0}', [error]), TerminalLineType.stderr);
    }
  }

  void _handleTabPressed() {
    if (_isRunning) {
      if (_nativePtySessionId != null) {
        unawaited(_writeNativePtyInput('\t'));
      } else {
        _writeInputToRunningProcess('\t', confirmation: null);
      }
      return;
    }
    // 历史下拉里有高亮项时,Tab 接受该项而非做路径补全
    if (_historyDropdownOpen && _historySuggestIndex >= 0) {
      _acceptHistorySuggestion(_historySuggestions[_historySuggestIndex]);
      return;
    }
    unawaited(_completeInput());
  }

  Future<void> _completeInput() async {
    final text = _inputController.text;
    final cursor = _inputCursorOffset;
    final prefixRange = _completionRange(text, cursor);
    final token = text.substring(prefixRange.$1, prefixRange.$2);
    final candidates = await _completionCandidates(text, token, prefixRange.$1);
    if (!mounted || candidates.isEmpty) return;
    if (candidates.length == 1) {
      _replaceInputRange(prefixRange.$1, prefixRange.$2, candidates.single);
      return;
    }
    final common = _commonPrefix(candidates);
    if (common.length > token.length) {
      _replaceInputRange(prefixRange.$1, prefixRange.$2, common);
      return;
    }
    _appendLine('${_promptText()} $text', TerminalLineType.prompt);
    _printCompletionCandidates(candidates);
    WidgetsBinding.instance.addPostFrameCallback((_) => _keepInputFocused());
  }

  void _printCompletionCandidates(List<String> candidates) {
    if (candidates.isEmpty || !mounted) return;
    const maxDisplayCount = 200;
    final displayList = candidates.length > maxDisplayCount
        ? candidates.sublist(0, maxDisplayCount)
        : candidates;

    var maxLen = 0;
    for (final item in displayList) {
      final itemWidth = terminalCellWidth(item);
      if (itemWidth > maxLen) {
        maxLen = itemWidth;
      }
    }
    final colWidth = maxLen + 2;
    final numCols = math.max(1, _ptyColumns ~/ colWidth);
    final numRows = (displayList.length + numCols - 1) ~/ numCols;

    _isLastOutputLineOpen = false;
    for (var r = 0; r < numRows; r++) {
      final rowBuf = StringBuffer();
      for (var c = 0; c < numCols; c++) {
        final idx = c * numRows + r;
        if (idx < displayList.length) {
          final item = displayList[idx];
          if (c == numCols - 1 || idx + numRows >= displayList.length) {
            rowBuf.write(item);
          } else {
            rowBuf.write(padTerminalRight(item, colWidth));
          }
        }
      }
      _lines.add(
        TerminalLine.plain(rowBuf.toString(), TerminalLineType.system),
      );
    }
    if (candidates.length > maxDisplayCount) {
      final remaining = candidates.length - maxDisplayCount;
      _lines.add(
        TerminalLine.plain(
          tr2('... 还有 {0} 个匹配项，请继续输入以缩小范围', [remaining]),
          TerminalLineType.system,
        ),
      );
    }
    _cursorY = _lines.length - 1;
    _cursorX = _lines.last.length;
    _trimLines();
    _refreshSearchMatches();
    _notifyTerminalOutputChanged();
    _scrollToBottom();
  }

  (int, int) _completionRange(String text, int cursor) {
    var start = cursor;
    while (start > 0 && !text[start - 1].contains(RegExp(r'\s'))) {
      start--;
    }
    return (start, cursor);
  }

  Future<List<String>> _completionCandidates(
    String fullText,
    String token,
    int tokenStart,
  ) async {
    if (tokenStart == 0 && !token.contains(Platform.pathSeparator)) {
      final commands = <String>{
        'cd',
        'clear',
        'exit',
        'ls',
        'pwd',
        'cat',
        'grep',
        'rg',
        'git',
        'go',
        'dart',
        'flutter',
        'npm',
        'pnpm',
        'yarn',
        'node',
        ..._systemCommandsCache,
        ..._history.map((entry) => entry.split(RegExp(r'\s+')).first),
      };
      // 频率排序:全库使用次数高的命令排前(SQLite 聚合),同频字母序 ——
      // 常用命令打一两个字母 Tab 就能直中
      var usage = const <String, int>{};
      try {
        usage = await CommandHistoryStore.usageByFirstToken();
      } catch (_) {
        // 频率信息只是排序增强,取不到就退回纯字母序
      }
      return commands.where((command) => command.startsWith(token)).toList()
        ..sort((a, b) {
          final byUsage = (usage[b] ?? 0).compareTo(usage[a] ?? 0);
          return byUsage != 0 ? byUsage : a.compareTo(b);
        });
    }

    final pathToken = _stripMatchingQuotes(token);
    final separator = Platform.pathSeparator;
    final slashIndex = pathToken.lastIndexOf(separator);
    final directoryPart = slashIndex >= 0
        ? (slashIndex == 0 ? separator : pathToken.substring(0, slashIndex))
        : '';
    final namePrefix = slashIndex >= 0
        ? pathToken.substring(slashIndex + 1)
        : pathToken;
    final directoryPath = _resolvePath(directoryPart);

    final isCdCommand = fullText
        .substring(0, tokenStart)
        .trimRight()
        .endsWith('cd');

    try {
      final entries = await Directory(
        directoryPath,
      ).list(followLinks: true).toList();
      final completions = <String>[];
      for (final entry in entries) {
        final segments = entry.path.split(separator).where((s) => s.isNotEmpty);
        if (segments.isEmpty) continue;
        final name = segments.last;
        if (!name.startsWith(namePrefix)) continue;
        if (name.startsWith('.') && !namePrefix.startsWith('.')) continue;
        final isDir =
            entry is Directory || FileSystemEntity.isDirectorySync(entry.path);
        if (isCdCommand && !isDir) continue;
        final suffix = isDir ? separator : '';
        final prefix = directoryPart.isEmpty
            ? ''
            : (directoryPart == separator
                  ? separator
                  : '$directoryPart$separator');
        completions.add('$prefix$name$suffix');
      }
      return completions..sort();
    } catch (_) {
      return const [];
    }
  }

  String _commonPrefix(List<String> values) {
    if (values.isEmpty) return '';
    var prefix = values.first;
    for (final value in values.skip(1)) {
      var index = 0;
      while (index < prefix.length &&
          index < value.length &&
          prefix.codeUnitAt(index) == value.codeUnitAt(index)) {
        index++;
      }
      prefix = prefix.substring(0, index);
      if (prefix.isEmpty) break;
    }
    return prefix;
  }

  void _showSearch() {
    _isSearchVisible = true;
    _publishUiState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusNode.requestFocus();
      _searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchController.text.length,
      );
    });
  }

  void _hideSearch() {
    _isSearchVisible = false;
    _searchQuery = '';
    _searchController.clear();
    _searchMatches = const [];
    _searchMatchSet = const {};
    _activeSearchMatch = -1;
    _searchError = false;
    _notifyTerminalOutputChanged();
    _activeInputNode.requestFocus();
  }

  void _setSearchQuery(String value) {
    _searchQuery = value;
    _refreshSearchMatches();
    _notifyTerminalOutputChanged();
    if (_searchMatches.isNotEmpty) {
      _scrollToSearchMatch(_searchMatches[_activeSearchMatch]);
    }
  }

  // 输出驱动的搜索重扫节流:首次立即扫,150ms 冷却窗内的后续输出合并成
  // 窗口到期后的一次补扫。搜索没开(query 空)时零开销。
  Timer? _searchRefreshCooldown;
  bool _searchRefreshDirty = false;

  @override
  void _scheduleSearchRefresh() {
    if (_searchQuery.trim().isEmpty) return;
    if (_searchRefreshCooldown != null) {
      _searchRefreshDirty = true;
      return;
    }
    _refreshSearchMatches();
    _searchRefreshCooldown = Timer(const Duration(milliseconds: 150), () {
      _searchRefreshCooldown = null;
      if (_searchRefreshDirty && mounted) {
        _searchRefreshDirty = false;
        _scheduleSearchRefresh();
        _notifyTerminalOutputChanged();
      }
    });
  }

  void _refreshSearchMatches() {
    final query = _searchQuery.trim();
    _searchError = false;
    if (query.isEmpty) {
      _searchMatches = const [];
      _searchMatchSet = const {};
      _activeSearchMatch = -1;
      return;
    }
    final matcher = _buildSearchMatcher(query);
    if (matcher == null) {
      // 正则非法:无结果 + 标红,不抛异常
      _searchError = true;
      _searchMatches = const [];
      _searchMatchSet = const {};
      _activeSearchMatch = -1;
      return;
    }
    final matches = <int>[];
    for (var index = 0; index < _lines.length; index++) {
      if (matcher.hasMatch(_lines[index].text)) {
        matches.add(index);
      }
    }
    _searchMatches = matches;
    _searchMatchSet = matches.toSet();
    if (matches.isEmpty) {
      _activeSearchMatch = -1;
    } else if (_activeSearchMatch < 0 || _activeSearchMatch >= matches.length) {
      _activeSearchMatch = 0;
    }
  }

  /// 依据当前搜索选项(正则/大小写/全词)构造匹配器;正则非法返回 null。
  RegExp? _buildSearchMatcher(String query) {
    var pattern = _searchRegex ? query : RegExp.escape(query);
    if (_searchWholeWord) {
      pattern =
          r'\b(?:'
          '$pattern'
          r')\b';
    }
    try {
      return RegExp(pattern, caseSensitive: _searchCaseSensitive);
    } catch (_) {
      return null;
    }
  }

  /// 切换某个搜索选项后重算并刷新。
  void _toggleSearchOption(void Function() mutate) {
    setState(mutate);
    _refreshSearchMatches();
    _notifyTerminalOutputChanged();
    if (_searchMatches.isNotEmpty) {
      _scrollToSearchMatch(_searchMatches[_activeSearchMatch]);
    }
  }

  void _moveSearchMatch(int delta) {
    if (_searchMatches.isEmpty) return;
    _activeSearchMatch = (_activeSearchMatch + delta) % _searchMatches.length;
    if (_activeSearchMatch < 0) {
      _activeSearchMatch += _searchMatches.length;
    }
    _notifyTerminalOutputChanged();
    _scrollToSearchMatch(_searchMatches[_activeSearchMatch]);
  }

  /// 跳到上一条(delta<0)/下一条(delta>0)命令的提示符行并滚动过去。
  /// 依赖 Shell 集成(OSC 133)标记的提示符边界。
  void _jumpToPrompt(int delta) {
    final prompts = <int>[
      for (var i = 0; i < _lines.length; i++)
        if (_lines[i].isPromptStart) i,
    ];
    if (prompts.isEmpty) {
      _toastNoShellIntegration();
      return;
    }
    // 以当前视口顶部对应的行为基准找相邻提示符
    final total = math.max(1, _lines.length);
    var anchor = 0;
    if (_scrollController.hasClients) {
      final p = _scrollController.position;
      final ratio = p.maxScrollExtent <= 0
          ? 0.0
          : (p.pixels / p.maxScrollExtent).clamp(0.0, 1.0);
      anchor = (ratio * (total - 1)).round();
    }
    int? target;
    if (delta < 0) {
      for (final i in prompts.reversed) {
        if (i < anchor) {
          target = i;
          break;
        }
      }
      target ??= prompts.first;
    } else {
      for (final i in prompts) {
        if (i > anchor) {
          target = i;
          break;
        }
      }
      target ??= prompts.last;
    }
    _scrollToSearchMatch(target);
  }

  /// 命令块范围 [起, 止):从提示符行到下一个提示符行(不含)。
  // ── 输出折叠(OSC 133 命令块)──
  // 以提示符行对象的身份记折叠态(行号会随追加/裁剪漂移,对象不动);
  // 被裁剪的行在下次计算时顺带从集合剔除,不泄漏。
  final Set<TerminalLine> _foldedPrompts = Set<TerminalLine>.identity();

  /// 每行是否被折叠隐藏;没有任何折叠时返回 null(零开销路径)。
  List<bool>? _computeFoldedHidden() {
    if (_foldedPrompts.isEmpty || _isAltBufferActive) return null;
    final hidden = List<bool>.filled(_lines.length, false);
    final alive = <TerminalLine>{};
    var folding = false;
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      if (line.isPromptStart) {
        folding = _foldedPrompts.contains(line);
        if (folding) alive.add(line);
        continue; // 提示符行本身永远可见
      }
      if (folding) hidden[i] = true;
    }
    if (alive.length != _foldedPrompts.length) {
      _foldedPrompts
        ..clear()
        ..addAll(alive);
      if (_foldedPrompts.isEmpty) return null;
    }
    return hidden;
  }

  /// 该命令块被折叠隐藏的行数(供占位条显示)。
  int _foldedLineCount(int promptLine) {
    final range = _commandBlockRange(promptLine);
    return math.max(0, range.end - range.start - 1);
  }

  void _toggleFold(int promptLine) {
    final line = _lines[promptLine];
    if (!line.isPromptStart) return;
    setState(() {
      if (!_foldedPrompts.remove(line)) {
        _foldedPrompts.add(line);
      }
    });
    _notifyTerminalOutputChanged();
  }

  ({int start, int end}) _commandBlockRange(int promptLine) {
    var end = _lines.length;
    for (var i = promptLine + 1; i < _lines.length; i++) {
      if (_lines[i].isPromptStart) {
        end = i;
        break;
      }
    }
    return (start: promptLine, end: end);
  }

  /// 复制某条命令的输出(或命令+输出)到剪贴板。
  /// 有 OSC 133;C 标记则从输出起点算,否则回退为跳过命令行本身。
  Future<void> _copyCommandOutput(
    int promptLine, {
    required bool includeCommand,
  }) async {
    final range = _commandBlockRange(promptLine);
    var outputStart = range.start + 1; // 回退:跳过提示符/命令行
    for (var i = range.start; i < range.end; i++) {
      if (_lines[i].isCommandStart) {
        outputStart = i;
        break;
      }
    }
    final from = includeCommand ? range.start : outputStart;
    if (from >= range.end) {
      _logToast(tr('该命令没有输出'), ToastificationType.info);
      return;
    }
    final text = [
      for (var i = from; i < range.end; i++) _lines[i].text,
    ].join('\n').trimRight();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _logToast(
      includeCommand ? tr('已复制命令+输出') : tr('已复制命令输出'),
      ToastificationType.success,
    );
  }

  /// 右键提示符行弹出的命令菜单。
  Future<void> _showCommandMenu(int promptLine, Offset globalPos) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final chosen = await showMenu<String>(
      context: context,
      color: AppTheme.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppTheme.borderColor),
      ),
      position: RelativeRect.fromRect(
        globalPos & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'output',
          height: 38,
          child: Text('复制命令输出', style: TextStyle(fontSize: 12.5)),
        ),
        const PopupMenuItem(
          value: 'both',
          height: 38,
          child: Text('复制命令 + 输出', style: TextStyle(fontSize: 12.5)),
        ),
        if (_foldedLineCount(promptLine) > 0)
          PopupMenuItem(
            value: 'fold',
            height: 38,
            child: Text(
              _foldedPrompts.contains(_lines[promptLine])
                  ? tr('展开输出')
                  : tr2('折叠输出({0} 行)', [_foldedLineCount(promptLine)]),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
      ],
    );
    if (chosen == null) return;
    if (chosen == 'fold') {
      _toggleFold(promptLine);
      return;
    }
    await _copyCommandOutput(promptLine, includeCommand: chosen == 'both');
  }

  void _toastNoShellIntegration() {
    _logToast(
      tr('未检测到命令标记 —— 需在 shell 里启用 OSC 133 集成'),
      ToastificationType.info,
    );
  }

  void _scrollToSearchMatch(int lineIndex) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients || _lines.length <= 1) return;
      final position = _scrollController.position;
      final ratio = lineIndex / math.max(1, _lines.length - 1);
      final target = (position.maxScrollExtent * ratio).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      _autoFollowOutput = false;
      _publishUiState();
      _scrollController.jumpTo(target);
    });
  }

  void _showPreviousHistory() {
    if (_history.isEmpty) return;
    _historyIndex = (_historyIndex - 1).clamp(0, _history.length - 1);
    _setInputText(_history[_historyIndex]);
  }

  void _showNextHistory() {
    if (_history.isEmpty) return;
    if (_historyIndex >= _history.length - 1) {
      _historyIndex = _history.length;
      _setInputText('');
      return;
    }
    _historyIndex++;
    _setInputText(_history[_historyIndex]);
  }

  void _setInputText(String value) {
    _inputController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  // ── 命令历史下拉补全 ────────────────────────────────────────────────

  /// 输入变化时重算匹配的历史项并显示/隐藏下拉。
  void _onInputChanged(String text) {
    if (_suppressHistoryFilter || _isRunning) return;
    final query = text.trim();
    if (query.isEmpty) {
      _hideHistoryDropdown();
      return;
    }
    final lower = query.toLowerCase();
    final seen = <String>{};
    final matches = <String>[];
    // 最近的在前:倒序遍历历史,去重,子串匹配,排除与输入完全相同的项
    for (var i = _history.length - 1; i >= 0; i--) {
      final entry = _history[i];
      if (entry == query) continue;
      if (!entry.toLowerCase().contains(lower)) continue;
      if (seen.add(entry)) matches.add(entry);
      if (matches.length >= 8) break;
    }
    if (matches.isEmpty) {
      _hideHistoryDropdown();
      return;
    }
    _historySuggestions = matches;
    _historySuggestIndex = -1;
    _showHistoryDropdown();
  }

  void _showHistoryDropdown() {
    if (_historyOverlay == null) {
      _historyOverlay = OverlayEntry(builder: _buildHistoryDropdown);
      Overlay.of(context).insert(_historyOverlay!);
    } else {
      _historyOverlay!.markNeedsBuild();
    }
  }

  void _hideHistoryDropdown() {
    _historyOverlay?.remove();
    _historyOverlay = null;
    _historySuggestions = const [];
    _historySuggestIndex = -1;
  }

  /// ↑/↓ 在下拉里移动并把选中项填入输入框(填充时抑制重新过滤)。
  void _moveHistorySuggestion(int delta) {
    if (_historySuggestions.isEmpty) return;
    final n = _historySuggestions.length;
    _historySuggestIndex = (_historySuggestIndex + delta) % n;
    if (_historySuggestIndex < 0) _historySuggestIndex += n;
    _suppressHistoryFilter = true;
    _setInputText(_historySuggestions[_historySuggestIndex]);
    _suppressHistoryFilter = false;
    _historyOverlay?.markNeedsBuild();
  }

  void _acceptHistorySuggestion(String value) {
    _suppressHistoryFilter = true;
    _setInputText(value);
    _suppressHistoryFilter = false;
    _hideHistoryDropdown();
    _activeInputNode.requestFocus();
  }

  Widget _buildHistoryDropdown(BuildContext context) {
    return Positioned(
      width: 420,
      child: CompositedTransformFollower(
        link: _historyLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(0, -4),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxHeight: 240),
            decoration: BoxDecoration(
              color: AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _historySuggestions.length,
              itemBuilder: (context, i) {
                final active = i == _historySuggestIndex;
                return InkWell(
                  onTap: () => _acceptHistorySuggestion(_historySuggestions[i]),
                  child: Container(
                    color: active
                        ? AppTheme.brandColor.withValues(alpha: 0.14)
                        : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.history300,
                          size: 12,
                          color: AppTheme.subtleTextColor,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _historySuggestions[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: _monospaceFontFamily,
                              color: active
                                  ? AppTheme.headingColor
                                  : AppTheme.subtleTextColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadHistory() async {
    try {
      // SQLite 存储(CommandHistoryStore 内部完成旧 prefs 的一次性迁移,
      // 新会话无自身历史时回落旧全局种子,行为与迁移前一致)
      final stored = await CommandHistoryStore.load(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _history
          ..clear()
          ..addAll(stored);
        _historyIndex = _history.length;
      });
    } catch (_) {
      // History is a convenience feature; failures should not block terminal use.
    }
  }

  Future<void> _loadSystemCommands() async {
    try {
      final pathEnv = Platform.environment['PATH'] ?? '';
      final dirs = pathEnv.split(Platform.isWindows ? ';' : ':');
      for (final dirPath in dirs) {
        if (dirPath.trim().isEmpty) continue;
        final dir = Directory(dirPath.trim());
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(followLinks: true)) {
          try {
            final stat = await entity.stat();
            if (stat.type == FileSystemEntityType.file ||
                stat.type == FileSystemEntityType.link) {
              final name = entity.path.split(Platform.pathSeparator).last;
              if (name.isNotEmpty && !name.startsWith('.')) {
                _systemCommandsCache.add(name);
              }
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _rememberCommand(String command) {
    _history.removeWhere((entry) => entry == command);
    _history.add(command);
    if (_history.length > _maxHistoryEntries) {
      _history.removeRange(0, _history.length - _maxHistoryEntries);
    }
    _historyIndex = _history.length;
    unawaited(CommandHistoryStore.record(widget.sessionId, command));
  }

  String _promptText() => '${_shortPath(_cwd)}\$';

  String _shortPath(String path) {
    final home = _homeDirectory;
    if (home != null &&
        (path == home || path == '$home${Platform.pathSeparator}')) {
      return '~';
    }
    final segments = path
        .split(Platform.pathSeparator)
        .where((part) => part.isNotEmpty)
        .toList();
    if (segments.isEmpty) return path;
    return segments.last;
  }

  String get _shellExecutable {
    if (Platform.isWindows) {
      return Platform.environment['ComSpec'] ?? 'cmd.exe';
    }
    final shell = Platform.environment['SHELL'];
    if (shell != null && shell.isNotEmpty) return shell;
    return '/bin/zsh';
  }

  String get _shellLabel {
    final executable = _shellExecutable;
    final separator = Platform.isWindows ? r'\' : '/';
    return executable.split(separator).last;
  }

  String get _terminalBackendLabel {
    if ((Platform.isMacOS || Platform.isWindows) && !_nativePtyUnavailable) {
      return 'PTY · $_shellLabel';
    }
    return _shellLabel;
  }

  List<String> _shellArguments(String command) {
    if (Platform.isWindows) return ['/C', command];
    if (_shellLabel.toLowerCase() == 'zsh') return ['-f', '-c', command];
    return ['-c', command];
  }

  /// GUI 启动的 App 只从 launchd 继承最小 PATH:/etc/paths.d(如 go)和
  /// 用户 rc 文件里追加的目录全都缺席,内置终端会莫名找不到命令。仿
  /// VS Code 用「登录 + 交互」shell 解析一次真实 PATH,所有会话复用;
  /// 解析失败(超时/异常)就退回 _processEnvironment 手拼的兜底列表。
  static String? _loginShellPath;
  static Future<void>? _loginShellPathResolve;

  static Future<void> _resolveLoginShellPath() {
    return _loginShellPathResolve ??= () async {
      if (Platform.isWindows) return;
      final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
      // rc 文件可能往 stdout 打招呼语,用标记行把 PATH 捞出来
      const marker = '__TERMORA_LOGIN_PATH__';
      try {
        final result = await Process.run(shell, [
          '-l',
          '-i',
          '-c',
          'printf "\\n$marker%s\\n" "\$PATH"',
        ]).timeout(const Duration(seconds: 5));
        final stdout = result.stdout;
        if (result.exitCode != 0 || stdout is! String) return;
        for (final line in stdout.split('\n').reversed) {
          final index = line.lastIndexOf(marker);
          if (index < 0) continue;
          final path = line.substring(index + marker.length).trim();
          if (path.isNotEmpty) _loginShellPath = path;
          return;
        }
      } catch (_) {
        // 拿不到就用兜底列表,不影响使用
      }
    }();
  }

  Map<String, String> get _processEnvironment {
    final currentPath = Platform.environment['PATH'] ?? '';
    final home = _homeDirectoryPath;
    final loginPath = _loginShellPath ?? '';
    final pathEntries = <String>[
      // 登录 shell 的真实 PATH 优先,保留用户自己的目录顺序
      if (loginPath.isNotEmpty) loginPath,
      if (home != null) '$home/.local/bin',
      if (home != null) '$home/go/bin',
      '/opt/homebrew/bin',
      '/opt/homebrew/sbin',
      '/usr/local/bin',
      '/usr/local/sbin',
      // /etc/paths.d/go 只在登录 shell 生效,GUI 环境下手动兜底
      '/usr/local/go/bin',
      '/usr/bin',
      '/bin',
      '/usr/sbin',
      '/sbin',
      if (currentPath.isNotEmpty) currentPath,
    ];
    return {
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      // GUI 启动的 App 没有 LANG,子进程落在 POSIX locale:ssh 会把非 ASCII
      // 路径转成 \234 式八进制转义(乱码),ls/zsh 的中文也会坏。
      // 仿 Terminal.app 按系统区域注入 UTF-8 locale。
      'LANG': _utf8Lang,
      'COLUMNS': math.max(40, _ptyColumns).toString(),
      'LINES': math.max(10, _ptyRows).toString(),
      'PATH': _dedupePathEntries(pathEntries),
    };
  }

  /// 计算一次全局复用:优先父进程已有的 UTF-8 LANG,否则由系统区域推导
  /// (zh-Hans-CN → zh_CN.UTF-8),兜底 en_US.UTF-8。
  static final String _utf8Lang = _computeUtf8Lang();

  static String _computeUtf8Lang() {
    final existing = Platform.environment['LANG'];
    if (existing != null && existing.toUpperCase().contains('UTF-8')) {
      return existing;
    }
    final parts = Platform.localeName.split(RegExp('[-_]'));
    if (parts.length >= 2) {
      final lang = parts.first.toLowerCase();
      final region = parts.last.toUpperCase();
      if (RegExp(r'^[a-z]{2,3}$').hasMatch(lang) &&
          RegExp(r'^[A-Z]{2}$').hasMatch(region)) {
        return '${lang}_$region.UTF-8';
      }
    }
    return 'en_US.UTF-8';
  }

  String _dedupePathEntries(List<String> entries) {
    final seen = <String>{};
    return entries
        .expand((entry) => entry.split(':'))
        .where((entry) => entry.isNotEmpty && seen.add(entry))
        .join(':');
  }

  String? get _homeDirectory => _homeDirectoryPath;

  String _shellQuote(String value) {
    if (Platform.isWindows) {
      return '"${value.replaceAll('"', r'\"')}"';
    }
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  String _stripMatchingQuotes(String value) {
    if (value.length < 2) return value;
    final first = value[0];
    final last = value[value.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  Future<void> _openTerminalLink(String rawUrl) async {
    final url = _normalizeTerminalLink(rawUrl);
    try {
      final result = await Process.run(
        _platformOpenExecutable,
        _platformOpenArguments(url),
      );
      if (!mounted) return;
      if (result.exitCode != 0) {
        final message = result.stderr.toString().trim();
        _appendLine(
          message.isEmpty ? tr2('打开链接失败: {0}', [url]) : message,
          TerminalLineType.stderr,
        );
      }
    } catch (error) {
      _appendLine(tr2('打开链接失败: {0}', [error]), TerminalLineType.stderr);
    }
  }

  String _normalizeTerminalLink(String rawUrl) {
    final trimmed = _trimTerminalLinkText(rawUrl);
    return trimmed.startsWith('www.') ? 'https://$trimmed' : trimmed;
  }

  String _trimTerminalLinkText(String value) {
    var end = value.length;
    while (end > 0 && '.,;:!?)]}\'"'.contains(value[end - 1])) {
      end--;
    }
    return value.substring(0, end);
  }

  String get _platformOpenExecutable {
    if (Platform.isMacOS) return '/usr/bin/open';
    if (Platform.isWindows) return 'rundll32';
    return 'xdg-open';
  }

  List<String> _platformOpenArguments(String url) {
    if (Platform.isWindows) return ['url.dll,FileProtocolHandler', url];
    return [url];
  }

  void _syncPtySizeForViewport(
    BoxConstraints constraints,
    _TerminalCellMetrics metrics,
  ) {
    if (!Platform.isMacOS) return;
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) return;
    _lastCellWidth = metrics.cellWidth;
    _lastLineHeight = metrics.lineHeight;

    // 上限只是防御性护栏,要够大:大屏 + 缩小字号时 300 列就封顶了,
    // vim 只画左边一截,右侧留白("宽度不占满"就是它)
    final columns = math.max(
      20,
      math.min(600, ((constraints.maxWidth - 36) / metrics.cellWidth).floor()),
    );
    // Each rendered line occupies lineHeight + 5px (3px bottom margin + 2×1px
    final rows = math.max(
      5,
      math.min(
        240,
        ((constraints.maxHeight - 26) / metrics.lineHeight).floor(),
      ),
    );
    if (columns == _ptyColumns && rows == _ptyRows) return;

    final oldColumns = _ptyColumns;
    _ptyColumns = columns;
    _ptyRows = rows;
    // 列宽变化时回流普通缓冲区:历史软折行按新宽度重排(对标 xterm.js)
    if (oldColumns != columns) {
      _reflowOnColumnChange(oldColumns, columns);
    }
    _tabStops.ensureCovers(
      math.max(math.max(_ptyColumns, _defaultPtyColumns), columns),
    );
    _cursorX = _clampInt(_cursorX, 0, _maxCursorColumn);
    _savedCursorX = _clampInt(_savedCursorX, 0, _maxCursorColumn);
    _normalCursorX = _clampInt(_normalCursorX, 0, _maxCursorColumn);
    _normalSavedCursorX = _clampInt(_normalSavedCursorX, 0, _maxCursorColumn);
    if (_scrollTopMargin == 0 || _scrollBottomMargin >= rows) {
      _scrollBottomMargin = math.max(0, rows - 1);
    }
    if (_isAltBufferActive) {
      _scrollTopMargin = 0;
      _scrollBottomMargin = math.max(0, rows - 1);
      _resizeAltBuffer(TerminalLineType.stdout);
    }
    final sessionId = _nativePtySessionId;
    if (sessionId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        _resizeNativePtySession(sessionId, columns: columns, rows: rows),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final monoStyle = TextStyle(
      fontFamily: _monospaceFontFamily,
      fontFamilyFallback: _monospaceFontFamilyFallback,
      // 默认字号比原来小一号(11);Command+加号仍可放大
      fontSize: 11 * widget.fontScale,
      // 行高收紧到接近真终端(原 1.35 偏松,换行时上下行显得间隔大)
      height: 1.2,
      letterSpacing: 0,
    );

    // 详情面板浮动覆盖在右侧(非分栏,终端保持满宽);作为 Stack 的兄弟层放在
    // 终端手势层之外——否则点面板(如地址栏)时 pointer-up 会冒泡到外层
    // Listener,把焦点又抢回终端输入框,地址栏就获取不到焦点。
    return Stack(
      fit: StackFit.expand,
      children: [
        Focus(
          onKeyEvent: _handleKeyEvent,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerUp: (_) => _handleSurfaceTap(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _handleSurfaceTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildToolbar(context),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(color: AppTheme.surfaceColor),
                      clipBehavior: Clip.antiAlias,
                      child: Consumer(
                        builder: (context, ref, _) {
                          final isSearchVisible = ref.watch(
                            terminalUiControllerProvider(
                              widget.sessionId,
                            ).select((state) => state.isSearchVisible),
                          );
                          return Column(
                            children: [
                              if (isSearchVisible) _buildSearchBar(monoStyle),
                              Expanded(child: _buildTerminalOutput(monoStyle)),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  _buildFooterBar(context),
                ],
              ),
            ),
          ),
        ),
        if (_detailsPanelVisible)
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            child: _buildDetailsPanel(context),
          ),
      ],
    );
  }

  void _handleSurfaceTap() {
    if (!widget.isActive) widget.onRequestActivate?.call();
    _keepInputFocused();
  }

  // ---------------------------------------------------------------------------
  // Details side panel (info / outline / git / files)
  // ---------------------------------------------------------------------------

  void _toggleDetailsPanel() {
    setState(() => _detailsPanelVisible = !_detailsPanelVisible);
  }

  Future<void> _loadDetailsWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getDouble(_detailsWidthPrefKey);
      if (stored == null || !mounted) return;
      final clamped = stored
          .clamp(_minDetailsWidth, _maxDetailsWidth)
          .toDouble();
      if (clamped == _detailsPanelWidth) return;
      setState(() => _detailsPanelWidth = clamped);
    } catch (_) {}
  }

  Future<void> _persistDetailsWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_detailsWidthPrefKey, _detailsPanelWidth);
    } catch (_) {}
  }

  void _resizeDetailsPanel(double dx) {
    // 面板贴右边:向左拖(dx<0)变宽,向右拖变窄
    final next = (_detailsPanelWidth - dx)
        .clamp(_minDetailsWidth, _maxDetailsWidth)
        .toDouble();
    if (next == _detailsPanelWidth) return;
    setState(() => _detailsPanelWidth = next);
  }

  void _insertIntoInput(String text) {
    if (_isNativePtyActive) {
      unawaited(_writeNativePtyInput(text));
      return;
    }
    final base = _inputController.text;
    final sel = _inputController.selection;
    final start = sel.start >= 0 ? sel.start : base.length;
    final end = sel.end >= 0 ? sel.end : base.length;
    _inputController.text = base.replaceRange(start, end, text);
    _inputController.selection = TextSelection.collapsed(
      offset: start + text.length,
    );
    _activeInputNode.requestFocus();
  }

  /// 文件面板「在终端进入此目录」:向运行中的会话发 cd 并回车
  void _cdInTerminal(String remotePath) {
    final command = 'cd ${_shellQuote(remotePath)}';
    if (_isNativePtyActive) {
      unawaited(_writeNativePtyInput('$command\n'));
    } else {
      _sendInputToRunningProcess(command);
    }
  }

  void _insertPathIntoInput(String fullPath) {
    var relative = fullPath;
    if (fullPath.startsWith(_cwd)) {
      relative = fullPath.substring(_cwd.length);
      while (relative.startsWith(Platform.pathSeparator)) {
        relative = relative.substring(1);
      }
    }
    if (relative.isEmpty) relative = fullPath;
    _insertIntoInput('${_shellQuote(relative)} ');
  }

  void _scrollToLine(int index) {
    if (!_scrollController.hasClients) return;
    setState(() => _autoFollowOutput = false);
    _publishUiState();
    final position = _scrollController.position;
    final offset = 14 + index * (_lastLineHeight + 4);
    _scrollController.jumpTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  Future<ProcessResult?> _runGit(List<String> args) async {
    try {
      return await Process.run(
        'git',
        args,
        workingDirectory: _cwd,
        environment: _processEnvironment,
        includeParentEnvironment: true,
      );
    } catch (_) {
      return null;
    }
  }

  Widget _buildDetailsPanel(BuildContext context) {
    return SizedBox(
      width: _detailsPanelWidth,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceColor,
                border: Border(left: BorderSide(color: AppTheme.borderColor)),
                // 浮动在终端上方,用投影托起层次
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 16,
                    offset: const Offset(-4, 0),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPanelTabBar(),
                  Divider(height: 1, thickness: 1, color: AppTheme.borderColor),
                  Expanded(child: _buildPanelContent()),
                ],
              ),
            ),
          ),
          // 左边缘拖拽把手:调节面板宽窄
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 8,
            child: _buildDetailsResizeHandle(),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsResizeHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => _resizeDetailsPanel(d.delta.dx),
        onHorizontalDragEnd: (_) => unawaited(_persistDetailsWidth()),
        onDoubleTap: () {
          setState(() => _detailsPanelWidth = _defaultDetailsWidth);
          unawaited(_persistDetailsWidth());
        },
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _buildPanelTabBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
      child: Row(
        children: [
          _buildPanelTab(_TerminalPanelTab.info, LucideIcons.info300, tr('信息')),
          const SizedBox(width: 2),
          _buildPanelTab(
            _TerminalPanelTab.outline,
            LucideIcons.listTree300,
            tr('大纲'),
          ),
          // 本地会话:git 跑本地 cwd;SSH 会话:仅当提供了远端 git 运行器
          // 才显示(走 ssh 到远端仓库),否则隐藏(本地 cwd 对 SSH 无意义)
          if (!_isRemoteSession || widget.runRemoteGit != null) ...[
            const SizedBox(width: 2),
            _buildPanelTab(
              _TerminalPanelTab.git,
              LucideIcons.gitBranch300,
              'Git',
            ),
          ],
          const SizedBox(width: 2),
          _buildPanelTab(
            _TerminalPanelTab.files,
            LucideIcons.folder300,
            tr('文件'),
          ),
          const Spacer(),
          _TerminalIconButton(
            tooltip: tr('关闭面板'),
            icon: LucideIcons.x300,
            size: 28,
            iconSize: 14,
            ghost: true,
            onPressed: _toggleDetailsPanel,
          ),
        ],
      ),
    );
  }

  Widget _buildPanelTab(_TerminalPanelTab tab, IconData icon, String label) {
    final active = _activePanelTab == tab;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _activePanelTab = tab),
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.symmetric(
            horizontal: active ? 9 : 7,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: active ? AppTheme.softBrandColor : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: active ? AppTheme.brandColor : AppTheme.subtleTextColor,
              ),
              if (active) ...[
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.brandColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPanelContent() {
    switch (_activePanelTab) {
      case _TerminalPanelTab.info:
        return _buildInfoTabContent();
      case _TerminalPanelTab.outline:
        return _buildOutlineTabContent();
      case _TerminalPanelTab.git:
        final remoteKey = widget.remoteKey;
        final runRemoteGit = widget.runRemoteGit;
        if (_isRemoteSession && remoteKey != null && runRemoteGit != null) {
          final dir = _remoteCwdGuess ?? '';
          return _TerminalGitTab(
            key: ValueKey('git_remote_$dir'),
            cwd: dir,
            runGit: (args) => runRemoteGit(remoteKey, dir, args),
            onInsertPath: _insertPathIntoInput,
          );
        }
        return _TerminalGitTab(
          cwd: _cwd,
          runGit: _runGit,
          onInsertPath: _insertPathIntoInput,
        );
      case _TerminalPanelTab.files:
        final remoteKey = widget.remoteKey;
        final listRemote = widget.listRemoteDir;
        if (_isRemoteSession && remoteKey != null && listRemote != null) {
          // 远端 SFTP:默认打开到命令行当前目录(探测不到则回落家目录),
          // 目录随 cd 变化跟随刷新
          final upload = widget.uploadToRemote;
          final uploadDir = widget.uploadDirToRemote;
          final download = widget.downloadFromRemote;
          final actions = widget.remoteFileActions;
          return _TerminalFilesTab(
            key: const ValueKey('files_remote'),
            cwd: _remoteCwdGuess ?? '',
            onInsertPath: _insertPathIntoInput,
            onCdInTerminal: _cdInTerminal,
            remoteLister: (path) => listRemote(remoteKey, path),
            remoteUploader: upload == null
                ? null
                : (localPath, remoteDir) =>
                      upload(remoteKey, localPath, remoteDir),
            remoteUploadDir: uploadDir == null
                ? null
                : (localDir, remoteDir) =>
                      uploadDir(remoteKey, localDir, remoteDir),
            remoteDownloader: download == null
                ? null
                : (remotePath, localPath, isDir) =>
                      download(remoteKey, remotePath, localPath, isDir),
            remoteRename: actions == null
                ? null
                : (path, newName) => actions.rename(remoteKey, path, newName),
            remoteDelete: actions == null
                ? null
                : (path, isDir) => actions.delete(remoteKey, path, isDir),
            remoteMakeDir: actions == null
                ? null
                : (parentDir, name) =>
                      actions.makeDir(remoteKey, parentDir, name),
            elevated: widget.isRemoteElevated?.call(remoteKey) ?? false,
            onElevate: widget.elevateRemote == null
                ? null
                : () => widget.elevateRemote!(remoteKey),
            onDropElevation: widget.dropRemoteElevation == null
                ? null
                : () => widget.dropRemoteElevation!(remoteKey),
          );
        }
        return _TerminalFilesTab(
          key: const ValueKey('files_local'),
          cwd: _cwd,
          onInsertPath: _insertPathIntoInput,
        );
    }
  }

  Widget _buildInfoTabContent() {
    final rows = <(String, String)>[
      (tr('当前目录'), _cwd),
      ('Shell', _shellLabel),
      (tr('后端'), _terminalBackendLabel),
      (tr('尺寸'), tr2('{0} 列 × {1} 行', [_ptyColumns, _ptyRows])),
      ('状态', _isRunning ? '运行中: ${_runningCommand ?? ''}' : '空闲'),
      (tr('字号'), '${(widget.fontScale * 100).round()}%'),
      (tr('自动折行'), _autoWrapMode ? tr('开') : tr('关')),
      (tr('光标'), _showCursor ? tr('显示') : tr('隐藏')),
      if (_isAltBufferActive) ('缓冲区', 'Alt Buffer'),
      if ((_titleStack.current ?? '').isNotEmpty)
        (tr('标题'), _titleStack.current!),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      children: [for (final (key, value) in rows) _buildInfoRow(key, value)],
    );
  }

  Widget _buildInfoRow(String key, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            key,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppTheme.subtleTextColor,
            ),
          ),
          const SizedBox(height: 3),
          SelectableText(
            value,
            style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
          ),
        ],
      ),
    );
  }

  Widget _buildOutlineTabContent() {
    final entries = <(int, String)>[];
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].type == TerminalLineType.prompt) {
        final text = _lines[i].text.trim();
        if (text.isNotEmpty) entries.add((i, text));
      }
    }
    if (entries.isEmpty) {
      return _buildPanelEmpty(LucideIcons.listTree300, tr('还没有执行过命令'));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final (lineIndex, text) = entries[index];
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _scrollToLine(lineIndex),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.cornerDownLeft300,
                    size: 13,
                    color: AppTheme.subtleTextColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.headingColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPanelEmpty(IconData icon, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 26,
            color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(fontSize: 12, color: AppTheme.subtleTextColor),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final ui = ref.watch(terminalUiControllerProvider(widget.sessionId));
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 360;
            final inline = <Widget>[
              _toolbarButton(tr('搜索'), LucideIcons.search300, _showSearch),
              const SizedBox(width: 2),
              Builder(
                builder: (btnContext) =>
                    _toolbarButton(tr('快捷命令 / 片段'), LucideIcons.zap300, () {
                      final box = btnContext.findRenderObject() as RenderBox?;
                      final pos = box == null
                          ? Offset.zero
                          : box.localToGlobal(box.size.bottomLeft(Offset.zero));
                      unawaited(_showSnippetMenu(pos));
                    }),
              ),
              if (widget.remoteCommand != null &&
                  widget.onOpenRemoteFiles != null) ...[
                const SizedBox(width: 2),
                _toolbarButton(
                  tr('文件(SFTP)—在 SSH 当前目录打开'),
                  LucideIcons.folder300,
                  widget.onOpenRemoteFiles,
                ),
              ],
              if (widget.remoteCommand != null && !ui.isRunning) ...[
                const SizedBox(width: 2),
                _toolbarButton(
                  tr('重新连接 SSH'),
                  LucideIcons.plugZap300,
                  _reconnectRemote,
                ),
              ],
              if (ui.isRunning) ...[
                const SizedBox(width: 2),
                _toolbarButton(
                  tr('停止'),
                  LucideIcons.square300,
                  () => _stopProcess(),
                ),
              ],
              if (!ui.autoFollowOutput) ...[
                const SizedBox(width: 2),
                _toolbarButton(
                  tr('滚动到底部'),
                  LucideIcons.arrowDownToLine300,
                  _forceScrollToBottom,
                ),
              ],
              // 开着的状态开关(广播/同步滚动/日志录制)保留在外面提示状态,
              // 其余不常用按钮统一收进「更多」下拉
              if (widget.broadcastAvailable && widget.broadcastEnabled) ...[
                const SizedBox(width: 2),
                _TerminalIconButton(
                  tooltip: tr('命令广播:开(输入同时发给所有会话)— 点击关闭'),
                  icon: LucideIcons.radio300,
                  size: 24,
                  iconSize: 13,
                  ghost: false,
                  onPressed: widget.onToggleBroadcast,
                ),
              ],
              if (widget.broadcastAvailable && widget.syncScrollEnabled) ...[
                const SizedBox(width: 2),
                _TerminalIconButton(
                  tooltip: tr('同步滚动:开(所有分屏一起滚)— 点击关闭'),
                  icon: LucideIcons.arrowDownUp300,
                  size: 24,
                  iconSize: 13,
                  ghost: false,
                  onPressed: widget.onToggleSyncScroll,
                ),
              ],
              if (_sessionLogger.isActive) ...[
                const SizedBox(width: 2),
                _TerminalIconButton(
                  tooltip: tr('会话日志:录制中(输出落盘)— 点击停止'),
                  icon: LucideIcons.circleStop300,
                  size: 24,
                  iconSize: 13,
                  ghost: false,
                  onPressed: () => unawaited(_toggleSessionLog()),
                ),
              ],
              if (widget.canClosePane) ...[
                const SizedBox(width: 2),
                _toolbarButton(
                  tr('关闭终端'),
                  LucideIcons.x300,
                  () => unawaited(_confirmClosePane()),
                ),
              ],
              const SizedBox(width: 2),
              _buildOverflowMenu(ui, compact: compact),
            ];
            final isMultiPane = widget.canClosePane;
            final toolbarBg = widget.isActive
                ? AppTheme.surfaceColor
                : (isMultiPane
                      ? AppTheme.subtleSurfaceColor.withValues(alpha: 0.35)
                      : AppTheme.surfaceColor);
            return Container(
              decoration: BoxDecoration(
                color: toolbarBg,
                border: Border(
                  top: isMultiPane
                      ? BorderSide(
                          color: widget.isActive
                              ? AppTheme.brandColor
                              : Colors.transparent,
                          width: 2,
                        )
                      : BorderSide.none,
                  bottom: BorderSide(color: AppTheme.borderColor),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Draggable<_TerminalDragData>(
                      data: _TerminalDragData(widget.sessionId),
                      dragAnchorStrategy: childDragAnchorStrategy,
                      onDragStarted: () {
                        if (!widget.isActive) widget.onRequestActivate?.call();
                      },
                      feedback: _TerminalDragFeedback(title: widget.title),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: _buildToolbarTitle(context, ui),
                      ),
                    ),
                  ),
                  if (constraints.maxWidth > 30) const SizedBox(width: 8),
                  Flexible(
                    flex: 10,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: inline,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildToolbarTitle(BuildContext context, TerminalUiState ui) {
    return Tooltip(
      message: tr('拖拽以重排布局'),
      waitDuration: const Duration(milliseconds: 600),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 50) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.gripVertical300,
                    size: 13,
                    color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    widget.remoteCommand != null
                        ? LucideIcons.server300
                        : LucideIcons.squareTerminal300,
                    size: 13,
                    color: widget.isActive
                        ? AppTheme.brandColor
                        : AppTheme.subtleTextColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.title,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: widget.isActive
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: widget.isActive
                          ? AppTheme.headingColor
                          : AppTheme.subtleTextColor,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            );
          }
          return Row(
            children: [
              Icon(
                LucideIcons.gripVertical300,
                size: 13,
                color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 4),
              Icon(
                widget.remoteCommand != null
                    ? LucideIcons.server300
                    : LucideIcons.squareTerminal300,
                size: 13,
                color: widget.isActive
                    ? AppTheme.brandColor
                    : AppTheme.subtleTextColor,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 108),
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: widget.isActive
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: widget.isActive
                          ? AppTheme.headingColor
                          : AppTheme.subtleTextColor,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ),
              if (_shortPath(ui.cwd).isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _shortPath(ui.cwd),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.subtleTextColor,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _toolbarButton(
    String tooltip,
    IconData icon,
    VoidCallback? onPressed,
  ) {
    return _TerminalIconButton(
      tooltip: tooltip,
      icon: icon,
      size: 24,
      iconSize: 13,
      ghost: true,
      onPressed: onPressed,
    );
  }

  final GlobalKey _overflowBtnKey = GlobalKey();

  Widget _buildOverflowMenu(TerminalUiState ui, {required bool compact}) {
    return SizedBox(
      key: _overflowBtnKey,
      width: 24,
      height: 24,
      child: GlassPopupMenuButton<_TerminalOverflowAction>(
        tooltip: tr('更多'),
        position: PopupMenuPosition.under,
        padding: EdgeInsets.zero,
        splashRadius: 16,
        iconSize: 13,
        color: AppTheme.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: AppTheme.borderColor),
        ),
        icon: Icon(
          LucideIcons.ellipsis300,
          size: 13,
          color: AppTheme.headingColor,
        ),
        onSelected: _handleOverflowAction,
        itemBuilder: (context) => [
          _overflowItem(
            _TerminalOverflowAction.splitHorizontal,
            LucideIcons.columns2300,
            tr('向右分屏'),
            enabled: widget.onSplitHorizontal != null,
          ),
          _overflowItem(
            _TerminalOverflowAction.splitVertical,
            LucideIcons.rows2300,
            tr('向下分屏'),
            enabled: widget.onSplitVertical != null,
          ),
          if (widget.onMinimizePane != null)
            _overflowItem(
              _TerminalOverflowAction.minimizePane,
              LucideIcons.minimize2300,
              tr('最小化到标签'),
            ),
          const PopupMenuDivider(),
          _overflowItem(
            _TerminalOverflowAction.minimap,
            LucideIcons.map300,
            _minimapVisible ? tr('隐藏缩略图') : tr('缩略图导航'),
          ),
          _overflowItem(
            _TerminalOverflowAction.detailsPanel,
            _detailsPanelVisible
                ? LucideIcons.panelRightClose300
                : LucideIcons.panelRight300,
            _detailsPanelVisible ? tr('隐藏详情面板') : tr('详情面板'),
          ),
          if (widget.broadcastAvailable) ...[
            _overflowItem(
              _TerminalOverflowAction.broadcast,
              LucideIcons.radio300,
              widget.broadcastEnabled ? tr('关闭命令广播') : tr('命令广播'),
            ),
            _overflowItem(
              _TerminalOverflowAction.syncScroll,
              LucideIcons.arrowDownUp300,
              widget.syncScrollEnabled ? tr('关闭同步滚动') : tr('同步滚动'),
            ),
          ],
          _overflowItem(
            _TerminalOverflowAction.sessionLog,
            _sessionLogger.isActive
                ? LucideIcons.circleStop300
                : LucideIcons.circleDot300,
            _sessionLogger.isActive ? tr('停止会话日志') : tr('录制会话日志'),
          ),
          _overflowItem(
            _TerminalOverflowAction.highlight,
            LucideIcons.highlighter300,
            tr('触发器高亮'),
          ),
          _overflowItem(
            _TerminalOverflowAction.theme,
            LucideIcons.palette300,
            tr('配色方案'),
          ),
          const PopupMenuDivider(),
          _overflowItem(
            _TerminalOverflowAction.copyAll,
            LucideIcons.copy300,
            tr('复制全部输出'),
            enabled: ui.hasOutput,
          ),
          _overflowItem(
            _TerminalOverflowAction.save,
            LucideIcons.save300,
            tr('保存输出'),
            enabled: ui.hasOutput,
          ),
          _overflowItem(
            _TerminalOverflowAction.paste,
            LucideIcons.clipboardList300,
            tr('粘贴'),
          ),
          _overflowItem(
            _TerminalOverflowAction.pickDir,
            LucideIcons.folderOpen300,
            tr('选择目录'),
            enabled: !(ui.isPreparingDirectory || ui.isRunning),
          ),
          if (Platform.isMacOS)
            _overflowItem(
              _TerminalOverflowAction.fullDiskAccess,
              LucideIcons.shield300,
              tr('完全磁盘访问'),
            ),
          _overflowItem(
            _TerminalOverflowAction.linkMatchers,
            LucideIcons.link300,
            tr('自定义链接规则'),
          ),
          const PopupMenuDivider(),
          _overflowItem(
            _TerminalOverflowAction.zoomIn,
            LucideIcons.zoomIn300,
            tr('放大字号'),
          ),
          _overflowItem(
            _TerminalOverflowAction.zoomOut,
            LucideIcons.zoomOut300,
            tr('缩小字号'),
          ),
          _overflowItem(
            _TerminalOverflowAction.zoomReset,
            LucideIcons.refreshCw300,
            tr2('重置字号 ({0}%)', [(widget.fontScale * 100).round()]),
          ),
          const PopupMenuDivider(),
          _overflowItem(
            _TerminalOverflowAction.clear,
            LucideIcons.eraser300,
            tr('清空'),
          ),
          _overflowItem(
            _TerminalOverflowAction.reset,
            LucideIcons.rotateCcw300,
            tr('重置会话'),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<_TerminalOverflowAction> _overflowItem(
    _TerminalOverflowAction action,
    IconData icon,
    String label, {
    bool enabled = true,
  }) {
    final color = enabled ? AppTheme.headingColor : AppTheme.subtleTextColor;
    return PopupMenuItem<_TerminalOverflowAction>(
      value: action,
      enabled: enabled,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 13, color: color)),
        ],
      ),
    );
  }

  void _handleOverflowAction(_TerminalOverflowAction action) {
    switch (action) {
      case _TerminalOverflowAction.copyAll:
        unawaited(_copyAllOutput());
      case _TerminalOverflowAction.save:
        unawaited(_saveOutputToFile());
      case _TerminalOverflowAction.paste:
        unawaited(_pasteClipboard());
      case _TerminalOverflowAction.pickDir:
        unawaited(_pickWorkingDirectory());
      case _TerminalOverflowAction.fullDiskAccess:
        unawaited(_openFullDiskAccessSettings());
      case _TerminalOverflowAction.linkMatchers:
        unawaited(showLinkMatcherManager(context));
      case _TerminalOverflowAction.clear:
        _clearLines();
      case _TerminalOverflowAction.reset:
        _resetSession();
      case _TerminalOverflowAction.zoomIn:
        widget.onZoomIn();
      case _TerminalOverflowAction.zoomOut:
        widget.onZoomOut();
      case _TerminalOverflowAction.zoomReset:
        widget.onZoomReset();
      case _TerminalOverflowAction.splitHorizontal:
        widget.onSplitHorizontal?.call();
      case _TerminalOverflowAction.splitVertical:
        widget.onSplitVertical?.call();
      case _TerminalOverflowAction.closePane:
        unawaited(_confirmClosePane());
      case _TerminalOverflowAction.highlight:
        unawaited(showHighlightManager(context));
      case _TerminalOverflowAction.theme:
        unawaited(_showThemeMenu(_overflowMenuAnchor()));
      case _TerminalOverflowAction.broadcast:
        widget.onToggleBroadcast?.call();
      case _TerminalOverflowAction.syncScroll:
        widget.onToggleSyncScroll?.call();
      case _TerminalOverflowAction.sessionLog:
        unawaited(_toggleSessionLog());
      case _TerminalOverflowAction.minimizePane:
        widget.onMinimizePane?.call();
      case _TerminalOverflowAction.minimap:
        setState(() => _minimapVisible = !_minimapVisible);
      case _TerminalOverflowAction.detailsPanel:
        _toggleDetailsPanel();
    }
  }

  /// 「更多」按钮左下角的全局坐标,用作二级菜单(配色方案)的锚点
  Offset _overflowMenuAnchor() {
    final box =
        _overflowBtnKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    return box.localToGlobal(box.size.bottomLeft(Offset.zero));
  }

  Future<void> _confirmClosePane() async {
    final onClose = widget.onClosePane;
    if (onClose == null) return;
    final confirmed = await _showCloseTerminalConfirm(
      context,
      title: widget.title,
      running: _isRunning,
    );
    if (!mounted || !confirmed) return;
    onClose();
  }

  Widget _buildFooterBar(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final ui = ref.watch(terminalUiControllerProvider(widget.sessionId));
        final chips = _footerChips(ui);
        return Container(
          decoration: BoxDecoration(
            color: AppTheme.subtleSurfaceColor.withValues(alpha: 0.4),
            border: Border(top: BorderSide(color: AppTheme.borderColor)),
          ),
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showHints = constraints.maxWidth > 400;
              return Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      reverse: false,
                      child: Row(children: chips),
                    ),
                  ),
                  if (showHints) ...[
                    const SizedBox(width: 10),
                    Text(
                      tr('⌘F 搜索   ⌃R 历史   ⌃C 停止   ⌃D EOF   ⌘± 缩放'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }

  List<Widget> _footerChips(TerminalUiState ui) {
    final entries = <Widget>[
      _TerminalFooterChip(
        label: ui.backendLabel,
        tone: _FooterChipTone.neutral,
      ),
      if (widget.remoteCommand != null)
        _TerminalFooterChip(
          label: ui.isRunning ? tr('SSH · 已连接') : tr('SSH · 未连接'),
          tone: ui.isRunning ? _FooterChipTone.active : _FooterChipTone.warning,
        ),
      if (ui.isRunning)
        _TerminalFooterChip(
          label: '运行中 · ${_ellipsize(ui.runningCommand ?? '', 22)}',
          tone: _FooterChipTone.active,
        ),
      if (ui.isAltBufferActive)
        _TerminalFooterChip(label: 'Alt Buffer', tone: _FooterChipTone.active),
      if (ui.bracketedPasteMode)
        _TerminalFooterChip(label: tr('括号粘贴'), tone: _FooterChipTone.neutral),
      if (!ui.autoWrapMode)
        _TerminalFooterChip(label: tr('禁止折行'), tone: _FooterChipTone.neutral),
      if (!ui.showCursor)
        _TerminalFooterChip(label: tr('隐藏光标'), tone: _FooterChipTone.neutral),
      if (!ui.autoFollowOutput)
        _TerminalFooterChip(label: tr('滚动暂停'), tone: _FooterChipTone.warning),
      if (widget.fontScale != 1.0)
        _TerminalFooterChip(
          label: '${(widget.fontScale * 100).round()}%',
          tone: _FooterChipTone.neutral,
        ),
    ];
    final spaced = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      if (i > 0) spaced.add(const SizedBox(width: 6));
      spaced.add(entries[i]);
    }
    return spaced;
  }

  String _ellipsize(String value, int maxLength) {
    final trimmed = value.trim();
    if (trimmed.length <= maxLength) return trimmed;
    return '${trimmed.substring(0, maxLength - 1)}…';
  }

  // ── 格子级文本选择:真终端语义(按到哪个格子就从哪个格子选起)。
  // 之前用 SelectionArea,其光标制取整会把「按在字形中后段」的首字
  // 取整掉(Menlo 下按到字形 ~70% 处即丢),粘贴总少第一个字。──

  /// 输出区坐标 → (行,列)。行用 hitTest 命中行标记(行高可变也精确),
  /// 列按该行内容与渲染模式逐字累积换算。
  ({int row, int col})? _cellAtGlobal(
    Offset globalPosition,
    _TerminalCellMetrics metrics,
  ) {
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      globalPosition,
      View.of(context).viewId,
    );
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is _TerminalRowTag) {
        final row = (target.metaData as _TerminalRowTag).index;
        if (row < 0 || row >= _lines.length) return null;
        final local = target.globalToLocal(globalPosition);
        // 行 Container 有 horizontal:2 padding
        final col = _columnAtLineX(_lines[row], local.dx - 2, metrics);
        return (row: row, col: col);
      }
    }
    return null;
  }

  /// 行内 x → 列:按渲染布局逐 rune 累积(proportional 用 wideCellWidth,
  /// 网格模式宽字 = 2×cellWidth);字形内任意落点都归属该格(格子语义)。
  int _columnAtLineX(
    TerminalLine line,
    double x,
    _TerminalCellMetrics metrics,
  ) {
    if (x <= 0) return 0;
    final proportional = !_isAltBufferActive && !_isNativePtyActive;
    final wide = proportional ? metrics.wideCellWidth : metrics.cellWidth * 2;
    var px = 0.0;
    var col = 0;
    for (final rune in line.text.runes) {
      final w = terminalRuneCellWidth(rune);
      if (w == 0) continue;
      final advance = w == 2 ? wide : metrics.cellWidth;
      if (x < px + advance) return col;
      px += advance;
      col += w;
    }
    // 行尾右侧按网格延伸
    return col + math.max(0, ((x - px) / metrics.cellWidth).floor());
  }

  /// 规范化选区:起止都含入,(row,col) 字典序
  ({int startRow, int startCol, int endRow, int endCol})?
  get _normalizedGridSelection {
    final a = _gridSelAnchor;
    final f = _gridSelFocus;
    if (a == null || f == null) return null;
    final aFirst = a.row < f.row || (a.row == f.row && a.col <= f.col);
    final start = aFirst ? a : f;
    final end = aFirst ? f : a;
    return (
      startRow: start.row,
      startCol: start.col,
      endRow: end.row,
      endCol: end.col,
    );
  }

  Offset? _gridSelDownPos;
  ({int row, int col})? _gridSelPendingCell;
  bool _gridSelDragging = false;

  void _handleOutputPointerDown(
    PointerDownEvent event,
    _TerminalCellMetrics metrics,
  ) {
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryMouseButton) {
      return;
    }
    // 远端程序接管鼠标(vim 等)时选择让位,与真终端一致
    if (_isMouseReportingActive) return;
    _gridSelDownPos = event.position;
    _gridSelDragging = false;
    _gridSelPendingCell = _cellAtGlobal(event.position, metrics);
    // 按下即清掉旧选区(标准行为:新的点击/拖选替换旧选择)
    if (_hasGridSelection) setState(_clearGridSelection);
  }

  void _handleOutputPointerMove(
    PointerMoveEvent event,
    _TerminalCellMetrics metrics,
  ) {
    final down = _gridSelDownPos;
    if (down == null) return;
    if (!_gridSelDragging) {
      if ((event.position - down).distance <= 4) return;
      _gridSelDragging = true;
    }
    final cell = _cellAtGlobal(event.position, metrics);
    if (cell == null) return;
    setState(() {
      _gridSelAnchor ??= _gridSelPendingCell ?? cell;
      _gridSelFocus = cell;
    });
  }

  void _handleOutputPointerUp() {
    _gridSelDownPos = null;
    _gridSelPendingCell = null;
    _gridSelDragging = false;
  }

  /// 选区文本:软折行(isWrapped)的行无缝拼回逻辑行,硬换行加 \n;
  /// 选到行尾时去掉尾随空格(BCE 填充不进剪贴板)
  String _gridSelectionText() {
    final sel = _normalizedGridSelection;
    if (sel == null) return '';
    final buffer = StringBuffer();
    for (var row = sel.startRow; row <= sel.endRow; row++) {
      if (row < 0 || row >= _lines.length) continue;
      final line = _lines[row];
      if (line.image == null) {
        final startCell = row == sel.startRow ? sel.startCol : 0;
        final endCell = row == sel.endRow ? sel.endCol + 1 : line.length;
        var text = terminalSubstringByCellRange(
          line.text,
          startCell,
          math.max(startCell, math.min(endCell, line.length)),
        );
        if (endCell >= line.length) text = text.trimRight();
        buffer.write(text);
      }
      if (row < sel.endRow) {
        final nextWrapped =
            row + 1 < _lines.length && _lines[row + 1].isWrapped;
        if (!nextWrapped) buffer.write('\n');
      }
    }
    return buffer.toString();
  }

  Future<void> _copyGridSelection() async {
    final text = _gridSelectionText();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// 该行落在选区内的 [起始列, 结束列) 高亮区间
  (int, int)? _gridSelectionRangeForRow(int row) {
    final sel = _normalizedGridSelection;
    if (sel == null || row < sel.startRow || row > sel.endRow) return null;
    final start = row == sel.startRow ? sel.startCol : 0;
    final end = row == sel.endRow ? sel.endCol + 1 : 1 << 20;
    return (start, end);
  }

  /// ⌃R 全局历史搜索:跨会话查找命令,选中填入输入框
  Future<void> _showHistorySearchDialog() async {
    final selected = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => const _HistorySearchDialog(),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    _inputController.text = selected;
    _inputController.selection = TextSelection.collapsed(
      offset: selected.length,
    );
    _restoreInputFocus();
  }

  Future<void> _showGridSelectionMenu(Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      color: AppTheme.surfaceColor,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'copy', height: 34, child: Text('复制')),
        PopupMenuItem(value: 'clear', height: 34, child: Text('取消选择')),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copy':
        unawaited(_copyGridSelection());
      case 'clear':
        setState(_clearGridSelection);
    }
  }

  Widget _buildTerminalOutput(TextStyle monoStyle) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = _TerminalCellMetrics.fromStyle(monoStyle);
        _syncPtySizeForViewport(constraints, metrics);
        // 点击输出区任意处都把焦点还给命令输入(Listener 不进竞技场,
        // pointer-up 必达);同一个 Listener 承载格子选择的按下/拖动。
        // 注:不加 _externalWidgetHasFocus 守卫 —— 那是防「自动回抢」用的;
        // 用户主动点输出区就是要用终端,即便地址栏/搜索框正持焦点也应转移。
        // 详情面板是 Stack 兄弟层且悬浮在上,它的点击不会冒泡到这里。
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) => _handleOutputPointerDown(event, metrics),
          onPointerMove: (event) => _handleOutputPointerMove(event, metrics),
          onPointerUp: (_) {
            if (!mounted) return;
            _handleOutputPointerUp();
            _activeInputNode.requestFocus();
          },
          onPointerCancel: (_) => _handleOutputPointerUp(),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // 有选区时右键弹「复制/取消选择」;提示符行自身的命令菜单
            // 在更内层,竞技场里优先命中,互不冲突
            onSecondaryTapUp: _hasGridSelection
                ? (details) =>
                      unawaited(_showGridSelectionMenu(details.globalPosition))
                : null,
            child: ValueListenableBuilder<int>(
              valueListenable: _terminalOutputVersion,
              builder: (context, version, child) {
                return ColoredBox(
                  // 应用经 OSC 11 设置的终端背景色(vim 主题等);之前只存不画
                  color:
                      _dynamicBackgroundColor ??
                      _themeBackground ??
                      Colors.transparent,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _buildOutputScrollView(monoStyle, metrics),
                      ),
                      // overview minimap:全缓冲区缩略图 + 视口框,点击/拖拽定位
                      if (_minimapVisible)
                        Positioned(
                          top: 0,
                          bottom: 0,
                          right: 0,
                          width: 56,
                          child: _buildMinimap(),
                        ),
                      // 搜索时右侧滚动条标记:一眼看命中分布,点击跳转
                      // (minimap 开时让到 minimap 左侧)
                      if (_isSearchVisible && _searchMatches.isNotEmpty)
                        Positioned(
                          top: 0,
                          bottom: 0,
                          right: _minimapVisible ? 58 : 0,
                          width: 12,
                          child: _buildSearchRuler(),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildOutputScrollView(
    TextStyle monoStyle,
    _TerminalCellMetrics metrics,
  ) {
    // 输出折叠(OSC 133 命令块):一次线性扫描算出每行是否被折叠隐藏,
    // itemBuilder 里 O(1) 查。顺带把已被裁剪掉的行从折叠集里清理。
    final folded = _computeFoldedHidden();
    return CustomScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          sliver: SliverList.builder(
            itemCount: _lines.length,
            itemBuilder: (context, index) {
              final rawLine = _lines[index];
              if (folded != null && folded[index]) {
                return const SizedBox.shrink();
              }
              // 内联图片行(Sixel / iTerm2):渲染图片,不走文本路径
              if (rawLine.image != null) {
                return MetaData(
                  metaData: _TerminalRowTag(index),
                  behavior: HitTestBehavior.translucent,
                  child: _wrapTerminalMouseLine(
                    rowIndex: index,
                    metrics: metrics,
                    child: _buildInlineImage(rawLine.image!),
                  ),
                );
              }
              // 触发器高亮:非全屏(alt buffer)时把命中规则的文本上色。
              // 全屏 TUI(vim/htop)保留其自身配色,避免打架。
              final line = _isAltBufferActive
                  ? rawLine
                  : HighlightStore.apply(rawLine, HighlightStore.rules.value);
              final isSearchMatch = _searchMatchSet.contains(index);
              final isActiveSearchMatch =
                  isSearchMatch &&
                  _activeSearchMatch >= 0 &&
                  _activeSearchMatch < _searchMatches.length &&
                  _searchMatches[_activeSearchMatch] == index;
              // Shell 集成(OSC 133):提示符行左侧一道状态色竖条
              // (无退出码=品牌色,0=绿,非0=红)
              final promptBorder = rawLine.isPromptStart
                  ? BorderSide(
                      color: rawLine.commandExitCode == null
                          ? AppTheme.brandColor.withValues(alpha: 0.7)
                          : rawLine.commandExitCode == 0
                          ? AppTheme.successColor
                          : AppTheme.errorColor,
                      width: 2.5,
                    )
                  : BorderSide.none;
              final lineWidget = Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: isActiveSearchMatch
                      ? AppTheme.brandColor.withValues(alpha: 0.14)
                      : isSearchMatch
                      ? AppTheme.warningColor.withValues(alpha: 0.12)
                      : null,
                  border: Border(left: promptBorder),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: _TerminalOutputText(
                  line: line,
                  monoStyle: monoStyle,
                  metrics: metrics,
                  columns: _ptyColumns,
                  cursorColumn:
                      _isNativePtyActive && _showCursor && index == _cursorY
                      ? _visibleCursorColumn
                      : null,
                  cursorShape: _cursorShape,
                  cursorColor:
                      _dynamicCursorColor ??
                      _themeCursor ??
                      AppTheme.brandColor,
                  // 实心块状光标反显字符用终端背景色
                  cursorGlyphColor:
                      _dynamicBackgroundColor ??
                      _themeBackground ??
                      AppTheme.surfaceColor,
                  colorForLine: _colorForLine,
                  textStyleForSpan: _textStyleForSpan,
                  trimLinkText: _trimTerminalLinkText,
                  onOpenLink: (url) => unawaited(_openTerminalLink(url)),
                  // pty 活着(SSH / 交互式 shell)= 远端按网格
                  // 寻址,用严格网格才能对齐、不与 shell 折行打架;
                  // 比例渲染 + 组件折行只留给退出后的静态历史输出。
                  proportional: !_isAltBufferActive && !_isNativePtyActive,
                  selection: _gridSelectionRangeForRow(index),
                  selectionColor: AppTheme.brandColor.withValues(alpha: 0.28),
                ),
              );
              // 提示符行(Shell 集成):右键菜单;折叠时在其下方挂占位条
              Widget wrapped = lineWidget;
              if (rawLine.isPromptStart) {
                final isFolded = _foldedPrompts.contains(rawLine);
                wrapped = GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapUp: (d) =>
                      unawaited(_showCommandMenu(index, d.globalPosition)),
                  child: isFolded
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [lineWidget, _buildFoldPlaceholder(index)],
                        )
                      : lineWidget,
                );
              }
              return MetaData(
                metaData: _TerminalRowTag(index),
                behavior: HitTestBehavior.translucent,
                child: _wrapTerminalMouseLine(
                  rowIndex: index,
                  metrics: metrics,
                  child: wrapped,
                ),
              );
            },
          ),
        ),
        // The interactive input line lives in its own sliver so it
        // renders inline right after the output (scrolls with it),
        // yet output growth never re-indexes/reparents it — which is
        // what previously detached the focus node and dropped focus.
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _buildInteractiveTerminalLine(monoStyle),
          ),
        ),
      ],
    );
  }

  Widget _wrapTerminalMouseLine({
    required int rowIndex,
    required _TerminalCellMetrics metrics,
    required Widget child,
  }) {
    if (!_isNativePtyActive) return child;
    if (!_isMouseReportingActive &&
        (!_isAltBufferActive || !_alternateScrollMode)) {
      return child;
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _isMouseReportingActive
          ? (event) => _handleTerminalPointerDown(event, rowIndex, metrics)
          : null,
      onPointerUp: _isMouseReportingActive
          ? (event) => _handleTerminalPointerUp(event, rowIndex, metrics)
          : null,
      onPointerMove: _isMouseReportingActive
          ? (event) => _handleTerminalPointerMove(event, rowIndex, metrics)
          : null,
      onPointerSignal: (event) =>
          _handleTerminalPointerSignal(event, rowIndex, metrics),
      child: child,
    );
  }

  bool get _isMouseReportingActive {
    return _isNativePtyActive && _mouseTrackingMode != 0;
  }

  void _handleNativePtyFocusChange(bool hasFocus) {
    if (!_isNativePtyActive || !_focusReportingMode) return;
    _sendRawInputToProcess(hasFocus ? '\x1b[I' : '\x1b[O');
  }

  void _handleTerminalPointerDown(
    PointerDownEvent event,
    int rowIndex,
    _TerminalCellMetrics metrics,
  ) {
    final buttonCode = _mouseButtonCodeForButtons(event.buttons);
    _mouseButtonDown = true;
    _lastMouseButtonCode = buttonCode;
    _sendTerminalMouseEvent(
      buttonCode: buttonCode,
      localPosition: event.localPosition,
      rowIndex: rowIndex,
      metrics: metrics,
    );
  }

  void _handleTerminalPointerUp(
    PointerUpEvent event,
    int rowIndex,
    _TerminalCellMetrics metrics,
  ) {
    if (_mouseTrackingMode != 9) {
      _sendTerminalMouseEvent(
        buttonCode: _lastMouseButtonCode,
        localPosition: event.localPosition,
        rowIndex: rowIndex,
        metrics: metrics,
        release: true,
      );
    }
    _mouseButtonDown = false;
  }

  void _handleTerminalPointerMove(
    PointerMoveEvent event,
    int rowIndex,
    _TerminalCellMetrics metrics,
  ) {
    if (_mouseTrackingMode == 9) return;
    if (_mouseTrackingMode == 1000) return;
    if (_mouseTrackingMode == 1002 && !_mouseButtonDown) return;
    _sendTerminalMouseEvent(
      buttonCode: _mouseButtonDown ? _lastMouseButtonCode : 0,
      localPosition: event.localPosition,
      rowIndex: rowIndex,
      metrics: metrics,
      motion: true,
    );
  }

  void _handleTerminalPointerSignal(
    PointerSignalEvent event,
    int rowIndex,
    _TerminalCellMetrics metrics,
  ) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy == 0) return;
    if (!_isMouseReportingActive &&
        (!_isAltBufferActive || !_alternateScrollMode)) {
      return;
    }
    // The wheel belongs to the remote program here, so the event has to be
    // claimed on the pointerSignalResolver. A bare onPointerSignal callback
    // does not consume it: the enclosing Scrollable still scrolls the local
    // viewport, _handleScrollChanged then latches _autoFollowOutput off, and
    // from that point vim's last row (the ':' command line) stays parked
    // outside the visible area.
    GestureBinding.instance.pointerSignalResolver.register(event, (claimed) {
      final scroll = claimed as PointerScrollEvent;
      if (_isMouseReportingActive) {
        _sendTerminalMouseEvent(
          buttonCode: scroll.scrollDelta.dy < 0 ? 64 : 65,
          localPosition: scroll.localPosition,
          rowIndex: rowIndex,
          metrics: metrics,
        );
        return;
      }
      final steps = math.max(
        1,
        math.min(6, (scroll.scrollDelta.dy.abs() / 40).ceil()),
      );
      final sequence = scroll.scrollDelta.dy < 0
          ? _inputEncoder.cursorSequence('A', 1)
          : _inputEncoder.cursorSequence('B', 1);
      _sendRawInputToProcess(sequence * steps);
    });
  }

  int _mouseButtonCodeForButtons(int buttons) {
    if (buttons & kMiddleMouseButton != 0) return 1;
    if (buttons & kSecondaryMouseButton != 0) return 2;
    return 0;
  }

  void _sendTerminalMouseEvent({
    required int buttonCode,
    required Offset localPosition,
    required int rowIndex,
    required _TerminalCellMetrics metrics,
    bool release = false,
    bool motion = false,
  }) {
    if (!_isMouseReportingActive) return;
    var code = buttonCode;
    if (motion) code += 32;
    if (HardwareKeyboard.instance.isShiftPressed) code += 4;
    if (HardwareKeyboard.instance.isAltPressed) code += 8;
    if (HardwareKeyboard.instance.isControlPressed) code += 16;
    final column = _terminalMouseColumn(localPosition, metrics);
    final row = math.max(1, math.min(_ptyRows, rowIndex + 1));
    if (motion && column == _lastMouseColumn && row == _lastMouseRow) {
      return;
    }
    _lastMouseColumn = column;
    _lastMouseRow = row;

    final releaseCode = release ? 3 : code;
    final pixelPosition = _terminalMousePixelPosition(
      localPosition,
      rowIndex,
      metrics,
    );
    final sequence = _sgrPixelMouseMode
        ? '\x1b[<$code;${pixelPosition.$1};${pixelPosition.$2}${release ? 'm' : 'M'}'
        : _sgrMouseMode
        ? '\x1b[<$code;$column;$row${release ? 'm' : 'M'}'
        : _urxvtMouseMode
        ? TerminalInputEncoder.urxvtMouseSequence(
            code: releaseCode,
            column: column,
            row: row,
          )
        : _utf8MouseMode
        ? TerminalInputEncoder.utf8MouseSequence(
            code: releaseCode,
            column: column,
            row: row,
          )
        : TerminalInputEncoder.legacyMouseSequence(
            code: releaseCode,
            column: column,
            row: row,
          );
    if (sequence == null) return;
    unawaited(_writeNativePtyInput(sequence));
  }

  int _terminalMouseColumn(Offset position, _TerminalCellMetrics metrics) {
    final column =
        ((math.max(0, position.dx - 2) / metrics.cellWidth).floor() + 1);
    return math.max(1, math.min(_ptyColumns, column));
  }

  (int, int) _terminalMousePixelPosition(
    Offset position,
    int rowIndex,
    _TerminalCellMetrics metrics,
  ) {
    final maxX = math.max(1, (_ptyColumns * metrics.cellWidth).round());
    final maxY = math.max(1, (_ptyRows * metrics.lineHeight).round());
    final x = (math.max(0.0, position.dx).round() + 1).clamp(1, maxX);
    final y =
        (math.max(0.0, rowIndex * metrics.lineHeight + position.dy).round() + 1)
            .clamp(1, maxY);
    return (x, y);
  }

  /// 搜索命中滚动条标记(对标 xterm SearchAddon decorations):
  /// 右侧细条上按行占比画出每个命中,当前命中高亮;点击跳到最近命中。
  Widget _buildSearchRuler() {
    final total = math.max(1, _lines.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            final ratio = (d.localPosition.dy / constraints.maxHeight).clamp(
              0.0,
              1.0,
            );
            final targetLine = (ratio * (total - 1)).round();
            // 找离点击位置最近的命中,设为当前并跳转
            var best = 0;
            var bestDist = 1 << 30;
            for (var i = 0; i < _searchMatches.length; i++) {
              final dist = (_searchMatches[i] - targetLine).abs();
              if (dist < bestDist) {
                bestDist = dist;
                best = i;
              }
            }
            setState(() => _activeSearchMatch = best);
            _notifyTerminalOutputChanged();
            _scrollToSearchMatch(_searchMatches[best]);
          },
          child: CustomPaint(
            painter: _SearchRulerPainter(
              matches: _searchMatches,
              activeIndex: _activeSearchMatch,
              totalLines: total,
              matchColor: AppTheme.warningColor.withValues(alpha: 0.7),
              activeColor: AppTheme.brandColor,
              trackColor: AppTheme.borderColor.withValues(alpha: 0.35),
            ),
          ),
        );
      },
    );
  }

  /// overview minimap:整缓冲区缩略图(每行一道墨迹条,命令边界/搜索命中
  /// 上色)+ 视口框;点击或拖拽快速定位到对应位置。
  Widget _buildMinimap() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        void jump(double dy) {
          if (!_scrollController.hasClients) return;
          final ratio = (dy / height).clamp(0.0, 1.0);
          final p = _scrollController.position;
          _autoFollowOutput = false;
          _publishUiState();
          _scrollController.jumpTo(
            (p.maxScrollExtent * ratio).clamp(
              p.minScrollExtent,
              p.maxScrollExtent,
            ),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => jump(d.localPosition.dy),
          onVerticalDragUpdate: (d) => jump(d.localPosition.dy),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppTheme.backgroundColor.withValues(alpha: 0.35),
              border: Border(left: BorderSide(color: AppTheme.borderColor)),
            ),
            child: CustomPaint(
              size: Size.infinite,
              painter: _MinimapPainter(
                lines: _lines,
                scroll: _scrollController.hasClients
                    ? _scrollController.position
                    : null,
                searchMatches: _searchMatchSet,
                inkColor: AppTheme.subtleTextColor.withValues(alpha: 0.5),
                matchColor: AppTheme.warningColor,
                successColor: AppTheme.successColor,
                errorColor: AppTheme.errorColor,
                promptColor: AppTheme.brandColor,
                viewportColor: AppTheme.brandColor.withValues(alpha: 0.16),
                viewportBorder: AppTheme.brandColor.withValues(alpha: 0.5),
                repaint: Listenable.merge([
                  _terminalOutputVersion,
                  _scrollController,
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 折叠命令块的占位条:显示折叠行数,点击展开。
  Widget _buildFoldPlaceholder(int promptLine) {
    final count = _foldedLineCount(promptLine);
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _toggleFold(promptLine),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.subtleSurfaceColor.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: AppTheme.borderColor.withValues(alpha: 0.7),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.chevronsUpDown300,
                size: 11,
                color: AppTheme.subtleTextColor,
              ),
              const SizedBox(width: 5),
              Text(
                tr2('已折叠 {0} 行输出 — 点击展开', [count]),
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppTheme.subtleTextColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 内联图片渲染:限定最大宽/高,保持比例;解码失败显示占位。
  Widget _buildInlineImage(TerminalImage image) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 480),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.memory(
              image.bytes,
              filterQuality: FilterQuality.medium,
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              errorBuilder: (context, error, stack) => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                color: AppTheme.subtleSurfaceColor.withValues(alpha: 0.5),
                child: Text(
                  tr('⚠ 图片解码失败'),
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 搜索栏里的一个文字开关(Aa / W / .*),激活时高亮。
  Widget _searchToggle(
    String label,
    bool active,
    String tooltip,
    VoidCallback onTap,
  ) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: Material(
        color: active
            ? AppTheme.brandColor.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: AppTheme.subtleSurfaceColor.withValues(alpha: 0.8),
          onTap: onTap,
          child: SizedBox(
            width: 26,
            height: 22,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active
                      ? AppTheme.brandColor
                      : AppTheme.subtleTextColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar(TextStyle monoStyle) {
    return Consumer(
      builder: (context, ref, _) {
        final ui = ref.watch(terminalUiControllerProvider(widget.sessionId));
        final count = ui.searchMatchCount;
        return Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor,
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Icon(
                LucideIcons.search300,
                size: 15,
                color: AppTheme.subtleTextColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  minLines: 1,
                  maxLines: 1,
                  style: monoStyle.copyWith(
                    color: _searchError
                        ? AppTheme.errorColor
                        : AppTheme.headingColor,
                  ),
                  cursorColor: AppTheme.brandColor,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: _searchRegex ? tr('搜索输出(正则)') : tr('搜索输出'),
                    hintStyle: monoStyle.copyWith(
                      color: AppTheme.subtleTextColor,
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: _setSearchQuery,
                  onSubmitted: (_) => _moveSearchMatch(1),
                ),
              ),
              const SizedBox(width: 6),
              // 选项开关:区分大小写 / 全词 / 正则(对标 xterm SearchAddon)
              _searchToggle(
                'Aa',
                _searchCaseSensitive,
                tr('区分大小写'),
                () => _toggleSearchOption(
                  () => _searchCaseSensitive = !_searchCaseSensitive,
                ),
              ),
              const SizedBox(width: 4),
              _searchToggle(
                'W',
                _searchWholeWord,
                tr('全词匹配'),
                () => _toggleSearchOption(
                  () => _searchWholeWord = !_searchWholeWord,
                ),
              ),
              const SizedBox(width: 4),
              _searchToggle(
                '.*',
                _searchRegex,
                tr('正则表达式'),
                () => _toggleSearchOption(() => _searchRegex = !_searchRegex),
              ),
              const SizedBox(width: 10),
              Text(
                _searchError ? tr('正则错误') : ui.searchOrdinalLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: _searchError
                      ? AppTheme.errorColor
                      : AppTheme.subtleTextColor,
                ),
              ),
              const SizedBox(width: 8),
              _TerminalIconButton(
                tooltip: tr('上一个'),
                icon: LucideIcons.chevronUp300,
                onPressed: count == 0 ? null : () => _moveSearchMatch(-1),
              ),
              const SizedBox(width: 6),
              _TerminalIconButton(
                tooltip: tr('下一个'),
                icon: LucideIcons.chevronDown300,
                onPressed: count == 0 ? null : () => _moveSearchMatch(1),
              ),
              const SizedBox(width: 6),
              _TerminalIconButton(
                tooltip: tr('关闭搜索'),
                icon: LucideIcons.x300,
                onPressed: _hideSearch,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInteractiveTerminalLine(TextStyle monoStyle) {
    if (_isNativePtyActive) {
      return Focus(
        focusNode: _ptyFocusNode,
        autofocus: widget.isActive,
        onFocusChange: _handleNativePtyFocusChange,
        child: const SizedBox.shrink(),
      );
    }
    return Container(
      key: _interactiveLineKey,
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 3),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Row(
        // 顶部对齐:多行输入时提示符锚在第一行,不会被居中顶到中间、
        // 把第一行输入挤到提示符上方
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_isRunning)
            Padding(
              // 与 TextField 首行文本基线对齐(isDense 顶部内边距很小)
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                '${_promptText()} ',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: monoStyle.copyWith(
                  color: AppTheme.brandColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Expanded(
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.tab):
                    _handleTabPressed,
                // 多行输入框里 Enter 不再自动提交,这里接管;
                // Shift+Enter 不拦截,落回编辑器插入换行
                const SingleActivator(LogicalKeyboardKey.enter): _submitInput,
                const SingleActivator(LogicalKeyboardKey.numpadEnter):
                    _submitInput,
              },
              child: CompositedTransformTarget(
                link: _historyLink,
                child: TextField(
                  controller: _inputController,
                  focusNode: _inputFocusNode,
                  autofocus: widget.isActive,
                  enabled: true,
                  minLines: 1,
                  // 命令行支持多行(粘贴脚本/Shift+Enter 换行);够高再滚动,
                  // 减少"没几行就出滚动条"的局促
                  maxLines: 12,
                  style: monoStyle.copyWith(color: AppTheme.headingColor),
                  cursorColor: AppTheme.brandColor,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: _isRunning
                        ? tr('发送到进程 stdin，Ctrl+C 停止，Ctrl+D 结束输入')
                        : null,
                    hintStyle: monoStyle.copyWith(
                      color: AppTheme.subtleTextColor,
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: _onInputChanged,
                  onSubmitted: _runCommand,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _colorForLine(TerminalLineType type) {
    switch (type) {
      case TerminalLineType.prompt:
        return AppTheme.brandColor;
      case TerminalLineType.stderr:
        return AppTheme.errorColor;
      case TerminalLineType.system:
        return AppTheme.subtleTextColor;
      case TerminalLineType.stdout:
        return AppTheme.headingColor;
    }
  }

  TextStyle _textStyleForSpan(
    TextStyle baseStyle,
    TerminalLineType type,
    TerminalSpan span,
  ) {
    final style = span.style;
    final defaultForeground = type == TerminalLineType.stdout
        ? _dynamicForegroundColor ?? _themeForeground ?? _colorForLine(type)
        : _colorForLine(type);
    final foreground = style.foreground ?? defaultForeground;
    final background = style.background;
    // 反显(SGR 7)无显式色时:前景回退到终端默认背景色,背景用默认前景。
    // 之前前景错误回退到 headingColor(深色),与同为深色的背景叠成
    // 黑底黑字 —— zsh/bash 括号粘贴的高亮就踩在这上面。
    final defaultBackground =
        _dynamicBackgroundColor ?? _themeBackground ?? AppTheme.surfaceColor;
    final effectiveForeground = style.invisible
        ? (style.inverse ? foreground : background ?? defaultBackground)
        : style.inverse
        ? background ?? defaultBackground
        : foreground;
    final effectiveBackground = style.inverse ? foreground : background;
    final decorations = <TextDecoration>[
      if (style.underline) TextDecoration.underline,
      if (style.overline) TextDecoration.overline,
      if (style.strikethrough) TextDecoration.lineThrough,
    ];
    // 闪烁(SGR 5/6):相位为暗时把前景调到很淡,近乎隐去,形成闪烁。
    final blinkDimmed = style.blink && !_blinkPhaseOn;
    final foregroundAlpha = blinkDimmed
        ? 0.15
        : style.dim
        ? 0.62
        : 1.0;
    return baseStyle.copyWith(
      color: foregroundAlpha == 1.0
          ? effectiveForeground
          : effectiveForeground.withValues(alpha: foregroundAlpha),
      backgroundColor: effectiveBackground,
      fontWeight: style.bold ? FontWeight.w700 : baseStyle.fontWeight,
      fontStyle: style.italic ? FontStyle.italic : baseStyle.fontStyle,
      decoration: decorations.isEmpty
          ? null
          : TextDecoration.combine(decorations),
      decorationColor:
          style.decorationColor ??
          (style.dim
              ? effectiveForeground.withValues(alpha: 0.62)
              : effectiveForeground),
      decorationStyle: style.underlineStyle,
    );
  }

  String? get _monospaceFontFamily {
    // A real monospace font so ASCII fills each cell uniformly. The app font
    // (PingFang SC etc.) is proportional, which left narrow glyphs under-filling
    // their cells and made output look loosely spaced. CJK falls back below.
    if (Platform.isMacOS || Platform.isIOS) return 'Menlo';
    if (Platform.isWindows) return 'Consolas';
    if (Platform.isLinux) return 'DejaVu Sans Mono';
    return 'monospace';
  }

  List<String>? get _monospaceFontFamilyFallback {
    // Monospace fonts above lack CJK glyphs; fall back to the platform CJK font
    // so wide characters still render (their advance is measured separately).
    return <String>[
      ?AppTheme.appFontFamily,
      'PingFang SC',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'Noto Sans SC',
    ];
  }
}
