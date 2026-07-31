import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/data/note_pdf_exporter.dart';
import 'package:termora/features/notes/domain/markdown_html_export.dart';
import 'package:termora/features/notes/domain/mermaid/mermaid_layout.dart';
import 'package:termora/features/notes/domain/mermaid/mermaid_parser.dart';
import 'package:termora/features/notes/view/widgets/markdown_preview.dart';
import 'package:termora/features/notes/view/widgets/mermaid_view.dart';

/// 假测量:每字 8px 宽、16px 行高,让排版断言与字体无关
Size fakeSizer(String text, double fontSize, bool bold) {
  final lines = text.split('\n');
  final widest = lines.fold<int>(0, (m, l) => l.length > m ? l.length : m);
  return Size(widest * 8.0, lines.length * 16.0);
}

MermaidFlowchart flow(String source) =>
    MermaidParser.tryParse(source) as MermaidFlowchart;

void main() {
  group('flowchart 解析', () {
    test('方向 + 形状 + 边标签', () {
      final chart = flow('''
graph TD
    A[开始] --> B{判断}
    B -->|是| C(执行)
    B -->|否| D([结束])
''');
      expect(chart.direction, MermaidDirection.topDown);
      expect(chart.nodes.map((n) => n.id), ['A', 'B', 'C', 'D']);
      expect(chart.nodes[0].label, '开始');
      expect(chart.nodes[1].shape, MermaidNodeShape.rhombus);
      expect(chart.nodes[2].shape, MermaidNodeShape.round);
      expect(chart.nodes[3].shape, MermaidNodeShape.stadium);
      expect(chart.edges, hasLength(3));
      expect(chart.edges[1].label, '是');
      expect(chart.edges[2].label, '否');
    });

    test('LR/RL/BT 方向与 flowchart 关键字', () {
      expect(flow('flowchart LR\nA-->B').direction, MermaidDirection.leftRight);
      expect(flow('graph RL\nA-->B').direction, MermaidDirection.rightLeft);
      expect(flow('graph BT\nA-->B').direction, MermaidDirection.bottomUp);
      // 不写方向默认 TD
      expect(flow('graph\nA-->B').direction, MermaidDirection.topDown);
    });

    test('中缀标签 `A -- 文本 --> B` 归一成带标签的边', () {
      final chart = flow('graph LR\nA -- 请求 --> B\nB -. 回包 .-> A');
      expect(chart.edges[0].label, '请求');
      expect(chart.edges[0].style, MermaidLineStyle.solid);
      expect(chart.edges[1].label, '回包');
      expect(chart.edges[1].style, MermaidLineStyle.dotted);
    });

    test('线型:点线/粗线/无箭头', () {
      final chart = flow('graph TD\nA-.->B\nB==>C\nC---D');
      expect(chart.edges[0].style, MermaidLineStyle.dotted);
      expect(chart.edges[1].style, MermaidLineStyle.thick);
      expect(chart.edges[2].style, MermaidLineStyle.solid);
      expect(chart.edges[2].arrow, isFalse);
      expect(chart.edges[0].arrow, isTrue);
    });

    test('链式与 & 并列展开成多条边', () {
      final chain = flow('graph TD\nA --> B --> C');
      expect(chain.edges.map((e) => '${e.from}${e.to}'), ['AB', 'BC']);

      final fanIn = flow('graph TD\nA & B --> C');
      expect(fanIn.edges.map((e) => '${e.from}${e.to}'), ['AC', 'BC']);
    });

    test('后出现的形状定义补全先前的裸引用', () {
      final chart = flow('graph TD\nA --> B\nB[补上标题]');
      expect(chart.nodes.map((n) => n.id), ['A', 'B']);
      expect(chart.nodes[1].label, '补上标题');
    });

    test('subgraph 归组,标题可带 id', () {
      final chart = flow('''
graph TD
    A --> B
    subgraph svc[服务层]
        B --> C
    end
''');
      expect(chart.subgraphs.single.id, 'svc');
      expect(chart.subgraphs.single.title, '服务层');
      expect(
        {for (final n in chart.nodes) n.id: n.group},
        {'A': null, 'B': 'svc', 'C': 'svc'},
      );
    });

    test('<br/> 转换行,引号被剥掉,样式语句忽略', () {
      final chart = flow('''
graph TD
    %% 注释
    A["第一行<br/>第二行"] --> B
    classDef done fill:#f00
    class A done
    style B fill:#0f0
''');
      expect(chart.nodes.first.label, '第一行\n第二行');
      expect(chart.nodes, hasLength(2));
    });

    test('不支持的图种与残缺语法回退 null', () {
      expect(MermaidParser.tryParse('pie title 占比\n"A" : 40'), isNull);
      expect(MermaidParser.tryParse('gantt\nsection A'), isNull);
      expect(MermaidParser.tryParse(''), isNull);
      // subgraph 未闭合
      expect(MermaidParser.tryParse('graph TD\nsubgraph x\nA-->B'), isNull);
    });
  });

  group('flowchart 排版', () {
    test('按边分层,层内不重叠,画布含内边距', () {
      final chart = flow('graph TD\nA[开始] --> B[中间] --> C[结束]');
      final layout = MermaidLayoutEngine.layoutFlowchart(chart, fakeSizer);
      final byId = {for (final n in layout.nodes) n.node.id: n.rect};
      expect(byId['A']!.bottom, lessThan(byId['B']!.top));
      expect(byId['B']!.bottom, lessThan(byId['C']!.top));
      expect(layout.size.width, greaterThan(byId['A']!.width));
      expect(layout.edges, hasLength(2));
      // 竖排连线自上而下
      expect(layout.edges.first.points.first.dy,
          lessThan(layout.edges.first.points.last.dy));
    });

    test('LR 走横向,层沿 x 递增', () {
      final layout = MermaidLayoutEngine.layoutFlowchart(
        flow('graph LR\nA --> B'),
        fakeSizer,
      );
      final byId = {for (final n in layout.nodes) n.node.id: n.rect};
      expect(byId['A']!.right, lessThan(byId['B']!.left));
    });

    test('BT 反向:目标节点在源节点上方', () {
      final layout = MermaidLayoutEngine.layoutFlowchart(
        flow('graph BT\nA --> B'),
        fakeSizer,
      );
      final byId = {for (final n in layout.nodes) n.node.id: n.rect};
      expect(byId['B']!.bottom, lessThan(byId['A']!.top));
    });

    test('同层兄弟节点左右排开不重叠', () {
      final layout = MermaidLayoutEngine.layoutFlowchart(
        flow('graph TD\nA --> B\nA --> C'),
        fakeSizer,
      );
      final byId = {for (final n in layout.nodes) n.node.id: n.rect};
      expect(byId['B']!.overlaps(byId['C']!), isFalse);
      expect(byId['B']!.top, byId['C']!.top);
    });

    test('成环不死循环,自环单独成路径', () {
      final cyclic = MermaidLayoutEngine.layoutFlowchart(
        flow('graph TD\nA --> B\nB --> C\nC --> A'),
        fakeSizer,
      );
      expect(cyclic.nodes, hasLength(3));
      expect(cyclic.edges, hasLength(3));

      final selfLoop = MermaidLayoutEngine.layoutFlowchart(
        flow('graph TD\nA --> A'),
        fakeSizer,
      );
      expect(selfLoop.edges.single.points, hasLength(4));
    });

    test('多个 subgraph 的组框互不重叠,也不圈进组外节点', () {
      final layout = MermaidLayoutEngine.layoutFlowchart(
        flow('''
graph TD
    subgraph a[组A]
        A1 --> A2
    end
    subgraph b[组B]
        B1 --> B2
    end
    A2 --> B1
    A2 --> X[组外]
'''),
        fakeSizer,
      );
      expect(layout.groups, hasLength(2));
      expect(layout.groups[0].rect.overlaps(layout.groups[1].rect), isFalse);
      final outsider = layout.nodes
          .firstWhere((n) => n.node.id == 'X')
          .rect;
      for (final group in layout.groups) {
        expect(group.rect.overlaps(outsider), isFalse);
      }
    });

    test('连线走卡片之间的通道,回边也不横穿卡片', () {
      final layout = MermaidLayoutEngine.layoutFlowchart(
        flow('''
graph TD
    subgraph app[应用层]
        UI[界面] --> Ctrl[控制器]
        Bridge[桥接] --> Ctrl
    end
    Ctrl --> Svc[服务]
    Svc --> Deep[更深一层]
    Deep --> IM[消息总线]
    IM --> Bridge
    UI --> Deep
'''),
        fakeSizer,
      );

      // 沿折线采样,不允许落进任何卡片内部(边界上是出入口,不算)
      final cards = [for (final n in layout.nodes) n.rect.deflate(3)];
      for (final edge in layout.edges) {
        for (var i = 1; i < edge.points.length; i++) {
          final from = edge.points[i - 1];
          final to = edge.points[i];
          final steps = (to - from).distance ~/ 2 + 1;
          for (var s = 0; s <= steps; s++) {
            final point = Offset.lerp(from, to, s / steps)!;
            for (final card in cards) {
              expect(
                card.contains(point),
                isFalse,
                reason: '连线经过 $point 落在卡片 $card 内部',
              );
            }
          }
        }
      }
    });

    test('分组框把成员整个圈进去', () {
      final layout = MermaidLayoutEngine.layoutFlowchart(
        flow('graph TD\nA --> B\nsubgraph g[组]\nB --> C\nend'),
        fakeSizer,
      );
      final group = layout.groups.single;
      for (final node in layout.nodes.where((n) => n.node.group == 'g')) {
        expect(group.rect.contains(node.rect.topLeft), isTrue);
        expect(group.rect.contains(node.rect.bottomRight), isTrue);
      }
    });
  });

  group('sequenceDiagram', () {
    MermaidSequence parse(String s) =>
        MermaidParser.tryParse(s) as MermaidSequence;

    test('参与者别名、消息线型与箭头', () {
      final seq = parse('''
sequenceDiagram
    participant C as 客户端
    participant S as 服务端
    C->>S: 请求
    S-->>C: 响应
    C-xS: 断开
''');
      expect(seq.participants.map((p) => p.label), ['客户端', '服务端']);
      final messages = seq.steps.whereType<MermaidSeqMessage>().toList();
      expect(messages, hasLength(3));
      expect(messages[0].text, '请求');
      expect(messages[0].dotted, isFalse);
      expect(messages[1].dotted, isTrue);
      expect(messages[1].head, MermaidArrowHead.filled);
      expect(messages[2].head, MermaidArrowHead.cross);
    });

    test('隐式参与者按首次出现建立', () {
      final seq = parse('sequenceDiagram\n  A->>B: hi');
      expect(seq.participants.map((p) => p.id), ['A', 'B']);
    });

    test('Note 与 loop/alt 块', () {
      final seq = parse('''
sequenceDiagram
    A->>B: 开始
    Note over A,B: 双方握手
    loop 每秒
        A->>B: 心跳
    end
    alt 成功
        B-->>A: ok
    else 失败
        B-->>A: err
    end
''');
      final note = seq.steps.whereType<MermaidSeqNote>().single;
      expect(note.placement, MermaidNotePlacement.over);
      expect(note.participants, ['A', 'B']);
      expect(
        seq.steps.whereType<MermaidSeqBlockOpen>().map((b) => b.keyword),
        ['loop', 'alt'],
      );
      expect(
        seq.steps.whereType<MermaidSeqBlockElse>().single.title,
        '失败',
      );
      expect(seq.steps.whereType<MermaidSeqBlockClose>(), hasLength(2));
    });

    test('块未闭合 / 无法识别的语句回退 null', () {
      expect(MermaidParser.tryParse('sequenceDiagram\nloop x\nA->>B: t'), isNull);
      expect(MermaidParser.tryParse('sequenceDiagram\n???'), isNull);
    });

    test('长消息标签把参与者间距撑开,不压到旁边的生命线', () {
      final layout = MermaidLayoutEngine.layoutSequence(
        parse('''
sequenceDiagram
    participant A
    participant B
    participant C
    A->>B: 短
    B->>C: 这是一条特别长的消息说明文字需要更宽的间距才放得下
    A->>A: 自调也要留出右侧空间
'''),
        fakeSizer,
      );
      final long = layout.arrows[1];
      expect(
        (long.end.dx - long.start.dx).abs(),
        greaterThanOrEqualTo(long.labelSize.width),
      );
      // 自环加标签不能越过右邻居的生命线
      final self = layout.arrows[2];
      expect(
        self.loopRect!.right + self.labelSize.width,
        lessThanOrEqualTo(layout.actors[1].lifelineX),
      );
      expect(layout.size.width, greaterThan(long.labelSize.width));
    });

    test('排版:生命线自上而下,消息按顺序下移', () {
      final layout = MermaidLayoutEngine.layoutSequence(
        parse('''
sequenceDiagram
    participant A
    participant B
    A->>B: 一
    B->>A: 二
    loop 循环
        A->>A: 自调
    end
'''),
        fakeSizer,
      );
      expect(layout.actors, hasLength(2));
      expect(layout.actors[0].rect.right, lessThan(layout.actors[1].rect.left));
      expect(layout.arrows, hasLength(3));
      expect(layout.arrows[0].start.dy, lessThan(layout.arrows[1].start.dy));
      expect(layout.arrows[2].isSelf, isTrue);
      final frame = layout.frames.single;
      expect(frame.keyword, 'loop');
      expect(frame.rect.top, lessThan(layout.arrows[2].start.dy));
      expect(frame.rect.bottom, greaterThan(layout.arrows[2].start.dy));
      expect(layout.lifelineBottom, greaterThan(layout.lifelineTop));
      expect(layout.size.height, greaterThan(layout.lifelineBottom));
    });
  });

  group('导出', () {
    test('HTML:mermaid 块交给 mermaid.js,普通代码块不受影响', () {
      final html = MarkdownHtmlExport.exportDocument(
        '标题',
        '```mermaid\ngraph TD\n    A --> B\n```',
      );
      expect(html, contains('<pre class="mermaid">graph TD'));
      expect(html, contains('mermaid.esm.min.mjs'));

      final plain = MarkdownHtmlExport.exportDocument(
        '标题',
        '```dart\nfinal a = 1;\n```',
      );
      expect(plain, contains('<pre><code class="language-dart">'));
      expect(plain, isNot(contains('mermaid.esm')));
    });

    testWidgets('PDF:mermaid 块以位图嵌入,渲染不了则保持代码块', (tester) async {
      await tester.runAsync(() async {
        const source = '```mermaid\ngraph TD\n    A[开始] --> B[结束]\n```';
        final diagram = MermaidParser.tryParse(
          'graph TD\n    A[开始] --> B[结束]',
        );
        final png = await renderMermaidPng(diagram!);
        expect(png, isNotNull);
        // PNG 魔数
        expect(png!.bytes.sublist(1, 4), [0x50, 0x4E, 0x47]);
        expect(png.size.width, greaterThan(0));

        final withDiagram = await NotePdfExporter.export(
          source,
          renderMermaid: (code) async {
            final d = MermaidParser.tryParse(code);
            return d == null ? null : renderMermaidPng(d);
          },
        );
        final asCode = await NotePdfExporter.export(source);
        expect(String.fromCharCodes(withDiagram.sublist(0, 4)), '%PDF');
        expect(String.fromCharCodes(asCode.sublist(0, 4)), '%PDF');
        expect(withDiagram.length, greaterThan(asCode.length));
      });
    });
  });

  group('预览接线', () {
    testWidgets('```mermaid 渲染成图,非法内容回退代码块', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(
              source: '```mermaid\ngraph TD\nA[开始] --> B[结束]\n```',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MermaidBlockView), findsOneWidget);
      // 图是自绘的:源码不应作为文本出现
      expect(find.textContaining('graph TD'), findsNothing);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(
              source: '```mermaid\npie title 占比\n"A" : 40\n```',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MermaidBlockView), findsNothing);
      expect(find.textContaining('pie title'), findsOneWidget);
    });
  });
}
