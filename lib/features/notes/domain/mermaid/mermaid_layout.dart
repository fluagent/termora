/// mermaid 图表排版(纯几何计算,不碰 Flutter 组件)。
///
/// flowchart 走精简版 Sugiyama:最长路径分层 → 重心排序 → 坐标微调;
/// sequenceDiagram 按步骤顺序自上而下堆叠。文字尺寸由调用方注入
/// ([MermaidTextSizer]),便于单测里用假测量函数跑。
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:termora/features/notes/domain/mermaid/mermaid_parser.dart';

/// 文本测量:返回给定字号/字重下的文本尺寸(支持 \n 多行)
typedef MermaidTextSizer = Size Function(String text, double fontSize, bool bold);

const double kMermaidNodeFontSize = 13;
const double kMermaidEdgeFontSize = 11;
const double kMermaidGroupFontSize = 11.5;

/// 标签折行宽度上限:笔记版心只有 760,单行长标签会把整张图撑爆
const double kMermaidLabelMaxWidth = 230;

// ══════════════ flowchart 排版结果 ══════════════

class MermaidNodeBox {
  const MermaidNodeBox({required this.node, required this.rect});
  final MermaidNode node;
  final Rect rect;
}

class MermaidEdgeRoute {
  const MermaidEdgeRoute({
    required this.points,
    required this.style,
    required this.arrow,
    this.label,
    this.labelCenter = Offset.zero,
    this.labelSize = Size.zero,
  });

  /// 折线顶点(≥2 个),最后一段的方向即箭头朝向
  final List<Offset> points;
  final MermaidLineStyle style;
  final bool arrow;
  final String? label;
  final Offset labelCenter;
  final Size labelSize;

  Rect get labelRect => Rect.fromCenter(
    center: labelCenter,
    width: labelSize.width + 8,
    height: labelSize.height + 4,
  );

  MermaidEdgeRoute shifted(Offset delta) => MermaidEdgeRoute(
    points: [for (final p in points) p + delta],
    style: style,
    arrow: arrow,
    label: label,
    labelCenter: labelCenter + delta,
    labelSize: labelSize,
  );
}

class MermaidGroupBox {
  const MermaidGroupBox({
    required this.title,
    required this.rect,
    required this.titleSize,
  });
  final String title;
  final Rect rect;
  final Size titleSize;
}

class MermaidFlowLayout {
  const MermaidFlowLayout({
    required this.size,
    required this.nodes,
    required this.edges,
    required this.groups,
  });

  final Size size;
  final List<MermaidNodeBox> nodes;
  final List<MermaidEdgeRoute> edges;
  final List<MermaidGroupBox> groups;
}

// ══════════════ sequenceDiagram 排版结果 ══════════════

class MermaidActorBox {
  const MermaidActorBox({required this.participant, required this.rect});
  final MermaidParticipant participant;
  final Rect rect;
  double get lifelineX => rect.center.dx;
}

class MermaidArrowLine {
  const MermaidArrowLine({
    required this.start,
    required this.end,
    required this.label,
    required this.labelSize,
    required this.dotted,
    required this.head,
    this.loopRect,
  });

  final Offset start;
  final Offset end;
  final String label;
  final Size labelSize;
  final bool dotted;
  final MermaidArrowHead head;

  /// 自己发给自己的消息:画在右侧的小回环
  final Rect? loopRect;
  bool get isSelf => loopRect != null;
}

class MermaidNoteBox {
  const MermaidNoteBox({
    required this.rect,
    required this.text,
    required this.textSize,
  });
  final Rect rect;
  final String text;
  final Size textSize;
}

class MermaidFrameDivider {
  const MermaidFrameDivider({
    required this.y,
    required this.label,
    required this.labelSize,
  });
  final double y;
  final String label;
  final Size labelSize;
}

class MermaidFrameBox {
  const MermaidFrameBox({
    required this.rect,
    required this.keyword,
    required this.title,
    required this.titleSize,
    required this.dividers,
  });
  final Rect rect;
  final String keyword;
  final String title;
  final Size titleSize;
  final List<MermaidFrameDivider> dividers;
}

class MermaidSequenceLayout {
  const MermaidSequenceLayout({
    required this.size,
    required this.actors,
    required this.arrows,
    required this.notes,
    required this.frames,
    required this.lifelineTop,
    required this.lifelineBottom,
  });

  final Size size;
  final List<MermaidActorBox> actors;
  final List<MermaidArrowLine> arrows;
  final List<MermaidNoteBox> notes;
  final List<MermaidFrameBox> frames;
  final double lifelineTop;
  final double lifelineBottom;
}

// ══════════════ 排版引擎 ══════════════

class MermaidLayoutEngine {
  MermaidLayoutEngine._();

  static const double _pad = 18;
  static const double _crossGap = 26;
  static const double _layerGap = 54;

  /// 商图(含 subgraph 复合节点)那层排得松一点,组框之间才有呼吸
  static const double _groupCrossGap = 42;
  static const double _groupLayerGap = 64;

  // ── flowchart ──

  /// 虚拟占位点尺寸:跨层连线在中间每一层占一个细槽,把通道让出来
  static const Size _dummySize = Size(8, 8);
  static const Size _terminalSize = Size(10, 10);

  /// 排 flowchart:subgraph 先各自排成一张小图,再折叠成复合节点参与外层排版,
  /// 最后展开回真实坐标 —— 这样组框天然互不重叠,也不会把组外节点圈进去。
  ///
  /// 跨层的连线(含出/入 subgraph 的连线)在途经的每一层都插一个虚拟节点占位,
  /// 于是线走的是卡片之间的空档,而不是从卡片上横穿过去。
  static MermaidFlowLayout layoutFlowchart(
    MermaidFlowchart chart,
    MermaidTextSizer sizer,
  ) {
    final nodeSizes = <String, Size>{
      for (final n in chart.nodes) n.id: _nodeSize(n, sizer),
    };
    final groupOf = {for (final n in chart.nodes) n.id: n.group};
    final groupMembers = <String, List<String>>{};
    for (final sg in chart.subgraphs) {
      final members = [
        for (final n in chart.nodes)
          if (n.group == sg.id) n.id,
      ];
      if (members.isNotEmpty) groupMembers[sg.id] = members;
    }

    String keyOf(String id) {
      final g = groupOf[id];
      return g != null && groupMembers.containsKey(g) ? g : id;
    }

    // ① 商图的层号先算一遍:用来判断跨组边的方向
    //    (回边不占通道,后面走外侧车道)
    final quotientIds = <String>[];
    for (final n in chart.nodes) {
      final key = keyOf(n.id);
      if (!quotientIds.contains(key)) quotientIds.add(key);
    }
    final quotientEdges = <(String, String)>[];
    final quotientIndexOf = <int, int>{};
    for (var i = 0; i < chart.edges.length; i++) {
      final a = keyOf(chart.edges[i].from);
      final b = keyOf(chart.edges[i].to);
      if (a == b) continue;
      quotientIndexOf[i] = quotientEdges.length;
      quotientEdges.add((a, b));
    }
    final quotientLayer = _assignLayers(quotientIds, quotientEdges);
    /// 跨组连线是顺着层序走(true)还是回头走(false):
    /// 决定终端吸在组的哪一边 —— 顺行从底边出、顶边进,回边反过来。
    bool crossesForward(int edgeIndex) {
      final qi = quotientIndexOf[edgeIndex];
      if (qi == null) return true;
      final (a, b) = quotientEdges[qi];
      return (quotientLayer[b] ?? 0) >= (quotientLayer[a] ?? 0);
    }

    // ② 组内小图:出/入组的连线用「终端」占位,在组内也留出通道
    final subRects = <String, Map<String, Rect>>{};
    final groupSize = <String, Size>{};
    final groupTitle = <String, Size>{};
    final groupInset = <String, Offset>{};
    final localExit = <int, List<Offset>>{};
    final localEntry = <int, List<Offset>>{};
    final localInner = <int, List<Offset>>{};
    for (final sg in chart.subgraphs) {
      final members = groupMembers[sg.id];
      if (members == null) continue;
      final inside = members.toSet();
      final ids = [...members];
      final sizes = {for (final id in members) id: nodeSizes[id]!};
      final edges = <(String, String)>[];
      final terminals = <String, bool>{};
      final edgeSlot = <int, int>{};
      final exitOf = <int, String>{};
      final entryOf = <int, String>{};
      final innerOf = <int, bool>{};
      for (var i = 0; i < chart.edges.length; i++) {
        final e = chart.edges[i];
        final fromIn = inside.contains(e.from);
        final toIn = inside.contains(e.to);
        if (fromIn && toIn) {
          if (e.from == e.to) continue;
          edgeSlot[i] = edges.length;
          innerOf[i] = true;
          edges.add((e.from, e.to));
          continue;
        }
        if (!(fromIn || toIn)) continue;
        final forward = crossesForward(i);
        if (fromIn) {
          final t = '#exit$i';
          ids.add(t);
          sizes[t] = _terminalSize;
          // 顺行从末层(底边)离开,回边从首层(顶边)离开
          terminals[t] = forward;
          edgeSlot[i] = edges.length;
          exitOf[i] = t;
          edges.add((e.from, t));
        } else {
          final t = '#entry$i';
          ids.add(t);
          sizes[t] = _terminalSize;
          terminals[t] = !forward;
          edgeSlot[i] = edges.length;
          entryOf[i] = t;
          edges.add((t, e.to));
        }
      }

      final placed = _placeNodes(
        ids,
        sizes,
        edges,
        chart.direction,
        terminals: terminals,
      );
      if (placed.rects.isEmpty) continue;
      var bbox = placed.rects.values.first;
      for (final r in placed.rects.values) {
        bbox = bbox.expandToInclude(r);
      }
      final title = sizer(sg.title, kMermaidGroupFontSize, true);
      // 上边多留标题的高度,其余三边等距
      final inset = Offset(14, 12 + title.height + 8);
      subRects[sg.id] = {
        for (final entry in placed.rects.entries)
          entry.key: entry.value.shift(-bbox.topLeft),
      };
      groupTitle[sg.id] = title;
      groupInset[sg.id] = inset;
      groupSize[sg.id] = Size(
        bbox.width + inset.dx * 2,
        bbox.height + inset.dy + 14,
      );

      // 组内通道点(此刻还是组内局部坐标,展开时再整体平移)
      Offset? terminalAt(String? id) {
        if (id == null) return null;
        final r = placed.rects[id];
        return r == null ? null : r.center - bbox.topLeft;
      }

      for (final entry in edgeSlot.entries) {
        final via = [
          for (final p in placed.waypoints[entry.value] ?? const <Offset>[])
            p - bbox.topLeft,
        ];
        final i = entry.key;
        if (innerOf[i] == true) {
          if (via.isNotEmpty) localInner[i] = via;
          continue;
        }
        final exit = terminalAt(exitOf[i]);
        if (exit != null) localExit[i] = [...via, exit];
        final entryPoint = terminalAt(entryOf[i]);
        if (entryPoint != null) localEntry[i] = [entryPoint, ...via];
      }
    }

    // ③ 商图:subgraph 折叠成一个复合节点,与组外节点一起排
    final quotient = _placeNodes(
      quotientIds,
      {for (final key in quotientIds) key: groupSize[key] ?? nodeSizes[key]!},
      quotientEdges,
      chart.direction,
      crossGap: _groupCrossGap,
      layerGap: _groupLayerGap,
    );

    // ④ 展开:组内成员与通道点随组框整体平移
    final rects = <String, Rect>{};
    final groups = <MermaidGroupBox>[];
    final memberBounds = <String, Rect>{};
    final groupOrigin = <String, Offset>{};
    for (final key in quotientIds) {
      final box = quotient.rects[key];
      if (box == null) continue;
      final members = subRects[key];
      if (members == null) {
        rects[key] = box;
        continue;
      }
      final origin = box.topLeft + groupInset[key]!;
      groupOrigin[key] = origin;
      Rect? inner;
      for (final entry in members.entries) {
        final rect = entry.value.shift(origin);
        rects[entry.key] = rect;
        inner = inner == null ? rect : inner.expandToInclude(rect);
      }
      if (inner != null) memberBounds[key] = inner;
      groups.add(
        MermaidGroupBox(
          title: chart.subgraphs.firstWhere((s) => s.id == key).title,
          titleSize: groupTitle[key]!,
          rect: box,
        ),
      );
    }
    if (rects.isEmpty) {
      return const MermaidFlowLayout(
        size: Size.zero,
        nodes: [],
        edges: [],
        groups: [],
      );
    }

    List<Offset> shifted(Map<int, List<Offset>> source, int i, String? group) {
      final points = source[i];
      final origin = group == null ? null : groupOrigin[group];
      if (points == null || origin == null) return const [];
      return [for (final p in points) p + origin];
    }

    // ⑤ 连线:通道点串成正交折线,回边也走通道(不再绕图外侧)
    final vertical = chart.direction.isVertical;
    var fullBounds = rects.values.first;
    for (final r in [...rects.values, ...groups.map((g) => g.rect)]) {
      fullBounds = fullBounds.expandToInclude(r);
    }

    final routes = <MermaidEdgeRoute>[];
    for (var i = 0; i < chart.edges.length; i++) {
      final e = chart.edges[i];
      final a = rects[e.from];
      final b = rects[e.to];
      if (a == null || b == null) continue;
      final labelSize = (e.label == null || e.label!.isEmpty)
          ? Size.zero
          : sizer(e.label!, kMermaidEdgeFontSize, false);
      final group = groupOf[e.from];

      if (e.from != e.to) {
        final qi = quotientIndexOf[i];
        final via = [
          ...shifted(localExit, i, group),
          if (qi != null) ...(quotient.waypoints[qi] ?? const <Offset>[]),
          ...shifted(localEntry, i, groupOf[e.to]),
          ...shifted(localInner, i, group),
        ];
        if (via.isNotEmpty) {
          routes.add(_routeThrough(e, a, b, vertical, labelSize, via));
          continue;
        }
      }

      routes.add(_routeEdge(e, a, b, vertical, labelSize));
    }

    // ⑥ 归一化:所有几何平移到 (pad, pad) 起点
    var bounds = fullBounds;
    for (final route in routes) {
      for (final p in route.points) {
        bounds = bounds.expandToInclude(Rect.fromCircle(center: p, radius: 2));
      }
      if (route.label != null) bounds = bounds.expandToInclude(route.labelRect);
    }
    final delta = Offset(_pad - bounds.left, _pad - bounds.top);

    return MermaidFlowLayout(
      size: Size(bounds.width + _pad * 2, bounds.height + _pad * 2),
      nodes: [
        for (final n in chart.nodes)
          if (rects[n.id] != null)
            MermaidNodeBox(node: n, rect: rects[n.id]!.shift(delta)),
      ],
      edges: [for (final r in routes) r.shifted(delta)],
      groups: [
        for (final g in groups)
          MermaidGroupBox(
            title: g.title,
            titleSize: g.titleSize,
            rect: g.rect.shift(delta),
          ),
      ],
    );
  }

  /// 一次分层排点的结果:节点矩形 + 每条边的途经点(按 from→to 顺序)
  static ({Map<String, Rect> rects, Map<int, List<Offset>> waypoints})
  _placeNodes(
    List<String> ids,
    Map<String, Size> sizes,
    List<(String, String)> edges,
    MermaidDirection direction, {
    double crossGap = _crossGap,
    double layerGap = _layerGap,
    Map<String, bool> terminals = const {},
  }) {
    if (ids.isEmpty) return (rects: <String, Rect>{}, waypoints: {});

    // 终端不参与分层,免得把真实节点挤到别的层
    final realIds = [
      for (final id in ids)
        if (!terminals.containsKey(id)) id,
    ];
    final layerOf = _assignLayers(realIds, [
      for (final (from, to) in edges)
        if (!terminals.containsKey(from) && !terminals.containsKey(to))
          (from, to),
    ]);
    var maxLayer = 0;
    for (final l in layerOf.values) {
      maxLayer = math.max(maxLayer, l);
    }
    // 出组的终端吸在末层(从底边离开),入组的吸在首层(从顶边进来)
    terminals.forEach((id, atEnd) => layerOf[id] = atEnd ? maxLayer : 0);

    // 终端和它的邻居同层时没有通道可留,直接丢掉,让连线照常直连
    final dropped = <String>{};
    for (final id in terminals.keys) {
      String? neighbour;
      for (final (from, to) in edges) {
        if (from == id) neighbour = to;
        if (to == id) neighbour = from;
      }
      if (neighbour == null || layerOf[neighbour] == layerOf[id]) {
        dropped.add(id);
      }
    }

    final placedIds = [
      for (final id in ids)
        if (!dropped.contains(id)) id,
    ];
    final workSizes = {for (final id in placedIds) id: sizes[id]!};
    final segments = <(String, String)>[];
    final chains = <int, List<String>>{};
    for (var i = 0; i < edges.length; i++) {
      final (from, to) = edges[i];
      if (dropped.contains(from) || dropped.contains(to)) continue;
      final lf = layerOf[from];
      final lt = layerOf[to];
      if (lf == null || lt == null) continue;
      // 同层与相邻层直连;跨层的(含回边)按行进方向逐层占位
      if ((lt - lf).abs() <= 1) {
        segments.add((from, to));
        continue;
      }
      final step = lt > lf ? 1 : -1;
      final dummies = <String>[];
      var prev = from;
      for (var l = lf + step; l != lt; l += step) {
        final dummy = '#d${i}_$l';
        placedIds.add(dummy);
        workSizes[dummy] = _dummySize;
        layerOf[dummy] = l;
        segments.add((prev, dummy));
        dummies.add(dummy);
        prev = dummy;
      }
      segments.add((prev, to));
      chains[i] = dummies;
    }

    final layerCount = placedIds.fold<int>(
      0,
      (m, id) => math.max(m, layerOf[id]! + 1),
    );
    final layers = List.generate(layerCount, (_) => <String>[]);
    for (final id in placedIds) {
      layers[layerOf[id]!].add(id);
    }

    final vertical = direction.isVertical;
    double crossSize(String id) =>
        vertical ? workSizes[id]!.width : workSizes[id]!.height;
    double layerSize(String id) =>
        vertical ? workSizes[id]!.height : workSizes[id]!.width;

    // 相邻关系按层序归一:低层 → 高层
    final preds = {for (final id in placedIds) id: <String>[]};
    final succs = {for (final id in placedIds) id: <String>[]};
    for (final (from, to) in segments) {
      final lf = layerOf[from];
      final lt = layerOf[to];
      if (lf == null || lt == null || lf == lt) continue;
      final (low, high) = lf < lt ? (from, to) : (to, from);
      succs[low]!.add(high);
      preds[high]!.add(low);
    }

    _orderLayers(layers, preds, succs);

    final crossPos = <String, double>{};
    for (final layer in layers) {
      var cursor = 0.0;
      for (final id in layer) {
        crossPos[id] = cursor;
        cursor += crossSize(id) + crossGap;
      }
    }
    // 交替上下扫,把节点拉到邻居中心附近再消重叠
    for (var sweep = 0; sweep < 4; sweep++) {
      final downward = sweep.isEven;
      final indices = downward
          ? [for (var l = 1; l < layerCount; l++) l]
          : [for (var l = layerCount - 2; l >= 0; l--) l];
      for (final l in indices) {
        final neighbors = downward ? preds : succs;
        final desired = <String, double>{};
        for (final id in layers[l]) {
          final ns = neighbors[id]!;
          if (ns.isEmpty) continue;
          var sum = 0.0;
          for (final n in ns) {
            sum += crossPos[n]! + crossSize(n) / 2;
          }
          desired[id] = sum / ns.length - crossSize(id) / 2;
        }
        _packLayer(layers[l], desired, crossPos, crossSize, crossGap);
      }
    }

    final layerExtent = [
      for (final layer in layers)
        layer.fold<double>(0, (m, id) => math.max(m, layerSize(id))),
    ];
    final layerStart = <double>[];
    var acc = 0.0;
    for (final extent in layerExtent) {
      layerStart.add(acc);
      acc += extent + layerGap;
    }
    final layerTotal = acc - layerGap;

    final rects = <String, Rect>{};
    for (var l = 0; l < layers.length; l++) {
      for (final id in layers[l]) {
        final s = workSizes[id]!;
        final along = layerStart[l] + (layerExtent[l] - layerSize(id)) / 2;
        final pos = direction.isReversed
            ? layerTotal - along - layerSize(id)
            : along;
        rects[id] = vertical
            ? Rect.fromLTWH(crossPos[id]!, pos, s.width, s.height)
            : Rect.fromLTWH(pos, crossPos[id]!, s.width, s.height);
      }
    }

    return (
      rects: rects,
      waypoints: {
        for (final entry in chains.entries)
          entry.key: [
            for (final d in entry.value)
              if (rects[d] != null) rects[d]!.center,
          ],
      },
    );
  }

  /// 串起通道点的正交折线:相邻两点若同时错开两轴,就在两层之间的空档拐弯
  static MermaidEdgeRoute _routeThrough(
    MermaidEdge edge,
    Rect a,
    Rect b,
    bool vertical,
    Size labelSize,
    List<Offset> through,
  ) {
    final raw = [
      _anchor(a, through.first, vertical),
      ...through,
      _anchor(b, through.last, vertical),
    ];
    final points = <Offset>[raw.first];
    for (var i = 1; i < raw.length; i++) {
      final prev = points.last;
      final next = raw[i];
      final dx = (next.dx - prev.dx).abs();
      final dy = (next.dy - prev.dy).abs();
      if (dx > 0.5 && dy > 0.5) {
        if (vertical) {
          final mid = (prev.dy + next.dy) / 2;
          points.add(Offset(prev.dx, mid));
          points.add(Offset(next.dx, mid));
        } else {
          final mid = (prev.dx + next.dx) / 2;
          points.add(Offset(mid, prev.dy));
          points.add(Offset(mid, next.dy));
        }
      }
      points.add(next);
    }
    final mid = points.length ~/ 2;
    return MermaidEdgeRoute(
      points: points,
      style: edge.style,
      arrow: edge.arrow,
      label: (edge.label?.isEmpty ?? true) ? null : edge.label,
      labelCenter: Offset.lerp(points[mid - 1], points[mid], 0.5)!,
      labelSize: labelSize,
    );
  }

  /// 朝着目标方向取矩形边上的出入点
  static Offset _anchor(Rect r, Offset toward, bool vertical) => vertical
      ? Offset(r.center.dx, toward.dy >= r.center.dy ? r.bottom : r.top)
      : Offset(toward.dx >= r.center.dx ? r.right : r.left, r.center.dy);

  static Size _nodeSize(MermaidNode node, MermaidTextSizer sizer) {
    final t = sizer(node.label, kMermaidNodeFontSize, false);
    return switch (node.shape) {
      MermaidNodeShape.circle => () {
        final d = math.max(math.max(t.width, t.height) + 34, 62.0);
        return Size(d, d);
      }(),
      MermaidNodeShape.rhombus => Size(
        math.max(t.width * 1.35 + 30, 88),
        math.max(t.height + 38, 62),
      ),
      MermaidNodeShape.hexagon => Size(
        math.max(t.width + 48, 78),
        math.max(t.height + 20, 40),
      ),
      MermaidNodeShape.stadium => Size(
        math.max(t.width + 38, 72),
        math.max(t.height + 20, 40),
      ),
      MermaidNodeShape.subroutine => Size(
        math.max(t.width + 40, 72),
        math.max(t.height + 20, 40),
      ),
      _ => Size(math.max(t.width + 30, 62), math.max(t.height + 20, 40)),
    };
  }

  /// 最长路径分层。先用 DFS 找出回边(环)剔除,保证是 DAG。
  static Map<String, int> _assignLayers(
    List<String> ids,
    List<(String, String)> edges,
  ) {
    final adj = <String, List<String>>{for (final id in ids) id: <String>[]};
    for (final (from, to) in edges) {
      if (from == to) continue;
      if (!adj.containsKey(from) || !adj.containsKey(to)) continue;
      adj[from]!.add(to);
    }

    // 0=未访问 1=在递归栈上 2=已完成;指向栈上节点的边即回边
    final state = <String, int>{for (final id in ids) id: 0};
    final back = <String>{};
    void visit(String u) {
      state[u] = 1;
      for (final v in adj[u]!) {
        if (state[v] == 1) {
          back.add('$u $v');
        } else if (state[v] == 0) {
          visit(v);
        }
      }
      state[u] = 2;
    }

    for (final id in ids) {
      if (state[id] == 0) visit(id);
    }

    final forward = <String, List<String>>{
      for (final id in ids) id: <String>[],
    };
    final indegree = <String, int>{for (final id in ids) id: 0};
    for (final (from, to) in edges) {
      if (from == to) continue;
      if (!forward.containsKey(from) || !forward.containsKey(to)) continue;
      if (back.contains('$from $to')) continue;
      forward[from]!.add(to);
      indegree[to] = indegree[to]! + 1;
    }

    final layer = <String, int>{for (final id in ids) id: 0};
    final queue = <String>[for (final id in ids) if (indegree[id] == 0) id];
    var head = 0;
    while (head < queue.length) {
      final u = queue[head++];
      for (final v in forward[u]!) {
        layer[v] = math.max(layer[v]!, layer[u]! + 1);
        indegree[v] = indegree[v]! - 1;
        if (indegree[v] == 0) queue.add(v);
      }
    }
    return layer;
  }

  /// 层内重心排序:按相邻层邻居的平均位置重排,减少连线交叉
  static void _orderLayers(
    List<List<String>> layers,
    Map<String, List<String>> preds,
    Map<String, List<String>> succs,
  ) {
    final index = <String, int>{};
    void reindex() {
      for (final layer in layers) {
        for (var i = 0; i < layer.length; i++) {
          index[layer[i]] = i;
        }
      }
    }

    reindex();
    for (var sweep = 0; sweep < 4; sweep++) {
      final downward = sweep.isEven;
      final order = downward
          ? [for (var l = 1; l < layers.length; l++) l]
          : [for (var l = layers.length - 2; l >= 0; l--) l];
      for (final l in order) {
        final neighbors = downward ? preds : succs;
        final keys = <String, double>{};
        for (var i = 0; i < layers[l].length; i++) {
          final id = layers[l][i];
          final ns = neighbors[id]!;
          if (ns.isEmpty) {
            keys[id] = i.toDouble();
          } else {
            var sum = 0.0;
            for (final n in ns) {
              sum += index[n]!.toDouble();
            }
            keys[id] = sum / ns.length;
          }
        }
        final original = {
          for (var i = 0; i < layers[l].length; i++) layers[l][i]: i,
        };
        final sorted = [...layers[l]];
        // Dart 的 sort 非稳定:显式用原下标兜底,保证结果可复现
        sorted.sort((a, b) {
          final byKey = keys[a]!.compareTo(keys[b]!);
          if (byKey != 0) return byKey;
          return original[a]!.compareTo(original[b]!);
        });
        layers[l] = sorted;
        reindex();
      }
    }
  }

  /// 先按期望位置从左往右摆(不重叠),再从右往左回拉贴近期望位置
  static void _packLayer(
    List<String> layer,
    Map<String, double> desired,
    Map<String, double> pos,
    double Function(String) sizeOf,
    double gap,
  ) {
    double? cursor;
    for (final id in layer) {
      var p = desired[id] ?? pos[id]!;
      if (cursor != null && p < cursor) p = cursor;
      pos[id] = p;
      cursor = p + sizeOf(id) + gap;
    }
    for (var i = layer.length - 2; i >= 0; i--) {
      final id = layer[i];
      final limit = pos[layer[i + 1]]! - gap - sizeOf(id);
      final want = math.max(desired[id] ?? pos[id]!, pos[id]!);
      final p = math.min(want, limit);
      if (p > pos[id]!) pos[id] = p;
    }
  }

  static MermaidEdgeRoute _routeEdge(
    MermaidEdge edge,
    Rect a,
    Rect b,
    bool vertical,
    Size labelSize,
  ) {
    final label = (edge.label?.isEmpty ?? true) ? null : edge.label;
    List<Offset> points;
    Offset labelCenter;

    if (edge.from == edge.to) {
      // 自环:右侧一圈小回环
      final y1 = a.center.dy - 8;
      final y2 = a.center.dy + 10;
      final x = a.right + 32;
      points = [Offset(a.right, y1), Offset(x, y1), Offset(x, y2), Offset(a.right, y2)];
      labelCenter = Offset(x + labelSize.width / 2 + 8, a.center.dy + 1);
      return MermaidEdgeRoute(
        points: points,
        style: edge.style,
        arrow: edge.arrow,
        label: label,
        labelCenter: labelCenter,
        labelSize: labelSize,
      );
    }

    if (vertical) {
      if ((a.center.dy - b.center.dy).abs() < 1) {
        // 同层:走水平直线
        final rightward = b.center.dx >= a.center.dx;
        final start = Offset(rightward ? a.right : a.left, a.center.dy);
        final end = Offset(rightward ? b.left : b.right, b.center.dy);
        points = [start, end];
        labelCenter = Offset.lerp(start, end, 0.5)!;
      } else {
        final downward = b.center.dy > a.center.dy;
        final start = Offset(a.center.dx, downward ? a.bottom : a.top);
        final end = Offset(b.center.dx, downward ? b.top : b.bottom);
        if ((start.dx - end.dx).abs() < 0.5) {
          points = [start, end];
          labelCenter = Offset.lerp(start, end, 0.5)!;
        } else {
          final mid = (start.dy + end.dy) / 2;
          points = [start, Offset(start.dx, mid), Offset(end.dx, mid), end];
          labelCenter = Offset((start.dx + end.dx) / 2, mid);
        }
      }
    } else {
      if ((a.center.dx - b.center.dx).abs() < 1) {
        final downward = b.center.dy >= a.center.dy;
        final start = Offset(a.center.dx, downward ? a.bottom : a.top);
        final end = Offset(b.center.dx, downward ? b.top : b.bottom);
        points = [start, end];
        labelCenter = Offset.lerp(start, end, 0.5)!;
      } else {
        final rightward = b.center.dx > a.center.dx;
        final start = Offset(rightward ? a.right : a.left, a.center.dy);
        final end = Offset(rightward ? b.left : b.right, b.center.dy);
        if ((start.dy - end.dy).abs() < 0.5) {
          points = [start, end];
          labelCenter = Offset.lerp(start, end, 0.5)!;
        } else {
          final mid = (start.dx + end.dx) / 2;
          points = [start, Offset(mid, start.dy), Offset(mid, end.dy), end];
          labelCenter = Offset(mid, (start.dy + end.dy) / 2);
        }
      }
    }

    return MermaidEdgeRoute(
      points: points,
      style: edge.style,
      arrow: edge.arrow,
      label: label,
      labelCenter: labelCenter,
      labelSize: labelSize,
    );
  }

  // ── sequenceDiagram ──

  static const double _actorGap = 46;
  static const double _seqFont = 11.5;

  static MermaidSequenceLayout layoutSequence(
    MermaidSequence diagram,
    MermaidTextSizer sizer,
  ) {
    final ids = [for (final p in diagram.participants) p.id];
    final index = {for (var i = 0; i < ids.length; i++) ids[i]: i};

    final boxes = <Size>[];
    var actorHeight = 34.0;
    for (final p in diagram.participants) {
      final t = sizer(p.label, _seqFont, true);
      final size = Size(math.max(t.width + 28, 88), math.max(t.height + 16, 34));
      actorHeight = math.max(actorHeight, size.height);
      boxes.add(size);
    }

    // 文字先量好:消息/备注的宽度决定参与者之间要拉开多远
    final stepText = [
      for (final step in diagram.steps)
        switch (step) {
          MermaidSeqMessage(:final text) =>
            text.isEmpty ? Size.zero : sizer(text, _seqFont, false),
          MermaidSeqNote(:final text) => sizer(text, _seqFont, false),
          MermaidSeqBlockOpen(:final title) =>
            title.isEmpty ? Size.zero : sizer(title, _seqFont, false),
          MermaidSeqBlockElse(:final title) =>
            title.isEmpty ? Size.zero : sizer(title, _seqFont, false),
          MermaidSeqBlockClose() => Size.zero,
        },
    ];

    final gaps = List<double>.filled(math.max(ids.length - 1, 0), _actorGap);
    var startX = _pad;
    List<double> centersOf() {
      final out = <double>[];
      var x = startX;
      for (var i = 0; i < boxes.length; i++) {
        out.add(x + boxes[i].width / 2);
        x += boxes[i].width + (i < gaps.length ? gaps[i] : 0);
      }
      return out;
    }

    // 迭代加宽:标签放不下就把它跨过的那几个间隙一起撑开
    for (var pass = 0; pass < 5; pass++) {
      final centers = centersOf();
      var changed = false;
      void widen(int lo, int hi, double need) {
        if (hi <= lo || hi >= centers.length) return;
        final available = centers[hi] - centers[lo];
        if (available >= need) return;
        final add = (need - available) / (hi - lo);
        for (var k = lo; k < hi; k++) {
          gaps[k] += add;
        }
        changed = true;
      }

      for (var s = 0; s < diagram.steps.length; s++) {
        final step = diagram.steps[s];
        final width = stepText[s].width;
        if (step is MermaidSeqMessage) {
          final i = index[step.from];
          final j = index[step.to];
          if (i == null || j == null) continue;
          if (i == j) {
            // 自环:右边要放得下回环加它的标签
            widen(i, i + 1, 42 + width + 20);
          } else {
            widen(math.min(i, j), math.max(i, j), width + 30);
          }
        } else if (step is MermaidSeqNote &&
            step.placement == MermaidNotePlacement.over &&
            step.participants.length > 1) {
          final xs = [
            for (final p in step.participants)
              if (index[p] != null) index[p]!,
          ];
          if (xs.length < 2) continue;
          widen(xs.reduce(math.min), xs.reduce(math.max), width + 30);
        }
      }
      if (!changed) break;
    }

    // 左置备注可能顶到画布外,提前把整体右推
    var extraLeft = 0.0;
    {
      final centers = centersOf();
      for (var s = 0; s < diagram.steps.length; s++) {
        final step = diagram.steps[s];
        if (step is! MermaidSeqNote ||
            step.placement != MermaidNotePlacement.leftOf) {
          continue;
        }
        final i = index[step.participants.first];
        if (i == null) continue;
        final need = stepText[s].width + 38;
        extraLeft = math.max(extraLeft, need - (centers[i] - _pad));
      }
    }
    startX = _pad + math.max(extraLeft, 0);

    final centers = centersOf();
    final actors = [
      for (var i = 0; i < diagram.participants.length; i++)
        MermaidActorBox(
          participant: diagram.participants[i],
          rect: Rect.fromLTWH(
            centers[i] - boxes[i].width / 2,
            _pad,
            boxes[i].width,
            boxes[i].height,
          ),
        ),
    ];
    double lifelineOf(String id) {
      final i = index[id];
      if (i != null) return centers[i];
      return centers.isEmpty ? startX : centers.first;
    }

    final lifelineTop = _pad + actorHeight;
    var y = lifelineTop + 18;
    var maxX = actors.isEmpty ? startX : actors.last.rect.right;

    final arrows = <MermaidArrowLine>[];
    final notes = <MermaidNoteBox>[];
    final closed = <_PendingFrame>[];
    final open = <_PendingFrame>[];

    for (var s = 0; s < diagram.steps.length; s++) {
      final step = diagram.steps[s];
      final ts = stepText[s];
      switch (step) {
        case MermaidSeqMessage(:final from, :final to, :final text):
          final fromX = lifelineOf(from);
          final toX = lifelineOf(to);
          if (from == to) {
            y += ts.height + 8;
            final loop = Rect.fromLTWH(fromX, y, 42, 26);
            arrows.add(
              MermaidArrowLine(
                start: loop.topLeft,
                end: Offset(fromX, loop.bottom),
                label: text,
                labelSize: ts,
                dotted: step.dotted,
                head: step.head,
                loopRect: loop,
              ),
            );
            maxX = math.max(maxX, loop.right + ts.width + 14);
            y += 26 + 18;
          } else {
            y += ts.height + 10;
            arrows.add(
              MermaidArrowLine(
                start: Offset(fromX, y),
                end: Offset(toX, y),
                label: text,
                labelSize: ts,
                dotted: step.dotted,
                head: step.head,
              ),
            );
            maxX = math.max(
              maxX,
              (fromX + toX) / 2 + ts.width / 2 + 8,
            );
            y += 22;
          }

        case MermaidSeqNote(:final placement, :final participants, :final text):
          final w = ts.width + 26;
          final h = ts.height + 16;
          final anchor = lifelineOf(participants.first);
          final rect = switch (placement) {
            MermaidNotePlacement.leftOf => Rect.fromLTWH(
              anchor - 12 - w,
              y,
              w,
              h,
            ),
            MermaidNotePlacement.rightOf => Rect.fromLTWH(anchor + 12, y, w, h),
            MermaidNotePlacement.over => () {
              final xs = [for (final p in participants) lifelineOf(p)];
              final left = xs.reduce(math.min);
              final right = xs.reduce(math.max);
              final span = math.max(right - left + 48, w);
              return Rect.fromLTWH((left + right) / 2 - span / 2, y, span, h);
            }(),
          };
          notes.add(MermaidNoteBox(rect: rect, text: text, textSize: ts));
          maxX = math.max(maxX, rect.right);
          y += h + 16;

        case MermaidSeqBlockOpen(:final keyword, :final title):
          open.add(
            _PendingFrame(
              keyword: keyword,
              title: title,
              titleSize: ts,
              top: y - 10,
              depth: open.length,
            ),
          );
          y += math.max(ts.height, 14) + 14;

        case MermaidSeqBlockElse(:final title):
          if (open.isEmpty) break;
          open.last.dividers.add(
            MermaidFrameDivider(y: y - 6, label: title, labelSize: ts),
          );
          y += math.max(ts.height, 14) + 12;

        case MermaidSeqBlockClose():
          if (open.isEmpty) break;
          final frame = open.removeLast();
          frame.bottom = y + 4;
          closed.add(frame);
          y += 16;
      }
    }

    final width = math.max(maxX + _pad, 240.0);
    // 框的左右边界取决于总宽度,故等步骤走完再按嵌套深度内缩生成
    final frames = [
      for (final f in closed)
        f.build(_pad / 2 + f.depth * 9, width - _pad / 2 - f.depth * 9),
    ];

    final bottom = y + 8;
    return MermaidSequenceLayout(
      size: Size(width, bottom + _pad),
      actors: actors,
      arrows: arrows,
      notes: notes,
      frames: frames,
      lifelineTop: lifelineTop,
      lifelineBottom: bottom,
    );
  }
}

/// 待闭合的框(loop/alt/…),`end` 时才知道底边
class _PendingFrame {
  _PendingFrame({
    required this.keyword,
    required this.title,
    required this.titleSize,
    required this.top,
    required this.depth,
  });

  final String keyword;
  final String title;
  final Size titleSize;
  final double top;
  final int depth;
  final List<MermaidFrameDivider> dividers = [];
  double bottom = 0;

  MermaidFrameBox build(double left, double right) => MermaidFrameBox(
    keyword: keyword,
    title: title,
    titleSize: titleSize,
    dividers: dividers,
    rect: Rect.fromLTRB(left, top, right, bottom),
  );
}
