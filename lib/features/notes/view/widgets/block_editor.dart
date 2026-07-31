import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/notes/domain/markdown_blocks.dart';
import 'package:termora/features/notes/domain/markdown_editing.dart';
import 'package:termora/features/notes/domain/markdown_parser.dart';
import 'package:termora/features/notes/view/widgets/editable_table_block.dart';
import 'package:termora/features/notes/view/widgets/markdown_editing_controller.dart';
import 'package:termora/features/notes/view/widgets/markdown_preview.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 块式自绘编辑器(muya/Notion 架构的 Flutter 版):
/// 文档切成块,每块渲染成真实组件——表格就是表格、图片就是图片、
/// 代码块带高亮底色;点击哪块,哪块就地变回源码编辑,失焦/Esc 提交写回全文。
///
/// 块间光标流:块首行按 ↑(或块首按 ←/Backspace)去上一块,
/// 末行按 ↓(或块尾按 →)去下一块;Backspace 在块首把文本块向上合并;
/// 空行上再按回车跳出当前块,在其后起新块。
class BlockEditor extends StatefulWidget {
  const BlockEditor({super.key, required this.source, required this.onChanged});

  final String source;
  final ValueChanged<String> onChanged;

  @override
  State<BlockEditor> createState() => _BlockEditorState();
}

class _BlockEditorState extends State<BlockEditor> {
  /// 正在编辑的已有块下标(与 _insertPos 互斥)
  int? _editingIndex;

  /// 新块插入位置:在该下标的块之前插入;== blocks.length 表示文末
  int? _insertPos;

  /// 块内源码编辑(复用所见即所得控制器,块内也有实时样式)
  final MarkdownEditingController _blockController =
      MarkdownEditingController();
  final FocusNode _blockFocus = FocusNode();

  /// 提交中标志,避免 blur 提交与显式提交重入
  bool _committing = false;

  /// hover 的块下标(显示拖拽把手)
  int? _hoverIndex;

  @override
  void initState() {
    super.initState();
    _blockFocus.addListener(_onBlockFocusChanged);
    _blockFocus.onKeyEvent = _onBlockKey;
  }

  @override
  void dispose() {
    _blockFocus.removeListener(_onBlockFocusChanged);
    _blockController.dispose();
    _blockFocus.dispose();
    super.dispose();
  }

  void _onBlockFocusChanged() {
    if (!_blockFocus.hasFocus) _commit();
  }

  List<SourceBlock> get _blocks => MarkdownBlockSplitter.split(widget.source);

  bool get _isEditing => _editingIndex != null || _insertPos != null;

  // ══════════════ 编辑态切换 ══════════════

  void _startEdit(int index, List<SourceBlock> blocks, {int? caretOffset}) {
    // 提交当前编辑可能改动全文,目标块的区间随之漂移:按内容重新定位
    final targetSource = blocks[index].source;
    _commit();
    final fresh = _blocks;
    if (fresh.isEmpty) return;
    var idx = fresh.indexWhere((b) => b.source == targetSource);
    if (idx < 0) idx = index.clamp(0, fresh.length - 1);
    _editAt(idx, fresh, caretOffset: caretOffset);
  }

  void _editAt(int index, List<SourceBlock> blocks, {int? caretOffset}) {
    setState(() {
      _editingIndex = index;
      _insertPos = null;
      _blockController.text = blocks[index].source;
      _blockController.selection = TextSelection.collapsed(
        offset: (caretOffset ?? blocks[index].source.length).clamp(
          0,
          blocks[index].source.length,
        ),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _blockFocus.requestFocus();
    });
  }

  void _startInsert(int position) {
    setState(() {
      _editingIndex = null;
      _insertPos = position;
      _blockController.text = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _blockFocus.requestFocus();
    });
  }

  /// 提交当前编辑(已有块写回 / 新块插入),退出编辑态。
  /// 已有块清空内容 = 删除。返回 true 表示已有块被删除。
  bool _commit() {
    if (_committing || !_isEditing) return false;
    _committing = true;
    var removed = false;
    try {
      final blocks = _blocks;
      final index = _editingIndex;
      final insertPos = _insertPos;
      if (index != null && index < blocks.length) {
        final next = MarkdownBlockSplitter.replaceBlock(
          widget.source,
          blocks[index],
          _blockController.text,
        );
        removed = _blockController.text.trim().isEmpty;
        if (next != widget.source) widget.onChanged(next);
      } else if (insertPos != null) {
        final text = _blockController.text.trim();
        if (text.isNotEmpty) {
          widget.onChanged(_spliceInsert(blocks, insertPos, text));
        }
      }
      setState(() {
        _editingIndex = null;
        _insertPos = null;
      });
    } finally {
      _committing = false;
    }
    return removed;
  }

  String _spliceInsert(List<SourceBlock> blocks, int position, String text) {
    if (position >= blocks.length) {
      return MarkdownBlockSplitter.appendBlock(widget.source, text);
    }
    final at = blocks[position].start;
    return '${widget.source.substring(0, at)}$text\n\n'
        '${widget.source.substring(at)}';
  }

  // ══════════════ 块间光标流 ══════════════

  KeyEventResult _onBlockKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final selection = _blockController.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final text = _blockController.text;
    final offset = selection.baseOffset;
    final onFirstLine = offset == 0 || text.lastIndexOf('\n', offset - 1) == -1;
    final onLastLine = text.indexOf('\n', offset) == -1;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        if (onFirstLine) return _moveTo(forward: false);
      case LogicalKeyboardKey.arrowLeft:
        if (offset == 0) return _moveTo(forward: false);
      case LogicalKeyboardKey.arrowDown:
        if (onLastLine) return _moveTo(forward: true);
      case LogicalKeyboardKey.arrowRight:
        if (offset == text.length) {
          return _moveTo(forward: true, caretAtStart: true);
        }
      case LogicalKeyboardKey.backspace:
        if (offset == 0) return _mergeWithPrevious();
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        // 空行上再按回车:跳出当前块,在其后起新块(Notion 手感)
        if (offset == text.length && (text.isEmpty || text.endsWith('\n'))) {
          return _escapeToNewBlock();
        }
      default:
        break;
    }
    return KeyEventResult.ignored;
  }

  /// 提交当前块,把编辑焦点移到相邻块
  KeyEventResult _moveTo({required bool forward, bool caretAtStart = false}) {
    final index = _editingIndex;
    if (index == null) return KeyEventResult.ignored;
    final removed = _commit();
    final fresh = _blocks;
    if (fresh.isEmpty) return KeyEventResult.handled;
    final target = forward ? (removed ? index : index + 1) : index - 1;
    if (target < 0 || target >= fresh.length) {
      // 越过文档边界:向下越界起新块,向上越界停在原地
      if (forward) _startInsert(fresh.length);
      return KeyEventResult.handled;
    }
    _editAt(target, fresh, caretOffset: (forward || caretAtStart) ? 0 : null);
    return KeyEventResult.handled;
  }

  /// 块首 Backspace:上一块是文本块则合并(光标停在接缝),否则移过去编辑
  KeyEventResult _mergeWithPrevious() {
    final index = _editingIndex;
    if (index == null || index == 0) return KeyEventResult.ignored;
    final blocks = _blocks;
    if (index >= blocks.length) return KeyEventResult.ignored;
    final prev = blocks[index - 1];
    final current = blocks[index];

    if (prev.kind != SourceBlockKind.text) {
      _startEdit(index - 1, blocks);
      return KeyEventResult.handled;
    }

    // 拼接两块(去掉中间的空行分隔),接缝处落光标
    final mergedBlockText = '${prev.source}\n${_blockController.text}';
    final next =
        widget.source.substring(0, prev.start) +
        mergedBlockText +
        widget.source.substring(current.end);
    _editingIndex = null;
    widget.onChanged(next);
    final fresh = MarkdownBlockSplitter.split(next);
    var idx = fresh.indexWhere((b) => b.start == prev.start);
    if (idx < 0) idx = (index - 1).clamp(0, fresh.length - 1);
    _editAt(idx, fresh, caretOffset: prev.source.length + 1);
    return KeyEventResult.handled;
  }

  /// 空行回车:剥掉尾部空行提交,在当前块之后起新块
  KeyEventResult _escapeToNewBlock() {
    final index = _editingIndex;
    if (index == null) return KeyEventResult.ignored;
    _blockController.text = _blockController.text.trimRight();
    final removed = _commit();
    final fresh = _blocks;
    _startInsert((removed ? index : index + 1).clamp(0, fresh.length));
    return KeyEventResult.handled;
  }

  // ══════════════ 构建 ══════════════

  /// 拖拽重排。编辑中把手不显示,故回调触发时 children 恰为纯块列表,
  /// 下标与块下标一一对应。
  void _onReorder(int oldIndex, int newIndex) {
    if (_isEditing) return;
    if (newIndex > oldIndex) newIndex--;
    final next = MarkdownBlockSplitter.moveBlock(
      widget.source,
      oldIndex,
      newIndex,
    );
    if (next != widget.source) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final blocks = _blocks;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        // 点空白处:提交当前块,尾部起新块
        if (_insertPos != null) return;
        _commit();
        _startInsert(_blocks.length);
      },
      // SelectionArea:渲染块的文字可跨块拖选、⌘C 复制
      child: SelectionArea(
        child: Builder(
          builder: (context) {
            // 内容水平内边距放在行内（而非列表），给左侧留出拖拽把手的沟槽
            const rowPadding = EdgeInsets.symmetric(horizontal: 32);
            return ReorderableListView(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.fromLTRB(0, 28, 0, 120),
              onReorderStart: (_) => _commit(),
              onReorder: _onReorder,
              proxyDecorator: (child, index, animation) =>
                  Material(color: Colors.transparent, child: child),
              children: [
                for (final (index, block) in blocks.indexed) ...[
                  if (_insertPos == index)
                    Padding(
                      key: const ValueKey('insert-editor'),
                      padding: rowPadding,
                      child: _buildBlockEditorField(),
                    ),
                  _buildRow(index, block, blocks, rowPadding),
                ],
                if (_insertPos != null && _insertPos! >= blocks.length)
                  Padding(
                    key: const ValueKey('insert-tail'),
                    padding: rowPadding,
                    child: _buildBlockEditorField(),
                  ),
                if (blocks.isEmpty && !_isEditing)
                  Padding(
                    key: const ValueKey('empty-placeholder'),
                    padding: const EdgeInsets.only(top: 40),
                    child: Text(
                      tr('点击任意空白处开始书写…'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 一行 = 块内容 + 左侧沟槽里的拖拽把手(hover 显示,编辑中不显示)
  Widget _buildRow(
    int index,
    SourceBlock block,
    List<SourceBlock> blocks,
    EdgeInsets rowPadding, [
    double sidePadding = 0,
  ]) {
    final content = _editingIndex == index
        ? _buildBlockEditorField()
        : _buildRenderedBlock(index, block, blocks);
    return MouseRegion(
      key: ValueKey('block-$index'),
      onEnter: (_) => setState(() => _hoverIndex = index),
      onExit: (_) => setState(() {
        if (_hoverIndex == index) _hoverIndex = null;
      }),
      child: Stack(
        children: [
          Padding(padding: rowPadding, child: content),
          if (_hoverIndex == index && !_isEditing)
            Positioned(
              left: 6 + sidePadding,
              top: 6,
              child: ReorderableDragStartListener(
                index: index,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      LucideIcons.gripVertical,
                      size: 15,
                      color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRenderedBlock(
    int index,
    SourceBlock block,
    List<SourceBlock> blocks,
  ) {
    // 表格块:单元格级就地编辑,不退整块源码
    if (block.kind == SourceBlockKind.table) {
      return Padding(
        padding: EdgeInsets.only(top: index == 0 ? 0 : 10),
        child: EditableTableBlock(
          key: ValueKey('table-$index'),
          source: block.source,
          onBeforeEdit: _commit,
          onChanged: (tableSource) {
            // 用最新区间写回(onBeforeEdit 的提交可能已移动区间)
            final fresh = _blocks;
            final idx =
                index < fresh.length &&
                    fresh[index].kind == SourceBlockKind.table
                ? index
                : fresh.indexWhere((b) => b.kind == SourceBlockKind.table);
            if (idx < 0) return;
            widget.onChanged(
              MarkdownBlockSplitter.replaceBlock(
                widget.source,
                fresh[idx],
                tableSource,
              ),
            );
          },
          onEditSource: () => _startEdit(index, _blocks),
        ),
      );
    }

    final parsed = MarkdownParser.parse(block.source);
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _startEdit(index, blocks),
        // 不再吞内部手势:链接可点、代码复制可用、文字可拖选;
        // 点普通文字(无内部手势竞争)仍进入块编辑
        child: Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, b) in parsed.indexed)
                MarkdownBlockView(block: b, isFirst: i == 0),
            ],
          ),
        ),
      ),
    );
  }

  /// 就地源码编辑框(带所见即所得样式与回车续列表)
  Widget _buildBlockEditorField() {
    final isInsert = _insertPos != null;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _commit},
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.mutedSurfaceColor.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: AppTheme.brandColor.withValues(alpha: 0.45),
            width: 1,
          ),
        ),
        child: TextField(
          controller: _blockController,
          focusNode: _blockFocus,
          maxLines: null,
          inputFormatters: [MarkdownAutoContinueFormatter()],
          style: TextStyle(
            fontSize: 13.5,
            height: 1.65,
            color: AppTheme.bodyColor,
          ),
          cursorColor: AppTheme.brandColor,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: isInsert ? tr('写点什么…(Esc 完成)') : null,
            hintStyle: TextStyle(
              fontSize: 13.5,
              color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
            ),
          ),
          onTapOutside: (_) {
            _commit();
            _blockFocus.unfocus();
          },
        ),
      ),
    );
  }
}
