import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/notes/domain/markdown_source_highlighter.dart';

/// 所见即所得编辑控制器 — buildTextSpan 按 token 实时上样式:
/// 标题变大变粗、粗斜删直接生效、代码/公式等宽、列表记号与链接着品牌色。
///
/// 选区感知的动态显隐(marktext 式):光标不在的行,行内语法记号
/// (# 前缀、** ~~ ` 、链接的括号和地址)用透明色 + 极小字号隐藏——
/// 字符逻辑上还在(光标偏移、撤销、IME 不受影响),视觉宽度趋近零;
/// 光标移到该行记号立即显形(淡灰),供直接编辑。
class MarkdownEditingController extends TextEditingController {
  String? _cacheText;
  List<MdSourceToken> _cacheTokens = const [];

  /// 查找命中高亮区间(升序不重叠)与活动命中下标
  List<TextRange> _highlights = const [];
  int _activeHighlight = -1;

  /// 聚焦模式:光标所在段落外的文字淡化
  bool _focusMode = false;

  /// 本次 build 的聚焦段落范围(_emit 分段时用)
  int _focusStart = -1;
  int _focusEnd = -1;

  bool get focusMode => _focusMode;
  set focusMode(bool on) {
    if (_focusMode == on) return;
    _focusMode = on;
    notifyListeners();
  }

  /// 隐藏态:透明 + 0.1 字号把视觉宽度压到近零,字符仍占逻辑位置
  static const _concealedStyle = TextStyle(
    color: Colors.transparent,
    fontSize: 0.1,
  );

  /// 占位态:透明但保留原始宽度,空出的位置由装饰层画真实符号
  /// (圆点/勾选框/引用条/分隔线,marktext 渲染方式)
  static const _placeholderStyle = TextStyle(color: Colors.transparent);

  static final _orderedMarkerRe = RegExp(r'^\s*\d');

  /// 该 token 是否由装饰层代画(光标不在行上时字符转透明占位):
  /// 无序列表符/任务框、引用前缀、分隔线。有序编号保留数字可见。
  static bool isReplacedByDecoration(MdSourceToken t, String text) {
    switch (t.kind) {
      case MdSourceKind.quote:
      case MdSourceKind.divider:
        return true;
      case MdSourceKind.listMarker:
        return !_orderedMarkerRe.hasMatch(text.substring(t.start, t.end));
      default:
        return false;
    }
  }

  /// 给装饰层用:当前文本的 token(与 buildTextSpan 同一份缓存)
  List<MdSourceToken> tokensFor(String text) {
    if (_cacheText != text) {
      _cacheTokens = MarkdownSourceHighlighter.tokenize(text);
      _cacheText = text;
    }
    return _cacheTokens;
  }

  /// 设置查找高亮;内容一致时不通知,避免与查找条互相触发死循环
  void setHighlights(List<TextRange> ranges, {int active = -1}) {
    if (active == _activeHighlight && _rangesEqual(ranges, _highlights)) {
      return;
    }
    _highlights = ranges;
    _activeHighlight = active;
    notifyListeners();
  }

  static bool _rangesEqual(List<TextRange> a, List<TextRange> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    if (text.isEmpty) return TextSpan(style: style);
    tokensFor(text);

    // 光标/选区所在的行,记号显形;无有效选区(未聚焦)则全部隐藏
    var activeStart = -1;
    var activeEnd = -1;
    if (value.selection.isValid) {
      (activeStart, activeEnd) = MarkdownSourceHighlighter.activeLineRange(
        text,
        value.selection.start,
        value.selection.end,
      );
    }
    // 聚焦模式:光标所在段落之外整体淡化
    _focusStart = -1;
    _focusEnd = -1;
    if (_focusMode && value.selection.isValid) {
      final (blockStart, blockEnd) = MarkdownSourceHighlighter.focusBlockRange(
        text,
        value.selection.start,
        value.selection.end,
      );
      _focusStart = blockStart;
      _focusEnd = blockEnd;
    }

    final children = <TextSpan>[];
    var index = 0;
    for (final t in _cacheTokens) {
      if (t.start < index || t.end > text.length) continue; // 防御越界/重叠
      if (t.start > index) {
        _emit(text, index, t.start, null, children);
      }
      final active = t.start <= activeEnd && t.end > activeStart;
      if (t.concealable && !active) {
        // 隐藏记号不叠命中高亮(视觉宽度近零,高亮没有意义)
        children.add(
          TextSpan(text: text.substring(t.start, t.end), style: _concealedStyle),
        );
      } else if (!active && isReplacedByDecoration(t, text)) {
        // 透明占位,符号本体由 EditorDecorations 绘制
        children.add(
          TextSpan(
            text: text.substring(t.start, t.end),
            style: _placeholderStyle,
          ),
        );
      } else {
        _emit(text, t.start, t.end, _styleFor(t), children);
      }
      index = t.end;
    }
    if (index < text.length) {
      _emit(text, index, text.length, null, children);
    }
    return TextSpan(style: style, children: children);
  }

  /// 输出 [start, end) 的文本,与查找命中区间求交叠加高亮底色
  void _emit(
    String text,
    int start,
    int end,
    TextStyle? style,
    List<TextSpan> out,
  ) {
    if (_highlights.isEmpty) {
      _emitFocusAware(text, start, end, style, out);
      return;
    }
    var pos = start;
    for (final (i, r) in _highlights.indexed) {
      if (r.end <= pos || r.start >= end) continue;
      final hs = r.start.clamp(pos, end);
      if (hs > pos) {
        _emitFocusAware(text, pos, hs, style, out);
      }
      final he = r.end.clamp(pos, end);
      final base = style ?? const TextStyle();
      out.add(
        TextSpan(
          text: text.substring(hs, he),
          style: base.copyWith(
            backgroundColor: AppTheme.warningColor.withValues(
              alpha: i == _activeHighlight ? 0.55 : 0.25,
            ),
          ),
        ),
      );
      pos = he;
    }
    if (pos < end) {
      _emitFocusAware(text, pos, end, style, out);
    }
  }

  /// 聚焦模式下把段落外的部分拆出来淡化;关闭时原样输出
  void _emitFocusAware(
    String text,
    int start,
    int end,
    TextStyle? style,
    List<TextSpan> out,
  ) {
    if (_focusStart < 0) {
      out.add(TextSpan(text: text.substring(start, end), style: style));
      return;
    }
    void piece(int s, int e, {required bool dimmed}) {
      if (s >= e) return;
      out.add(
        TextSpan(
          text: text.substring(s, e),
          style: dimmed ? _dimStyle(style) : style,
        ),
      );
    }

    piece(start, math.min(end, _focusStart), dimmed: true);
    piece(
      math.max(start, _focusStart),
      math.min(end, _focusEnd),
      dimmed: false,
    );
    piece(math.max(start, _focusEnd), end, dimmed: true);
  }

  TextStyle _dimStyle(TextStyle? style) {
    final dim = (style?.color ?? AppTheme.bodyColor).withValues(alpha: 0.3);
    return (style ?? const TextStyle()).copyWith(color: dim);
  }

  static const _headingSizes = [19.5, 17.5, 16.5, 15.0, 14.0, 13.5];

  TextStyle _styleFor(MdSourceToken t) {
    const mono = TextStyle(
      fontFamily: 'Menlo',
      fontFamilyFallback: ['Consolas', 'monospace'],
    );
    switch (t.kind) {
      case MdSourceKind.syntax:
        return TextStyle(
          color: AppTheme.subtleTextColor.withValues(alpha: 0.55),
        );
      case MdSourceKind.heading:
        return TextStyle(
          fontSize: _headingSizes[(t.level - 1).clamp(0, 5)],
          fontWeight: FontWeight.w700,
          color: AppTheme.headingColor,
        );
      case MdSourceKind.bold:
        return TextStyle(
          fontWeight: FontWeight.w700,
          color: AppTheme.headingColor,
        );
      case MdSourceKind.italic:
        return const TextStyle(fontStyle: FontStyle.italic);
      case MdSourceKind.boldItalic:
        return TextStyle(
          fontWeight: FontWeight.w700,
          fontStyle: FontStyle.italic,
          color: AppTheme.headingColor,
        );
      case MdSourceKind.strike:
        return TextStyle(
          decoration: TextDecoration.lineThrough,
          color: AppTheme.subtleTextColor,
        );
      case MdSourceKind.codeSpan:
        return mono.copyWith(fontSize: 12, color: AppTheme.brandColor);
      case MdSourceKind.codeBlock:
        // 12 × 1.9 ≈ 正文 13.5 × 1.7 的行高,块内空行(正文行高)节奏一致
        return mono.copyWith(
          fontSize: 12,
          height: 1.9,
          color: AppTheme.headingColor,
        );
      case MdSourceKind.math:
        return mono.copyWith(
          fontSize: 12,
          height: 1.9,
          fontStyle: FontStyle.italic,
          color: AppTheme.brandColor,
        );
      case MdSourceKind.link:
        return TextStyle(
          color: AppTheme.brandColor,
          decoration: TextDecoration.underline,
          decorationColor: AppTheme.brandColor.withValues(alpha: 0.4),
        );
      case MdSourceKind.url:
        return TextStyle(
          color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
        );
      case MdSourceKind.listMarker:
        return TextStyle(
          fontWeight: FontWeight.w600,
          color: AppTheme.brandColor,
        );
      case MdSourceKind.quote:
        return TextStyle(color: AppTheme.brandColor);
      case MdSourceKind.divider:
        return TextStyle(
          color: AppTheme.subtleTextColor.withValues(alpha: 0.55),
        );
    }
  }
}
