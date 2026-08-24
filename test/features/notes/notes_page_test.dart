import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/features/notes/data/note_store.dart';
import 'package:termora/features/notes/view/notes_page.dart';
import 'package:termora/features/notes/view/widgets/block_editor.dart';
import 'package:termora/features/notes/view/widgets/markdown_editing_controller.dart';
import 'package:termora/features/notes/view/widgets/markdown_preview.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('termora_notes_page');
    NoteStore.debugDirectoryOverride = tempDir;
  });

  tearDown(() {
    NoteStore.debugDirectoryOverride = null;
    tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpNotesPage(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: NotesPage())),
      ),
    );
    // 等磁盘加载 + 视图模式恢复
    await tester.pumpAndSettle();
  }

  Finder editorField() => find.byWidgetPredicate(
    (w) => w is TextField && w.expands,
  );

  testWidgets('空状态提示 → 新建 → 编辑联动列表,预览渲染成品', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpNotesPage(tester);

    expect(find.textContaining('还没有笔记'), findsOneWidget);
    expect(find.textContaining('选择或新建一篇笔记'), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();
    expect(editorField(), findsOneWidget);
    expect(find.text('无标题笔记'), findsWidgets); // 列表项 + 顶栏标题

    await tester.enterText(editorField(), '# 周报\n\n本周完成 **联调**');
    // 吃掉落盘防抖(500ms)定时器
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    // 列表标题联动;默认编辑模式(所见即所得),无预览组件
    expect(find.text('周报'), findsWidgets);
    expect(find.byType(MarkdownPreview), findsNothing);

    // 切到预览:渲染出内容
    await tester.tap(find.byIcon(LucideIcons.eye));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownPreview), findsOneWidget);
    expect(find.textContaining('联调', findRichText: true), findsWidgets);
  });

  testWidgets('编辑/预览两态切换', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpNotesPage(tester);
    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();
    await tester.enterText(editorField(), '内容');
    await tester.pump(const Duration(milliseconds: 600));

    // 预览模式:编辑器消失
    await tester.tap(find.byIcon(LucideIcons.eye));
    await tester.pumpAndSettle();
    expect(editorField(), findsNothing);
    expect(find.byType(MarkdownPreview), findsOneWidget);

    // 编辑模式:预览消失
    await tester.tap(find.byIcon(LucideIcons.pencil));
    await tester.pumpAndSettle();
    expect(editorField(), findsOneWidget);
    expect(find.byType(MarkdownPreview), findsNothing);
  });

  testWidgets('选中文字浮现格式工具栏,收起选区后消失', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpNotesPage(tester);
    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();
    await tester.enterText(editorField(), '选中这些字加粗');
    await tester.pump(const Duration(milliseconds: 600));

    // 未选中:无浮动工具栏
    expect(find.byIcon(LucideIcons.bold), findsNothing);

    final field = tester.widget<TextField>(editorField());
    field.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 4,
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.bold), findsOneWidget);
    expect(find.byIcon(LucideIcons.removeFormatting), findsOneWidget);

    // 点加粗:选区被包裹,工具栏仍在(选区保持)
    await tester.tap(find.byIcon(LucideIcons.bold));
    await tester.pumpAndSettle();
    expect(field.controller!.text, startsWith('**选中这些**'));

    // 收起选区:工具栏消失
    field.controller!.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.bold), findsNothing);
  });

  testWidgets('插入菜单:插入表格模板', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpNotesPage(tester);
    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(LucideIcons.plus));
    await tester.pumpAndSettle();
    await tester.tap(find.text('表格'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(editorField());
    expect(field.controller!.text, contains('| 列1 | 列2 |'));
    await tester.pump(const Duration(milliseconds: 600)); // 落盘防抖
  });

  testWidgets('hover 列表项菜单:置顶后再删除', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpNotesPage(tester);
    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();
    await tester.enterText(editorField(), '# 要删的');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('要删的').first));
    await tester.pumpAndSettle();

    // 置顶:菜单操作后条目出现置顶图钉
    await tester.tap(find.byIcon(LucideIcons.ellipsisVertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.pin), findsOneWidget);

    // 删除(重新 hover 后走菜单 + 确认框)
    await gesture.moveTo(tester.getCenter(find.text('要删的').first));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.ellipsisVertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有笔记'), findsOneWidget);
  });

  testWidgets('装饰替换:非活动行列表符/引用符透明占位,有序编号保留', (tester) async {
    final controller = MarkdownEditingController();
    addTearDown(controller.dispose);
    controller.value = const TextEditingValue(
      text: '- 甲\n1. 乙\n> 引\n光标行',
      selection: TextSelection.collapsed(offset: 15), // 最后一行
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: TextField(controller: controller, maxLines: null),
        ),
      ),
    );
    final context = tester.element(find.byType(TextField));

    TextSpan? spanOf(String marker) {
      final root = controller.buildTextSpan(
        context: context,
        style: const TextStyle(),
        withComposing: false,
      );
      TextSpan? found;
      root.visitChildren((span) {
        if (span is TextSpan && span.text == marker) {
          found = span;
          return false;
        }
        return true;
      });
      return found;
    }

    // 无序符/引用符透明占位(宽度保留,由装饰层画符号)
    expect(spanOf('- ')!.style?.color, Colors.transparent);
    expect(spanOf('- ')!.style?.fontSize, isNull); // 保留原字号=保留宽度
    expect(spanOf('> ')!.style?.color, Colors.transparent);
    // 有序编号保留可见
    expect(spanOf('1. ')!.style?.color, isNot(Colors.transparent));

    // 光标移到列表行:符号显形
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    expect(spanOf('- ')!.style?.color, isNot(Colors.transparent));
  });

  testWidgets('所见即所得:非活动行记号隐藏,光标移入显形', (tester) async {
    final controller = MarkdownEditingController();
    addTearDown(controller.dispose);
    controller.value = const TextEditingValue(
      text: '**粗**\n第二行',
      selection: TextSelection.collapsed(offset: 9), // 光标在第二行
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: TextField(controller: controller, maxLines: null),
        ),
      ),
    );
    final context = tester.element(find.byType(TextField));

    List<TextSpan> spansOf(String marker) {
      final root = controller.buildTextSpan(
        context: context,
        style: const TextStyle(),
        withComposing: false,
      );
      final result = <TextSpan>[];
      root.visitChildren((span) {
        if (span is TextSpan && span.text == marker) result.add(span);
        return true;
      });
      return result;
    }

    // 光标在别的行:** 记号透明隐藏
    for (final s in spansOf('**')) {
      expect(s.style?.color, Colors.transparent);
    }

    // 光标移到粗体所在行:记号显形(非透明)
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();
    for (final s in spansOf('**')) {
      expect(s.style?.color, isNot(Colors.transparent));
    }
  });

  testWidgets('侧栏收缩:收起后列表不可交互,再点展开恢复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpNotesPage(tester);
    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();
    // 收起时侧栏被裁剪成 0 宽但保留在树中(保搜索词/滚动位置),用 hitTestable 断言
    final searchField = find
        .byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == '搜索笔记…',
        )
        .hitTestable();
    expect(searchField, findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.panelLeftClose));
    await tester.pumpAndSettle();
    expect(searchField, findsNothing);

    await tester.tap(find.byIcon(LucideIcons.panelLeftOpen));
    await tester.pumpAndSettle();
    expect(searchField, findsOneWidget);
  });

  testWidgets('查找替换:高亮计数、跳转、全部替换', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpNotesPage(tester);
    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();
    await tester.enterText(editorField(), '猫和猫还有猫');
    await tester.pump(const Duration(milliseconds: 600));

    // 打开查找条,输入查询词
    await tester.tap(find.byIcon(LucideIcons.textSearch));
    await tester.pumpAndSettle();
    final findField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '查找…',
    );
    await tester.enterText(findField, '猫');
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);

    // 下一个:计数步进(.last 避开插入菜单里的同款小箭头)
    await tester.tap(find.byIcon(LucideIcons.chevronDown).last);
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);

    // 全部替换
    final replaceField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '替换为…',
    );
    await tester.enterText(replaceField, '狗');
    await tester.tap(find.text('全部替换'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    final editor = tester.widget<TextField>(editorField());
    expect(editor.controller!.text, '狗和狗还有狗');
    expect(find.text('无结果'), findsOneWidget);

    // 等"已替换"toast 自动关闭(2s),它悬浮在右上角会挡住关闭按钮
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    // 关闭
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    expect(findField, findsNothing);
  });

  testWidgets('列表搜索命中后打开笔记:查找条自动带词、定位高亮', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpNotesPage(tester);

    // 笔记甲:正文里有两处搜索词
    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();
    await tester.enterText(editorField(), '# 甲\n\n压测报告与压测结论');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    // 笔记乙:不含搜索词,建完停在乙上
    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();
    await tester.enterText(editorField(), '# 乙\n\n无关内容');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    // 侧栏搜索:列表只剩笔记甲
    final searchField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '搜索笔记…',
    );
    await tester.enterText(searchField, '压测');
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget); // 只在列表项里(顶栏还是乙)

    // 点开命中的笔记:查找条自动展开并带上搜索词,定位到第一处
    await tester.tap(find.text('甲'));
    await tester.pumpAndSettle();

    final findField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '查找…',
    );
    expect(findField, findsOneWidget);
    expect(tester.widget<TextField>(findField).controller!.text, '压测');
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('大纲面板:列出标题,点击跳转光标', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpNotesPage(tester);
    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();
    const source = '# 第一章\n内容甲\n\n## 第二节\n内容乙';
    await tester.enterText(editorField(), source);
    await tester.pump(const Duration(milliseconds: 600));

    // 打开大纲(「第一章」还出现在列表和标题栏,数量只增不减)
    expect(find.text('第二节'), findsNothing);
    await tester.tap(find.byIcon(LucideIcons.tableOfContents));
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsWidgets);
    expect(find.text('第二节'), findsOneWidget);

    // 点"第二节"跳转:光标落到该标题行首
    await tester.tap(find.text('第二节'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(editorField());
    expect(
      field.controller!.selection.baseOffset,
      source.indexOf('## 第二节'),
    );
  });

  testWidgets('预览里点任务勾选框回调正确序号', (tester) async {
    final toggled = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(
            source: '- [ ] 甲\n- [x] 乙',
            onToggleTask: toggled.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(LucideIcons.squareCheck)); // 已勾选的"乙"
    await tester.tap(find.byIcon(LucideIcons.square)); // 未勾选的"甲"
    expect(toggled, [1, 0]);
  });

  testWidgets('块编辑器:真表格渲染,点击块就地改源码,失焦写回', (tester) async {
    String source = '段落甲\n\n| A | B |\n|---|---|\n| 1 | 2 |';
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => BlockEditor(
              source: source,
              onChanged: (s) => setState(() {
                source = s;
                changes.add(s);
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 表格块渲染成真实 Table 组件
    expect(find.byType(Table), findsOneWidget);
    expect(find.textContaining('段落甲', findRichText: true), findsOneWidget);

    // 点击段落块 → 就地源码编辑
    await tester.tap(find.textContaining('段落甲', findRichText: true));
    await tester.pumpAndSettle();
    final blockField = find.byType(TextField);
    expect(blockField, findsOneWidget);
    expect(tester.widget<TextField>(blockField).controller!.text, '段落甲');

    // 改内容,点表格单元格(失焦提交段落)→ 写回全文,进入单元格编辑
    await tester.enterText(blockField, '段落甲改');
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(source, startsWith('段落甲改'));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '1', // 单元格级编辑,不是整块源码
    );
  });

  testWidgets('块编辑器:文字可选择复制,点链接不误入编辑', (tester) async {
    String source = '看 [官网](https://a.io) 吧\n\n第二段';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => BlockEditor(
              source: source,
              onChanged: (s) => setState(() => source = s),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 跨块选择的载体存在
    expect(
      find.descendant(
        of: find.byType(BlockEditor),
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );

    // 点链接:内部手势赢,打开链接(测试平台走剪贴板),不进入块编辑
    await tester.tap(find.text('官网'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);

    // 点普通文字:仍进入块编辑
    await tester.tap(find.textContaining('第二段', findRichText: true));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '第二段',
    );
  });

  testWidgets('块拖拽排序:hover 出把手,拖动重排源码', (tester) async {
    String source = '甲\n\n乙\n\n丙';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => BlockEditor(
              source: source,
              onChanged: (s) => setState(() => source = s),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.gripVertical), findsNothing);

    // hover 第一块 → 把手浮现
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(
      tester.getCenter(find.textContaining('甲', findRichText: true)),
    );
    await tester.pumpAndSettle();
    final handle = find.byIcon(LucideIcons.gripVertical);
    expect(handle, findsOneWidget);

    // 向下拖 60px(测试行高小,跨过两块落到末尾)
    await tester.timedDrag(
      handle,
      const Offset(0, 60),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(source, '乙\n\n丙\n\n甲');
  });

  testWidgets('表格单元格编辑:改值 Tab 移格,尾格 Tab 加行', (tester) async {
    String source = '| A | B |\n|---|---|\n| 1 | 2 |';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => BlockEditor(
              source: source,
              onChanged: (s) => setState(() => source = s),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点单元格 1 → 就地编辑
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '1',
    );

    // 改成 99,Tab → 写回并移到下一格(B 列的 2)
    await tester.enterText(find.byType(TextField), '99');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(source, contains('| 99 | 2 |'));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '2',
    );

    // 尾格 Tab → 自动加一空行,编辑新行首格
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(source.split('\n'), hasLength(4)); // 表头+分隔+两行数据
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );

    // Esc 提交收起
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('块编辑器:方向键跨块、块首 Backspace 合并、空行回车起新块', (tester) async {
    String source = '甲\n\n乙';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => BlockEditor(
              source: source,
              onChanged: (s) => setState(() => source = s),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 进入第一块编辑
    await tester.tap(find.textContaining('甲', findRichText: true));
    await tester.pumpAndSettle();
    TextField field() => tester.widget<TextField>(find.byType(TextField));
    expect(field().controller!.text, '甲');

    // 末行按 ↓ → 移到下一块,光标在块首
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(field().controller!.text, '乙');
    expect(field().controller!.selection.baseOffset, 0);

    // 块首 Backspace → 与上一文本块合并,光标停在接缝
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(source, '甲\n乙');
    expect(field().controller!.text, '甲\n乙');
    expect(field().controller!.selection.baseOffset, 2);

    // 空行上按回车 → 跳出当前块,其后出现新块编辑框
    field().controller!.text = '甲\n乙\n';
    field().controller!.selection = const TextSelection.collapsed(offset: 4);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final insertField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '写点什么…(Esc 完成)',
    );
    expect(insertField, findsOneWidget);

    // 输入新块内容,Esc 提交追加
    await tester.enterText(insertField, '丙');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(source, '甲\n乙\n\n丙');
  });

  testWidgets('本地附件链接渲染成卡片:视频图标+缺失提示,普通网址仍是链接', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(
            source: '[演示.mp4](/tmp/termora不存在的附件.mp4)\n\n'
                '[官网](https://a.io)',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 视频附件卡片:类型图标 + 文件名 + 缺失提示
    expect(find.byIcon(LucideIcons.clapperboard), findsOneWidget);
    expect(find.text('演示.mp4'), findsOneWidget);
    expect(find.text('(文件缺失)'), findsOneWidget);
    // 普通 URL 不受影响,仍按链接渲染
    expect(find.text('官网'), findsOneWidget);
    expect(find.byIcon(LucideIcons.paperclip), findsNothing);
  });

  testWidgets('MarkdownPreview 渲染标题/代码块/列表/表格/公式', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(
            source: '# 大标题\n\n'
                '```dart\nfinal x = 1;\n```\n\n'
                '- [x] 完成项\n\n'
                '| 列A | 列B |\n|---|---|\n| 甲 | 乙 |\n\n'
                '> 引用一句\n\n'
                '\$\$E=mc^2\$\$',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('大标题', findRichText: true), findsOneWidget);
    // 语法高亮把整行拆成多个着色 span,按片段断言
    expect(find.textContaining('final', findRichText: true), findsOneWidget);
    expect(find.text('dart'), findsOneWidget); // 代码块语言标签
    expect(find.byIcon(LucideIcons.copy), findsOneWidget);
    expect(find.byIcon(LucideIcons.squareCheck), findsOneWidget);
    expect(find.textContaining('列A', findRichText: true), findsOneWidget);
    expect(find.textContaining('引用一句', findRichText: true), findsOneWidget);
    expect(find.byType(Math), findsOneWidget); // LaTeX 公式块
  });

  testWidgets('窄屏幕下工具栏正常折叠不溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 450, // 450 - 260(sidebar) = 190 workspace width
              height: 400,
              child: NotesPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pumpAndSettle();

    expect(find.text('无标题笔记'), findsWidgets);

    // 窄屏下按钮可能滚出标题栏可视区,先滚进来再点
    await tester.ensureVisible(find.byIcon(LucideIcons.textSearch));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.textSearch));
    await tester.pumpAndSettle();
    expect(find.text('替换'), findsOneWidget);
  });
}

