import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/notes/domain/mermaid/mermaid_layout.dart';
import 'package:termora/features/notes/domain/mermaid/mermaid_parser.dart';

/// 图表配色。预览跟随主题;导出固定浅色 —— 暗色主题下导出的 PDF 是白纸,
/// 直接用主题色会画成一片看不清的浅字。
class MermaidPalette {
  const MermaidPalette({
    required this.background,
    required this.surface,
    required this.subtleSurface,
    required this.border,
    required this.line,
    required this.text,
    required this.body,
    required this.subtleText,
    required this.accent,
    required this.note,
  });

  /// 画布底色(导出时铺一层,预览里由外层容器提供)
  final Color background;

  /// 线上标签的抠底色,盖住穿过文字的连线
  final Color surface;
  final Color subtleSurface;
  final Color border;
  final Color line;
  final Color text;
  final Color body;
  final Color subtleText;
  final Color accent;
  final Color note;

  factory MermaidPalette.theme() => MermaidPalette(
    background: AppTheme.mutedSurfaceColor,
    surface: AppTheme.mutedSurfaceColor,
    subtleSurface: AppTheme.subtleSurfaceColor,
    border: AppTheme.borderColor,
    line: AppTheme.subtleTextColor.withValues(alpha: 0.85),
    text: AppTheme.headingColor,
    body: AppTheme.bodyColor,
    subtleText: AppTheme.subtleTextColor,
    accent: AppTheme.brandColor,
    note: AppTheme.warningColor,
  );

  /// 导出用:白底 + 中性灰,暗色主题下把品牌色压深保证对比度
  factory MermaidPalette.export() => MermaidPalette(
    background: const Color(0xFFFFFFFF),
    surface: const Color(0xFFFFFFFF),
    subtleSurface: const Color(0xFFF1F3F0),
    border: const Color(0xFFD5D9D3),
    line: const Color(0xFF6B7280),
    text: const Color(0xFF111827),
    body: const Color(0xFF374151),
    subtleText: const Color(0xFF6B7280),
    accent: AppTheme.isDarkMode
        ? Color.lerp(AppTheme.brandColor, const Color(0xFF000000), 0.3)!
        : AppTheme.brandColor,
    note: const Color(0xFFD97706),
  );
}

/// mermaid 图表渲染(自绘)。
///
/// 解析 + 排版都在纯 Dart 侧完成,这里只负责按排版结果落笔;
/// 图超出可用宽度时整体等比缩小,缩到下限还放不下就横向滚动。
class MermaidBlockView extends StatelessWidget {
  const MermaidBlockView({super.key, required this.diagram});

  final MermaidDiagram diagram;

  /// 缩放下限:再小就看不清了,改用横向滚动
  static const double _minScale = 0.55;

  /// 文本测量,与绘制用同一套 TextStyle 和折行宽度,保证排版与落笔一致
  static Size measure(String text, double fontSize, bool bold) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: mermaidTextStyle(fontSize, bold)),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: kMermaidLabelMaxWidth);
    return painter.size;
  }

  static TextStyle mermaidTextStyle(double fontSize, bool bold, [Color? color]) {
    return TextStyle(
      fontSize: fontSize,
      height: 1.3,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
      color: color,
    );
  }

  @override
  Widget build(BuildContext context) {
    final painter = mermaidPainter(diagram, MermaidPalette.theme());
    final size = painter.canvasSize;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: AppTheme.mutedSurfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor, width: 0.6),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : size.width;
          final scale = math.min(1.0, available / size.width);
          if (scale >= _minScale) {
            return Center(
              child: SizedBox(
                width: size.width * scale,
                height: size.height * scale,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: CustomPaint(size: size, painter: painter),
                ),
              ),
            );
          }
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: size.width * _minScale,
              height: size.height * _minScale,
              child: FittedBox(
                fit: BoxFit.contain,
                child: CustomPaint(size: size, painter: painter),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 按图种取画笔(预览与导出共用)
MermaidCanvasPainter mermaidPainter(
  MermaidDiagram diagram,
  MermaidPalette palette,
) => switch (diagram) {
  MermaidFlowchart d => _MermaidFlowPainter(
    MermaidLayoutEngine.layoutFlowchart(d, MermaidBlockView.measure),
    palette,
  ),
  MermaidSequence d => _MermaidSequencePainter(
    MermaidLayoutEngine.layoutSequence(d, MermaidBlockView.measure),
    palette,
  ),
};

/// 把图离屏渲成 PNG —— 导出 PDF 用,和预览走的是同一套画笔。
/// 返回 null 表示图无内容或渲染失败,调用方回退成代码块。
Future<({Uint8List bytes, Size size})?> renderMermaidPng(
  MermaidDiagram diagram, {
  double scale = 3,
  MermaidPalette? palette,
}) async {
  final colors = palette ?? MermaidPalette.export();
  final painter = mermaidPainter(diagram, colors);
  final size = painter.canvasSize;
  if (size.width < 1 || size.height < 1) return null;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  canvas.drawRect(Offset.zero & size, Paint()..color = colors.background);
  painter.paint(canvas, size);
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(
      (size.width * scale).ceil(),
      (size.height * scale).ceil(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;
    return (bytes: data.buffer.asUint8List(), size: size);
  } finally {
    picture.dispose();
  }
}

// ══════════════ 画笔共用 ══════════════

abstract class MermaidCanvasPainter extends CustomPainter {
  MermaidCanvasPainter(this.palette);

  final MermaidPalette palette;

  Size get canvasSize;

  Color get lineColor => palette.line;
  Color get textColor => palette.text;
  Color get accentColor => palette.accent;
  Color get surfaceColor => palette.surface;

  void drawText(
    Canvas canvas,
    String text,
    Offset center, {
    double fontSize = kMermaidNodeFontSize,
    bool bold = false,
    Color? color,
  }) {
    if (text.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: MermaidBlockView.mermaidTextStyle(
          fontSize,
          bold,
          color ?? textColor,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: kMermaidLabelMaxWidth);
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  /// 折线路径,拐角做圆角过渡
  Path polylinePath(List<Offset> points, {double radius = 8}) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final prev = points[i - 1];
      final corner = points[i];
      final next = points[i + 1];
      final inLen = (corner - prev).distance;
      final outLen = (next - corner).distance;
      final r = math.min(radius, math.min(inLen, outLen) / 2);
      if (r <= 0.5) {
        path.lineTo(corner.dx, corner.dy);
        continue;
      }
      final enter = corner + (prev - corner) / inLen * r;
      final exit = corner + (next - corner) / outLen * r;
      path.lineTo(enter.dx, enter.dy);
      path.quadraticBezierTo(corner.dx, corner.dy, exit.dx, exit.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  /// 虚线化:按 [dash]/[gap] 走 PathMetrics 抽段
  Path dashed(Path source, {double dash = 5, double gap = 4}) {
    final out = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        out.addPath(metric.extractPath(distance, next), Offset.zero);
        distance = next + gap;
      }
    }
    return out;
  }

  void drawArrowHead(
    Canvas canvas,
    Offset tip,
    Offset from,
    Paint paint, {
    double length = 9,
    double width = 6,
  }) {
    final delta = tip - from;
    final len = delta.distance;
    if (len < 0.01) return;
    final dir = delta / len;
    final normal = Offset(-dir.dy, dir.dx);
    final base = tip - dir * length;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(
        base.dx + normal.dx * width / 2,
        base.dy + normal.dy * width / 2,
      )
      ..lineTo(
        base.dx - normal.dx * width / 2,
        base.dy - normal.dy * width / 2,
      )
      ..close();
    canvas.drawPath(path, paint..style = PaintingStyle.fill);
  }

  /// 线上标签:先用底色扣出一块,避免连线穿过文字
  void drawEdgeLabel(Canvas canvas, String label, Offset center, Size size) {
    if (label.isEmpty) return;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center,
        width: size.width + 10,
        height: size.height + 4,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(rect, Paint()..color = surfaceColor);
    drawText(
      canvas,
      label,
      center,
      fontSize: kMermaidEdgeFontSize,
      color: palette.subtleText,
    );
  }
}

// ══════════════ flowchart ══════════════

class _MermaidFlowPainter extends MermaidCanvasPainter {
  _MermaidFlowPainter(this.layout, super.palette);

  final MermaidFlowLayout layout;

  @override
  Size get canvasSize => layout.size;

  @override
  void paint(Canvas canvas, Size size) {
    // 分组底框(在节点之下)
    final groupFill = Paint()
      ..color = palette.subtleSurface.withValues(alpha: 0.45);
    final groupStroke = Paint()
      ..color = palette.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final group in layout.groups) {
      final rrect = RRect.fromRectAndRadius(
        group.rect,
        const Radius.circular(10),
      );
      canvas.drawRRect(rrect, groupFill);
      canvas.drawPath(dashed(Path()..addRRect(rrect)), groupStroke);
      drawText(
        canvas,
        group.title,
        Offset(
          group.rect.left + 12 + group.titleSize.width / 2,
          group.rect.top + 8 + group.titleSize.height / 2,
        ),
        fontSize: kMermaidGroupFontSize,
        bold: true,
        color: palette.subtleText,
      );
    }

    // 连线
    for (final edge in layout.edges) {
      final stroke = Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = edge.style == MermaidLineStyle.thick ? 2.4 : 1.3;
      final path = polylinePath(edge.points);
      canvas.drawPath(
        edge.style == MermaidLineStyle.dotted ? dashed(path) : path,
        stroke,
      );
      if (edge.arrow) {
        final tip = edge.points.last;
        final from = edge.points[edge.points.length - 2];
        drawArrowHead(canvas, tip, from, Paint()..color = lineColor);
      }
    }

    // 节点
    final fill = Paint()..color = accentColor.withValues(alpha: 0.10);
    final stroke = Paint()
      ..color = accentColor.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final box in layout.nodes) {
      final path = _shapePath(box.node.shape, box.rect);
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
      if (box.node.shape == MermaidNodeShape.subroutine) {
        // 子程序:内侧两道竖线
        canvas.drawLine(
          Offset(box.rect.left + 8, box.rect.top),
          Offset(box.rect.left + 8, box.rect.bottom),
          stroke,
        );
        canvas.drawLine(
          Offset(box.rect.right - 8, box.rect.top),
          Offset(box.rect.right - 8, box.rect.bottom),
          stroke,
        );
      }
      drawText(canvas, box.node.label, box.rect.center);
    }

    // 边标签画在最上层:折线可能贴着别的节点走,压在下面会被盖掉
    for (final edge in layout.edges) {
      if (edge.label == null) continue;
      drawEdgeLabel(canvas, edge.label!, edge.labelCenter, edge.labelSize);
    }
  }

  Path _shapePath(MermaidNodeShape shape, Rect rect) {
    switch (shape) {
      case MermaidNodeShape.circle:
        return Path()..addOval(rect);
      case MermaidNodeShape.stadium:
        return Path()
          ..addRRect(
            RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
          );
      case MermaidNodeShape.round:
        return Path()
          ..addRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(12)),
          );
      case MermaidNodeShape.rhombus:
        return Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.center.dx, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
      case MermaidNodeShape.hexagon:
        final inset = math.min(18.0, rect.width / 4);
        return Path()
          ..moveTo(rect.left + inset, rect.top)
          ..lineTo(rect.right - inset, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.right - inset, rect.bottom)
          ..lineTo(rect.left + inset, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
      case MermaidNodeShape.rect:
      case MermaidNodeShape.subroutine:
        return Path()
          ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)));
    }
  }

  @override
  bool shouldRepaint(covariant _MermaidFlowPainter old) =>
      old.layout != layout || old.palette != palette;
}

// ══════════════ sequenceDiagram ══════════════

class _MermaidSequencePainter extends MermaidCanvasPainter {
  _MermaidSequencePainter(this.layout, super.palette);

  final MermaidSequenceLayout layout;

  @override
  Size get canvasSize => layout.size;

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..color = palette.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // 生命线
    for (final actor in layout.actors) {
      final line = Path()
        ..moveTo(actor.lifelineX, layout.lifelineTop)
        ..lineTo(actor.lifelineX, layout.lifelineBottom);
      canvas.drawPath(dashed(line, dash: 4, gap: 4), border);
    }

    // 分组框(loop/alt/…)
    for (final frame in layout.frames) {
      final rrect = RRect.fromRectAndRadius(
        frame.rect,
        const Radius.circular(6),
      );
      canvas.drawRRect(rrect, border);
      final tabWidth = math.max(frame.titleSize.width + 44, 62.0);
      final tab = Rect.fromLTWH(frame.rect.left, frame.rect.top, tabWidth, 20);
      canvas.drawPath(
        Path()
          ..moveTo(tab.left, tab.top)
          ..lineTo(tab.right, tab.top)
          ..lineTo(tab.right - 8, tab.bottom)
          ..lineTo(tab.left, tab.bottom)
          ..close(),
        Paint()..color = palette.subtleSurface,
      );
      drawText(
        canvas,
        frame.keyword,
        Offset(tab.left + 22, tab.center.dy),
        fontSize: kMermaidEdgeFontSize,
        bold: true,
        color: palette.subtleText,
      );
      if (frame.title.isNotEmpty) {
        drawText(
          canvas,
          frame.title,
          Offset(
            tab.right + 8 + frame.titleSize.width / 2,
            tab.center.dy,
          ),
          fontSize: kMermaidEdgeFontSize,
          color: palette.subtleText,
        );
      }
      for (final divider in frame.dividers) {
        canvas.drawPath(
          dashed(
            Path()
              ..moveTo(frame.rect.left, divider.y)
              ..lineTo(frame.rect.right, divider.y),
          ),
          border,
        );
        if (divider.label.isNotEmpty) {
          drawText(
            canvas,
            divider.label,
            Offset(
              frame.rect.left + 14 + divider.labelSize.width / 2,
              divider.y + 10 + divider.labelSize.height / 2,
            ),
            fontSize: kMermaidEdgeFontSize,
            color: palette.subtleText,
          );
        }
      }
    }

    // 消息
    final arrowPaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.3;
    for (final arrow in layout.arrows) {
      if (arrow.isSelf) {
        final loop = arrow.loopRect!;
        final path = polylinePath([
          Offset(loop.left, loop.top),
          Offset(loop.right, loop.top),
          Offset(loop.right, loop.bottom),
          Offset(loop.left, loop.bottom),
        ], radius: 6);
        canvas.drawPath(arrow.dotted ? dashed(path) : path, arrowPaint);
        _head(canvas, arrow, Offset(loop.left, loop.bottom),
            Offset(loop.right, loop.bottom));
        drawText(
          canvas,
          arrow.label,
          Offset(
            loop.right + 8 + arrow.labelSize.width / 2,
            loop.center.dy,
          ),
          fontSize: 11.5,
          color: palette.body,
        );
        continue;
      }
      final path = Path()
        ..moveTo(arrow.start.dx, arrow.start.dy)
        ..lineTo(arrow.end.dx, arrow.end.dy);
      canvas.drawPath(arrow.dotted ? dashed(path) : path, arrowPaint);
      _head(canvas, arrow, arrow.end, arrow.start);
      drawText(
        canvas,
        arrow.label,
        Offset(
          (arrow.start.dx + arrow.end.dx) / 2,
          arrow.start.dy - arrow.labelSize.height / 2 - 5,
        ),
        fontSize: 11.5,
        color: palette.body,
      );
    }

    // 备注
    for (final note in layout.notes) {
      final rrect = RRect.fromRectAndRadius(
        note.rect,
        const Radius.circular(4),
      );
      canvas.drawRRect(
        rrect,
        Paint()..color = palette.note.withValues(alpha: 0.14),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = palette.note.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      drawText(
        canvas,
        note.text,
        note.rect.center,
        fontSize: 11.5,
        color: palette.body,
      );
    }

    // 参与者(画在最上层,盖住生命线起点)
    final fill = Paint()..color = accentColor.withValues(alpha: 0.12);
    final stroke = Paint()
      ..color = accentColor.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final actor in layout.actors) {
      final rrect = RRect.fromRectAndRadius(
        actor.rect,
        const Radius.circular(6),
      );
      canvas.drawRRect(rrect, fill);
      canvas.drawRRect(rrect, stroke);
      drawText(
        canvas,
        actor.participant.label,
        actor.rect.center,
        fontSize: 11.5,
        bold: true,
      );
    }
  }

  /// 按箭头种类落头:实心三角 / 开口 V / 叉 / 异步开口
  void _head(Canvas canvas, MermaidArrowLine arrow, Offset tip, Offset from) {
    final paint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.3;
    final delta = tip - from;
    final len = delta.distance;
    if (len < 0.01) return;
    final dir = delta / len;
    final normal = Offset(-dir.dy, dir.dx);

    switch (arrow.head) {
      case MermaidArrowHead.filled:
        drawArrowHead(canvas, tip, from, Paint()..color = lineColor);
      case MermaidArrowHead.open:
      case MermaidArrowHead.async:
        final base = tip - dir * 8;
        canvas.drawLine(tip, base + normal * 4, paint);
        canvas.drawLine(tip, base - normal * 4, paint);
      case MermaidArrowHead.cross:
        final base = tip - dir * 9;
        canvas.drawLine(base + normal * 4.5, tip - normal * 4.5, paint);
        canvas.drawLine(base - normal * 4.5, tip + normal * 4.5, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MermaidSequencePainter old) =>
      old.layout != layout || old.palette != palette;
}
