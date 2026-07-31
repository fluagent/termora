import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:termora/features/notes/domain/markdown_parser.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 把一段 mermaid 源码渲成 PNG。PDF 是矢量文档、画不了 Flutter 画笔,
/// 所以由调用方(界面层)把图离屏渲成位图再塞进来;返回 null = 渲染不了。
typedef MermaidPngRenderer =
    Future<({Uint8List bytes, Size size})?> Function(String code);

/// 笔记导出 PDF(marktext 的 Export PDF)— AST → pdf 组件排版。
/// 中文必须内嵌字体:优先加载系统 CJK TTF(macOS 的 Arial Unicode),
/// 作为 Helvetica 系列的 fallback;找不到时拉丁文仍正常,中文会缺字。
class NotePdfExporter {
  NotePdfExporter._();

  /// 正文可用宽高(A4 减页边距),图超出就等比缩到放得下
  static final double _contentWidth = PdfPageFormat.a4.width - 104;
  static final double _contentHeight = PdfPageFormat.a4.height - 112;

  static const _cjkFontCandidates = [
    '/System/Library/Fonts/Supplemental/Arial Unicode.ttf', // macOS
    r'C:\Windows\Fonts\msyh.ttf', // Windows(若为 ttc 则跳过)
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  ];

  static pw.Font? _cjk;
  static bool _cjkLoaded = false;

  static pw.Font? _loadCjkFont() {
    if (_cjkLoaded) return _cjk;
    _cjkLoaded = true;
    for (final path in _cjkFontCandidates) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        _cjk = pw.Font.ttf(
          file.readAsBytesSync().buffer.asByteData(),
        );
        break;
      } catch (_) {
        // ttc 等不支持的格式,尝试下一个候选
      }
    }
    return _cjk;
  }

  static Future<Uint8List> export(
    String source, {
    MermaidPngRenderer? renderMermaid,
  }) async {
    final cjk = _loadCjkFont();
    final fallback = [?cjk];
    final theme = pw.ThemeData.withFont(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
      italic: pw.Font.helveticaOblique(),
      boldItalic: pw.Font.helveticaBoldOblique(),
      fontFallback: fallback,
    );
    final mono = pw.TextStyle(
      font: pw.Font.courier(),
      fontFallback: fallback,
      fontSize: 9,
    );

    final blocks = MarkdownParser.parse(source);
    final diagrams = await _renderDiagrams(blocks, renderMermaid);

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: theme,
        margin: const pw.EdgeInsets.symmetric(horizontal: 52, vertical: 56),
        build: (_) => [
          for (final block in blocks)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: _block(block, mono, diagrams),
            ),
        ],
      ),
    );
    return doc.save();
  }

  /// ```mermaid 块预先渲成位图(渲不出来的保持代码块原样)
  static Future<Map<MdCodeBlock, _Diagram>> _renderDiagrams(
    List<MdBlock> blocks,
    MermaidPngRenderer? renderMermaid,
  ) async {
    final out = <MdCodeBlock, _Diagram>{};
    if (renderMermaid == null) return out;
    for (final block in _flatten(blocks)) {
      if (block is! MdCodeBlock) continue;
      if (block.language?.toLowerCase() != 'mermaid') continue;
      final png = await renderMermaid(block.code);
      if (png == null) continue;
      final scale = math.min(
        1.0,
        math.min(
          _contentWidth / png.size.width,
          _contentHeight / png.size.height,
        ),
      );
      out[block] = _Diagram(
        pw.MemoryImage(png.bytes),
        png.size.width * scale,
        png.size.height * scale,
      );
    }
    return out;
  }

  /// 引用块里也可能嵌代码块,展平后统一处理
  static Iterable<MdBlock> _flatten(List<MdBlock> blocks) sync* {
    for (final block in blocks) {
      yield block;
      if (block is MdQuote) yield* _flatten(block.children);
    }
  }

  static pw.Widget _block(
    MdBlock block,
    pw.TextStyle mono,
    Map<MdCodeBlock, _Diagram> diagrams,
  ) {
    switch (block) {
      case MdHeading():
        final size = switch (block.level) {
          1 => 20.0,
          2 => 16.0,
          3 => 13.5,
          _ => 11.5,
        };
        final text = pw.RichText(
          text: pw.TextSpan(
            style: pw.TextStyle(
              fontSize: size,
              fontWeight: pw.FontWeight.bold,
            ),
            children: _inline(block.spans, mono),
          ),
        );
        if (block.level > 2) return text;
        return pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.only(bottom: 4),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.7),
            ),
          ),
          child: text,
        );
      case MdParagraph():
        return _richText(block.spans, mono);
      case MdCodeBlock():
        final diagram = diagrams[block];
        if (diagram != null) {
          return pw.Center(
            child: pw.Image(
              diagram.image,
              width: diagram.width,
              height: diagram.height,
            ),
          );
        }
        return pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            color: PdfColors.grey100,
            borderRadius: pw.BorderRadius.circular(6),
            border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
          ),
          child: pw.Text(block.code, style: mono),
        );
      case MdQuote():
        return pw.Container(
          padding: const pw.EdgeInsets.only(left: 10, top: 4, bottom: 4),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              left: pw.BorderSide(color: PdfColors.grey400, width: 2.5),
            ),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (final child in block.children)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 4),
                  child: _block(child, mono, diagrams),
                ),
            ],
          ),
        );
      case MdList():
        return pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            for (final item in block.items)
              pw.Padding(
                padding: pw.EdgeInsets.only(
                  left: 4.0 + item.indent * 14,
                  bottom: 2.5,
                ),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.SizedBox(
                      width: 16,
                      child: pw.Text(
                        item.checked != null
                            ? (item.checked! ? '☑' : '☐')
                            : item.number != null
                            ? '${item.number}.'
                            : '•',
                        style: const pw.TextStyle(fontSize: 10.5),
                      ),
                    ),
                    pw.Expanded(child: _richText(item.spans, mono)),
                  ],
                ),
              ),
          ],
        );
      case MdDivider():
        return pw.Divider(color: PdfColors.grey300, height: 4, thickness: 0.7);
      case MdTable():
        return _table(block, mono);
      case MdMathBlock():
        return pw.Center(
          child: pw.Text(
            block.tex,
            style: mono.copyWith(fontStyle: pw.FontStyle.italic),
          ),
        );
    }
  }

  static pw.Widget _table(MdTable table, pw.TextStyle mono) {
    pw.Alignment align(int column) => switch (table.alignAt(column)) {
      MdTableAlign.left => pw.Alignment.centerLeft,
      MdTableAlign.center => pw.Alignment.center,
      MdTableAlign.right => pw.Alignment.centerRight,
    };
    pw.Widget cell(List<MdInline> spans, int column, {bool header = false}) {
      return pw.Container(
        alignment: header ? pw.Alignment.center : align(column),
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: pw.RichText(
          text: pw.TextSpan(
            style: pw.TextStyle(
              fontSize: 9.5,
              fontWeight: header ? pw.FontWeight.bold : null,
            ),
            children: _inline(spans, mono),
          ),
        ),
      );
    }

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            for (final (c, h) in table.header.indexed)
              cell(h, c, header: true),
          ],
        ),
        for (final row in table.rows)
          pw.TableRow(
            children: [
              for (var c = 0; c < table.header.length; c++)
                cell(c < row.length ? row[c] : const [], c),
            ],
          ),
      ],
    );
  }

  static pw.Widget _richText(List<MdInline> spans, pw.TextStyle mono) {
    return pw.RichText(
      text: pw.TextSpan(
        style: const pw.TextStyle(fontSize: 10.5, lineSpacing: 3),
        children: _inline(spans, mono),
      ),
    );
  }

  static List<pw.InlineSpan> _inline(
    List<MdInline> spans,
    pw.TextStyle mono,
  ) {
    return [
      for (final s in spans)
        pw.TextSpan(
          text: s.imageUrl != null ? tr2('[图片 {0}]', [s.text]) : s.text,
          style: pw.TextStyle(
            font: s.code ? mono.font : null,
            fontFallback: mono.fontFallback,
            fontSize: s.code ? 9 : null,
            fontWeight: s.bold ? pw.FontWeight.bold : null,
            fontStyle: s.italic ? pw.FontStyle.italic : null,
            decoration: s.strikethrough
                ? pw.TextDecoration.lineThrough
                : (s.url != null ? pw.TextDecoration.underline : null),
            color: s.url != null
                ? PdfColors.teal700
                : (s.code ? PdfColors.teal800 : null),
          ),
        ),
    ];
  }
}

/// 预渲好的图:位图 + 落到页面上的尺寸
class _Diagram {
  const _Diagram(this.image, this.width, this.height);
  final pw.MemoryImage image;
  final double width;
  final double height;
}
