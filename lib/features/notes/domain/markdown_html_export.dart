/// 笔记导出 HTML(marktext 的 Export HTML)— AST → 自包含带样式文档。
/// 纯 Dart,可单测;含公式时引入 KaTeX CDN 自动渲染。
library;

import 'package:termora/features/notes/domain/markdown_parser.dart';

class MarkdownHtmlExport {
  MarkdownHtmlExport._();

  /// 完整 HTML 文档
  static String exportDocument(String title, String source) {
    final body = renderBody(source);
    final blocks = MarkdownParser.parse(source);
    final hasMath = blocks.any((b) => b is MdMathBlock);
    final hasMermaid = blocks.any(
      (b) => b is MdCodeBlock && b.language?.toLowerCase() == 'mermaid',
    );
    return '''
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_escape(title)}</title>
<style>
$_css
</style>
${hasMath ? _katex : ''}${hasMermaid ? _mermaid : ''}
</head>
<body>
<article>
$body
</article>
</body>
</html>
''';
  }

  /// 正文块渲染(测试断言用)
  static String renderBody(String source) {
    final buffer = StringBuffer();
    for (final block in MarkdownParser.parse(source)) {
      _writeBlock(buffer, block);
    }
    return buffer.toString();
  }

  static void _writeBlock(StringBuffer out, MdBlock block) {
    switch (block) {
      case MdHeading():
        out.writeln(
          '<h${block.level}>${_inline(block.spans)}</h${block.level}>',
        );
      case MdParagraph():
        out.writeln('<p>${_inline(block.spans)}</p>');
      case MdCodeBlock():
        final lang = block.language;
        // mermaid 交给页面里的 mermaid.js 现场渲染成图
        if (lang?.toLowerCase() == 'mermaid') {
          out.writeln('<pre class="mermaid">${_escape(block.code)}</pre>');
          return;
        }
        final cls = lang == null ? '' : ' class="language-${_escape(lang)}"';
        out.writeln('<pre><code$cls>${_escape(block.code)}</code></pre>');
      case MdQuote():
        out.writeln('<blockquote>');
        for (final child in block.children) {
          _writeBlock(out, child);
        }
        out.writeln('</blockquote>');
      case MdList():
        _writeList(out, block);
      case MdDivider():
        out.writeln('<hr>');
      case MdTable():
        _writeTable(out, block);
      case MdMathBlock():
        out.writeln('<div class="math">\$\$${_escape(block.tex)}\$\$</div>');
    }
  }

  /// 按缩进层级嵌套 ul/ol;任务项带禁用勾选框
  static void _writeList(StringBuffer out, MdList list) {
    final tag = list.ordered ? 'ol' : 'ul';
    var depth = -1;
    void open(int to) {
      while (depth < to) {
        out.writeln('<$tag>');
        depth++;
      }
    }

    void close(int to) {
      while (depth > to) {
        out.writeln('</$tag>');
        depth--;
      }
    }

    for (final item in list.items) {
      open(item.indent);
      close(item.indent);
      final checkbox = item.checked == null
          ? ''
          : '<input type="checkbox" disabled${item.checked! ? ' checked' : ''}> ';
      final cls = item.checked == null ? '' : ' class="task"';
      out.writeln('<li$cls>$checkbox${_inline(item.spans)}</li>');
    }
    close(-1);
  }

  static void _writeTable(StringBuffer out, MdTable table) {
    String align(int column) => switch (table.alignAt(column)) {
      MdTableAlign.left => '',
      MdTableAlign.center => ' style="text-align:center"',
      MdTableAlign.right => ' style="text-align:right"',
    };
    out.writeln('<table>');
    out.writeln('<thead><tr>');
    for (final (c, cell) in table.header.indexed) {
      out.writeln('<th${align(c)}>${_inline(cell)}</th>');
    }
    out.writeln('</tr></thead>');
    out.writeln('<tbody>');
    for (final row in table.rows) {
      out.writeln('<tr>');
      for (var c = 0; c < table.header.length; c++) {
        final cell = c < row.length ? row[c] : const <MdInline>[];
        out.writeln('<td${align(c)}>${_inline(cell)}</td>');
      }
      out.writeln('</tr>');
    }
    out.writeln('</tbody></table>');
  }

  static String _inline(List<MdInline> spans) {
    final out = StringBuffer();
    for (final s in spans) {
      if (s.imageUrl != null) {
        out.write(
          '<img src="${_escapeAttr(s.imageUrl!)}" alt="${_escapeAttr(s.text)}">',
        );
        continue;
      }
      var text = _escape(s.text);
      if (s.code) text = '<code>$text</code>';
      if (s.bold) text = '<strong>$text</strong>';
      if (s.italic) text = '<em>$text</em>';
      if (s.strikethrough) text = '<del>$text</del>';
      if (s.url != null) {
        text = '<a href="${_escapeAttr(s.url!)}">$text</a>';
      }
      out.write(text);
    }
    return out.toString();
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _escapeAttr(String s) =>
      _escape(s).replaceAll('"', '&quot;');

  /// 与应用预览一致的 github 风排版(浅色)
  static const _css = '''
:root { color-scheme: light; }
* { box-sizing: border-box; }
body {
  margin: 0; padding: 32px 24px 80px;
  font: 15px/1.7 -apple-system, "PingFang SC", "Microsoft YaHei", "Segoe UI", sans-serif;
  color: #4b5563; background: #fff;
}
article { max-width: 760px; margin: 0 auto; }
h1, h2, h3, h4, h5, h6 { color: #111827; line-height: 1.3; margin: 1.4em 0 .6em; }
h1 { font-size: 27px; } h2 { font-size: 21px; } h3 { font-size: 17.5px; }
h1, h2 { border-bottom: 1px solid #e2e5e0; padding-bottom: .25em; }
p { margin: .8em 0; }
a { color: #6a8a82; }
code {
  font-family: Menlo, Consolas, monospace; font-size: .88em;
  background: #f0f2ef; color: #6a8a82;
  padding: .15em .35em; border-radius: 4px;
}
pre {
  background: #f7f7f4; border: 1px solid #e2e5e0; border-radius: 10px;
  padding: 14px 16px; overflow-x: auto;
}
pre code { background: none; color: #111827; padding: 0; font-size: 12.5px; line-height: 1.6; }
blockquote {
  margin: .8em 0; padding: 8px 14px;
  border-left: 3px solid #6a8a82; background: #f7f7f4aa;
  border-radius: 0 8px 8px 0;
}
table { border-collapse: collapse; margin: 1em 0; }
th, td { border: 1px solid #e2e5e0; padding: 7px 12px; font-size: 13.5px; }
th { background: #f7f7f4; }
ul, ol { padding-left: 1.6em; }
li { margin: .25em 0; }
li.task { list-style: none; margin-left: -1.3em; }
hr { border: 0; border-top: 1px solid #e2e5e0; margin: 1.6em 0; }
img { max-width: 100%; border-radius: 8px; }
.math { text-align: center; margin: 1.2em 0; }
pre.mermaid {
  background: none;
  border: 0;
  padding: 0;
  text-align: center;
  margin: 1.4em 0;
}
''';

  /// 含图表时引入 mermaid 自动渲染(与公式一样,需要联网打开)
  static const _mermaid = '''
<script type="module">
import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
mermaid.initialize({ startOnLoad: true, theme: 'neutral', securityLevel: 'strict' });
</script>
''';

  /// 含公式时引入 KaTeX 自动渲染(需要联网打开)
  static const _katex = '''
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
  onload="renderMathInElement(document.body,{delimiters:[{left:'\$\$',right:'\$\$',display:true}]});"></script>
''';
}
