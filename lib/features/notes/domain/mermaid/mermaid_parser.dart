/// mermaid 图表解析(纯 Dart 自研子集)。
///
/// 只覆盖笔记里最常用的两类:flowchart(graph TD/LR…)与 sequenceDiagram。
/// 任何解析不了的图种或语法一律返回 null,调用方回退成代码块原样展示 ——
/// 宁可显示源码,也不画一张缺胳膊少腿的图。
library;

// ══════════════ 通用模型 ══════════════

enum MermaidDirection { topDown, bottomUp, leftRight, rightLeft }

extension MermaidDirectionX on MermaidDirection {
  /// 层轴是否竖直(TD/BT);LR/RL 为水平
  bool get isVertical =>
      this == MermaidDirection.topDown || this == MermaidDirection.bottomUp;

  /// 层序是否沿轴反向(BT/RL)
  bool get isReversed =>
      this == MermaidDirection.bottomUp || this == MermaidDirection.rightLeft;
}

/// 节点形状。解析时把同类近似形状(平行四边形/梯形等)归并到最近的一种。
enum MermaidNodeShape {
  rect,
  round,
  stadium,
  circle,
  rhombus,
  hexagon,
  subroutine,
}

enum MermaidLineStyle { solid, dotted, thick }

sealed class MermaidDiagram {
  const MermaidDiagram();
}

// ══════════════ flowchart 模型 ══════════════

class MermaidNode {
  MermaidNode({
    required this.id,
    required this.label,
    this.shape = MermaidNodeShape.rect,
    this.group,
  });

  final String id;
  String label;
  MermaidNodeShape shape;

  /// 所属 subgraph 的 id;null = 不在任何分组里
  String? group;

  /// 只写了 id(未带形状括号)的引用不覆盖已有定义
  bool defined = false;

  @override
  String toString() => 'MermaidNode($id, "$label", ${shape.name})';
}

class MermaidEdge {
  const MermaidEdge({
    required this.from,
    required this.to,
    this.label,
    this.style = MermaidLineStyle.solid,
    this.arrow = true,
  });

  final String from;
  final String to;
  final String? label;
  final MermaidLineStyle style;

  /// 终点是否有箭头(`---` 这类无箭头连线为 false)
  final bool arrow;

  @override
  String toString() =>
      'MermaidEdge($from->$to${label == null ? '' : ' "$label"'})';
}

class MermaidSubgraph {
  const MermaidSubgraph({required this.id, required this.title});
  final String id;
  final String title;
}

class MermaidFlowchart extends MermaidDiagram {
  const MermaidFlowchart({
    required this.direction,
    required this.nodes,
    required this.edges,
    this.subgraphs = const [],
  });

  final MermaidDirection direction;
  final List<MermaidNode> nodes;
  final List<MermaidEdge> edges;
  final List<MermaidSubgraph> subgraphs;
}

// ══════════════ sequenceDiagram 模型 ══════════════

enum MermaidArrowHead { open, filled, cross, async }

enum MermaidNotePlacement { leftOf, rightOf, over }

class MermaidParticipant {
  const MermaidParticipant({
    required this.id,
    required this.label,
    this.actor = false,
  });

  final String id;
  final String label;

  /// `actor X` 声明的参与者(画小人而非方框)
  final bool actor;
}

sealed class MermaidSeqStep {
  const MermaidSeqStep();
}

class MermaidSeqMessage extends MermaidSeqStep {
  const MermaidSeqMessage({
    required this.from,
    required this.to,
    required this.text,
    this.dotted = false,
    this.head = MermaidArrowHead.filled,
  });

  final String from;
  final String to;
  final String text;
  final bool dotted;
  final MermaidArrowHead head;
}

class MermaidSeqNote extends MermaidSeqStep {
  const MermaidSeqNote({
    required this.placement,
    required this.participants,
    required this.text,
  });

  final MermaidNotePlacement placement;
  final List<String> participants;
  final String text;
}

/// loop / alt / opt / par / critical / break / rect 的开框
class MermaidSeqBlockOpen extends MermaidSeqStep {
  const MermaidSeqBlockOpen({required this.keyword, required this.title});
  final String keyword;
  final String title;
}

/// alt 的 else 分支、par 的 and 分支
class MermaidSeqBlockElse extends MermaidSeqStep {
  const MermaidSeqBlockElse(this.title);
  final String title;
}

class MermaidSeqBlockClose extends MermaidSeqStep {
  const MermaidSeqBlockClose();
}

class MermaidSequence extends MermaidDiagram {
  const MermaidSequence({required this.participants, required this.steps});
  final List<MermaidParticipant> participants;
  final List<MermaidSeqStep> steps;
}

// ══════════════ 解析器 ══════════════

class MermaidParser {
  MermaidParser._();

  /// 解析 mermaid 源码;不支持则返回 null(调用方回退代码块)
  static MermaidDiagram? tryParse(String source) {
    try {
      final lines = _cleanLines(source);
      if (lines.isEmpty) return null;
      final head = lines.first;
      if (RegExp(r'^sequenceDiagram\b').hasMatch(head)) {
        return _parseSequence(lines.sublist(1));
      }
      final flow = RegExp(
        r'^(?:graph|flowchart)(?:\s+(TB|TD|BT|LR|RL))?$',
        caseSensitive: false,
      ).firstMatch(head);
      if (flow != null) {
        return _parseFlowchart(_direction(flow[1]), lines.sublist(1));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static MermaidDirection _direction(String? token) =>
      switch (token?.toUpperCase()) {
        'BT' => MermaidDirection.bottomUp,
        'LR' => MermaidDirection.leftRight,
        'RL' => MermaidDirection.rightLeft,
        _ => MermaidDirection.topDown,
      };

  /// 去注释/指令/空行,按 `;` 拆句,统一 trim
  static List<String> _cleanLines(String source) {
    final out = <String>[];
    for (final raw in source.replaceAll('\r\n', '\n').split('\n')) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      // %%{init: …}%% 指令与 %% 整行注释
      if (line.startsWith('%%')) continue;
      for (final part in line.split(';')) {
        final s = part.trim();
        if (s.isNotEmpty) out.add(s);
      }
    }
    return out;
  }

  /// 标签清洗:去引号、<br> 转换行、常见 HTML 实体还原
  static String _label(String raw) {
    var s = raw.trim();
    if (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith("'") && s.endsWith("'")))) {
      s = s.substring(1, s.length - 1);
    }
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('#quot;', '"');
    return s.trim();
  }

  // ── flowchart ──

  /// 可安全忽略的样式类语句(不影响拓扑)
  static final _ignorableRe = RegExp(
    r'^(classDef|class|style|linkStyle|click|direction|accTitle|accDescr)\b',
  );

  static final _subgraphRe = RegExp(r'^subgraph\s+(.*)$');

  /// 连线记号:点线 / 实线 / 粗线,可带 `|标签|`
  static final _linkRe = RegExp(
    r'<?(-\.+->|-\.+-|-{2,}>|-{2,}[xo]|-{3,}|={2,}>|={3,})(?:\|([^|]*)\|)?',
  );

  static final _nodeIdRe = RegExp(r'^([A-Za-z0-9_.一-龥-]+)\s*(.*)$');

  /// 形状括号表(长记号在前,避免 `[` 抢走 `[[`)
  static const _shapeTokens = <(String, String, MermaidNodeShape)>[
    ('((', '))', MermaidNodeShape.circle),
    ('([', '])', MermaidNodeShape.stadium),
    ('[[', ']]', MermaidNodeShape.subroutine),
    ('{{', '}}', MermaidNodeShape.hexagon),
    ('[/', '/]', MermaidNodeShape.rect),
    ('[/', r'\]', MermaidNodeShape.rect),
    (r'[\', '/]', MermaidNodeShape.rect),
    (r'[\', r'\]', MermaidNodeShape.rect),
    ('[(', ')]', MermaidNodeShape.stadium),
    ('[', ']', MermaidNodeShape.rect),
    ('(', ')', MermaidNodeShape.round),
    ('{', '}', MermaidNodeShape.rhombus),
    ('>', ']', MermaidNodeShape.rect),
  ];

  static MermaidFlowchart? _parseFlowchart(
    MermaidDirection direction,
    List<String> lines,
  ) {
    final nodes = <String, MermaidNode>{};
    final order = <String>[];
    final edges = <MermaidEdge>[];
    final subgraphs = <MermaidSubgraph>[];
    final groupStack = <String>[];
    var anonymousGroup = 0;

    MermaidNode? register(MermaidNode parsed) {
      final existing = nodes[parsed.id];
      if (existing == null) {
        parsed.group ??= groupStack.isEmpty ? null : groupStack.last;
        nodes[parsed.id] = parsed;
        order.add(parsed.id);
        return parsed;
      }
      // 后出现的形状定义覆盖早先的裸引用
      if (parsed.defined && !existing.defined) {
        existing.label = parsed.label;
        existing.shape = parsed.shape;
        existing.defined = true;
      }
      existing.group ??= groupStack.isEmpty ? null : groupStack.last;
      return existing;
    }

    for (final line in lines) {
      if (_ignorableRe.hasMatch(line)) continue;

      final sg = _subgraphRe.firstMatch(line);
      if (sg != null) {
        final rest = sg[1]!.trim();
        // `subgraph id[标题]` / `subgraph 标题`
        final withTitle = RegExp(r'^(\S+)\s*\[(.*)\]$').firstMatch(rest);
        final id = withTitle != null
            ? withTitle[1]!
            : (rest.isEmpty ? 'sg${anonymousGroup++}' : rest);
        final title = _label(withTitle != null ? withTitle[2]! : rest);
        subgraphs.add(MermaidSubgraph(id: id, title: title));
        groupStack.add(id);
        continue;
      }
      if (line == 'end') {
        if (groupStack.isEmpty) return null;
        groupStack.removeLast();
        continue;
      }

      if (!_parseFlowStatement(line, register, edges)) return null;
    }

    if (groupStack.isNotEmpty || nodes.isEmpty) return null;
    return MermaidFlowchart(
      direction: direction,
      nodes: [for (final id in order) nodes[id]!],
      edges: edges,
      subgraphs: subgraphs,
    );
  }

  /// 解析一条连线/节点声明语句。无法识别返回 false(整图回退)。
  static bool _parseFlowStatement(
    String line,
    MermaidNode? Function(MermaidNode) register,
    List<MermaidEdge> edges,
  ) {
    final normalized = _normalizeLinkLabels(line);
    final links = _linkRe.allMatches(normalized).toList();

    if (links.isEmpty) {
      final group = _parseNodeGroup(normalized);
      if (group == null || group.isEmpty) return false;
      for (final node in group) {
        register(node);
      }
      return true;
    }

    var cursor = 0;
    List<MermaidNode>? previous;
    // 连接用的是「本段之前」的那条线,不是刚扫到的这条
    RegExpMatch? pending;
    for (final link in links) {
      final segment = normalized.substring(cursor, link.start);
      final group = _parseNodeGroup(segment);
      if (group == null || group.isEmpty) return false;
      final registered = [for (final n in group) register(n)!];
      if (previous != null && pending != null) {
        _connect(edges, previous, registered, pending);
      }
      previous = registered;
      pending = link;
      cursor = link.end;
    }
    final tail = _parseNodeGroup(normalized.substring(cursor));
    if (tail == null || tail.isEmpty) return false;
    final registered = [for (final n in tail) register(n)!];
    _connect(edges, previous!, registered, pending!);
    return true;
  }

  static void _connect(
    List<MermaidEdge> edges,
    List<MermaidNode> from,
    List<MermaidNode> to,
    RegExpMatch link,
  ) {
    final token = link[1]!;
    final label = link[2] == null ? null : _label(link[2]!);
    final style = token.contains('.')
        ? MermaidLineStyle.dotted
        : (token.startsWith('=')
              ? MermaidLineStyle.thick
              : MermaidLineStyle.solid);
    final arrow = token.endsWith('>') || token.endsWith('x') ||
        token.endsWith('o');
    for (final a in from) {
      for (final b in to) {
        edges.add(
          MermaidEdge(
            from: a.id,
            to: b.id,
            label: (label == null || label.isEmpty) ? null : label,
            style: style,
            arrow: arrow,
          ),
        );
      }
    }
  }

  /// `A -- 文本 --> B` 归一成 `A -->|文本| B`(点线/粗线同理),
  /// 之后统一按 `|标签|` 一种形态解析。
  static String _normalizeLinkLabels(String line) {
    var out = line;
    // 标签两侧的空格可有可无(`-- 文本 -->` 与 `--文本-->` 都算)
    out = out.replaceAllMapped(
      RegExp(
        r'(?:-{2,}|={2,})\s*([^|>\n]+?)\s*(-{2,}>|-{3,}|={2,}>|={3,}|-{2,}[xo])',
      ),
      (m) => '${m[2]}|${m[1]}|',
    );
    out = out.replaceAllMapped(
      RegExp(r'-\.\s*([^|\n]+?)\s*\.(-+>|-)'),
      (m) => m[2]!.endsWith('>') ? '-.->|${m[1]}|' : '-.-|${m[1]}|',
    );
    return out;
  }

  /// 一段节点声明,支持 `A & B` 的并列写法
  static List<MermaidNode>? _parseNodeGroup(String segment) {
    final text = segment.trim();
    if (text.isEmpty) return null;
    final out = <MermaidNode>[];
    for (final part in text.split('&')) {
      final node = _parseNodeToken(part);
      if (node == null) return null;
      out.add(node);
    }
    return out;
  }

  static MermaidNode? _parseNodeToken(String token) {
    final text = token.trim();
    if (text.isEmpty) return null;
    final m = _nodeIdRe.firstMatch(text);
    if (m == null) return null;
    final id = m[1]!;
    final rest = m[2]!.trim();
    if (rest.isEmpty) {
      return MermaidNode(id: id, label: id);
    }
    for (final (open, close, shape) in _shapeTokens) {
      if (rest.length > open.length + close.length - 1 &&
          rest.startsWith(open) &&
          rest.endsWith(close)) {
        final inner = rest.substring(open.length, rest.length - close.length);
        return MermaidNode(id: id, label: _label(inner), shape: shape)
          ..defined = true;
      }
    }
    return null;
  }

  // ── sequenceDiagram ──

  static final _seqMessageRe = RegExp(
    r'^([^:>]+?)\s*(-{1,2}>>?|-{1,2}[x)])\s*([^:]+?)\s*:\s*(.*)$',
  );
  static final _seqNoteRe = RegExp(
    r'^Note\s+(left of|right of|over)\s+([^:]+):\s*(.*)$',
    caseSensitive: false,
  );
  static final _seqParticipantRe = RegExp(
    r'^(participant|actor)\s+(.+)$',
    caseSensitive: false,
  );
  static final _seqBlockOpenRe = RegExp(
    r'^(loop|alt|opt|par|critical|break|rect)\b\s*(.*)$',
    caseSensitive: false,
  );
  static final _seqBlockElseRe = RegExp(
    r'^(else|and|option)\b\s*(.*)$',
    caseSensitive: false,
  );
  static final _seqIgnorableRe = RegExp(
    r'^(autonumber|activate|deactivate|links?|accTitle|accDescr)\b',
    caseSensitive: false,
  );

  static MermaidSequence? _parseSequence(List<String> lines) {
    final participants = <String, MermaidParticipant>{};
    final steps = <MermaidSeqStep>[];
    var depth = 0;

    void touch(String id, {String? label, bool actor = false}) {
      final key = id.trim();
      if (key.isEmpty) return;
      final existing = participants[key];
      if (existing == null) {
        participants[key] = MermaidParticipant(
          id: key,
          label: _label(label ?? key),
          actor: actor,
        );
      } else if (label != null) {
        participants[key] = MermaidParticipant(
          id: key,
          label: _label(label),
          actor: actor || existing.actor,
        );
      }
    }

    for (final line in lines) {
      if (_seqIgnorableRe.hasMatch(line)) continue;

      final participant = _seqParticipantRe.firstMatch(line);
      if (participant != null) {
        final body = participant[2]!.trim();
        final alias = RegExp(
          r'^(.+?)\s+as\s+(.+)$',
          caseSensitive: false,
        ).firstMatch(body);
        touch(
          alias != null ? alias[1]!.trim() : body,
          label: alias != null ? alias[2]!.trim() : body,
          actor: participant[1]!.toLowerCase() == 'actor',
        );
        continue;
      }

      final note = _seqNoteRe.firstMatch(line);
      if (note != null) {
        final placement = switch (note[1]!.toLowerCase()) {
          'left of' => MermaidNotePlacement.leftOf,
          'right of' => MermaidNotePlacement.rightOf,
          _ => MermaidNotePlacement.over,
        };
        final targets = [
          for (final p in note[2]!.split(',')) p.trim(),
        ]..removeWhere((p) => p.isEmpty);
        if (targets.isEmpty) return null;
        for (final t in targets) {
          touch(t);
        }
        steps.add(
          MermaidSeqNote(
            placement: placement,
            participants: targets,
            text: _label(note[3]!),
          ),
        );
        continue;
      }

      final message = _seqMessageRe.firstMatch(line);
      if (message != null) {
        final from = message[1]!.trim();
        final to = message[3]!.trim();
        final token = message[2]!;
        touch(from);
        touch(to);
        steps.add(
          MermaidSeqMessage(
            from: from,
            to: to,
            text: _label(message[4]!),
            dotted: token.startsWith('--'),
            head: token.endsWith('>>')
                ? MermaidArrowHead.filled
                : token.endsWith('x')
                ? MermaidArrowHead.cross
                : token.endsWith(')')
                ? MermaidArrowHead.async
                : MermaidArrowHead.open,
          ),
        );
        continue;
      }

      if (line == 'end') {
        if (depth == 0) return null;
        depth--;
        steps.add(const MermaidSeqBlockClose());
        continue;
      }

      final blockElse = _seqBlockElseRe.firstMatch(line);
      if (blockElse != null && depth > 0) {
        steps.add(MermaidSeqBlockElse(_label(blockElse[2]!)));
        continue;
      }

      final blockOpen = _seqBlockOpenRe.firstMatch(line);
      if (blockOpen != null) {
        final keyword = blockOpen[1]!.toLowerCase();
        depth++;
        steps.add(
          MermaidSeqBlockOpen(
            keyword: keyword,
            // rect rgb(…) 只是配色语句,不当标题
            title: keyword == 'rect' ? '' : _label(blockOpen[2]!),
          ),
        );
        continue;
      }

      return null;
    }

    if (depth != 0 || participants.isEmpty) return null;
    return MermaidSequence(
      participants: participants.values.toList(),
      steps: steps,
    );
  }
}
