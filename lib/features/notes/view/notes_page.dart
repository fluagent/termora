import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:termora/app/shell/page_top_bar.dart';
import 'package:toastification/toastification.dart';

import 'package:termora/core/utils/file_picker_helper.dart';
import 'package:termora/core/widgets/app_toast.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/notes/controller/notes_providers.dart';
import 'package:termora/features/notes/data/note_asset_store.dart';
import 'package:termora/features/notes/data/note_pdf_exporter.dart';
import 'package:termora/features/notes/data/note_store.dart';
import 'package:termora/features/notes/domain/markdown_editing.dart';
import 'package:termora/features/notes/domain/markdown_html_export.dart';
import 'package:termora/features/notes/domain/markdown_outline.dart';
import 'package:termora/features/notes/domain/note.dart';
import 'package:termora/features/notes/domain/mermaid/mermaid_parser.dart';
import 'package:termora/features/notes/domain/note_find.dart';
import 'package:termora/features/notes/view/widgets/block_editor.dart';
import 'package:termora/features/notes/view/widgets/editor_decorations.dart';
import 'package:termora/features/notes/view/widgets/editor_toolbar.dart';
import 'package:termora/features/notes/view/widgets/markdown_editing_controller.dart';
import 'package:termora/features/notes/view/widgets/markdown_preview.dart';
import 'package:termora/features/notes/view/widgets/mermaid_view.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 编辑视图模式。blocks 追加在末尾保证旧的持久化下标依然有效:
/// edit = 源码所见即所得;blocks = 块式自绘编辑(真表格/真图片);preview = 只读成品
enum NoteViewMode { edit, preview, blocks }

/// 屏蔽子树里 Scrollable 的内建滚动条(TextField 多行时 EditableText 会自绘一条,
/// 位于 contentPadding 内侧)。由外层 Scrollbar 统一贴编辑区最右侧绘制。
class _NoInnerScrollbarBehavior extends MaterialScrollBehavior {
  const _NoInnerScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// 笔记主页 — 左侧笔记列表,右侧 markdown 编辑/预览工作区
class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  final MarkdownEditingController _editorController =
      MarkdownEditingController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _editorFocus = FocusNode();
  final ScrollController _editorScroll = ScrollController();

  /// 用于向下找 EditableTextState,取选区在屏幕上的位置
  final GlobalKey _editorFieldKey = GlobalKey();

  /// 浮动格式工具栏(选中文字时浮现,marktext 式)
  OverlayEntry? _formatBar;
  double _barLeft = 0;
  double _barTop = 0;

  NoteViewMode _mode = NoteViewMode.edit;

  /// 大纲侧栏开关(持久化)
  bool _showOutline = false;

  /// 左侧笔记列表栏开关(持久化,⌘J 或按钮切换)
  bool _showSidebar = true;

  /// 聚焦模式:光标所在段落外淡化(持久化)
  bool _focusMode = false;

  /// 打字机模式:光标行始终滚动到编辑器纵向居中(持久化)
  bool _typewriter = false;

  // ── 查找/替换 ──
  bool _showFind = false;
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();
  final FocusNode _findFocus = FocusNode();
  List<TextRange> _findMatches = const [];
  int _activeMatch = -1;

  /// 编辑器当前展示的笔记(切换选中时同步文本)
  String? _editingNoteId;

  @override
  void initState() {
    super.initState();
    NoteStore.loadViewMode().then((mode) {
      if (mounted) {
        setState(
          () => _mode = NoteViewMode
              .values[mode.clamp(0, NoteViewMode.values.length - 1)],
        );
      }
    });
    NoteStore.loadShowOutline().then((show) {
      if (mounted && show) setState(() => _showOutline = show);
    });
    NoteStore.loadShowSidebar().then((show) {
      if (mounted && !show) setState(() => _showSidebar = show);
    });
    NoteStore.loadFocusMode().then((on) {
      if (mounted && on) {
        setState(() => _focusMode = on);
        _editorController.focusMode = on;
      }
    });
    NoteStore.loadTypewriter().then((on) {
      if (mounted && on) setState(() => _typewriter = on);
    });
    // controller 同时通知内容与选区变化,一个监听两件事都管
    _editorController.addListener(_onEdited);
    _editorFocus.addListener(_scheduleFormatBarUpdate);
    _editorScroll.addListener(_scheduleFormatBarUpdate);
  }

  @override
  void dispose() {
    _removeFormatBar();
    _editorController.removeListener(_onEdited);
    _editorController.dispose();
    _searchController.dispose();
    _findController.dispose();
    _replaceController.dispose();
    _findFocus.dispose();
    _editorFocus.dispose();
    _editorScroll.dispose();
    super.dispose();
  }

  void _onEdited() {
    _scheduleFormatBarUpdate();
    if (_typewriter && _editorFocus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _centerCaretLine();
      });
    }
    // 大纲需要跟随光标高亮当前章节;选区变化不经过 provider,手动刷新。
    // controller 通知可能落在 build 阶段,延到帧末再 setState。
    if (_showOutline) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    // 查找打开时,正文变化后重算命中(setHighlights 有等值守卫,不会循环)
    if (_showFind) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshFind());
    }
    final id = _editingNoteId;
    if (id == null) return;
    ref.read(notesProvider.notifier).updateContent(id, _editorController.text);
  }

  // ══════════════ 查找 / 替换 ══════════════

  void _openFind() {
    // 有选中文字则预填为查找词
    final sel = _editorController.selection;
    if (sel.isValid && !sel.isCollapsed) {
      _findController.text = _editorController.text.substring(
        sel.start,
        sel.end,
      );
    }
    setState(() => _showFind = true);
    _refreshFind(resetActive: true, reveal: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _findFocus.requestFocus();
    });
  }

  void _closeFind() {
    setState(() {
      _showFind = false;
      _findMatches = const [];
      _activeMatch = -1;
    });
    _editorController.setHighlights(const []);
    _editorFocus.requestFocus();
  }

  /// 重算命中并同步高亮。[resetActive] 从光标处重新定位活动命中;
  /// [reveal] 滚动到活动命中(仅显式动作时,避免打字途中抢滚动)。
  void _refreshFind({bool resetActive = false, bool reveal = false}) {
    if (!mounted || !_showFind) return;
    final matches = NoteFind.matches(
      _editorController.text,
      _findController.text,
    );
    int active;
    if (matches.isEmpty) {
      active = -1;
    } else if (resetActive ||
        _activeMatch < 0 ||
        _activeMatch >= matches.length) {
      final caret = _editorController.selection.isValid
          ? _editorController.selection.start
          : 0;
      active = NoteFind.activeIndexFor(matches, caret);
    } else {
      active = _activeMatch;
    }
    setState(() {
      _findMatches = matches;
      _activeMatch = active;
    });
    _editorController.setHighlights(matches, active: active);
    if (reveal) _revealActiveMatch();
  }

  void _stepMatch(int delta) {
    final total = _findMatches.length;
    if (total == 0) return;
    setState(() => _activeMatch = (_activeMatch + delta + total) % total);
    _editorController.setHighlights(_findMatches, active: _activeMatch);
    _revealActiveMatch();
  }

  void _revealActiveMatch() {
    if (_activeMatch < 0 || _activeMatch >= _findMatches.length) return;
    final offset = _findMatches[_activeMatch].start;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _findEditableTextState()?.bringIntoView(TextPosition(offset: offset));
    });
  }

  void _replaceActive() {
    if (_activeMatch < 0 || _activeMatch >= _findMatches.length) return;
    _editorController.value = NoteFind.replaceMatch(
      _editorController.value,
      _findMatches[_activeMatch],
      _replaceController.text,
    );
    _refreshFind(reveal: true);
  }

  void _replaceAllMatches() {
    final (value, count) = NoteFind.replaceAll(
      _editorController.value,
      _findController.text,
      _replaceController.text,
    );
    if (count == 0) return;
    _editorController.value = value;
    _refreshFind(resetActive: true);
    _toast(tr2('已替换 {0} 处', [count]));
  }

  void _toggleOutline() {
    setState(() => _showOutline = !_showOutline);
    NoteStore.saveShowOutline(_showOutline);
  }

  void _toggleSidebar() {
    setState(() => _showSidebar = !_showSidebar);
    NoteStore.saveShowSidebar(_showSidebar);
  }

  void _toggleFocusMode() {
    setState(() => _focusMode = !_focusMode);
    _editorController.focusMode = _focusMode;
    NoteStore.saveFocusMode(_focusMode);
  }

  void _toggleTypewriter() {
    setState(() => _typewriter = !_typewriter);
    NoteStore.saveTypewriter(_typewriter);
    if (_typewriter) _centerCaretLine();
  }

  /// 打字机模式:把光标行滚到编辑器视口纵向中央
  void _centerCaretLine() {
    if (!_typewriter || _mode != NoteViewMode.edit) return;
    final selection = _editorController.selection;
    if (!selection.isValid || !_editorScroll.hasClients) return;
    final render = _findEditableTextState()?.renderEditable;
    if (render == null) return;
    final caret = render.getLocalRectForCaret(
      TextPosition(offset: selection.extentOffset),
    );
    final position = _editorScroll.position;
    final target =
        (caret.top + caret.height / 2 - position.viewportDimension / 2).clamp(
          0.0,
          position.maxScrollExtent,
        );
    _editorScroll.jumpTo(target);
  }

  /// 大纲点击:跳到标题行(预览模式先切回编辑)
  void _jumpToHeading(OutlineEntry entry) {
    if (_mode == NoteViewMode.preview) _setMode(NoteViewMode.edit);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final offset = entry.offset.clamp(0, _editorController.text.length);
      _editorController.selection = TextSelection.collapsed(offset: offset);
      _editorFocus.requestFocus();
      _findEditableTextState()?.bringIntoView(TextPosition(offset: offset));
    });
  }

  /// 选中笔记变化时把内容灌进编辑器(摘监听避免自触发)。
  /// [listQuery] = 侧栏列表的搜索词,非空时把它接力进查找条。
  void _syncEditor(Note? note, {String listQuery = ''}) {
    if (note?.id == _editingNoteId) return;
    _editingNoteId = note?.id;
    _editorController.removeListener(_onEdited);
    _editorController.text = note?.content ?? '';
    _editorController.addListener(_onEdited);
    _scheduleFormatBarUpdate();
    // 从列表搜索点进来的:把搜索词接力进查找条,定位并高亮正文里的命中。
    // 否则"列表搜到了这篇"之后,用户还得在正文里把同一个词再搜一遍。
    final query = listQuery.trim();
    if (note != null && query.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _editingNoteId != note.id) return;
        _revealListQuery(query);
      });
      return;
    }
    // 换笔记后按新正文重算命中(摘了监听不会自动触发)
    if (_showFind) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _refreshFind(resetActive: true),
      );
    }
  }

  /// 把列表搜索词落到当前笔记:命中才展开查找条并跳到第一处。
  /// 只有编辑模式的 buildTextSpan 会画命中底色,预览/块模式先切回编辑。
  void _revealListQuery(String query) {
    if (NoteFind.matches(_editorController.text, query).isEmpty) {
      // 只在标题上命中的笔记:别让上一篇留下的高亮挂在这篇正文上
      if (_showFind) _refreshFind(resetActive: true);
      return;
    }
    if (_mode != NoteViewMode.edit) _setMode(NoteViewMode.edit);
    _findController.text = query;
    setState(() => _showFind = true);
    // 定位从正文开头起算,而不是上一篇笔记留下的光标位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshFind(resetActive: true, reveal: true);
    });
  }

  void _setMode(NoteViewMode mode) {
    setState(() => _mode = mode);
    NoteStore.saveViewMode(mode.index);
    _scheduleFormatBarUpdate();
  }

  void _createNote() {
    ref.read(notesProvider.notifier).create();
    // 新笔记为空,直接聚焦编辑
    if (_mode == NoteViewMode.preview) _setMode(NoteViewMode.edit);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editorFocus.requestFocus();
    });
  }

  // ══════════════ 浮动格式工具栏定位 ══════════════

  /// 选区几何要等本帧布局完成才准,统一延到帧末更新
  void _scheduleFormatBarUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateFormatBar());
  }

  void _updateFormatBar() {
    if (!mounted) return;
    final selection = _editorController.selection;
    final show =
        _mode == NoteViewMode.edit &&
        _editorFocus.hasFocus &&
        _editingNoteId != null &&
        selection.isValid &&
        !selection.isCollapsed;
    final editable = show ? _findEditableTextState() : null;
    if (editable == null) {
      _removeFormatBar();
      return;
    }

    final render = editable.renderEditable;
    final startRect = render.getLocalRectForCaret(
      TextPosition(offset: selection.start),
    );
    final endRect = render.getLocalRectForCaret(
      TextPosition(offset: selection.end),
    );
    final startTop = render.localToGlobal(startRect.topLeft);
    final endTop = render.localToGlobal(endRect.topLeft);
    final screen = MediaQuery.of(context).size;

    _barLeft =
        ((startTop.dx + endTop.dx) / 2 -
                FloatingFormatToolbar.estimatedWidth / 2)
            .clamp(
              8.0,
              screen.width - FloatingFormatToolbar.estimatedWidth - 8,
            );
    // 默认悬在选区上方;顶部放不下就落到选区下方
    _barTop = startTop.dy - FloatingFormatToolbar.height - 8;
    if (_barTop < 8) {
      _barTop = render.localToGlobal(endRect.bottomLeft).dy + 8;
    }

    if (_formatBar == null) {
      _formatBar = OverlayEntry(
        builder: (_) => Positioned(
          left: _barLeft,
          top: _barTop,
          child: FloatingFormatToolbar(
            controller: _editorController,
            focusNode: _editorFocus,
            onPickImage: _pickAndInsertImage,
          ),
        ),
      );
      Overlay.of(context).insert(_formatBar!);
    } else {
      _formatBar!.markNeedsBuild();
    }
  }

  void _removeFormatBar() {
    _formatBar?.remove();
    _formatBar = null;
  }

  /// TextField 内部的 EditableTextState(拿 renderEditable 算选区坐标)
  EditableTextState? _findEditableTextState() {
    final fieldContext = _editorFieldKey.currentContext;
    if (fieldContext == null) return null;
    EditableTextState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        found = element.state as EditableTextState;
        return;
      }
      element.visitChildren(visit);
    }

    (fieldContext as Element).visitChildren(visit);
    return found;
  }

  // ══════════════ 导入 / 导出 ══════════════

  void _toast(String message) {
    if (!mounted) return;
    AppToast.show(
      context: context,
      style: ToastificationStyle.flat,
      applyBlurEffect: true,
      type: ToastificationType.success,
      autoCloseDuration: const Duration(seconds: 2),
      title: Text(
        message,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400),
      ),
    );
  }

  /// 导出为指定格式(marktext 的 Export 菜单:md/html/pdf)
  Future<void> _exportNote(Note note, String extension) async {
    final safeName = note.title.replaceAll(RegExp(r'[/\\:*?"<>|]'), '-');
    final path = await FilePicker.saveFile(
      dialogTitle: tr('导出笔记'),
      fileName: '$safeName.$extension',
    );
    if (path == null) return;
    final finalPath = path.contains('.') ? path : '$path.$extension';
    try {
      final bytes = switch (extension) {
        'html' => utf8.encode(
          MarkdownHtmlExport.exportDocument(note.title, note.content),
        ),
        // PDF 画不了 Flutter 画笔,mermaid 交给界面层离屏渲成位图再嵌进去
        'pdf' => await NotePdfExporter.export(
          note.content,
          renderMermaid: (code) async {
            final diagram = MermaidParser.tryParse(code);
            return diagram == null ? null : await renderMermaidPng(diagram);
          },
        ),
        _ => utf8.encode(note.content),
      };
      await File(finalPath).writeAsBytes(bytes);
      FilePickerHelper.updateLastDirectory(finalPath);
      _toast(tr2('已导出到 {0}', [finalPath]));
    } catch (e) {
      _toast(tr2('导出失败: {0}', [e]));
    }
  }

  PopupMenuItem<String> _exportMenuItem(
    String value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem(
      value: value,
      height: 34,
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppTheme.subtleTextColor),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
          ),
        ],
      ),
    );
  }

  // ══════════════ 插入图片 / 文件 ══════════════

  /// 选择图片文件 → 复制到笔记资源目录 → 光标处插入图片语法
  Future<void> _pickAndInsertImage() => _pickAndImport(
    dialogTitle: tr('插入图片'),
    allowedExtensions: const [
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'bmp',
      'svg',
    ],
  );

  /// 选择视频/任意文件 → 复制进资源目录 → 插入附件链接(预览成卡片)
  Future<void> _pickAndInsertFile() => _pickAndImport(dialogTitle: tr('插入文件'));

  Future<void> _pickAndImport({
    required String dialogTitle,
    List<String>? allowedExtensions,
  }) async {
    final initialDirectory = await FilePickerHelper.getInitialDirectory();
    final result = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      allowMultiple: true,
      type: allowedExtensions == null ? FileType.any : FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    final paths = [
      for (final f in result?.files ?? <PlatformFile>[])
        if (f.path != null && f.path!.isNotEmpty) f.path!,
    ];
    if (paths.isEmpty) return;
    try {
      final assets = <(String, String)>[];
      for (final source in paths) {
        FilePickerHelper.updateLastDirectory(source);
        assets.add((source, await NoteAssetStore.importFile(source)));
      }
      _applyShortcut((v) => MarkdownEditing.insertStoredAssets(v, assets));
      _editorFocus.requestFocus();
    } catch (e) {
      _toast(tr2('插入失败: {0}', [e]));
    }
  }

  /// ⌘V:剪贴板里是图片(截屏/复制的图)就落盘插图,否则按普通文本粘贴
  Future<void> _pasteSmart() async {
    final imagePath = await NoteAssetStore.saveClipboardImage();
    if (imagePath != null) {
      _applyShortcut((v) => MarkdownEditing.insertDroppedPaths(v, [imagePath]));
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _applyShortcut((v) => MarkdownEditing.insertText(v, text));
  }

  Future<void> _importNotes() async {
    final initialDirectory = await FilePickerHelper.getInitialDirectory();
    final result = await FilePicker.pickFiles(
      dialogTitle: tr('导入 Markdown'),
      initialDirectory: initialDirectory,
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['md', 'markdown', 'txt'],
    );
    final files = result?.files ?? [];
    final controller = ref.read(notesProvider.notifier);
    var imported = 0;
    for (final f in files) {
      final path = f.path;
      if (path == null || path.isEmpty) continue;
      try {
        final content = MarkdownEditing.normalizeNewlines(
          await File(path).readAsString(),
        );
        controller.updateContent(controller.create(), content);
        FilePickerHelper.updateLastDirectory(path);
        imported++;
      } catch (_) {
        // 单个文件读取失败跳过,不打断批量导入
      }
    }
    if (imported > 0) {
      await controller.flush();
      _toast(tr2('已导入 {0} 篇笔记', [imported]));
    }
  }

  Future<void> _confirmDelete(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => AlertDialog(
        title: Text(tr('删除笔记')),
        content: Text(tr2('确定删除「{0}」吗?此操作不可恢复。', [note.title])),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('删除'), style: TextStyle(color: AppTheme.errorColor)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(notesProvider.notifier).remove(note.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(notesProvider);
    _syncEditor(state.selected, listQuery: state.query);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageTopBar(
          icon: LucideIcons.notebookPen300,
          title: AppL10n.current.notes,
          subtitle: _headerSubtitle(state),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 收缩栏:动画折叠,内容用 OverflowBox 固定宽度避免折叠中挤压重排
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                width: _showSidebar ? 260 : 0,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: 260,
                    maxWidth: 260,
                    child: _buildSidebar(state),
                  ),
                ),
              ),
              if (_showSidebar)
                VerticalDivider(width: 0.5, color: AppTheme.borderColor),
              Expanded(child: _buildWorkspace(state)),
            ],
          ),
        ),
      ],
    );
  }

  /// 页面头部副标题:当前笔记标题 → 当前笔记本名 → 全部笔记
  String _headerSubtitle(NotesState state) {
    final note = state.selected;
    if (note != null && note.title.isNotEmpty) return note.title;
    return state.activeNotebook?.name ?? AppL10n.current.allNotes;
  }

  // ══════════════ 左侧:笔记列表 ══════════════

  Widget _buildSidebar(NotesState state) {
    final notes = state.visibleNotes;
    // 侧栏与内容区同为亮面,靠分隔线和选中/hover 色块区分(Apple Notes 式)
    return Container(
      color: AppTheme.surfaceColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部两行:1) 笔记本切换器占满 + 唯一主操作「新建」;
          // 2) 搜索框 + 排序。导入 Markdown 收进笔记本菜单(库级低频操作)。
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 0),
            child: Row(
              children: [
                Expanded(child: _buildNotebookSwitcher(state)),
                IconButton(
                  tooltip: tr('新建笔记'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    LucideIcons.squarePen,
                    size: 17,
                    color: AppTheme.brandColor,
                  ),
                  onPressed: _createNote,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) =>
                        ref.read(notesProvider.notifier).setQuery(v),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.headingColor,
                    ),
                    decoration: InputDecoration(
                      hintText: tr('搜索笔记…'),
                      hintStyle: TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.subtleTextColor,
                      ),
                      prefixIcon: Icon(
                        LucideIcons.search,
                        size: 14,
                        color: AppTheme.subtleTextColor,
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 30),
                      isDense: true,
                      filled: true,
                      fillColor: AppTheme.mutedSurfaceColor,
                      contentPadding: const EdgeInsets.symmetric(vertical: 7),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _buildSortMenu(state),
              ],
            ),
          ),
          Expanded(
            child: notes.isEmpty
                ? _sidebarPlaceholder(state)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    itemCount: notes.length,
                    itemBuilder: (context, index) => _NoteListTile(
                      note: notes[index],
                      selected: notes[index].id == state.selectedId,
                      notebooks: state.notebooks,
                      onTap: () => ref
                          .read(notesProvider.notifier)
                          .select(notes[index].id),
                      onTogglePin: () => ref
                          .read(notesProvider.notifier)
                          .togglePin(notes[index].id),
                      onMove: (notebookId) => ref
                          .read(notesProvider.notifier)
                          .moveToNotebook(notes[index].id, notebookId),
                      onDelete: () => _confirmDelete(notes[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 笔记本切换器(侧栏头部):全部/各笔记本 + 新建/重命名/删除
  Widget _buildNotebookSwitcher(NotesState state) {
    final active = state.activeNotebook;
    return PopupMenuButton<String>(
      tooltip: tr('切换笔记本'),
      position: PopupMenuPosition.under,
      onSelected: (value) => _onNotebookAction(value, state),
      itemBuilder: (context) {
        PopupMenuItem<String> entry(
          String value,
          String label,
          int count, {
          required bool checked,
        }) {
          return PopupMenuItem(
            value: value,
            height: 34,
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: checked
                      ? Icon(
                          LucideIcons.check,
                          size: 13,
                          color: AppTheme.brandColor,
                        )
                      : null,
                ),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ],
            ),
          );
        }

        PopupMenuItem<String> action(
          String value,
          IconData icon,
          String label,
        ) {
          return PopupMenuItem(
            value: value,
            height: 34,
            child: Row(
              children: [
                Icon(icon, size: 14, color: AppTheme.subtleTextColor),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
                ),
              ],
            ),
          );
        }

        return [
          entry(
            '__all__',
            tr('全部笔记'),
            state.countIn(null),
            checked: active == null,
          ),
          for (final nb in state.notebooks)
            entry(
              nb.id,
              nb.name,
              state.countIn(nb.id),
              checked: nb.id == active?.id,
            ),
          const PopupMenuDivider(),
          action('__create__', LucideIcons.folderPlus, tr('新建笔记本…')),
          if (active != null) ...[
            action(
              '__rename__',
              LucideIcons.pencil,
              tr2('重命名「{0}」…', [active.name]),
            ),
            action(
              '__delete__',
              LucideIcons.trash2,
              tr2('删除「{0}」', [active.name]),
            ),
          ],
          const PopupMenuDivider(),
          action('__import__', LucideIcons.fileDown, tr('导入 Markdown…')),
        ];
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            active == null ? LucideIcons.notebookText : LucideIcons.notebook,
            size: 15,
            color: active == null ? AppTheme.headingColor : AppTheme.brandColor,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              active?.name ?? tr('全部笔记'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.headingColor,
              ),
            ),
          ),
          const SizedBox(width: 3),
          Icon(
            LucideIcons.chevronDown,
            size: 12,
            color: AppTheme.subtleTextColor,
          ),
          const SizedBox(width: 5),
          Text(
            '${state.countIn(state.activeNotebookId)}',
            style: TextStyle(fontSize: 12, color: AppTheme.subtleTextColor),
          ),
        ],
      ),
    );
  }

  Future<void> _onNotebookAction(String value, NotesState state) async {
    final controller = ref.read(notesProvider.notifier);
    switch (value) {
      case '__all__':
        controller.setActiveNotebook(null);
      case '__import__':
        await _importNotes();
      case '__create__':
        final name = await _promptNotebookName(title: tr('新建笔记本'));
        if (name != null && name.trim().isNotEmpty) {
          controller.createNotebook(name);
        }
      case '__rename__':
        final active = state.activeNotebook;
        if (active == null) return;
        final name = await _promptNotebookName(
          title: tr('重命名笔记本'),
          initial: active.name,
        );
        if (name != null && name.trim().isNotEmpty) {
          controller.renameNotebook(active.id, name);
        }
      case '__delete__':
        final active = state.activeNotebook;
        if (active == null) return;
        final confirmed = await showDialog<bool>(
          context: context,
          useRootNavigator: false,
          barrierColor: Colors.black.withValues(alpha: 0.3),
          builder: (context) => AlertDialog(
            title: Text(tr('删除笔记本')),
            content: Text(tr2('删除「{0}」?其中的笔记会移回「全部笔记」,不会被删除。', [active.name])),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(tr('取消')),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(
                  tr('删除'),
                  style: TextStyle(color: AppTheme.errorColor),
                ),
              ),
            ],
          ),
        );
        if (confirmed == true) controller.deleteNotebook(active.id);
      default:
        controller.setActiveNotebook(value);
    }
  }

  Future<String?> _promptNotebookName({
    required String title,
    String? initial,
  }) {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(fontSize: 13.5, color: AppTheme.headingColor),
          decoration: InputDecoration(hintText: tr('笔记本名称')),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
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
    ).whenComplete(() {
      // 对话框关闭后再释放,避免输入中被销毁
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    });
  }

  /// 列表排序菜单:名称(数字自然序)/最近修改/最近创建,置顶恒在前
  Widget _buildSortMenu(NotesState state) {
    final items = [
      (NoteSortMode.title, LucideIcons.arrowDownAZ, tr('名称(数字自然序)')),
      (NoteSortMode.updated, LucideIcons.clock, tr('最近修改')),
      (NoteSortMode.created, LucideIcons.calendarPlus, tr('最近创建')),
    ];
    return PopupMenuButton<NoteSortMode>(
      tooltip: tr('排序'),
      position: PopupMenuPosition.under,
      onSelected: (mode) => ref.read(notesProvider.notifier).setSortMode(mode),
      itemBuilder: (context) => [
        for (final (mode, icon, label) in items)
          PopupMenuItem(
            value: mode,
            height: 34,
            child: Row(
              children: [
                Icon(icon, size: 14, color: AppTheme.subtleTextColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ),
                if (state.sortMode == mode)
                  Icon(LucideIcons.check, size: 13, color: AppTheme.brandColor),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Icon(
          LucideIcons.arrowUpDown,
          size: 15,
          color: state.sortMode == NoteSortMode.title
              ? AppTheme.subtleTextColor
              : AppTheme.brandColor,
        ),
      ),
    );
  }

  Widget _sidebarPlaceholder(NotesState state) {
    if (!state.loaded) return const SizedBox.shrink();
    final searching = state.query.trim().isNotEmpty;
    return Center(
      child: Text(
        searching ? tr('没有匹配的笔记') : '还没有笔记\n点右上角新建一篇',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.6,
          color: AppTheme.subtleTextColor,
        ),
      ),
    );
  }

  // ══════════════ 右侧:编辑/预览工作区 ══════════════

  Widget _buildWorkspace(NotesState state) {
    final note = state.selected;
    if (note == null) {
      return Container(
        color: AppTheme.surfaceColor,
        child: Stack(
          children: [
            // 侧栏收起时,空态页也要能把它请回来
            Positioned(left: 6, top: 6, child: _sidebarToggleButton()),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.notebookPen,
                    size: 40,
                    color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tr('选择或新建一篇笔记,用 Markdown 记录'),
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.subtleTextColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      color: AppTheme.surfaceColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(note),
          Divider(height: 0.5, color: AppTheme.borderColor),
          if (_showFind) _buildFindBar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _buildEditorArea()),
                if (_showOutline) ...[
                  VerticalDivider(width: 0.5, color: AppTheme.borderColor),
                  SizedBox(width: 200, child: _buildOutline()),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 查找/替换条(Cmd+F 呼出,Esc 关闭)
  Widget _buildFindBar() {
    final total = _findMatches.length;
    final counter = total == 0
        ? (_findController.text.isEmpty ? '' : tr('无结果'))
        : '${_activeMatch + 1}/$total';

    InputDecoration decoration(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 12.5, color: AppTheme.subtleTextColor),
      isDense: true,
      filled: true,
      fillColor: AppTheme.mutedSurfaceColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
    );

    Widget iconButton(IconData icon, String tooltip, VoidCallback? onTap) {
      return IconButton(
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          icon,
          size: 14,
          color: onTap == null
              ? AppTheme.subtleTextColor.withValues(alpha: 0.4)
              : AppTheme.subtleTextColor,
        ),
        onPressed: onTap,
      );
    }

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeFind},
      child: Container(
        color: AppTheme.surfaceColor,
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 450;
            final findField = TextField(
              controller: _findController,
              focusNode: _findFocus,
              style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
              decoration: decoration(tr('查找…')),
              onChanged: (_) => _refreshFind(resetActive: true, reveal: true),
              onSubmitted: (_) {
                _stepMatch(1);
                _findFocus.requestFocus(); // 回车连续跳下一个
              },
            );
            final replaceField = TextField(
              controller: _replaceController,
              style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
              decoration: decoration(tr('替换为…')),
              onSubmitted: (_) => _replaceActive(),
            );

            final children = [
              Icon(
                LucideIcons.textSearch,
                size: 14,
                color: AppTheme.subtleTextColor,
              ),
              const SizedBox(width: 8),
              isNarrow
                  ? SizedBox(width: 140, child: findField)
                  : Expanded(flex: 3, child: findField),
              SizedBox(
                width: 64,
                child: Text(
                  counter,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.subtleTextColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              iconButton(
                LucideIcons.chevronUp,
                tr('上一个'),
                total > 0 ? () => _stepMatch(-1) : null,
              ),
              iconButton(
                LucideIcons.chevronDown,
                tr('下一个'),
                total > 0 ? () => _stepMatch(1) : null,
              ),
              const SizedBox(width: 8),
              isNarrow
                  ? SizedBox(width: 120, child: replaceField)
                  : Expanded(flex: 2, child: replaceField),
              const SizedBox(width: 4),
              TextButton(
                onPressed: total > 0 ? _replaceActive : null,
                child: Text(tr('替换'), style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: total > 0 ? _replaceAllMatches : null,
                child: Text(tr('全部替换'), style: TextStyle(fontSize: 12)),
              ),
              iconButton(LucideIcons.x, tr('关闭 (Esc)'), _closeFind),
            ];

            if (isNarrow) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: children),
              );
            }
            return Row(children: children);
          },
        ),
      ),
    );
  }

  Widget _buildOutline() {
    final entries = MarkdownOutline.extract(_editorController.text);
    final caret = _editorController.selection.isValid
        ? _editorController.selection.start
        : 0;
    final active = MarkdownOutline.activeEntry(entries, caret);
    return Container(
      color: AppTheme.surfaceColor,
      child: entries.isEmpty
          ? Center(
              child: Text(
                tr('暂无标题'),
                style: TextStyle(fontSize: 12, color: AppTheme.subtleTextColor),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final isActive = identical(entry, active);
                return InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _jumpToHeading(entry),
                  child: Container(
                    padding: EdgeInsets.only(
                      left: 8.0 + (entry.level - 1) * 12,
                      top: 5,
                      bottom: 5,
                      right: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppTheme.softBrandColor
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: entry.level <= 2 ? 12.5 : 12,
                        fontWeight: entry.level == 1
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: isActive
                            ? AppTheme.brandColor
                            : entry.level <= 2
                            ? AppTheme.headingColor
                            : AppTheme.bodyColor,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  /// 收起/展开左侧列表(标题栏与空态页共用)
  Widget _sidebarToggleButton() {
    return IconButton(
      tooltip: _showSidebar ? tr('收起列表 (⌘J)') : tr('展开列表 (⌘J)'),
      visualDensity: VisualDensity.compact,
      icon: Icon(
        _showSidebar ? LucideIcons.panelLeftClose : LucideIcons.panelLeftOpen,
        size: 16,
        color: AppTheme.subtleTextColor,
      ),
      onPressed: _toggleSidebar,
    );
  }

  Widget _buildToolbar(Note note) {
    return Container(
      height: 44,
      color: AppTheme.surfaceColor,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _sidebarToggleButton(),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.headingColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            flex: 10,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr2('{0} 字', [Note.wordCount(note.content)]),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.subtleTextColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: tr('聚焦模式(段落外淡化)'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      LucideIcons.focus,
                      size: 15,
                      color: _focusMode
                          ? AppTheme.brandColor
                          : AppTheme.subtleTextColor,
                    ),
                    onPressed: _toggleFocusMode,
                  ),
                  IconButton(
                    tooltip: tr('打字机模式(光标行居中)'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      LucideIcons.keyboard,
                      size: 15,
                      color: _typewriter
                          ? AppTheme.brandColor
                          : AppTheme.subtleTextColor,
                    ),
                    onPressed: _toggleTypewriter,
                  ),
                  IconButton(
                    tooltip: tr('查找替换 (⌘F)'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      LucideIcons.textSearch,
                      size: 15,
                      color: _showFind
                          ? AppTheme.brandColor
                          : AppTheme.subtleTextColor,
                    ),
                    onPressed: _showFind ? _closeFind : _openFind,
                  ),
                  IconButton(
                    tooltip: tr('大纲'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      LucideIcons.tableOfContents,
                      size: 15,
                      color: _showOutline
                          ? AppTheme.brandColor
                          : AppTheme.subtleTextColor,
                    ),
                    onPressed: _toggleOutline,
                  ),
                  PopupMenuButton<String>(
                    tooltip: tr('导出'),
                    position: PopupMenuPosition.under,
                    onSelected: (ext) => _exportNote(note, ext),
                    itemBuilder: (context) => [
                      _exportMenuItem(
                        'md',
                        LucideIcons.fileText,
                        'Markdown (.md)',
                      ),
                      _exportMenuItem(
                        'html',
                        LucideIcons.fileCode,
                        'HTML (.html)',
                      ),
                      _exportMenuItem('pdf', LucideIcons.printer, 'PDF (.pdf)'),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 6,
                      ),
                      child: Icon(
                        LucideIcons.fileUp,
                        size: 15,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ),
                  if (_mode == NoteViewMode.edit)
                    NoteInsertMenu(
                      controller: _editorController,
                      focusNode: _editorFocus,
                      onPickImage: _pickAndInsertImage,
                      onPickFile: _pickAndInsertFile,
                    ),
                  const SizedBox(width: 8),
                  _ModeSwitcher(mode: _mode, onChanged: _setMode),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorArea() {
    switch (_mode) {
      case NoteViewMode.edit:
        return _buildEditor();
      case NoteViewMode.blocks:
        return BlockEditor(
          // 换笔记时重建,丢弃上一篇的块编辑状态
          key: ValueKey('blocks-$_editingNoteId'),
          source: _editorController.text,
          onChanged: (source) {
            _editorController.text = source; // listener 链路负责落盘
            setState(() {});
          },
        );
      case NoteViewMode.preview:
        return MarkdownPreview(
          source: _editorController.text,
          onToggleTask: (index) {
            // 预览里点勾选框:直接改源码并落盘(listener 链路)
            _editorController.text = MarkdownEditing.toggleTaskAt(
              _editorController.text,
              index,
            );
            setState(() {});
          },
        );
    }
  }

  /// 快捷键直接改 controller.value(工具栏同款纯函数变换)
  void _applyShortcut(TextEditingValue Function(TextEditingValue) transform) {
    _editorController.value = transform(_editorController.value);
  }

  Widget _buildEditor() {
    return CallbackShortcuts(
      bindings: {
        // 双绑 meta/control,macOS 与 Windows/Linux 通吃
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
            _applyShortcut((v) => MarkdownEditing.toggleInline(v, '**')),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            _applyShortcut((v) => MarkdownEditing.toggleInline(v, '**')),
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
            _applyShortcut((v) => MarkdownEditing.toggleInline(v, '*')),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            _applyShortcut((v) => MarkdownEditing.toggleInline(v, '*')),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            _applyShortcut(MarkdownEditing.insertLink),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            _applyShortcut(MarkdownEditing.insertLink),
        // 智能粘贴:剪贴板是图片(截屏等)→ 落盘插图,否则按文本粘贴
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _pasteSmart,
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _pasteSmart,
        // Tab 缩进/反缩进(列表嵌套),拦掉默认的焦点切换
        const SingleActivator(LogicalKeyboardKey.tab): () =>
            _applyShortcut(MarkdownEditing.indentLines),
        const SingleActivator(LogicalKeyboardKey.tab, shift: true): () =>
            _applyShortcut(MarkdownEditing.outdentLines),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _openFind,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _openFind,
        const SingleActivator(LogicalKeyboardKey.keyJ, meta: true):
            _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true):
            _toggleSidebar,
        // ⌘E 编辑/预览互切(marktext 的模式切换习惯)
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true): () =>
            _setMode(
              _mode == NoteViewMode.edit
                  ? NoteViewMode.preview
                  : NoteViewMode.edit,
            ),
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
            _setMode(
              _mode == NoteViewMode.edit
                  ? NoteViewMode.preview
                  : NoteViewMode.edit,
            ),
      },
      // 拖文件进来:复制进资源目录后插入(图片语法/附件链接)
      child: DropTarget(
        onDragDone: (detail) async {
          final paths = [
            for (final f in detail.files)
              if (f.path.isNotEmpty) f.path,
          ];
          if (paths.isEmpty) return;
          try {
            final assets = <(String, String)>[];
            for (final source in paths) {
              assets.add((source, await NoteAssetStore.importFile(source)));
            }
            _editorController.value = MarkdownEditing.insertStoredAssets(
              _editorController.value,
              assets,
            );
            _editorFocus.requestFocus();
          } catch (e) {
            _toast(tr2('插入失败: {0}', [e]));
          }
        },
        // 版心靠 contentPadding 实现,但那会把 TextField
        // 多行时的内建滚动条推到正文右缘(而非内容区最右)。这里屏蔽内建滚动条,
        // 改由外层 Scrollbar 用同一 controller 贴编辑区最右侧绘制。
        child: Scrollbar(
          controller: _editorScroll,
          child: ScrollConfiguration(
            behavior: const _NoInnerScrollbarBehavior(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _editorFocus.requestFocus(),
              child: _buildTextField(0),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(double sidePadding) {
    // 所见即所得:底样式是正文字体,标题/粗斜删/代码等由
    // MarkdownEditingController 按 token 实时上样式;
    // 圆点/勾选框/引用条/代码块底色由装饰层画在文字之下
    return Stack(
      fit: StackFit.expand,
      children: [
        EditorDecorations(
          controller: _editorController,
          scrollController: _editorScroll,
          editableFinder: _findEditableTextState,
          sidePadding: sidePadding,
        ),
        _buildRawTextField(sidePadding),
      ],
    );
  }

  Widget _buildRawTextField(double sidePadding) {
    return TextField(
      key: _editorFieldKey,
      controller: _editorController,
      focusNode: _editorFocus,
      scrollController: _editorScroll,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      inputFormatters: [MarkdownAutoContinueFormatter()],
      style: TextStyle(fontSize: 13.5, height: 1.7, color: AppTheme.bodyColor),
      cursorColor: AppTheme.brandColor,
      decoration: InputDecoration(
        hintText: '# 标题\n\n开始书写 Markdown…',
        hintStyle: TextStyle(
          fontSize: 13.5,
          height: 1.7,
          color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
        ),
        border: InputBorder.none,
        contentPadding: EdgeInsets.fromLTRB(
          sidePadding + 24,
          20,
          sidePadding + 24,
          40,
        ),
      ),
    );
  }
}

// ══════════════ 组件 ══════════════

/// 编辑/预览 两态切换
class _ModeSwitcher extends StatelessWidget {
  const _ModeSwitcher({required this.mode, required this.onChanged});

  final NoteViewMode mode;
  final ValueChanged<NoteViewMode> onChanged;

  static const _items = [
    (mode: NoteViewMode.edit, icon: LucideIcons.pencil, label: '编辑'),
    (mode: NoteViewMode.blocks, icon: LucideIcons.blocks, label: '排版'),
    (mode: NoteViewMode.preview, icon: LucideIcons.eye, label: '预览'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppTheme.mutedSurfaceColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in _items)
            Tooltip(
              message: item.label,
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => onChanged(item.mode),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: mode == item.mode
                        ? AppTheme.surfaceColor
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: mode == item.mode
                        ? Border.all(color: AppTheme.borderColor, width: 0.6)
                        : null,
                  ),
                  child: Icon(
                    item.icon,
                    size: 14,
                    color: mode == item.mode
                        ? AppTheme.brandColor
                        : AppTheme.subtleTextColor,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 列表里的一条笔记(hover 出现删除按钮)
class _NoteListTile extends StatefulWidget {
  const _NoteListTile({
    required this.note,
    required this.selected,
    required this.notebooks,
    required this.onTap,
    required this.onTogglePin,
    required this.onMove,
    required this.onDelete,
  });

  final Note note;
  final bool selected;
  final List<Notebook> notebooks;
  final VoidCallback onTap;
  final VoidCallback onTogglePin;

  /// 移动到笔记本(null = 移出分组)
  final ValueChanged<String?> onMove;
  final VoidCallback onDelete;

  @override
  State<_NoteListTile> createState() => _NoteListTileState();
}

class _NoteListTileState extends State<_NoteListTile> {
  bool _hovered = false;

  /// 菜单弹开时模态遮罩会抢走 hover;若因此把 PopupMenuButton 卸载,
  /// showMenu 回调 mounted==false,onSelected 会被丢弃。打开期间强制保留。
  bool _menuOpen = false;

  static String _formatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(time.year, time.month, time.day);
    String two(int n) => n.toString().padLeft(2, '0');
    if (day == today) return '${two(time.hour)}:${two(time.minute)}';
    if (day == today.subtract(Duration(days: 1))) return tr('昨天');
    if (time.year == now.year) return tr2('{0}月{1}日', [time.month, time.day]);
    return '${time.year}/${two(time.month)}/${two(time.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          // 紧凑排版:字号小于内容区、间距收紧,单屏多显示约三成条目
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
          decoration: BoxDecoration(
            color: widget.selected
                ? AppTheme.softBrandColor
                : _hovered
                ? AppTheme.mutedSurfaceColor
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          // hover 菜单叠加在右上角,不参与布局(悬停时标题/时间不位移)
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (note.pinned) ...[
                        Icon(
                          LucideIcons.pin,
                          size: 10,
                          color: AppTheme.brandColor,
                        ),
                        const SizedBox(width: 3),
                      ],
                      // 标题居左、时间靠右(列表惯例),摘要独占第二行
                      Expanded(
                        child: Text(
                          note.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                            color: widget.selected
                                ? AppTheme.brandColor
                                : AppTheme.headingColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _formatTime(note.updatedAt),
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.35,
                          color: AppTheme.subtleTextColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // 摘要略缩进,与标题拉开层次(Apple Notes 式)
                  Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Text(
                      note.summary.isEmpty ? ' ' : note.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ),
                ],
              ),
              if (_hovered || _menuOpen)
                Positioned(right: 0, top: 0, child: _buildMenu()),
            ],
          ),
        ),
      ),
    );
  }

  /// hover 菜单:置顶 / 移动到笔记本 / 删除
  Widget _buildMenu() {
    final note = widget.note;
    PopupMenuItem<String> item(String value, IconData icon, String label) {
      return PopupMenuItem(
        value: value,
        height: 32,
        child: Row(
          children: [
            Icon(icon, size: 14, color: AppTheme.subtleTextColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
              ),
            ),
          ],
        ),
      );
    }

    return PopupMenuButton<String>(
      tooltip: tr('更多'),
      position: PopupMenuPosition.under,
      onOpened: () => setState(() => _menuOpen = true),
      onCanceled: () => setState(() => _menuOpen = false),
      onSelected: (value) {
        setState(() => _menuOpen = false);
        switch (value) {
          case '__pin__':
            widget.onTogglePin();
          case '__delete__':
            widget.onDelete();
          case '__ungroup__':
            widget.onMove(null);
          default:
            widget.onMove(value);
        }
      },
      itemBuilder: (context) => [
        item(
          '__pin__',
          note.pinned ? LucideIcons.pinOff : LucideIcons.pin,
          note.pinned ? tr('取消置顶') : tr('置顶'),
        ),
        if (widget.notebooks.isNotEmpty) ...[
          const PopupMenuDivider(),
          for (final nb in widget.notebooks)
            if (nb.id != note.notebookId)
              item(nb.id, LucideIcons.folderInput, tr2('移动到「{0}」', [nb.name])),
          if (note.notebookId != null)
            item('__ungroup__', LucideIcons.folderInput, tr('移出笔记本')),
        ],
        const PopupMenuDivider(),
        item('__delete__', LucideIcons.trash2, tr('删除')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Icon(
          LucideIcons.ellipsisVertical,
          size: 14,
          color: AppTheme.subtleTextColor,
        ),
      ),
    );
  }
}
