// DbDataGrid 多行选择 + 拷贝 + 无限滚动的 widget 测试
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/features/database/view/widgets/db_data_grid.dart';

void main() {
  const output = DbQueryOutput(
    columns: ['id', 'name'],
    rows: [
      [1, 'alice'],
      [2, 'bob'],
      [3, 'carol'],
    ],
  );

  Future<void> pumpGrid(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DbDataGrid(output: output)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 捕获写入剪贴板的文本
  List<String> mockClipboard(WidgetTester tester) {
    final captured = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          captured.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return captured;
  }

  Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('单击选中某行,Ctrl+C 复制该行(TSV)', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    await tester.tap(find.text('bob'));
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.keyC);

    await tester.pump(const Duration(milliseconds: 350)); // 清掉双击识别器计时器
    expect(clip, isNotEmpty);
    expect(clip.last, '2\tbob');
  });

  testWidgets('Ctrl+A 全选后 Ctrl+C 复制所有行(TSV,每列 Tab 分隔)', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    // 先点一格让网格拿到焦点
    await tester.tap(find.text('alice'));
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.keyA);
    await ctrl(tester, LogicalKeyboardKey.keyC);

    await tester.pump(const Duration(milliseconds: 350)); // 清掉双击识别器计时器
    expect(clip.last, '1\talice\n2\tbob\n3\tcarol');
  });

  testWidgets('Shift 连选:选头尾之间的所有行', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    await tester.tap(find.text('alice')); // 锚点 = 第 1 行
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('carol')); // 连选到第 3 行
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.keyC);

    await tester.pump(const Duration(milliseconds: 350)); // 清掉双击识别器计时器
    expect(clip.last, '1\talice\n2\tbob\n3\tcarol');
  });

  testWidgets('Ctrl 加选:挑不连续的两行', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    await tester.tap(find.text('alice'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('carol'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.keyC);

    await tester.pump(const Duration(milliseconds: 350)); // 清掉双击识别器计时器
    expect(clip.last, '1\talice\n3\tcarol');
  });

  testWidgets('编辑单元格时 Ctrl+C 不拦截为复制整行', (tester) async {
    final clip = mockClipboard(tester);
    final edits = DbEditSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DbDataGrid(
            output: output,
            editable: true,
            edits: edits,
            onCellEdit: (_, _, _, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 先单击选中该行(与真实交互一致),再双击进入编辑
    await tester.tap(find.text('bob'));
    await tester.pump();
    await tester.tap(find.text('bob'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('bob'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget); // 已进入编辑

    await ctrl(tester, LogicalKeyboardKey.keyC);
    // 网格不应把它当「复制整行」写剪贴板(文本框自己的复制走系统通道,
    // 空选区时也不会写);更不能出现整行 TSV
    expect(clip.where((t) => t.contains('\t')), isEmpty);
  });

  testWidgets('按住拖动框选:从第 1 行拖到第 3 行选中全部', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    // 在第 1 行按下,拖到第 3 行,松开 → 选中 1..3
    final g = await tester.startGesture(
      tester.getCenter(find.text('alice')),
    );
    await tester.pump();
    await g.moveTo(tester.getCenter(find.text('bob')));
    await tester.pump();
    await g.moveTo(tester.getCenter(find.text('carol')));
    await tester.pump();
    await g.up();
    await tester.pump(const Duration(milliseconds: 350));

    await ctrl(tester, LogicalKeyboardKey.keyC);
    expect(clip.last, '1\talice\n2\tbob\n3\tcarol');
  });

  testWidgets('反向拖动(从下往上)同样选中区间', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    final g = await tester.startGesture(
      tester.getCenter(find.text('carol')),
    );
    await tester.pump();
    await g.moveTo(tester.getCenter(find.text('alice')));
    await tester.pump();
    await g.up();
    await tester.pump(const Duration(milliseconds: 350));

    await ctrl(tester, LogicalKeyboardKey.keyC);
    expect(clip.last, '1\talice\n2\tbob\n3\tcarol');
  });

  testWidgets('空表(0 行)仍渲染列头', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DbDataGrid(
            output: DbQueryOutput(columns: ['id', 'name', 'email'], rows: []),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 无数据行,但列头字段都在
    expect(find.text('id'), findsOneWidget);
    expect(find.text('name'), findsOneWidget);
    expect(find.text('email'), findsOneWidget);
  });

  testWidgets('底部状态条:hasMore 显示提示,loadingMore 显示加载中', (tester) async {
    Widget grid(bool loadingMore) => MaterialApp(
      home: Scaffold(
        body: DbDataGrid(
          output: const DbQueryOutput(
            columns: ['id'],
            rows: [
              [1],
            ],
          ),
          hasMore: true,
          loadingMore: loadingMore,
          onLoadMore: () async {},
        ),
      ),
    );
    await tester.pumpWidget(grid(false));
    await tester.pump();
    expect(find.text('下滑加载更多'), findsOneWidget);

    // loadingMore 有无限转圈的 CircularProgressIndicator,用 pump 而非 pumpAndSettle
    await tester.pumpWidget(grid(true));
    await tester.pump();
    expect(find.text('加载中…'), findsOneWidget);
  });

  testWidgets('滚动到底触发 onLoadMore', (tester) async {
    var calls = 0;
    final rows = [
      for (var i = 0; i < 200; i++) [i, 'v$i'],
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: DbDataGrid(
              output: DbQueryOutput(columns: const ['id', 'v'], rows: rows),
              hasMore: true,
              onLoadMore: () async => calls++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 用鼠标滚轮向下滚(拖动会被框选拦截,故走 scroll 事件)
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final center = tester.getCenter(find.byType(ListView));
    pointer.hover(center);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 6000)));
    await tester.pumpAndSettle();

    expect(calls, greaterThan(0));
  });

  testWidgets('无选择时 Ctrl+C 不写剪贴板', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    // 不点任何行,直接尝试复制(网格未必有焦点,也不应崩)
    await ctrl(tester, LogicalKeyboardKey.keyC);
    expect(clip, isEmpty);
  });
}
