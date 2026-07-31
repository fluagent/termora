import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';
import 'package:toastification/toastification.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/widgets/app_toast.dart';
import 'package:termora/features/notes/domain/markdown_parser.dart';
import 'package:termora/features/notes/domain/mermaid/mermaid_parser.dart';
import 'package:termora/features/notes/view/widgets/mermaid_view.dart';
import 'package:termora/core/l10n/app_l10n.dart';



/// markdown 渲染预览(marktext 预览形态的 Flutter 版)
class MarkdownPreview extends StatelessWidget {
  const MarkdownPreview({
    super.key,
    required this.source,
    this.padding,
    this.onToggleTask,
  });

  final String source;
  final EdgeInsetsGeometry? padding;

  /// 点击任务勾选框回调,参数为全文任务序号
  /// (MarkdownEditing.toggleTaskAt 同口径);null = 只读
  final ValueChanged<int>? onToggleTask;

  @override
  Widget build(BuildContext context) {
    final blocks = MarkdownParser.parse(source);
    if (blocks.isEmpty) {
      return Center(
        child: Text(
          tr('暂无内容'),
          style: TextStyle(fontSize: 13, color: AppTheme.subtleTextColor),
        ),
      );
    }
    return SelectionArea(
      child: Builder(
        builder: (context) {
          final effectivePadding =
              padding?.resolve(TextDirection.ltr) ??
              const EdgeInsets.fromLTRB(32, 28, 32, 56);
          return ListView.builder(
            padding: effectivePadding,
            itemCount: blocks.length,
            itemBuilder: (context, index) => MarkdownBlockView(
              block: blocks[index],
              isFirst: index == 0,
              onToggleTask: onToggleTask,
            ),
          );
        },
      ),
    );
  }
}

/// 单个 markdown 块的渲染组件(预览与块式编辑器共用)
class MarkdownBlockView extends StatelessWidget {
  const MarkdownBlockView({
    super.key,
    required this.block,
    this.isFirst = false,
    this.onToggleTask,
  });

  final MdBlock block;
  final bool isFirst;
  final ValueChanged<int>? onToggleTask;

  @override
  Widget build(BuildContext context) {
    final b = block;
    final child = switch (b) {
      MdHeading() => _heading(context, b),
      MdParagraph() => _richText(context, b.spans),
      MdCodeBlock() => _codeBlock(b),
      MdQuote() => _quote(b),
      MdList() => _list(context, b),
      MdDivider() => Divider(height: 1, color: AppTheme.borderColor),
      MdTable() => _table(context, b),
      MdMathBlock() => _math(b),
    };
    return Padding(
      padding: EdgeInsets.only(top: isFirst ? 0 : _spacingAbove(b)),
      child: child,
    );
  }

  /// ```mermaid 走自绘图表;解析不了(不支持的图种/语法)回退成代码块
  Widget _codeBlock(MdCodeBlock b) {
    if (b.language?.toLowerCase() == 'mermaid') {
      final diagram = MermaidParser.tryParse(b.code);
      if (diagram != null) return MermaidBlockView(diagram: diagram);
    }
    return _CodeBlockView(block: b);
  }

  double _spacingAbove(MdBlock b) => switch (b) {
    MdHeading(level: 1) => 26,
    MdHeading() => 22,
    MdDivider() => 18,
    MdMathBlock() => 16,
    _ => 13,
  };

  Widget _heading(BuildContext context, MdHeading h) {
    final style = switch (h.level) {
      1 => TextStyle(
        fontSize: 25,
        fontWeight: FontWeight.w700,
        color: AppTheme.headingColor,
        height: 1.3,
        letterSpacing: -0.4,
      ),
      2 => TextStyle(
        fontSize: 19.5,
        fontWeight: FontWeight.w700,
        color: AppTheme.headingColor,
        height: 1.3,
        letterSpacing: -0.3,
      ),
      3 => TextStyle(
        fontSize: 16.5,
        fontWeight: FontWeight.w600,
        color: AppTheme.headingColor,
        height: 1.3,
      ),
      _ => TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppTheme.headingColor,
        height: 1.3,
      ),
    };
    final text = _richText(context, h.spans, baseStyle: style);
    if (h.level > 2) return text;
    // h1/h2 底部细线,github 风格
    return Container(
      padding: const EdgeInsets.only(bottom: 7),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: text,
    );
  }

  Widget _quote(MdQuote q) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.mutedSurfaceColor.withValues(alpha: 0.6),
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(8),
        ),
        border: Border(
          left: BorderSide(
            color: AppTheme.brandColor.withValues(alpha: 0.55),
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, child) in q.children.indexed)
            MarkdownBlockView(
              block: child,
              isFirst: index == 0,
              onToggleTask: onToggleTask,
            ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, MdList list) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in list.items)
          Padding(
            padding: EdgeInsets.only(left: item.indent * 20.0, bottom: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 24, child: _listMarker(item)),
                Expanded(
                  child: _richText(
                    context,
                    item.spans,
                    baseStyle: item.checked == true
                        ? TextStyle(
                            fontSize: 13.5,
                            height: 1.65,
                            color: AppTheme.subtleTextColor,
                            decoration: TextDecoration.lineThrough,
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _listMarker(MdListItem item) {
    if (item.checked != null) {
      final icon = Icon(
        item.checked! ? LucideIcons.squareCheck : LucideIcons.square,
        size: 15,
        color: item.checked! ? AppTheme.brandColor : AppTheme.subtleTextColor,
      );
      final toggle = onToggleTask;
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        // 有回调且知道源码序号时,勾选框可点击(marktext 预览同款)
        child: toggle != null && item.taskIndex != null
            ? MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => toggle(item.taskIndex!),
                  child: icon,
                ),
              )
            : icon,
      );
    }
    if (item.number != null) {
      return Text(
        '${item.number}.',
        style: TextStyle(
          fontSize: 13.5,
          height: 1.65,
          color: AppTheme.subtleTextColor,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Container(
        width: 5,
        height: 5,
        margin: const EdgeInsets.only(left: 4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppTheme.bodyColor,
        ),
      ),
    );
  }

  Widget _table(BuildContext context, MdTable t) {
    final columnCount = t.header.length;
    TextAlign textAlign(int column) => switch (t.alignAt(column)) {
      MdTableAlign.left => TextAlign.left,
      MdTableAlign.center => TextAlign.center,
      MdTableAlign.right => TextAlign.right,
    };
    TableRow buildRow(List<List<MdInline>> cells, {bool header = false}) {
      return TableRow(
        decoration: header
            ? BoxDecoration(color: AppTheme.mutedSurfaceColor)
            : null,
        children: [
          for (var c = 0; c < columnCount; c++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: _richText(
                context,
                c < cells.length ? cells[c] : const [],
                // 表头一律居中(marktext 风格),数据行按声明的对齐
                textAlign: header ? TextAlign.center : textAlign(c),
                baseStyle: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  fontWeight: header ? FontWeight.w600 : FontWeight.w400,
                  color: header ? AppTheme.headingColor : AppTheme.bodyColor,
                ),
              ),
            ),
        ],
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Table(
        border: TableBorder.all(color: AppTheme.borderColor, width: 0.6),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: [
          buildRow(t.header, header: true),
          for (final row in t.rows) buildRow(row),
        ],
      ),
    );
  }

  Widget _math(MdMathBlock m) {
    if (m.tex.isEmpty) return const SizedBox.shrink();
    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Math.tex(
            m.tex,
            mathStyle: MathStyle.display,
            textStyle: TextStyle(fontSize: 17, color: AppTheme.headingColor),
            onErrorFallback: (error) => Text(
              m.tex,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontFamilyFallback: const ['Consolas', 'monospace'],
                fontSize: 13,
                color: AppTheme.errorColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 行内渲染 ──

  Widget _richText(
    BuildContext context,
    List<MdInline> spans, {
    TextStyle? baseStyle,
    TextAlign? textAlign,
  }) {
    final base =
        baseStyle ??
        TextStyle(fontSize: 13.5, height: 1.7, color: AppTheme.bodyColor);
    return Text.rich(
      TextSpan(
        style: base,
        children: [for (final s in spans) _inlineSpan(context, s, base)],
      ),
      textAlign: textAlign,
    );
  }

  /// 由样式标志叠出 TextStyle(粗/斜/删可任意组合)
  TextStyle _composeStyle(MdInline s, TextStyle base) {
    var style = const TextStyle();
    if (s.bold) {
      style = style.copyWith(
        fontWeight: FontWeight.w700,
        color: AppTheme.headingColor,
      );
    }
    if (s.italic) {
      style = style.copyWith(fontStyle: FontStyle.italic);
    }
    if (s.strikethrough) {
      style = style.copyWith(
        decoration: TextDecoration.lineThrough,
        color: s.bold ? AppTheme.headingColor : AppTheme.subtleTextColor,
      );
    }
    return style;
  }

  /// 本地附件链接(插入的视频/文件落在 assets 的绝对路径)
  static bool _isLocalAttachment(String url) =>
      !url.contains('://') && url.startsWith('/');

  InlineSpan _inlineSpan(BuildContext context, MdInline s, TextStyle base) {
    if (s.imageUrl != null) return _imageSpan(s);
    if (s.url != null && _isLocalAttachment(s.url!)) {
      return _attachmentChip(context, s);
    }

    final style = _composeStyle(s, base);
    if (s.url != null) {
      // WidgetSpan 承载点击,避免手势 recognizer 生命周期管理
      return WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _openLink(context, s.url!),
            child: Text(
              s.text,
              style: base.merge(style).copyWith(
                color: AppTheme.brandColor,
                decoration: TextDecoration.underline,
                decorationColor: AppTheme.brandColor.withValues(alpha: 0.45),
              ),
            ),
          ),
        ),
      );
    }
    if (s.code) return _codeChip(s, base);
    if (s.isPlain) return TextSpan(text: s.text);
    return TextSpan(text: s.text, style: style);
  }

  static const _videoExtensions = {
    'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', 'flv',
  };
  static const _audioExtensions = {'mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg'};
  static const _archiveExtensions = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2'};

  static IconData _attachmentIcon(String url) {
    final name = url.split('/').last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (_videoExtensions.contains(ext)) return LucideIcons.clapperboard;
    if (_audioExtensions.contains(ext)) return LucideIcons.music;
    if (_archiveExtensions.contains(ext)) return LucideIcons.fileArchive;
    return LucideIcons.paperclip;
  }

  /// 附件卡片:类型图标 + 文件名,点击用系统默认应用打开(视频即播放)
  InlineSpan _attachmentChip(BuildContext context, MdInline s) {
    final url = s.url!;
    final missing = !File(url).existsSync();
    final color = missing ? AppTheme.subtleTextColor : AppTheme.headingColor;
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _openLink(context, url),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: AppTheme.mutedSurfaceColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor, width: 0.6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_attachmentIcon(url), size: 14, color: AppTheme.brandColor),
                const SizedBox(width: 6),
                Text(
                  s.text.isEmpty ? url.split('/').last : s.text,
                  style: TextStyle(fontSize: 12.5, color: color),
                ),
                if (missing) ...[
                  const SizedBox(width: 5),
                  Text(
                    tr('(文件缺失)'),
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.subtleTextColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 行内代码:短的用圆角 chip(marktext 风格),
  /// 超长的退回底色文字保证换行能力
  InlineSpan _codeChip(MdInline s, TextStyle base) {
    final codeStyle = TextStyle(
      fontFamily: 'Menlo',
      fontFamilyFallback: const ['Consolas', 'monospace'],
      fontSize: (base.fontSize ?? 14.5) - 1.5,
      height: 1.4,
      color: AppTheme.brandColor,
    );
    if (s.text.length > 40) {
      return TextSpan(
        text: ' ${s.text} ',
        style: codeStyle.copyWith(
          backgroundColor: AppTheme.subtleSurfaceColor,
        ),
      );
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          color: AppTheme.subtleSurfaceColor,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(s.text, style: codeStyle),
      ),
    );
  }

  InlineSpan _imageSpan(MdInline s) {
    final url = s.imageUrl!;
    Widget wrap(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: child,
        ),
      ),
    );

    // 本地路径直接渲染
    if (url.isNotEmpty && !url.contains('://')) {
      final file = File(url);
      if (file.existsSync()) {
        return WidgetSpan(child: wrap(Image.file(file, fit: BoxFit.contain)));
      }
    }
    // 网络图片:加载失败回落到占位说明
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return WidgetSpan(
        child: wrap(
          Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => _imagePlaceholder(s),
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : _imagePlaceholder(s),
          ),
        ),
      );
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _imagePlaceholder(s),
    );
  }

  Widget _imagePlaceholder(MdInline s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.mutedSurfaceColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.borderColor, width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.image, size: 13, color: AppTheme.subtleTextColor),
          const SizedBox(width: 5),
          Text(
            s.text.isEmpty ? tr('图片') : s.text,
            style: TextStyle(fontSize: 12, color: AppTheme.subtleTextColor),
          ),
        ],
      ),
    );
  }

  void _openLink(BuildContext context, String url) {
    if (url.isEmpty) return;
    try {
      switch (defaultTargetPlatform) {
        case TargetPlatform.macOS:
          Process.run('open', [url]);
        case TargetPlatform.windows:
          Process.run('cmd', ['/c', 'start', '', url]);
        case TargetPlatform.linux:
          Process.run('xdg-open', [url]);
        default:
          Clipboard.setData(ClipboardData(text: url));
      }
    } catch (_) {
      Clipboard.setData(ClipboardData(text: url));
    }
  }
}

// ══════════════ 代码块 ══════════════

/// 语法高亮引擎(懒加载,一次注册全部语言)
class _CodeHighlighter {
  static final Highlight _engine = () {
    final h = Highlight();
    h.registerLanguages(builtinAllLanguages);
    return h;
  }();

  static const _aliases = {
    'js': 'javascript',
    'ts': 'typescript',
    'py': 'python',
    'rb': 'ruby',
    'sh': 'bash',
    'zsh': 'bash',
    'shell': 'bash',
    'yml': 'yaml',
    'golang': 'go',
    'objc': 'objectivec',
    'html': 'xml',
    'vue': 'xml',
  };

  /// 高亮失败(未知语言等)返回 null,调用方退回纯文本
  static TextSpan? highlight(String code, String? language, TextStyle base) {
    if (language == null || language.isEmpty) return null;
    final lang = _aliases[language.toLowerCase()] ?? language.toLowerCase();
    try {
      final result = _engine.highlight(code: code, language: lang);
      final renderer = TextSpanRenderer(
        base,
        AppTheme.isDarkMode ? atomOneDarkTheme : atomOneLightTheme,
      );
      result.render(renderer);
      return renderer.span;
    } catch (_) {
      return null;
    }
  }
}

/// 代码块:mutedSurface 底 + 语言标签 + 语法高亮 + 一键复制
class _CodeBlockView extends StatelessWidget {
  const _CodeBlockView({required this.block});

  final MdCodeBlock block;

  @override
  Widget build(BuildContext context) {
    final codeStyle = TextStyle(
      fontFamily: 'Menlo',
      fontFamilyFallback: const ['Consolas', 'monospace'],
      fontSize: 12.5,
      height: 1.6,
      color: AppTheme.headingColor,
    );
    final highlighted =
        _CodeHighlighter.highlight(block.code, block.language, codeStyle);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.mutedSurfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
            child: Row(
              children: [
                Text(
                  block.language ?? 'text',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: tr('复制代码'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    LucideIcons.copy,
                    size: 13,
                    color: AppTheme.subtleTextColor,
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: block.code));
                    AppToast.show(
                      context: context,
                      style: ToastificationStyle.flat,
                      applyBlurEffect: true,
                      type: ToastificationType.success,
                      autoCloseDuration: const Duration(seconds: 1),
                      title: const Text(
                        '代码已复制',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: highlighted != null
                  ? Text.rich(highlighted)
                  : Text(block.code, style: codeStyle),
            ),
          ),
        ],
      ),
    );
  }
}
