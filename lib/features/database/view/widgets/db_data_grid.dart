import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/widgets/glass_menu.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/features/database/view/widgets/cell_detail_dialog.dart';

/// 查询结果网格 — dbeaver 式累积编辑:
/// 双向滚动、斑马纹、行悬停、列分隔线;编辑写入 [edits] 缓冲(脏格高亮),
/// 支持标记删除行、新增行(绿底),行号槽点删除按钮切换删除。
class DbDataGrid extends StatefulWidget {
  const DbDataGrid({
    super.key,
    required this.output,
    this.editable = false,
    this.edits,
    this.onCellEdit,
    this.onToggleDelete,
    this.sortColumn,
    this.sortAscending = true,
    this.onHeaderTap,
    this.onHeaderFilter,
    this.filteredColumns = const {},
    this.hasMore = false,
    this.loadingMore = false,
    this.onLoadMore,
  });

  final DbQueryOutput output;

  /// 是否允许就地编辑(表有主键时)
  final bool editable;

  /// 累积编辑缓冲(null = 只读展示)
  final DbEditSession? edits;

  /// 提交单元格编辑到缓冲:(row, col, newValue, setNull)
  /// row >= output.rows.length 表示新增行
  final void Function(int row, int col, String? value, bool setNull)? onCellEdit;

  /// 切换某行的删除标记
  final void Function(int row)? onToggleDelete;

  /// 当前排序列与方向(表头显示箭头)
  final String? sortColumn;
  final bool sortAscending;

  /// 点击列头(排序);null 时表头不可点
  final void Function(String columnName)? onHeaderTap;

  /// 点击列头漏斗(过滤),带全局位置;null 时不显示漏斗
  final void Function(String columnName, Offset position)? onHeaderFilter;

  /// 已有过滤条件的列(漏斗高亮)
  final Set<String> filteredColumns;

  /// 还有更多数据可下滑加载(触发 [onLoadMore],底部显示提示)
  final bool hasMore;

  /// 正在加载下一页(底部转圈)
  final bool loadingMore;

  /// 滚动到底部时请求加载更多;null 时不启用无限滚动
  final Future<void> Function()? onLoadMore;

  @override
  State<DbDataGrid> createState() => _DbDataGridState();
}

class _DbDataGridState extends State<DbDataGrid> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();

  static const _rowHeight = 24.0;
  static const _headerHeight = 26.0;
  static const _rowNumberWidth = 44.0;
  static const _minColWidth = 70.0;
  static const _maxColWidth = 300.0;
  static const _cellPadding = EdgeInsets.symmetric(horizontal: 6);

  late List<double> _colWidths;
  int? _hoveredRow;

  // 行选择态(多选:点选替换 / Cmd·Ctrl 加选 / Shift 连选 / 按住拖动框选)
  final Set<int> _selectedRows = {};
  int? _selectionAnchor;
  final FocusNode _gridFocus = FocusNode();

  // 拖动框选态
  bool _dragSelecting = false;
  int? _dragAnchor;
  Set<int> _preDragSelection = const {};
  double _lastDragLocalY = 0;
  Timer? _autoScrollTimer;
  double _autoScrollDelta = 0;

  // 内联编辑态
  int? _editingRow;
  int? _editingCol;
  TextEditingController? _editController;
  final FocusNode _editFocus = FocusNode();

  /// 进入编辑时的原始文本/值 — 用于判断是否真的改动过(没改则不记入缓冲)
  String _editOriginalText = '';
  Object? _editOriginalValue;

  DbEditSession get _edits => widget.edits ?? DbEditSession();

  /// 新增行数量
  int get _addedCount => _edits.addedRows.length;

  /// 总显示行数 = 原始行 + 新增行
  int get _totalRows => widget.output.rows.length + _addedCount;

  /// 无限滚动:一次加载中的去重守卫(避免同一次滑动重复触发 onLoadMore)
  bool _loadMoreInFlight = false;

  @override
  void initState() {
    super.initState();
    _measureColumns();
    // 编辑框内的键盘导航:Tab/Enter 提交并移到相邻格,Esc 取消
    _editFocus.onKeyEvent = _handleEditKey;
    _vertical.addListener(_onScroll);
  }

  /// 滚动接近底部且还有更多 → 拉下一页
  void _onScroll() {
    if (widget.onLoadMore == null || !widget.hasMore || _loadMoreInFlight) {
      return;
    }
    if (!_vertical.hasClients) return;
    final pos = _vertical.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      _loadMoreInFlight = true;
      widget.onLoadMore!().whenComplete(() {
        if (mounted) _loadMoreInFlight = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant DbDataGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.output.columns.join(' ') !=
        widget.output.columns.join(' ')) {
      _measureColumns();
      _hoveredRow = null;
      _cancelEdit();
    }
    // 新增了行 → 自动滚到底并进入首列编辑,省去手动双击
    final oldAdded = oldWidget.edits?.addedRows.length ?? 0;
    final newAdded = widget.edits?.addedRows.length ?? 0;
    if (newAdded > oldAdded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final r = _totalRows - 1;
        _ensureRowVisible(r);
        _startEdit(r, 0);
      });
    }
    // 换了结果集(新查询/排序/过滤)→ 行下标失效,清空选择
    if (!identical(oldWidget.output, widget.output)) {
      _selectedRows.clear();
      _selectionAnchor = null;
    }
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _vertical.removeListener(_onScroll);
    _horizontal.dispose();
    _vertical.dispose();
    _editController?.dispose();
    _editFocus.dispose();
    _gridFocus.dispose();
    super.dispose();
  }

  void _measureColumns() {
    final output = widget.output;
    _colWidths = List.filled(output.columns.length, _minColWidth);
    for (var c = 0; c < output.columns.length; c++) {
      var maxChars = output.columns[c].length;
      for (var r = 0; r < output.rows.length && r < 30; r++) {
        final len = _cellText(output.rows[r][c]).length;
        if (len > maxChars) maxChars = len;
      }
      _colWidths[c] = (maxChars * 6.2 + 18).clamp(_minColWidth, _maxColWidth);
    }
  }

  void _autoFitColumn(int c) {
    final output = widget.output;
    var maxChars = output.columns[c].length;
    for (var r = 0; r < output.rows.length; r++) {
      final len = _cellText(output.rows[r][c]).length;
      if (len > maxChars) maxChars = len;
    }
    setState(() {
      _colWidths[c] = (maxChars * 6.2 + 18).clamp(30.0, 1500.0);
    });
  }

  static String _cellText(Object? value) {
    if (identical(value, DbEditSession.unsetValue)) return '';
    if (value == null) return 'NULL';
    if (value is DateTime) return value.toIso8601String();
    if (value is List<int>) return '<${value.length} bytes>';
    final text = value.toString();
    return text.length > 300 ? '${text.substring(0, 300)}…' : text;
  }

  /// 拷贝用的完整文本(不像 [_cellText] 那样截断到 300 字)
  static String _fullCellText(Object? value) {
    if (identical(value, DbEditSession.unsetValue)) return '';
    if (value == null) return 'NULL';
    if (value is DateTime) return value.toIso8601String();
    if (value is List<int>) return '<${value.length} bytes>';
    return value.toString();
  }

  double get _totalWidth =>
      _colWidths.fold(0.0, (a, b) => a + b) + _rowNumberWidth;

  TextStyle get _monoStyle => TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: const ['Consolas', 'monospace'],
    fontSize: 10.5,
    color: AppTheme.headingColor,
    height: 1.15,
  );

  BorderSide get _columnSeparator => BorderSide(
    color: AppTheme.borderColor.withValues(alpha: 0.45),
    width: 0.5,
  );

  /// 取某显示行、某列的当前值(叠加编辑缓冲)
  Object? _valueAt(int row, int col) {
    final originalCount = widget.output.rows.length;
    if (row >= originalCount) {
      return _edits.addedRows[row - originalCount][col];
    }
    return _edits.displayValue(row, col, widget.output.rows[row][col]);
  }

  bool _isAddedRow(int row) => row >= widget.output.rows.length;

  bool _isRemoved(int row) =>
      !_isAddedRow(row) && _edits.isRowRemoved(row);

  bool _isEditedCell(int row, int col) =>
      !_isAddedRow(row) && _edits.isCellEdited(row, col);

  // ── 行选择 / 拷贝 ──

  /// 点选一行:普通=替换选择;Cmd/Ctrl=切换加选;Shift=从锚点连选
  void _selectRow(int r) {
    final kb = HardwareKeyboard.instance;
    final additive = kb.isMetaPressed || kb.isControlPressed;
    final range = kb.isShiftPressed;
    setState(() {
      if (range && _selectionAnchor != null) {
        final a = _selectionAnchor!;
        final lo = a < r ? a : r;
        final hi = a < r ? r : a;
        if (!additive) _selectedRows.clear();
        for (var i = lo; i <= hi; i++) {
          _selectedRows.add(i);
        }
      } else if (additive) {
        if (!_selectedRows.remove(r)) _selectedRows.add(r);
        _selectionAnchor = r;
      } else {
        _selectedRows
          ..clear()
          ..add(r);
        _selectionAnchor = r;
      }
    });
    _gridFocus.requestFocus(); // 拿到焦点,Cmd/Ctrl+C 才能拦到
  }

  void _selectAll() {
    setState(() {
      _selectedRows
        ..clear()
        ..addAll([for (var i = 0; i < _totalRows; i++) i]);
      _selectionAnchor = 0;
    });
  }

  // ── 拖动框选(按住左键拖动跨行选择)──

  /// 纵向局部坐标 → 显示行下标(叠加滚动偏移),越界返回 null
  int? _rowAtLocalY(double dy) {
    if (!_vertical.hasClients) return null;
    final r = ((dy + _vertical.offset) / _rowHeight).floor();
    if (r < 0 || r >= _totalRows) return null;
    return r;
  }

  /// 选中 [_preDragSelection] ∪ [锚点..row] 区间(拖动实时更新)
  void _applyDragRange(int row) {
    final anchor = _dragAnchor;
    if (anchor == null) return;
    final lo = anchor < row ? anchor : row;
    final hi = anchor < row ? row : anchor;
    setState(() {
      _selectedRows
        ..clear()
        ..addAll(_preDragSelection);
      for (var i = lo; i <= hi; i++) {
        _selectedRows.add(i);
      }
    });
  }

  void _onSelectPointerDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return; // 仅左键起框选(右键留给菜单)
    final row = _rowAtLocalY(e.localPosition.dy);
    if (row == null) return;
    final kb = HardwareKeyboard.instance;
    final additive = kb.isMetaPressed || kb.isControlPressed;
    final range = kb.isShiftPressed;
    _gridFocus.requestFocus();
    setState(() => _dragSelecting = true); // 立即禁用拖动滚动,避免起手抖动

    if (range && _selectionAnchor != null) {
      // Shift:从既有锚点连选(拖动继续扩展)
      _dragAnchor = _selectionAnchor;
      _preDragSelection = const {};
      _applyDragRange(row);
    } else if (additive) {
      // Cmd/Ctrl:切换该行(可取消选中);拖动则在现有选区上叠加范围
      setState(() {
        if (!_selectedRows.remove(row)) _selectedRows.add(row);
      });
      _selectionAnchor = row;
      _dragAnchor = row;
      _preDragSelection = Set.of(_selectedRows);
    } else {
      // 普通:以本行为新锚点,替换选区(拖动扩展成范围)
      _selectionAnchor = row;
      _dragAnchor = row;
      _preDragSelection = const {};
      setState(() {
        _selectedRows
          ..clear()
          ..add(row);
      });
    }
  }

  void _onSelectPointerMove(PointerMoveEvent e) {
    if (!_dragSelecting) return;
    _lastDragLocalY = e.localPosition.dy;
    final row = _rowAtLocalY(e.localPosition.dy);
    if (row != null) _applyDragRange(row);
    _maybeAutoScroll(e.localPosition.dy);
  }

  void _endDrag([PointerEvent? _]) {
    _stopAutoScroll();
    if (_dragSelecting) setState(() => _dragSelecting = false);
  }

  /// 拖到视口上/下边缘时自动滚动并持续扩选
  void _maybeAutoScroll(double localY) {
    if (!_vertical.hasClients) return;
    const edge = 26.0;
    const step = 14.0;
    final vh = _vertical.position.viewportDimension;
    double delta = 0;
    if (localY < edge) {
      delta = -step;
    } else if (localY > vh - edge) {
      delta = step;
    }
    _autoScrollDelta = delta;
    if (delta == 0) {
      _stopAutoScroll();
      return;
    }
    _autoScrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_dragSelecting || !_vertical.hasClients) {
        _stopAutoScroll();
        return;
      }
      final target = (_vertical.offset + _autoScrollDelta).clamp(
        0.0,
        _vertical.position.maxScrollExtent,
      );
      if (target == _vertical.offset) return; // 到顶/底
      _vertical.jumpTo(target);
      final row = _rowAtLocalY(_lastDragLocalY);
      if (row != null) _applyDragRange(row);
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollDelta = 0;
  }

  /// 选中行拼成文本:tsv=Tab 分隔(粘进表格更稳),否则 CSV(RFC4180 转义)
  String _selectedText({required bool tsv}) {
    final indices = _selectedRows.toList()..sort();
    final cols = widget.output.columns.length;
    String cell(int r, int i) => _fullCellText(_valueAt(r, i));
    if (tsv) {
      return [
        for (final r in indices)
          [for (var i = 0; i < cols; i++) cell(r, i)].join('\t'),
      ].join('\n');
    }
    String esc(String s) =>
        (s.contains(',') ||
            s.contains('"') ||
            s.contains('\n') ||
            s.contains('\r'))
        ? '"${s.replaceAll('"', '""')}"'
        : s;
    return [
      for (final r in indices)
        [for (var i = 0; i < cols; i++) esc(cell(r, i))].join(','),
    ].join('\n');
  }

  void _copySelected({required bool tsv}) {
    if (_selectedRows.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _selectedText(tsv: tsv)));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(tr2('已复制 {0} 行', [_selectedRows.length])),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 网格快捷键:Cmd/Ctrl+C 复制选中行,Cmd/Ctrl+A 全选。
  /// 正在编辑单元格时不拦截——按键冒泡自编辑框,Cmd+C/A 应是文本框自己的
  /// 复制/全选,而不是复制整行。
  KeyEventResult _handleGridKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_editingRow != null) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    if (!(kb.isMetaPressed || kb.isControlPressed)) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      if (_selectedRows.isEmpty) return KeyEventResult.ignored;
      _copySelected(tsv: true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyA) {
      _selectAll();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── 编辑动作 ──

  void _startEdit(int row, int col) {
    if (!widget.editable || widget.onCellEdit == null) return;
    if (_isRemoved(row)) return;
    final value = _valueAt(row, col);
    final initialText = switch (value) {
      DbEditSession.unsetValue => '',
      null => '',
      DateTime dt => dt.toIso8601String(),
      _ => value.toString(),
    };
    _editController?.dispose();
    _editController = TextEditingController(text: initialText);
    _editOriginalText = initialText;
    _editOriginalValue = value;
    setState(() {
      _editingRow = row;
      _editingCol = col;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editFocus.requestFocus();
      _editController?.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _editController?.text.length ?? 0,
      );
    });
  }

  /// 大内容弹窗:舒展查看长文本/JSON,可编辑时改写保存或设为 NULL
  Future<void> _openCellDetail(int r, int c, Object? value) async {
    final canEdit =
        widget.editable && widget.onCellEdit != null && !_isRemoved(r);
    final editText = switch (value) {
      DbEditSession.unsetValue => '',
      null => '',
      DateTime dt => dt.toIso8601String(),
      _ => value.toString(),
    };
    final result = await showCellDetailDialog(
      context,
      column: widget.output.columns[c],
      value: editText,
      editable: canEdit,
      isNull: value == null,
    );
    if (result == null || !mounted || !canEdit) return;
    if (result.setNull) {
      widget.onCellEdit?.call(r, c, null, true);
    } else if (result.value != editText) {
      widget.onCellEdit?.call(r, c, result.value, false);
    }
  }

  void _cancelEdit() {
    if (_editingRow == null) return;
    setState(() {
      _editingRow = null;
      _editingCol = null;
    });
  }

  void _commitEdit({bool setNull = false}) {
    final row = _editingRow;
    final col = _editingCol;
    final controller = _editController;
    if (row == null || col == null || controller == null) return;
    final origText = _editOriginalText;
    final origValue = _editOriginalValue;
    _cancelEdit();

    if (setNull) {
      // 原本就是 NULL(且非"未设置")→ 无变化,不记改动
      if (origValue == null) return;
      widget.onCellEdit?.call(row, col, null, true);
      return;
    }
    // 值未变化(含新增行留空的格)→ 不产生改动
    if (controller.text == origText) return;
    widget.onCellEdit?.call(row, col, controller.text, false);
  }

  /// 编辑框内按键:Tab→右一格,Shift+Tab→左一格,Enter→下一行同列,Esc→取消
  KeyEventResult _handleEditKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _cancelEdit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      _commitAndMove(colDelta: shift ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _commitAndMove(rowDelta: 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 提交当前格并移动到相邻格继续编辑(越列自动换行)
  void _commitAndMove({int colDelta = 0, int rowDelta = 0}) {
    final row = _editingRow;
    final col = _editingCol;
    if (row == null || col == null) return;
    _commitEdit();

    var nc = col + colDelta;
    var nr = row + rowDelta;
    final cols = widget.output.columns.length;
    if (nc >= cols) {
      nc = 0;
      nr += 1;
    } else if (nc < 0) {
      nc = cols - 1;
      nr -= 1;
    }
    if (nr < 0 || nr >= _totalRows) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureRowVisible(nr);
      _startEdit(nr, nc);
    });
  }

  /// 确保某显示行在纵向视口内
  void _ensureRowVisible(int r) {
    if (!_vertical.hasClients) return;
    final target = r * _rowHeight;
    final start = _vertical.offset;
    final viewport = _vertical.position.viewportDimension;
    if (target < start) {
      _vertical.jumpTo(target.clamp(0.0, _vertical.position.maxScrollExtent));
    } else if (target + _rowHeight > start + viewport) {
      _vertical.jumpTo(
        (target + _rowHeight - viewport)
            .clamp(0.0, _vertical.position.maxScrollExtent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _gridFocus,
      onKeyEvent: _handleGridKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 内容比可视区窄时把宽度撑满:列仍靠左,但斑马纹/分隔线/选中底色
          // 铺满整条,不再留一段空白显得表格"悬浮居中"。
          final width = _totalWidth > constraints.maxWidth
              ? _totalWidth
              : constraints.maxWidth;
          return Scrollbar(
            controller: _horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Column(
                  children: [
                    _buildHeader(),
                    Expanded(
                      child: Listener(
                        onPointerDown: _onSelectPointerDown,
                        onPointerMove: _onSelectPointerMove,
                        onPointerUp: _endDrag,
                        onPointerCancel: _endDrag,
                        child: Scrollbar(
                          controller: _vertical,
                          child: ListView.builder(
                            controller: _vertical,
                            // 拖动框选期间禁用拖动滚动(改由边缘自动滚动驱动);
                            // 非拖动时正常,滚轮/触控板/滚动条照常。
                            physics: _dragSelecting
                                ? const NeverScrollableScrollPhysics()
                                : null,
                            itemExtent: _rowHeight,
                            itemCount: _totalRows,
                            itemBuilder: (context, r) => _buildRow(r),
                          ),
                        ),
                      ),
                    ),
                    if (widget.hasMore || widget.loadingMore) _buildLoadMoreBar(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 底部无限滚动状态条:加载中转圈,否则提示下滑加载更多
  Widget _buildLoadMoreBar() {
    return Container(
      height: 24,
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.subtleSurfaceColor,
        border: Border(top: BorderSide(color: AppTheme.borderColor, width: 1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.loadingMore) ...[
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: 7),
          ],
          Text(
            widget.loadingMore ? tr('加载中…') : tr('下滑加载更多'),
            style: TextStyle(
              fontSize: 10.5,
              color: AppTheme.subtleTextColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final output = widget.output;
    return Container(
      height: _headerHeight,
      decoration: BoxDecoration(
        color: AppTheme.subtleSurfaceColor,
        border: Border(
          bottom: BorderSide(color: AppTheme.borderColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: _rowNumberWidth,
            padding: _cellPadding,
            alignment: Alignment.centerRight,
            decoration: BoxDecoration(border: Border(right: _columnSeparator)),
            child: Text(
              '#',
              style: _monoStyle.copyWith(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.subtleTextColor,
              ),
            ),
          ),
          for (var c = 0; c < output.columns.length; c++)
            _buildHeaderCell(c, output.columns[c], _colWidths[c]),
        ],
      ),
    );
  }

  Widget _buildHeaderCell(int colIndex, String name, double width) {
    final sorted = widget.sortColumn == name;
    final filtered = widget.filteredColumns.contains(name);
    return Container(
      width: width,
      decoration: BoxDecoration(border: Border(right: _columnSeparator)),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(left: 6, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: widget.onHeaderTap == null
                          ? null
                          : () => widget.onHeaderTap!(name),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              overflow: TextOverflow.ellipsis,
                              style: _monoStyle.copyWith(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: sorted
                                    ? AppTheme.brandColor
                                    : AppTheme.headingColor,
                              ),
                            ),
                          ),
                          if (sorted) ...[
                            const SizedBox(width: 2),
                            Icon(
                              widget.sortAscending
                                  ? Icons.arrow_upward_rounded
                                  : Icons.arrow_downward_rounded,
                              size: 12,
                              color: AppTheme.brandColor,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (widget.onHeaderFilter != null)
                    _HeaderFilterButton(
                      active: filtered,
                      onPressed: (pos) => widget.onHeaderFilter!(name, pos),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => _autoFitColumn(colIndex),
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _colWidths[colIndex] =
                        (_colWidths[colIndex] + details.delta.dx).clamp(30.0, 1500.0);
                  });
                },
                child: Container(
                  width: 8,
                  color: Colors.transparent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(int r) {
    final row = _buildRowCells(r);
    final hovered = _hoveredRow == r;
    final added = _isAddedRow(r);
    final removed = _isRemoved(r);

    final selected = _selectedRows.contains(r);
    final Color background;
    if (removed) {
      background = AppTheme.errorColor.withValues(alpha: 0.10);
    } else if (added) {
      background = AppTheme.successColor.withValues(alpha: 0.10);
    } else if (selected) {
      background = AppTheme.brandColor.withValues(alpha: hovered ? 0.28 : 0.20);
    } else if (hovered) {
      background = AppTheme.softBrandColor.withValues(alpha: 0.55);
    } else if (r.isOdd) {
      background = AppTheme.mutedSurfaceColor;
    } else {
      background = AppTheme.surfaceColor;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredRow = r),
      onExit: (_) => setState(() {
        if (_hoveredRow == r) _hoveredRow = null;
      }),
      child: Container(color: background, child: Row(children: row)),
    );
  }

  List<Widget> _buildRowCells(int r) {
    final removed = _isRemoved(r);
    final added = _isAddedRow(r);
    final selected = _selectedRows.contains(r);
    return [
      // 行号槽 + 删除/恢复按钮(选中走 Listener 的按下/拖动;右键行菜单)
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) =>
            _showRowMenu(details.globalPosition, r),
        child: SizedBox(
        width: _rowNumberWidth,
        child: Row(
          children: [
            const SizedBox(width: 2),
            if (widget.editable && widget.onToggleDelete != null)
              InkWell(
                onTap: () => widget.onToggleDelete!(r),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    added
                        ? Icons.close_rounded
                        : (removed
                              ? Icons.undo_rounded
                              : Icons.remove_circle_outline_rounded),
                    size: 11,
                    color: removed || added
                        ? AppTheme.errorColor
                        : AppTheme.subtleTextColor.withValues(alpha: 0.55),
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  added ? '＋' : '${r + 1}',
                  textAlign: TextAlign.right,
                  style: _monoStyle.copyWith(
                    fontSize: 9.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected
                        ? AppTheme.brandColor
                        : AppTheme.subtleTextColor,
                  ),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
      for (var c = 0; c < widget.output.columns.length; c++)
        _buildCell(r, c),
    ];
  }

  Widget _buildCell(int r, int c) {
    if (_editingRow == r && _editingCol == c) {
      return _buildEditingCell(c);
    }

    final value = _valueAt(r, c);
    final isUnset = identical(value, DbEditSession.unsetValue);
    final isNull = value == null;
    final text = _cellText(value);
    final edited = _isEditedCell(r, c);
    final removed = _isRemoved(r);

    final bg = edited ? AppTheme.warningColor.withValues(alpha: 0.22) : null;

    return GestureDetector(
      // 选中走 Listener 的按下/拖动;双击:可编辑→内联编辑,只读→详情弹窗;
      // 右键菜单复制/查看
      onDoubleTap: widget.editable
          ? () => _startEdit(r, c)
          : () => _openCellDetail(r, c, value),
      onSecondaryTapDown: (details) =>
          _showCellMenu(details.globalPosition, r, c, value),
      child: Container(
        width: _colWidths[c],
        height: _rowHeight,
        padding: _cellPadding,
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: bg,
          border: Border(right: _columnSeparator),
        ),
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: (isNull || isUnset)
              ? _monoStyle.copyWith(
                  fontStyle: FontStyle.italic,
                  color: AppTheme.subtleTextColor.withValues(alpha: 0.65),
                  decoration: removed ? TextDecoration.lineThrough : null,
                )
              : _monoStyle.copyWith(
                  decoration: removed ? TextDecoration.lineThrough : null,
                  fontWeight: edited ? FontWeight.w600 : FontWeight.w400,
                ),
        ),
      ),
    );
  }

  Widget _buildEditingCell(int c) {
    // Tab/Enter/Esc 由 _editFocus.onKeyEvent 统一处理;点击别处提交
    return Container(
      width: _colWidths[c],
      height: _rowHeight,
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        border: Border.all(color: AppTheme.brandColor, width: 1.5),
      ),
      child: TextField(
        controller: _editController,
        focusNode: _editFocus,
        style: _monoStyle,
        textAlignVertical: TextAlignVertical.center,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 6),
        ),
        onTapOutside: (_) => _commitEdit(),
      ),
    );
  }

  void _showCellMenu(Offset position, int r, int c, Object? value) {
    // 右键的行若不在当前选择内,先把它单选(符合直觉:右键即作用于此行)
    if (!_selectedRows.contains(r)) _selectRow(r);
    final multi = _selectedRows.length > 1;
    showGlassMenu<String>(
      context: context,
      position: position,
      items: [
        _menuItem('detail', widget.editable ? tr('查看/编辑内容…') : tr('查看内容…')),
        _menuItem('copy', tr('复制值')),
        _menuItem('copy_row', tr('复制整行(CSV)')),
        if (multi) ...[
          const PopupMenuDivider(),
          _menuItem('copy_sel_tsv', tr2('复制选中 {0} 行(TSV)', [_selectedRows.length])),
          _menuItem('copy_sel_csv', tr2('复制选中 {0} 行(CSV)', [_selectedRows.length])),
        ],
        _menuItem('select_all', tr('全选')),
        if (widget.editable) ...[
          const PopupMenuDivider(),
          _menuItem('edit', tr('编辑')),
          _menuItem('set_null', tr('设为 NULL')),
          _menuItem(
            'delete',
            _isRemoved(r) ? tr('恢复此行') : tr('标记删除此行'),
          ),
        ],
      ],
    ).then((action) {
      if (action == null || !mounted) return;
      switch (action) {
        case 'detail':
          _openCellDetail(r, c, value);
        case 'copy':
          Clipboard.setData(ClipboardData(text: value?.toString() ?? ''));
        case 'copy_row':
          final cells = [
            for (var i = 0; i < widget.output.columns.length; i++)
              _fullCellText(_valueAt(r, i)),
          ];
          Clipboard.setData(ClipboardData(text: cells.join(',')));
        case 'copy_sel_tsv':
          _copySelected(tsv: true);
        case 'copy_sel_csv':
          _copySelected(tsv: false);
        case 'select_all':
          _selectAll();
        case 'edit':
          _startEdit(r, c);
        case 'set_null':
          widget.onCellEdit?.call(r, c, null, true);
        case 'delete':
          widget.onToggleDelete?.call(r);
      }
    });
  }

  /// 行号槽右键菜单:专注于「选中行」的复制
  void _showRowMenu(Offset position, int r) {
    if (!_selectedRows.contains(r)) _selectRow(r);
    final n = _selectedRows.length;
    showGlassMenu<String>(
      context: context,
      position: position,
      items: [
        _menuItem('copy_sel_tsv', tr2('复制选中 {0} 行(TSV)', [n])),
        _menuItem('copy_sel_csv', tr2('复制选中 {0} 行(CSV)', [n])),
        _menuItem('select_all', tr('全选')),
        if (widget.editable && widget.onToggleDelete != null)
          _menuItem(
            'delete',
            _isRemoved(r) ? tr('恢复此行') : tr('标记删除此行'),
          ),
      ],
    ).then((action) {
      if (action == null || !mounted) return;
      switch (action) {
        case 'copy_sel_tsv':
          _copySelected(tsv: true);
        case 'copy_sel_csv':
          _copySelected(tsv: false);
        case 'select_all':
          _selectAll();
        case 'delete':
          widget.onToggleDelete?.call(r);
      }
    });
  }

  PopupMenuItem<String> _menuItem(String value, String label) => PopupMenuItem(
    value: value,
    height: 36,
    child: Text(label, style: const TextStyle(fontSize: 13)),
  );
}

/// 列头漏斗过滤按钮 — 点击时把自身屏幕位置回传,便于在其下方弹出面板
class _HeaderFilterButton extends StatelessWidget {
  const _HeaderFilterButton({required this.active, required this.onPressed});

  final bool active;
  final void Function(Offset position) onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box == null
            ? Offset.zero
            : box.localToGlobal(box.size.bottomLeft(Offset.zero));
        onPressed(pos);
      },
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(
          active ? Icons.filter_alt_rounded : Icons.filter_alt_outlined,
          size: 13,
          color: active
              ? AppTheme.brandColor
              : AppTheme.subtleTextColor.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}
