part of 'terminal_page.dart';

const int _defaultPtyColumns = 120;
const int _defaultPtyRows = 32;
const int _maxTerminalLines = 1200;

/// The VT/xterm emulator core mixed into the terminal session State: the two
/// screen buffers, cursor, style, modes, tab stops, palette, title, and the
/// escape-sequence parse pipeline. It is a mixin (rather than a standalone
/// object) so it shares the State's lifecycle and the widget's members without
/// any forwarding; the widget supplies the I/O boundary via the abstract
/// members declared at the bottom.
mixin _TerminalEmulator on State<_TerminalSessionView> {
  final List<TerminalLine> _lines = [];
  bool _isLastOutputLineOpen = false;
  int _ptyColumns = _defaultPtyColumns;
  int _ptyRows = _defaultPtyRows;
  AnsiStyle _ansiStyle = const AnsiStyle();
  int _cursorX = 0;
  int _cursorY = 0;
  int _savedCursorX = 0;
  int _savedCursorY = 0;
  AnsiStyle _savedAnsiStyle = const AnsiStyle();
  bool _wrapPending = false;
  bool _savedWrapPending = false;
  bool _savedG0LineDrawing = false;
  bool _savedG1LineDrawing = false;
  bool _savedUseG1Charset = false;
  bool _savedOriginMode = false;
  bool _savedAutoWrapMode = true;
  String? _activeOsc8Url;

  // ── 格子级文本选择(替代 SelectionArea:光标制取整会把按在字形
  // 中后段的首字取整掉;终端语义是按到哪个格子就从哪个格子选起)──
  // anchor = 按下格,focus = 拖到的格;两者都含入选择。
  ({int row, int col})? _gridSelAnchor;
  ({int row, int col})? _gridSelFocus;

  bool get _hasGridSelection => _gridSelAnchor != null && _gridSelFocus != null;

  void _clearGridSelection() {
    _gridSelAnchor = null;
    _gridSelFocus = null;
  }

  bool _isAltBufferActive = false;
  final List<TerminalLine> _normalLines = [];
  int _normalCursorX = 0;
  int _normalCursorY = 0;
  int _normalSavedCursorX = 0;
  int _normalSavedCursorY = 0;
  AnsiStyle _normalAnsiStyle = const AnsiStyle();
  AnsiStyle _normalSavedAnsiStyle = const AnsiStyle();
  bool _normalWrapPending = false;
  bool _normalSavedWrapPending = false;
  bool _normalG0LineDrawing = false;
  bool _normalG1LineDrawing = false;
  bool _normalUseG1Charset = false;
  bool _normalSavedG0LineDrawing = false;
  bool _normalSavedG1LineDrawing = false;
  bool _normalSavedUseG1Charset = false;
  bool _normalSavedOriginMode = false;
  bool _normalSavedAutoWrapMode = true;

  int _scrollTopMargin = 0;
  int _scrollBottomMargin = _defaultPtyRows - 1;

  bool _showCursor = true;
  TerminalCursorShape _cursorShape = TerminalCursorShape.block;
  bool _cursorBlinkMode = false;
  bool _autoWrapMode = true;
  bool _reverseWrapAroundMode = false;
  bool _bracketedPasteMode = false;
  bool _synchronizedOutputMode = false;
  bool _synchronizedOutputRefreshPending = false;
  Timer? _synchronizedOutputSafetyTimer;
  bool _applicationCursorMode = false;
  bool _applicationKeypadMode = false;
  bool _originMode = false;
  bool _insertMode = false;
  bool _lineFeedNewLineMode = false;
  bool _focusReportingMode = false;
  bool _alternateScrollMode = true;
  int _modifyOtherKeysMode = 0;
  bool _g0LineDrawing = false;
  bool _g1LineDrawing = false;
  bool _useG1Charset = false;
  TerminalCharset get _charset => TerminalCharset(
    g0LineDrawing: _g0LineDrawing,
    g1LineDrawing: _g1LineDrawing,
    useG1: _useG1Charset,
  );
  int _mouseTrackingMode = 0;
  bool _sgrMouseMode = false;
  bool _sgrPixelMouseMode = false;
  bool _utf8MouseMode = false;
  bool _urxvtMouseMode = false;
  bool _mouseButtonDown = false;
  int _lastMouseButtonCode = 0;
  int _lastMouseColumn = -1;
  int _lastMouseRow = -1;
  final TerminalTabStops _tabStops = TerminalTabStops();
  final TerminalPalette _palette = TerminalPalette();
  final TerminalTitleStack _titleStack = TerminalTitleStack();
  String _pendingEscapeSequence = '';
  String _lastPrintedCharacter = ' ';
  Color? _dynamicForegroundColor;
  Color? _dynamicBackgroundColor;
  Color? _dynamicCursorColor;

  // 配色方案(全局主题)提供的前景/背景/光标默认;程序 OSC 10/11/12 仍可覆盖
  Color? _themeForeground;
  Color? _themeBackground;
  Color? _themeCursor;

  // --- Read-only widget metrics the emulator reports on ---
  double get _lastCellWidth;
  double get _lastLineHeight;

  /// Updates the working directory reported by the shell via OSC 7.
  void _setReportedCwd(String path);

  // --- I/O boundary implemented by the widget State ---
  void _sendRawInputToProcess(String payload);

  /// 写入了带 SGR 5/6 闪烁属性的内容 — State 据此启动闪烁时钟。
  void _noteBlinkContent();
  void _notifyTerminalOutputChanged();
  void _publishUiState();
  /// 节流版搜索重扫(输出路径用):搜索关闭时零开销,开着时合并到冷却窗口
  void _scheduleSearchRefresh();
  void _scrollToBottom();
  void _deferSynchronizedOutputRefresh();
  void _setSynchronizedOutputMode(bool enable);

  void _appendOutput(String text, TerminalLineType type) {
    if (text.isEmpty || !mounted) return;
    // SGR 颜色在解析时就固化进 span,这里按当前主题选默认调色板
    _palette.darkDefaults = AppTheme.isDarkMode;
    _writeTerminalOutput(text, type);
    _trimLines();
    if (_synchronizedOutputMode) {
      _deferSynchronizedOutputRefresh();
      return;
    }
    // 输出驱动的搜索重扫走节流版:洪峰时(每秒可达 ~125 次 flush)
    // 每次全缓冲区跑正则太重;用户操作(改查询/切选项)仍走即时版
    _scheduleSearchRefresh();
    _notifyTerminalOutputChanged();
    _scrollToBottom();
  }

  void _appendLine(String text, TerminalLineType type) {
    if (!mounted) return;
    _isLastOutputLineOpen = false;
    _wrapPending = false;
    _lines.add(TerminalLine.plain(text, type));
    _cursorY = _lines.length - 1;
    _cursorX = _lines.last.length;
    _trimLines();
    _scheduleSearchRefresh();
    _notifyTerminalOutputChanged();
    _scrollToBottom();
  }

  void _writeTerminalOutput(String text, TerminalLineType type) {
    if (_pendingEscapeSequence.isNotEmpty) {
      text = _pendingEscapeSequence + text;
      _pendingEscapeSequence = '';
    }
    final buffer = StringBuffer();

    void flushBuffer() {
      if (buffer.isEmpty) return;
      _writeBufferAtCursor(buffer.toString(), type);
      buffer.clear();
    }

    var index = 0;
    while (index < text.length) {
      final unit = text.codeUnitAt(index);
      if (unit == 0x1B) {
        flushBuffer();
        final nextIndex = _consumeEscapeSequence(text, index, type);
        if (nextIndex < 0) {
          _pendingEscapeSequence = text.substring(index);
          break;
        }
        index = nextIndex > index ? nextIndex : index + 1;
        continue;
      }
      if (unit == 0x9B) {
        flushBuffer();
        final nextIndex = _consumeCsiControl(text, index + 1, type);
        if (nextIndex < 0) {
          _pendingEscapeSequence = text.substring(index);
          break;
        }
        index = nextIndex;
        continue;
      }
      if (unit == 0x9D) {
        flushBuffer();
        final nextIndex = _consumeOscControl(text, index + 1, type);
        if (nextIndex < 0) {
          _pendingEscapeSequence = text.substring(index);
          break;
        }
        index = nextIndex;
        continue;
      }
      if (unit == 0x90 || unit == 0x98 || unit == 0x9E || unit == 0x9F) {
        flushBuffer();
        final nextIndex = _consumeStringControl(text, index + 1, unit);
        if (nextIndex < 0) {
          _pendingEscapeSequence = text.substring(index);
          break;
        }
        index = nextIndex;
        continue;
      }
      if (unit == 0x0A) {
        flushBuffer();
        _cancelPendingWrap();
        if (_shouldScrollRegion && _cursorY == _scrollBottomMargin) {
          _scrollRegionUp(_scrollTopMargin, _scrollBottomMargin, type);
        } else {
          if (_cursorY == _lines.length - 1) {
            _isLastOutputLineOpen = false;
          }
          _cursorY++;
        }
        if (_lineFeedNewLineMode) {
          _cursorX = 0;
        }
        index++;
        continue;
      }
      if (unit == 0x0D) {
        flushBuffer();
        _cancelPendingWrap();
        _cursorX = 0;
        index++;
        continue;
      }
      if (unit == 0x08) {
        flushBuffer();
        _handleBackspace(type);
        index++;
        continue;
      }
      if (unit == 0x09) {
        flushBuffer();
        _cancelPendingWrap();
        _cursorX = _tabStops.next(_cursorX, _ptyColumns);
        index++;
        continue;
      }
      if (unit == 0x0E) {
        flushBuffer();
        _useG1Charset = true;
        index++;
        continue;
      }
      if (unit == 0x0F) {
        flushBuffer();
        _useG1Charset = false;
        index++;
        continue;
      }
      if (unit < 0x20 || unit == 0x7F) {
        index++;
        continue;
      }
      if (unit >= 0x80 && unit <= 0x9F) {
        flushBuffer();
        _handleC1Control(unit, type);
        index++;
        continue;
      }
      final rune = _terminalRuneAt(text, index);
      buffer.write(String.fromCharCode(rune));
      index += rune > 0xFFFF ? 2 : 1;
    }
    flushBuffer();
  }

  int _terminalRuneAt(String text, int index) {
    final first = text.codeUnitAt(index);
    if (first >= 0xD800 && first <= 0xDBFF && index + 1 < text.length) {
      final second = text.codeUnitAt(index + 1);
      if (second >= 0xDC00 && second <= 0xDFFF) {
        return 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
      }
    }
    return first;
  }

  bool _handleC1Control(int unit, TerminalLineType type) {
    switch (unit) {
      case 0x84:
        _cancelPendingWrap();
        _indexCursor(type);
        return true;
      case 0x85:
        _cancelPendingWrap();
        _cursorX = 0;
        _moveCursorToNextLine(type);
        return true;
      case 0x88:
        _tabStops.setAt(_cursorX);
        _cancelPendingWrap();
        return true;
      case 0x8D:
        _cancelPendingWrap();
        _reverseIndexCursor(type);
        return true;
      default:
        return false;
    }
  }

  int _consumeEscapeSequence(
    String text,
    int escapeIndex,
    TerminalLineType type,
  ) {
    if (escapeIndex + 1 >= text.length) return -1;
    final marker = text.codeUnitAt(escapeIndex + 1);

    if (marker == 0x5B) {
      return _consumeCsiControl(text, escapeIndex + 2, type);
    }

    if (marker == 0x5D) {
      return _consumeOscControl(text, escapeIndex + 2, type);
    }

    if (marker == 0x50 || marker == 0x58 || marker == 0x5E || marker == 0x5F) {
      return _consumeStringControl(text, escapeIndex + 2, marker);
    }

    if (marker == 0x28 ||
        marker == 0x29 ||
        marker == 0x2A ||
        marker == 0x2B ||
        marker == 0x25 ||
        marker == 0x23) {
      if (escapeIndex + 2 >= text.length) return -1;
      _handleCharsetSequence(marker, text.codeUnitAt(escapeIndex + 2), type);
      return math.min(text.length, escapeIndex + 3);
    }

    if (marker >= 0x30 && marker <= 0x7E) {
      _handleEscSequence(marker, type);
      return escapeIndex + 2;
    }

    return escapeIndex + 2;
  }

  int _consumeCsiControl(String text, int paramsStart, TerminalLineType type) {
    var end = paramsStart;
    while (end < text.length) {
      final code = text.codeUnitAt(end);
      if (code >= 0x40 && code <= 0x7E) {
        _handleCsiSequence(text.substring(paramsStart, end), code, type);
        return end + 1;
      }
      end++;
    }
    return -1;
  }

  int _consumeOscControl(String text, int payloadStart, TerminalLineType type) {
    var end = payloadStart;
    while (end < text.length) {
      final code = text.codeUnitAt(end);
      if (code == 0x07 || code == 0x9C) {
        _handleOscSequence(text.substring(payloadStart, end), type);
        return end + 1;
      }
      if (code == 0x1B &&
          end + 1 < text.length &&
          text.codeUnitAt(end + 1) == 0x5C) {
        _handleOscSequence(text.substring(payloadStart, end), type);
        return end + 2;
      }
      end++;
    }
    return -1;
  }

  int _consumeStringControl(String text, int payloadStart, int marker) {
    var end = payloadStart;
    while (end < text.length) {
      final code = text.codeUnitAt(end);
      if (code == 0x07 || code == 0x9C) {
        _handleStringControlSequence(marker, text.substring(payloadStart, end));
        return end + 1;
      }
      if (code == 0x1B &&
          end + 1 < text.length &&
          text.codeUnitAt(end + 1) == 0x5C) {
        _handleStringControlSequence(marker, text.substring(payloadStart, end));
        return end + 2;
      }
      end++;
    }
    return -1;
  }

  void _handleStringControlSequence(int marker, String payload) {
    if (marker == 0x50 || marker == 0x90) {
      _handleDcsSequence(payload);
    } else if (marker == 0x5F || marker == 0x9F) {
      _handleApcSequence(payload);
    }
  }

  // ── Kitty 图形协议(APC _G)分块累积状态 ──
  final StringBuffer _kittyData = StringBuffer();
  Map<String, String>? _kittyControl;

  void _handleApcSequence(String payload) {
    if (payload.isEmpty || payload.codeUnitAt(0) != 0x47) return; // 'G'
    try {
      _handleKitty(payload.substring(1));
    } catch (_) {
      _kittyData.clear();
      _kittyControl = null;
    }
  }

  /// Kitty 图形:`G<控制键值>;<base64 数据块>`。首块带控制参数,
  /// 后续块只带 `m=1/0` 续传;m=0(或缺省)为末块,此时组装成图片。
  void _handleKitty(String body) {
    final semi = body.indexOf(';');
    final controlStr = semi < 0 ? body : body.substring(0, semi);
    final data = semi < 0 ? '' : body.substring(semi + 1);
    final control = <String, String>{};
    for (final pair in controlStr.split(',')) {
      final eq = pair.indexOf('=');
      if (eq > 0) control[pair.substring(0, eq)] = pair.substring(eq + 1);
    }

    // 首块记下控制参数;续传块只带 m=,控制沿用首块
    _kittyControl ??= control;
    _kittyData.write(data.trim());

    // 当前块 m=1 表示还有后续
    if ((control['m'] ?? '0') == '1') return;

    final ctrl = _kittyControl!;
    final b64 = _kittyData.toString();
    _kittyData.clear();
    _kittyControl = null;

    final action = ctrl['a'] ?? 'T';
    // 只处理传输并显示(T)与放置(p);纯查询/删除忽略
    if (action != 'T' && action != 'p' && action != 't') return;
    if (b64.isEmpty) return;

    final bytes = base64Decode(base64.normalize(b64));
    final format = ctrl['f'] ?? '100';
    TerminalImage? image;
    if (format == '100' || format == '0') {
      // PNG(或默认)——交给 Image.memory
      image = TerminalImage(bytes: bytes, pixelWidth: 0, pixelHeight: 0);
    } else if (format == '24' || format == '32') {
      final w = int.tryParse(ctrl['s'] ?? '') ?? 0;
      final h = int.tryParse(ctrl['v'] ?? '') ?? 0;
      image = decodeRawPixels(bytes, w, h, hasAlpha: format == '32');
    }
    // a=t 仅传输不显示:解码成功也不放置(此实现不做图片库缓存)
    if (image != null && action != 't') _placeImage(image);
  }

  void _handleDcsSequence(String payload) {
    if (payload.startsWith(r'$q')) {
      _handleDcsStatusStringRequest(payload.substring(2));
      return;
    }
    // Sixel:可选数字参数 P1;P2;P3 后接 'q',再是图形数据
    final qi = payload.indexOf('q');
    if (qi >= 0 && _sixelParamsPattern.hasMatch(payload.substring(0, qi))) {
      _handleSixel(payload);
      return;
    }
    if (!payload.startsWith('+q')) return;
    final query = payload.substring(2);
    if (query.isEmpty) return;
    for (final encodedName in query.split(';')) {
      if (encodedName.isEmpty) continue;
      final name = _decodeHexText(encodedName);
      if (name == null || name.isEmpty) {
        _sendRawInputToProcess('\x1bP0+r$encodedName\x1b\\');
        continue;
      }
      final response = _terminalCapabilityResponse(name);
      if (response == null) {
        _sendRawInputToProcess('\x1bP0+r$encodedName\x1b\\');
      } else {
        _sendRawInputToProcess('\x1bP1+r${_encodeHexText(response)}\x1b\\');
      }
    }
  }

  static final RegExp _sixelParamsPattern = RegExp(r'^[0-9;]*$');

  void _handleSixel(String payload) {
    try {
      final image = decodeSixel(payload);
      if (image != null) _placeImage(image);
    } catch (_) {
      // 图片解码失败不影响终端
    }
  }

  /// 把一张内联图片放到缓冲区:另起一行承载,光标移到其下方续排。
  void _placeImage(TerminalImage image) {
    const type = TerminalLineType.stdout;
    // 若当前行已有内容/图片,先换到新行
    _ensureCursorLine(type);
    if (_lines[_cursorY].image != null ||
        _lines[_cursorY].text.trim().isNotEmpty ||
        _cursorX > 0) {
      _moveCursorToNextLine(type);
      _ensureCursorLine(type);
    }
    _lines[_cursorY]
      ..clear()
      ..image = image;
    // 光标移到图片下一行,后续文本排在图片下方
    _moveCursorToNextLine(type);
    _ensureCursorLine(type);
    _cursorX = 0;
    _wrapPending = false;
  }

  void _handleDcsStatusStringRequest(String query) {
    final response = _dcsStatusStringResponse(query);
    if (response == null) {
      _sendRawInputToProcess('\x1bP0\$r$query\x1b\\');
      return;
    }
    _sendRawInputToProcess('\x1bP1\$r$response\x1b\\');
  }

  String? _dcsStatusStringResponse(String query) {
    switch (query) {
      case 'm':
        return '${TerminalSgr.toParameters(_ansiStyle)}m';
      case 'r':
        return '${_scrollTopMargin + 1};${_scrollBottomMargin + 1}r';
      case ' q':
        return '${_cursorShapeParameter()} q';
      case '"q':
        return '0"q';
      default:
        return null;
    }
  }

  String? _terminalCapabilityResponse(String name) {
    switch (name) {
      case 'Co':
      case 'colors':
        return '$name=256';
      case 'cols':
        return '$name=$_ptyColumns';
      case 'lines':
        return '$name=$_ptyRows';
      case 'it':
        return '$name=8';
      case 'TN':
      case 'name':
        return '$name=xterm-256color';
      case 'Tc':
      case 'RGB':
      case 'AX':
        return name;
      case 'Ms':
        return '$name=\\E]52;%p1%s;%p2%s\\007';
      case 'Ss':
        return '$name=\\E[%p1%d q';
      case 'Se':
        return '$name=\\E[2 q';
      case 'setaf':
        return '$name=\\E[38;5;%p1%dm';
      case 'setab':
        return '$name=\\E[48;5;%p1%dm';
      case 'setrgbf':
        return '$name=\\E[38;2;%p1%d;%p2%d;%p3%dm';
      case 'setrgbb':
        return '$name=\\E[48;2;%p1%d;%p2%d;%p3%dm';
      case 'op':
        return '$name=\\E[39;49m';
      case 'sgr0':
        return '$name=\\E(B\\E[m';
      case 'bold':
        return '$name=\\E[1m';
      case 'dim':
        return '$name=\\E[2m';
      case 'sitm':
        return '$name=\\E[3m';
      case 'ritm':
        return '$name=\\E[23m';
      case 'smul':
        return '$name=\\E[4m';
      case 'rmul':
        return '$name=\\E[24m';
      case 'smso':
        return '$name=\\E[7m';
      case 'rmso':
        return '$name=\\E[27m';
      case 'rev':
        return '$name=\\E[7m';
      case 'invis':
        return '$name=\\E[8m';
      case 'smxx':
        return '$name=\\E[9m';
      case 'rmxx':
        return '$name=\\E[29m';
      case 'clear':
        return '$name=\\E[H\\E[2J';
      case 'civis':
        return '$name=\\E[?25l';
      case 'cnorm':
      case 'cvvis':
        return '$name=\\E[?25h';
      case 'smcup':
        return '$name=\\E[?1049h';
      case 'rmcup':
        return '$name=\\E[?1049l';
      case 'smkx':
        return '$name=\\E[?1h\\E=';
      case 'rmkx':
        return '$name=\\E[?1l\\E>';
      case 'cup':
        return '$name=\\E[%i%p1%d;%p2%dH';
      case 'ed':
        return '$name=\\E[J';
      case 'el':
        return '$name=\\E[K';
      case 'el1':
        return '$name=\\E[1K';
      case 'dch1':
        return '$name=\\E[P';
      case 'dl1':
        return '$name=\\E[M';
      case 'ich1':
        return '$name=\\E[@';
      case 'il1':
        return '$name=\\E[L';
      case 'kbs':
        return '$name=\\177';
      case 'kich1':
        return '$name=\\E[2~';
      case 'kdch1':
        return '$name=\\E[3~';
      case 'khome':
        return '$name=\\EOH';
      case 'kend':
        return '$name=\\EOF';
      case 'kpp':
        return '$name=\\E[5~';
      case 'knp':
        return '$name=\\E[6~';
      case 'kcuu1':
        return '$name=\\EOA';
      case 'kcud1':
        return '$name=\\EOB';
      case 'kcuf1':
        return '$name=\\EOC';
      case 'kcub1':
        return '$name=\\EOD';
      case 'kf1':
        return '$name=\\EOP';
      case 'kf2':
        return '$name=\\EOQ';
      case 'kf3':
        return '$name=\\EOR';
      case 'kf4':
        return '$name=\\EOS';
      case 'kf5':
        return '$name=\\E[15~';
      case 'kf6':
        return '$name=\\E[17~';
      case 'kf7':
        return '$name=\\E[18~';
      case 'kf8':
        return '$name=\\E[19~';
      case 'kf9':
        return '$name=\\E[20~';
      case 'kf10':
        return '$name=\\E[21~';
      case 'kf11':
        return '$name=\\E[23~';
      case 'kf12':
        return '$name=\\E[24~';
      default:
        return null;
    }
  }

  String? _decodeHexText(String value) {
    if (value.length.isOdd) return null;
    final bytes = <int>[];
    for (var index = 0; index < value.length; index += 2) {
      final byte = int.tryParse(value.substring(index, index + 2), radix: 16);
      if (byte == null) return null;
      bytes.add(byte);
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  String _encodeHexText(String value) {
    final buffer = StringBuffer();
    for (final byte in utf8.encode(value)) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  void _handleCsiSequence(String params, int finalCode, TerminalLineType type) {
    if (finalCode == 0x6D && _csiParameterBytes(params).startsWith('>')) {
      _handleXtermKeyModifierOptions(params);
      return;
    }
    if (finalCode == 0x6D) {
      _ansiStyle = TerminalSgr.apply(_ansiStyle, params, _palette);
      if (_ansiStyle.blink) _noteBlinkContent();
      return;
    }

    final parameterBytes = _csiParameterBytes(params);
    final cleanParams =
        parameterBytes.startsWith('?') ||
            parameterBytes.startsWith('>') ||
            parameterBytes.startsWith('=')
        ? parameterBytes.substring(1)
        : parameterBytes.startsWith('!')
        ? parameterBytes.substring(1)
        : parameterBytes;
    final args = cleanParams.isEmpty
        ? <int>[]
        : cleanParams
              .split(';')
              .map((part) => int.tryParse(part) ?? 0)
              .toList(growable: false);
    final arg0 = args.isNotEmpty ? args[0] : 0;
    final arg1 = args.length > 1 ? args[1] : 0;
    if (_csiCancelsPendingWrap(finalCode, params)) {
      _cancelPendingWrap();
    }

    switch (finalCode) {
      case 0x40:
        final count = arg0 <= 0 ? 1 : arg0;
        if (_csiHasIntermediate(params, 0x20)) {
          _scrollColumnsLeft(count, type);
        } else {
          _ensureCursorLine(type);
          _lines[_cursorY].insertChars(_cursorX, count, _ansiStyle);
          _lines[_cursorY].truncateTo(_ptyColumns);
        }
      case 0x41:
        final n = arg0 <= 0 ? 1 : arg0;
        if (_csiHasIntermediate(params, 0x20)) {
          _scrollColumnsRight(n, type);
        } else {
          _moveCursorRows(-n, type);
        }
      case 0x42:
        final n = arg0 <= 0 ? 1 : arg0;
        _moveCursorRows(n, type);
      case 0x43:
      case 0x61:
        final n = arg0 <= 0 ? 1 : arg0;
        _cursorX = _clampInt(_cursorX + n, 0, _maxCursorColumn);
      case 0x62:
        final count = arg0 <= 0 ? 1 : arg0;
        _writeBufferAtCursor(_lastPrintedCharacter * count, type);
      case 0x44:
        final n = arg0 <= 0 ? 1 : arg0;
        _cursorX = math.max(0, _cursorX - n);
      case 0x45:
        final n = arg0 <= 0 ? 1 : arg0;
        _moveCursorRows(n, type);
        _cursorX = 0;
      case 0x46:
        final n = arg0 <= 0 ? 1 : arg0;
        _moveCursorRows(-n, type);
        _cursorX = 0;
      case 0x64:
        _setCursorRowFromParam(arg0, type);
      case 0x65:
        final n = arg0 <= 0 ? 1 : arg0;
        _moveCursorRows(n, type);
      case 0x47:
      case 0x60:
        final col = arg0 <= 0 ? 1 : arg0;
        _cursorX = _clampInt(col - 1, 0, _maxCursorColumn);
      case 0x48:
      case 0x66:
        _setCursorPositionFromParams(arg0, arg1, type);
      case 0x49:
        final count = arg0 <= 0 ? 1 : arg0;
        _cursorX = _tabStops.next(_cursorX, _ptyColumns, count);
      case 0x5A:
        final count = arg0 <= 0 ? 1 : arg0;
        _cursorX = _tabStops.previous(_cursorX, count);
      case 0x4A:
        _ensureCursorLine(type);
        if (arg0 == 0) {
          _lines[_cursorY].eraseFrom(
            _cursorX,
            style: _ansiStyle,
            maxCells: _ptyColumns,
          );
          while (_lines.length > _cursorY + 1) {
            _lines.removeLast();
          }
        } else if (arg0 == 1) {
          for (var i = 0; i < _cursorY; i++) {
            _clearTerminalLine(_lines[i]);
          }
          _lines[_cursorY].eraseTo(_cursorX, style: _ansiStyle);
        } else if (arg0 == 2 || arg0 == 3) {
          _clearScreen(type);
          _cursorX = 0;
          _cursorY = 0;
          _isLastOutputLineOpen = false;
        }
      case 0x4B:
        _ensureCursorLine(type);
        if (arg0 == 0) {
          _lines[_cursorY].eraseFrom(
            _cursorX,
            style: _ansiStyle,
            maxCells: _ptyColumns,
          );
        } else if (arg0 == 1) {
          _lines[_cursorY].eraseTo(_cursorX, style: _ansiStyle);
        } else if (arg0 == 2) {
          _clearTerminalLine(_lines[_cursorY]);
        }
      case 0x58:
        _ensureCursorLine(type);
        final count = arg0 <= 0 ? 1 : arg0;
        _lines[_cursorY].eraseChars(_cursorX, count, style: _ansiStyle);
      case 0x4C:
        _ensureCursorLine(type);
        if (_cursorY >= _scrollTopMargin && _cursorY <= _scrollBottomMargin) {
          final count = arg0 <= 0 ? 1 : arg0;
          for (var i = 0; i < count; i++) {
            _scrollRegionDown(_cursorY, _scrollBottomMargin, type);
          }
        }
      case 0x4D:
        _ensureCursorLine(type);
        if (_cursorY >= _scrollTopMargin && _cursorY <= _scrollBottomMargin) {
          final count = arg0 <= 0 ? 1 : arg0;
          for (var i = 0; i < count; i++) {
            _scrollRegionUp(_cursorY, _scrollBottomMargin, type);
          }
        }
      case 0x50:
        _ensureCursorLine(type);
        final count = arg0 <= 0 ? 1 : arg0;
        _lines[_cursorY].deleteChars(_cursorX, count, _ansiStyle);
        _lines[_cursorY].truncateTo(_ptyColumns);
      case 0x67:
        if (arg0 == 0) {
          _tabStops.clearAt(_cursorX);
        } else if (arg0 == 3) {
          _tabStops.clearAll();
        }
      case 0x72:
        final top = math.max(1, arg0 <= 0 ? 1 : arg0) - 1;
        final bottom = math.min(_ptyRows, arg1 <= 0 ? _ptyRows : arg1) - 1;
        if (top < bottom) {
          _scrollTopMargin = top;
          _scrollBottomMargin = bottom;
        } else {
          _scrollTopMargin = 0;
          _scrollBottomMargin = _ptyRows - 1;
        }
        _cursorX = 0;
        _cursorY = _originMode ? _scrollTopMargin : 0;
      case 0x53:
        final count = arg0 <= 0 ? 1 : arg0;
        for (var i = 0; i < count; i++) {
          if (_shouldScrollRegion) {
            _scrollRegionUp(_scrollTopMargin, _scrollBottomMargin, type);
          }
        }
      case 0x54:
        final count = arg0 <= 0 ? 1 : arg0;
        for (var i = 0; i < count; i++) {
          if (_shouldScrollRegion) {
            _scrollRegionDown(_scrollTopMargin, _scrollBottomMargin, type);
          }
        }
      case 0x5E:
        final count = arg0 <= 0 ? 1 : arg0;
        for (var i = 0; i < count; i++) {
          if (_shouldScrollRegion) {
            _scrollRegionDown(_scrollTopMargin, _scrollBottomMargin, type);
          }
        }
      case 0x68:
        if (parameterBytes.startsWith('?')) {
          for (final arg in args) {
            _handleDecPrivateMode(arg, true, type);
          }
        } else {
          for (final arg in args) {
            _handleAnsiMode(arg, true);
          }
        }
      case 0x6C:
        if (parameterBytes.startsWith('?')) {
          for (final arg in args) {
            _handleDecPrivateMode(arg, false, type);
          }
        } else {
          for (final arg in args) {
            _handleAnsiMode(arg, false);
          }
        }
      case 0x73:
        _saveCursor();
      case 0x75:
        if (!_isKittyKeyboardControl(parameterBytes)) {
          _restoreCursor();
        }
      case 0x63:
        if (parameterBytes.startsWith('>')) {
          _sendRawInputToProcess('\x1b[>0;276;0c');
        } else {
          // 主 DA:1(132列)、2(打印)、4(Sixel 图形)—— 通告 Sixel
          // 支持,img2sixel/lsix 等据此才输出图形
          _sendRawInputToProcess('\x1b[?62;1;2;4c');
        }
      case 0x6E:
        if (arg0 == 5) {
          _sendRawInputToProcess('\x1b[0n');
        } else if (parameterBytes.startsWith('?') && arg0 == 6) {
          _sendRawInputToProcess(
            '\x1b[?${_cursorY + 1};${_visibleCursorColumn + 1}R',
          );
        } else if (arg0 == 6) {
          _sendRawInputToProcess(
            '\x1b[${_cursorY + 1};${_visibleCursorColumn + 1}R',
          );
        }
      case 0x70:
        if (_csiHasIntermediate(params, 0x24)) {
          _reportModeStatus(
            modes: args.isEmpty ? const [0] : args,
            decPrivate: parameterBytes.startsWith('?'),
          );
        } else if (_csiHasIntermediate(params, 0x21)) {
          _softResetTerminal();
        }
      case 0x71:
        if (parameterBytes.startsWith('>')) {
          _sendRawInputToProcess('\x1bP>|SuperDesk Terminal 1.0\x1b\\');
        } else if (_csiHasIntermediate(params, 0x20)) {
          _setCursorShape(arg0);
        }
      case 0x74:
        _handleWindowOperation(args);
      case 0x7D:
        if (_csiHasIntermediate(params, 0x27)) {
          final count = arg0 <= 0 ? 1 : arg0;
          _insertColumns(count, type);
        }
      case 0x7E:
        if (_csiHasIntermediate(params, 0x27)) {
          final count = arg0 <= 0 ? 1 : arg0;
          _deleteColumns(count, type);
        }
      default:
        break;
    }
    if (_isAltBufferActive) {
      _resizeAltBuffer(type);
      _cursorX = _cursorX.clamp(0, math.max(0, _ptyColumns - 1));
    }
  }

  String _csiParameterBytes(String params) {
    if (params.isEmpty) return params;
    final buffer = StringBuffer();
    for (final code in params.codeUnits) {
      if (code >= 0x30 && code <= 0x3F) {
        buffer.writeCharCode(code);
      }
    }
    return buffer.toString();
  }

  bool _csiHasIntermediate(String params, int codeUnit) {
    return params.codeUnits.any((code) => code == codeUnit);
  }

  bool _isKittyKeyboardControl(String parameterBytes) {
    return parameterBytes.startsWith('?') ||
        parameterBytes.startsWith('=') ||
        parameterBytes.startsWith('>') ||
        parameterBytes.startsWith('<');
  }

  bool _csiCancelsPendingWrap(int finalCode, String params) {
    if (finalCode == 0x62) return false;
    if (finalCode == 0x68 || finalCode == 0x6C) return false;
    if (finalCode == 0x63 || finalCode == 0x6E) return false;
    if (finalCode == 0x73 || finalCode == 0x75) return false;
    if (finalCode == 0x71 || finalCode == 0x74) return false;
    if (finalCode == 0x70 && !_csiHasIntermediate(params, 0x21)) return false;
    return true;
  }

  void _handleXtermKeyModifierOptions(String params) {
    final parameterBytes = _csiParameterBytes(params);
    if (!parameterBytes.startsWith('>')) return;
    final args = parameterBytes
        .substring(1)
        .split(';')
        .where((part) => part.isNotEmpty)
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
    if (args.isEmpty) return;
    if (args.first == 4) {
      final value = args.length > 1 ? args[1] : 0;
      _modifyOtherKeysMode = value.clamp(0, 2).toInt();
    }
  }

  void _ensureCursorLine(TerminalLineType type) {
    if (_isAltBufferActive) {
      _resizeAltBuffer(type);
      _cursorY = _cursorY.clamp(0, math.max(0, _ptyRows - 1));
      _cursorX = math.max(0, _cursorX);
      return;
    }
    if (_lines.isEmpty) {
      _lines.add(_blankTerminalLine(type));
      _cursorY = 0;
      _cursorX = 0;
      _isLastOutputLineOpen = true;
      return;
    }
    if (_cursorY == _lines.length - 1) {
      if (!_isLastOutputLineOpen || _lines.last.type != type) {
        _lines.add(_blankTerminalLine(type));
        _cursorY = _lines.length - 1;
        _cursorX = 0;
        _isLastOutputLineOpen = true;
        return;
      }
    }
    while (_cursorY >= _lines.length) {
      _lines.add(_blankTerminalLine(type));
      _isLastOutputLineOpen = true;
    }
    if (_cursorY < 0) _cursorY = 0;
  }

  void _handleBackspace(TerminalLineType type) {
    // 末列"待折行"幻位(_wrapPending,cursorX==columns):退格只需解除待折行、
    // 落回最后一列(相当于一次左移),不能再额外减一格——否则填满整行后的
    // 第一次退格会错位一格,readline 跨行编辑重绘从边界起全对不上(表现为
    // "删到边界卡住 + 冒方块")。
    if (_wrapPending) {
      _wrapPending = false;
      _cursorX = _visibleCursorColumn;
      return;
    }

    if (!_reverseWrapAroundMode) {
      if (_cursorX > 0) _cursorX--;
      return;
    }

    if (_cursorX > 0) {
      _cursorX--;
      return;
    }

    if (_cursorY <= _scrollTopMargin || _cursorY > _scrollBottomMargin) {
      return;
    }
    if (_cursorY < 0 || _cursorY >= _lines.length) return;
    final currentLine = _lines[_cursorY];
    if (!currentLine.isWrapped) return;

    currentLine.isWrapped = false;
    _cursorY--;
    if (_cursorY < 0 || _cursorY >= _lines.length) {
      _cursorY = _clampInt(_cursorY, 0, math.max(0, _lines.length - 1));
      _cursorX = 0;
      return;
    }
    final previousLine = _lines[_cursorY];
    final occupiedColumn = math.min(_ptyColumns, previousLine.length) - 1;
    _cursorX = _clampInt(occupiedColumn, 0, _maxCursorColumn);
  }

  void _writeBufferAtCursor(String text, TerminalLineType type) {
    if (text.isEmpty) return;
    final columns = math.max(1, _ptyColumns);
    for (final rune in text.runes) {
      final sourceChar = String.fromCharCode(rune);
      final char = _charset.map(sourceChar);
      final width = terminalCellWidth(char);
      if (_autoWrapMode && _wrapPending && width > 0) {
        _moveCursorToNextLine(type, softWrap: true);
      }
      if (_autoWrapMode &&
          width > 0 &&
          _cursorX > 0 &&
          _cursorX + width > columns) {
        _moveCursorToNextLine(type, softWrap: true);
      } else if (!_autoWrapMode && width > 0 && _cursorX + width > columns) {
        _cursorX = math.max(0, columns - width);
        _wrapPending = false;
      }
      _ensureCursorLine(type);
      final line = _lines[_cursorY];
      if (_insertMode && width > 0) {
        line.insertChars(_cursorX, width, _ansiStyle);
      }
      line.writeAt(_cursorX, char, _ansiStyle, linkUrl: _activeOsc8Url);
      if (_insertMode) {
        line.truncateTo(_ptyColumns);
      }
      _cursorX += width;
      if (width > 0) {
        _lastPrintedCharacter = char;
        if (_autoWrapMode && _cursorX >= columns) {
          _cursorX = columns;
          _wrapPending = true;
        } else {
          _wrapPending = false;
          if (!_autoWrapMode) {
            _cursorX = math.min(_cursorX, math.max(0, columns - 1));
          }
        }
      }
    }
  }

  void _moveCursorToNextLine(TerminalLineType type, {bool softWrap = false}) {
    if (_shouldScrollRegion && _cursorY == _scrollBottomMargin) {
      _scrollRegionUp(_scrollTopMargin, _scrollBottomMargin, type);
    } else {
      if (_cursorY == _lines.length - 1) {
        _isLastOutputLineOpen = false;
      }
      _cursorY++;
    }
    _cursorX = 0;
    _wrapPending = false;
    if (softWrap) {
      _ensureLineCount(_cursorY + 1, type);
      _lines[_cursorY].isWrapped = true;
      // 软折行补出的新行就是当前开放的输出行。不置回 true 的话,
      // 随后的 _ensureCursorLine 会因「末行不开放」再追加一行并跳过去,
      // 每次折行都多出一条空行(readline 的 <SP>\r 强制折行手法必踩)。
      _isLastOutputLineOpen = true;
    } else if (_cursorY >= 0 && _cursorY < _lines.length) {
      _lines[_cursorY].isWrapped = false;
    }
  }

  void _indexCursor(TerminalLineType type) {
    if (_shouldScrollRegion && _cursorY == _scrollBottomMargin) {
      _scrollRegionUp(_scrollTopMargin, _scrollBottomMargin, type);
    } else {
      _cursorY++;
      _ensureCursorLine(type);
      if (_cursorY >= 0 && _cursorY < _lines.length) {
        _lines[_cursorY].isWrapped = false;
      }
    }
    _wrapPending = false;
  }

  void _reverseIndexCursor(TerminalLineType type) {
    if (_shouldScrollRegion && _cursorY == _scrollTopMargin) {
      _scrollRegionDown(_scrollTopMargin, _scrollBottomMargin, type);
    } else if (_cursorY > 0) {
      _cursorY--;
    } else if (!_isAltBufferActive) {
      // 反向索引在顶部滚入的行是滚动语义,与 _scrollRegionDown 一致用 BCE
      _lines.insert(0, _blankTerminalLine(type, erase: true));
      _trimLines();
    }
    _wrapPending = false;
  }

  void _enterAltBuffer(TerminalLineType type) {
    if (_isAltBufferActive) return;
    _normalLines.clear();
    _normalLines.addAll(_lines);
    _normalCursorX = _cursorX;
    _normalCursorY = _cursorY;
    _normalSavedCursorX = _savedCursorX;
    _normalSavedCursorY = _savedCursorY;
    _normalAnsiStyle = _ansiStyle;
    _normalSavedAnsiStyle = _savedAnsiStyle;
    _normalWrapPending = _wrapPending;
    _normalSavedWrapPending = _savedWrapPending;
    _normalG0LineDrawing = _g0LineDrawing;
    _normalG1LineDrawing = _g1LineDrawing;
    _normalUseG1Charset = _useG1Charset;
    _normalSavedG0LineDrawing = _savedG0LineDrawing;
    _normalSavedG1LineDrawing = _savedG1LineDrawing;
    _normalSavedUseG1Charset = _savedUseG1Charset;
    _normalSavedOriginMode = _savedOriginMode;
    _normalSavedAutoWrapMode = _savedAutoWrapMode;

    _isAltBufferActive = true;
    _lines.clear();
    _resizeAltBuffer(type);
    _cursorX = 0;
    _cursorY = 0;
    _wrapPending = false;
    _isLastOutputLineOpen = false;
  }

  void _exitAltBuffer() {
    if (!_isAltBufferActive) return;
    _lines.clear();
    _lines.addAll(_normalLines);
    _normalLines.clear();
    _cursorX = _normalCursorX;
    _cursorY = _normalCursorY;
    _savedCursorX = _normalSavedCursorX;
    _savedCursorY = _normalSavedCursorY;
    _ansiStyle = _normalAnsiStyle;
    _savedAnsiStyle = _normalSavedAnsiStyle;
    _wrapPending = _normalWrapPending;
    _savedWrapPending = _normalSavedWrapPending;
    _g0LineDrawing = _normalG0LineDrawing;
    _g1LineDrawing = _normalG1LineDrawing;
    _useG1Charset = _normalUseG1Charset;
    _savedG0LineDrawing = _normalSavedG0LineDrawing;
    _savedG1LineDrawing = _normalSavedG1LineDrawing;
    _savedUseG1Charset = _normalSavedUseG1Charset;
    _savedOriginMode = _normalSavedOriginMode;
    _savedAutoWrapMode = _normalSavedAutoWrapMode;
    _isAltBufferActive = false;
    _scrollTopMargin = 0;
    _scrollBottomMargin = math.max(0, _ptyRows - 1);
    _isLastOutputLineOpen = false;
  }

  void _scrollRegionUp(int top, int bottom, TerminalLineType type) {
    _ensureLineCount(bottom + 1, type);
    if (top < 0 || bottom >= _lines.length || top >= bottom) return;
    _lines.removeAt(top);
    final blankLine = _blankTerminalLine(type, erase: true);
    if (bottom <= _lines.length) {
      _lines.insert(bottom, blankLine);
    } else {
      _lines.add(blankLine);
    }
  }

  void _scrollRegionDown(int top, int bottom, TerminalLineType type) {
    _ensureLineCount(bottom + 1, type);
    if (top < 0 || bottom >= _lines.length || top >= bottom) return;
    _lines.removeAt(bottom);
    _lines.insert(top, _blankTerminalLine(type, erase: true));
  }

  bool get _shouldScrollRegion =>
      _isAltBufferActive ||
      _scrollTopMargin > 0 ||
      _scrollBottomMargin < _ptyRows - 1;

  bool get _cursorIsInsideScrollMargins =>
      _cursorY >= _scrollTopMargin && _cursorY <= _scrollBottomMargin;

  void _scrollColumnsLeft(int count, TerminalLineType type) {
    if (!_cursorIsInsideScrollMargins) return;
    _ensureLineCount(_scrollBottomMargin + 1, type);
    final actualCount = math.max(1, count);
    for (var row = _scrollTopMargin; row <= _scrollBottomMargin; row++) {
      _lines[row].isWrapped = false;
      _lines[row].deleteChars(0, actualCount, _ansiStyle);
      _lines[row].truncateTo(_ptyColumns);
    }
  }

  void _scrollColumnsRight(int count, TerminalLineType type) {
    if (!_cursorIsInsideScrollMargins) return;
    _ensureLineCount(_scrollBottomMargin + 1, type);
    final actualCount = math.max(1, count);
    for (var row = _scrollTopMargin; row <= _scrollBottomMargin; row++) {
      _lines[row].isWrapped = false;
      _lines[row].insertChars(0, actualCount, _ansiStyle);
      _lines[row].truncateTo(_ptyColumns);
    }
  }

  void _insertColumns(int count, TerminalLineType type) {
    if (!_cursorIsInsideScrollMargins) return;
    _ensureLineCount(_scrollBottomMargin + 1, type);
    final actualCount = math.max(1, count);
    for (var row = _scrollTopMargin; row <= _scrollBottomMargin; row++) {
      _lines[row].isWrapped = false;
      _lines[row].insertChars(_cursorX, actualCount, _ansiStyle);
      _lines[row].truncateTo(_ptyColumns);
    }
  }

  void _deleteColumns(int count, TerminalLineType type) {
    if (!_cursorIsInsideScrollMargins) return;
    _ensureLineCount(_scrollBottomMargin + 1, type);
    final actualCount = math.max(1, count);
    for (var row = _scrollTopMargin; row <= _scrollBottomMargin; row++) {
      _lines[row].isWrapped = false;
      _lines[row].deleteChars(_cursorX, actualCount, _ansiStyle);
      _lines[row].truncateTo(_ptyColumns);
    }
  }

  /// 列宽变化时把普通缓冲区按新宽度回流(reflow)。备用屏由 _resizeAltBuffer
  /// 单独处理,这里只动普通缓冲区;备用屏激活时回流其身后保存的普通缓冲区,
  /// 退出备用屏时看到的历史也是重排过的。异常绝不外泄(回流失败保持原样)。
  void _reflowOnColumnChange(int oldColumns, int newColumns) {
    if (oldColumns == newColumns || newColumns < 1) return;
    try {
      if (_isAltBufferActive) {
        if (_normalLines.isEmpty) return;
        final r = reflowTerminalLines(
          _normalLines,
          newColumns,
          cursorRow: _normalCursorY,
          cursorCol: _normalCursorX,
        );
        _normalLines
          ..clear()
          ..addAll(r.lines);
        _normalCursorY = r.cursorRow.clamp(0, math.max(0, r.lines.length - 1));
        _normalCursorX = r.cursorCol;
        return;
      }
      if (_lines.isEmpty) return;
      final r = reflowTerminalLines(
        _lines,
        newColumns,
        cursorRow: _cursorY,
        cursorCol: _cursorX,
      );
      _lines
        ..clear()
        ..addAll(r.lines);
      _cursorY = r.cursorRow.clamp(0, math.max(0, _lines.length - 1));
      _cursorX = _clampInt(r.cursorCol, 0, _maxCursorColumn);
      _savedCursorY = _clampInt(_savedCursorY, 0, math.max(0, _lines.length - 1));
      _wrapPending = false;
      // 回流后行号变了,重新定位最近的提示符行(OSC 133 退出码回填用)
      _lastPromptLine = -1;
      for (var k = _lines.length - 1; k >= 0; k--) {
        if (_lines[k].isPromptStart) {
          _lastPromptLine = k;
          break;
        }
      }
    } catch (_) {
      // 回流是纯优化,失败不影响终端可用性
    }
  }

  void _resizeAltBuffer(TerminalLineType type) {
    if (!_isAltBufferActive) return;
    _ensureLineCount(_ptyRows, type);
    if (_lines.length > _ptyRows) {
      _lines.removeRange(_ptyRows, _lines.length);
    }
    _scrollTopMargin = _scrollTopMargin.clamp(0, math.max(0, _ptyRows - 1));
    _scrollBottomMargin = _scrollBottomMargin.clamp(
      _scrollTopMargin,
      math.max(0, _ptyRows - 1),
    );
    if (_scrollBottomMargin <= _scrollTopMargin) {
      _scrollTopMargin = 0;
      _scrollBottomMargin = math.max(0, _ptyRows - 1);
    }
    _cursorY = _cursorY.clamp(0, math.max(0, _ptyRows - 1));
  }

  void _ensureLineCount(int count, TerminalLineType type) {
    // Alt buffer is a fixed rows x cols grid: out-of-range addressing/motion
    // must clamp to the last row, never grow the buffer. Once it exceeds
    // _ptyRows the output viewport turns scrollable, auto-follow can latch
    // off, and vim's last row (the ':' command line) sits outside the visible
    // area - which is exactly "typing :q neither echoes nor quits".
    final limit = _isAltBufferActive ? math.min(count, _ptyRows) : count;
    while (_lines.length < limit) {
      _lines.add(_blankTerminalLine(type));
    }
  }

  TerminalLine _blankTerminalLine(TerminalLineType type, {bool erase = false}) {
    final line = TerminalLine(const [], type);
    // BCE(用当前 SGR 背景填充)只属于显式擦除与备用屏网格:
    // - erase: 清屏/滚动流入行等擦除语义,xterm 用当前背景填充
    // - 备用屏: vim/htop 依赖 BCE 铺满屏底色
    // 普通缓冲里 换行/折行/寻址 新建的行必须是默认背景 —— 否则输出恰在
    // 背景色活跃时折行(Gin 日志的定宽彩底徽章必踩),会刷出通宽色带。
    if (erase || _isAltBufferActive) {
      _clearTerminalLine(line);
    }
    return line;
  }

  void _clearTerminalLine(TerminalLine line) {
    line.fillBlank(_ptyColumns, _ansiStyle);
  }

  void _clearScreen(TerminalLineType type) {
    _wrapPending = false;
    _lines.clear();
    if (_isAltBufferActive || _ansiStyle.background != null) {
      final rows = _isAltBufferActive ? math.max(1, _ptyRows) : 1;
      for (var row = 0; row < rows; row++) {
        _lines.add(_blankTerminalLine(type, erase: true));
      }
    }
  }

  void _resetTerminalModes() {
    _showCursor = true;
    _cursorShape = TerminalCursorShape.block;
    _cursorBlinkMode = false;
    _autoWrapMode = true;
    _reverseWrapAroundMode = false;
    _bracketedPasteMode = false;
    _setSynchronizedOutputMode(false);
    _applicationCursorMode = false;
    _applicationKeypadMode = false;
    _originMode = false;
    _insertMode = false;
    _lineFeedNewLineMode = false;
    _focusReportingMode = false;
    _alternateScrollMode = true;
    _modifyOtherKeysMode = 0;
    _g0LineDrawing = false;
    _g1LineDrawing = false;
    _useG1Charset = false;
    _mouseTrackingMode = 0;
    _sgrMouseMode = false;
    _sgrPixelMouseMode = false;
    _utf8MouseMode = false;
    _urxvtMouseMode = false;
    _mouseButtonDown = false;
    _lastMouseButtonCode = 0;
    _lastMouseColumn = -1;
    _lastMouseRow = -1;
    _lastPrintedCharacter = ' ';
    _tabStops.reset(math.max(_ptyColumns, _defaultPtyColumns));
  }

  void _handleAnsiMode(int mode, bool enable) {
    switch (mode) {
      case 4:
        _insertMode = enable;
      case 20:
        _lineFeedNewLineMode = enable;
      default:
        break;
    }
  }

  void _reportModeStatus({
    required Iterable<int> modes,
    required bool decPrivate,
  }) {
    for (final mode in modes) {
      final status = decPrivate
          ? _decPrivateModeStatus(mode)
          : _ansiModeStatus(mode);
      final prefix = decPrivate ? '?' : '';
      _sendRawInputToProcess('\x1b[$prefix$mode;$status\$y');
    }
  }

  int _ansiModeStatus(int mode) {
    switch (mode) {
      case 2:
        return 4;
      case 4:
        return _insertMode ? 1 : 2;
      case 12:
        return 3;
      case 20:
        return _lineFeedNewLineMode ? 1 : 2;
      default:
        return 0;
    }
  }

  int _decPrivateModeStatus(int mode) {
    switch (mode) {
      case 1:
        return _applicationCursorMode ? 1 : 2;
      case 6:
        return _originMode ? 1 : 2;
      case 7:
        return _autoWrapMode ? 1 : 2;
      case 8:
        return 3;
      case 12:
        return _cursorBlinkMode ? 1 : 2;
      case 25:
        return _showCursor ? 1 : 2;
      case 45:
        return _reverseWrapAroundMode ? 1 : 2;
      case 66:
        return _applicationKeypadMode ? 1 : 2;
      case 67:
        return 4;
      case 47:
      case 1047:
      case 1049:
        return _isAltBufferActive ? 1 : 2;
      case 9:
      case 1000:
      case 1002:
      case 1003:
        return _mouseTrackingMode == mode ? 1 : 2;
      case 1004:
        return _focusReportingMode ? 1 : 2;
      case 1005:
        return _utf8MouseMode ? 1 : 2;
      case 1006:
        return _sgrMouseMode ? 1 : 2;
      case 1007:
        return _alternateScrollMode ? 1 : 2;
      case 1015:
        return _urxvtMouseMode ? 1 : 2;
      case 1016:
        return _sgrPixelMouseMode ? 1 : 2;
      case 1048:
        return 1;
      case 2004:
        return _bracketedPasteMode ? 1 : 2;
      case 2026:
        return _synchronizedOutputMode ? 1 : 2;
      default:
        return 0;
    }
  }

  void _handleWindowOperation(List<int> args) {
    final operation = args.isEmpty ? 0 : args.first;
    switch (operation) {
      case 11:
        _sendRawInputToProcess('\x1b[1t');
      case 13:
        _sendRawInputToProcess('\x1b[3;0;0t');
      case 14:
        _sendRawInputToProcess(
          '\x1b[4;$_terminalPixelHeight;${_terminalPixelWidth}t',
        );
      case 16:
        _sendRawInputToProcess(
          '\x1b[6;$_terminalCellPixelHeight;${_terminalCellPixelWidth}t',
        );
      case 18:
        _sendRawInputToProcess('\x1b[8;$_ptyRows;${_ptyColumns}t');
      case 19:
        _sendRawInputToProcess('\x1b[9;$_ptyRows;${_ptyColumns}t');
      case 20:
        _sendRawInputToProcess(
          '\x1b]L${_terminalControlStringText(_titleStack.effective)}\x1b\\',
        );
      case 21:
        _sendRawInputToProcess(
          '\x1b]l${_terminalControlStringText(_titleStack.effective)}\x1b\\',
        );
      case 22:
        _titleStack.save();
      case 23:
        _titleStack.restore();
        _publishUiState();
      default:
        break;
    }
  }

  int get _terminalCellPixelWidth => math.max(1, _lastCellWidth.round());

  int get _terminalCellPixelHeight => math.max(1, _lastLineHeight.round());

  int get _terminalPixelWidth =>
      math.max(_terminalCellPixelWidth, (_ptyColumns * _lastCellWidth).round());

  int get _terminalPixelHeight =>
      math.max(_terminalCellPixelHeight, (_ptyRows * _lastLineHeight).round());

  String _terminalControlStringText(String value) {
    return value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
  }

  int _cursorShapeParameter() {
    return switch (_cursorShape) {
      TerminalCursorShape.underline => _cursorBlinkMode ? 3 : 4,
      TerminalCursorShape.bar => _cursorBlinkMode ? 5 : 6,
      TerminalCursorShape.block => _cursorBlinkMode ? 1 : 2,
    };
  }

  void _setCursorShape(int style) {
    _cursorBlinkMode = style == 1 || style == 3 || style == 5;
    switch (style) {
      case 3:
      case 4:
        _cursorShape = TerminalCursorShape.underline;
      case 5:
      case 6:
        _cursorShape = TerminalCursorShape.bar;
      case 0:
      case 1:
      case 2:
      default:
        _cursorShape = TerminalCursorShape.block;
    }
  }

  void _handleCharsetSequence(
    int marker,
    int finalCode,
    TerminalLineType type,
  ) {
    if (marker == 0x23) {
      if (finalCode == 0x38) {
        _screenAlignmentTest(type);
      }
      return;
    }
    if (marker == 0x25 && finalCode == 0x47) {
      _g0LineDrawing = false;
      _g1LineDrawing = false;
      _useG1Charset = false;
      return;
    }
    if (marker != 0x28 && marker != 0x29) return;
    final lineDrawing = finalCode == 0x30;
    if (marker == 0x28) {
      _g0LineDrawing = lineDrawing;
      if (finalCode == 0x42) _g0LineDrawing = false;
    } else {
      _g1LineDrawing = lineDrawing;
      if (finalCode == 0x42) _g1LineDrawing = false;
    }
  }

  void _screenAlignmentTest(TerminalLineType type) {
    _lines.clear();
    final fill = 'E' * math.max(1, _ptyColumns);
    for (var row = 0; row < math.max(1, _ptyRows); row++) {
      _lines.add(TerminalLine.plain(fill, type));
    }
    _cursorX = 0;
    _cursorY = 0;
    _wrapPending = false;
    _isLastOutputLineOpen = true;
    if (_isAltBufferActive) {
      _resizeAltBuffer(type);
    }
  }

  int _clampInt(int value, int min, int max) {
    return math.min(max, math.max(min, value));
  }

  int get _maxCursorColumn => math.max(0, _ptyColumns - 1);

  int get _visibleCursorColumn {
    return _clampInt(_cursorX, 0, _maxCursorColumn);
  }

  void _cancelPendingWrap() {
    if (_wrapPending) {
      _cursorX = _visibleCursorColumn;
    }
    _wrapPending = false;
  }

  int _cursorRowFromParam(int rowParam) {
    final row = (rowParam <= 0 ? 1 : rowParam) - 1;
    if (!_originMode) return math.max(0, row);
    return _clampInt(
      _scrollTopMargin + row,
      _scrollTopMargin,
      _scrollBottomMargin,
    );
  }

  void _setCursorRowFromParam(int rowParam, TerminalLineType type) {
    final row = _cursorRowFromParam(rowParam);
    _ensureLineCount(row + 1, type);
    _cursorY = math.min(row, math.max(0, _lines.length - 1));
    _wrapPending = false;
  }

  void _setCursorPositionFromParams(
    int rowParam,
    int colParam,
    TerminalLineType type,
  ) {
    _setCursorRowFromParam(rowParam, type);
    _cursorX = _clampInt(
      (colParam <= 0 ? 1 : colParam) - 1,
      0,
      _maxCursorColumn,
    );
    _wrapPending = false;
  }

  void _moveCursorRows(int delta, TerminalLineType type) {
    if (delta > 0 && !_originMode) {
      _ensureLineCount(_cursorY + delta + 1, type);
    }
    final minRow = _originMode ? _scrollTopMargin : 0;
    final maxRow = _originMode
        ? _scrollBottomMargin
        : math.max(0, _lines.length - 1);
    _cursorY = _clampInt(_cursorY + delta, minRow, maxRow);
    _wrapPending = false;
  }

  void _saveCursor() {
    _savedCursorX = _cursorX;
    _savedCursorY = _cursorY;
    _savedAnsiStyle = _ansiStyle;
    _savedWrapPending = _wrapPending;
    _savedG0LineDrawing = _g0LineDrawing;
    _savedG1LineDrawing = _g1LineDrawing;
    _savedUseG1Charset = _useG1Charset;
    _savedOriginMode = _originMode;
    _savedAutoWrapMode = _autoWrapMode;
  }

  void _restoreCursor() {
    _cursorX = _savedCursorX;
    _cursorY = math.min(_savedCursorY, math.max(0, _lines.length - 1));
    _ansiStyle = _savedAnsiStyle;
    _wrapPending = _savedWrapPending;
    _g0LineDrawing = _savedG0LineDrawing;
    _g1LineDrawing = _savedG1LineDrawing;
    _useG1Charset = _savedUseG1Charset;
    _originMode = _savedOriginMode;
    _autoWrapMode = _savedAutoWrapMode;
  }

  void _softResetTerminal() {
    _ansiStyle = const AnsiStyle();
    _activeOsc8Url = null;
    _cursorX = 0;
    _cursorY = 0;
    _savedCursorX = 0;
    _savedCursorY = 0;
    _savedAnsiStyle = const AnsiStyle();
    _wrapPending = false;
    _savedWrapPending = false;
    _savedOriginMode = false;
    _savedAutoWrapMode = true;
    _scrollTopMargin = 0;
    _scrollBottomMargin = math.max(0, _ptyRows - 1);
    _resetTerminalModes();
  }

  void _hardResetTerminal(TerminalLineType type) {
    _lines
      ..clear()
      ..add(TerminalLine(const [], type));
    _ansiStyle = const AnsiStyle();
    _cursorX = 0;
    _cursorY = 0;
    _savedCursorX = 0;
    _savedCursorY = 0;
    _savedAnsiStyle = const AnsiStyle();
    _wrapPending = false;
    _savedWrapPending = false;
    _savedG0LineDrawing = false;
    _savedG1LineDrawing = false;
    _savedUseG1Charset = false;
    _savedOriginMode = false;
    _savedAutoWrapMode = true;
    _activeOsc8Url = null;
    _isLastOutputLineOpen = true;
    _isAltBufferActive = false;
    _normalLines.clear();
    _normalCursorX = 0;
    _normalCursorY = 0;
    _normalSavedCursorX = 0;
    _normalSavedCursorY = 0;
    _normalAnsiStyle = const AnsiStyle();
    _normalSavedAnsiStyle = const AnsiStyle();
    _normalWrapPending = false;
    _normalSavedWrapPending = false;
    _normalG0LineDrawing = false;
    _normalG1LineDrawing = false;
    _normalUseG1Charset = false;
    _normalSavedG0LineDrawing = false;
    _normalSavedG1LineDrawing = false;
    _normalSavedUseG1Charset = false;
    _normalSavedOriginMode = false;
    _normalSavedAutoWrapMode = true;
    _scrollTopMargin = 0;
    _scrollBottomMargin = math.max(0, _ptyRows - 1);
    _resetTerminalModes();
    _pendingEscapeSequence = '';
    _titleStack.reset();
    _palette.clear();
    _dynamicForegroundColor = null;
    _dynamicBackgroundColor = null;
    _dynamicCursorColor = null;
  }

  void _handleDecPrivateMode(int mode, bool enable, TerminalLineType type) {
    switch (mode) {
      case 6:
        _originMode = enable;
        _cursorX = 0;
        _cursorY = enable ? _scrollTopMargin : 0;
      case 7:
        _autoWrapMode = enable;
      case 45:
        _reverseWrapAroundMode = enable;
      case 1:
        _applicationCursorMode = enable;
      case 12:
        _cursorBlinkMode = enable;
      case 25:
        _showCursor = enable;
      case 66:
        _applicationKeypadMode = enable;
      case 1048:
        if (enable) {
          _saveCursor();
        } else {
          _restoreCursor();
        }
      case 47:
      case 1047:
      case 1049:
        if (enable) {
          _enterAltBuffer(type);
        } else {
          _exitAltBuffer();
        }
      case 9:
      case 1000:
      case 1002:
      case 1003:
        if (enable) {
          _mouseTrackingMode = mode;
        } else if (_mouseTrackingMode == mode) {
          _mouseTrackingMode = 0;
        }
        _mouseButtonDown = false;
        _lastMouseColumn = -1;
        _lastMouseRow = -1;
      case 1004:
        _focusReportingMode = enable;
      case 1005:
        _utf8MouseMode = enable;
      case 1006:
        _sgrMouseMode = enable;
      case 1007:
        _alternateScrollMode = enable;
      case 1015:
        _urxvtMouseMode = enable;
      case 1016:
        _sgrPixelMouseMode = enable;
      case 2004:
        _bracketedPasteMode = enable;
      case 2026:
        _setSynchronizedOutputMode(enable);
      default:
        break;
    }
  }

  void _handleEscSequence(int marker, TerminalLineType type) {
    switch (marker) {
      case 0x37:
        _saveCursor();
      case 0x38:
        _restoreCursor();
      case 0x44:
        _indexCursor(type);
      case 0x45:
        _cursorX = 0;
        _moveCursorToNextLine(type);
      case 0x48:
        _tabStops.setAt(_cursorX);
      case 0x4D:
        _reverseIndexCursor(type);
      case 0x3D:
        _applicationKeypadMode = true;
      case 0x3E:
        _applicationKeypadMode = false;
      case 0x5A:
        _sendRawInputToProcess('\x1b[?1;2c');
      case 0x63:
        _hardResetTerminal(type);
      default:
        break;
    }
  }

  void _handleOscSequence(String payload, TerminalLineType type) {
    final colorQuery = RegExp(r'^(10|11|12);(.+)$').firstMatch(payload);
    if (colorQuery != null) {
      _handleOscColorControl(
        int.parse(colorQuery.group(1)!),
        colorQuery.group(2)!.trim(),
      );
      return;
    }
    if (payload.startsWith('4;')) {
      _handleOscPaletteControl(payload);
      return;
    }
    if (payload == '104' || payload.startsWith('104;')) {
      _handleOscPaletteReset(payload);
      return;
    }
    if (payload == '110') {
      _dynamicForegroundColor = null;
      return;
    }
    if (payload == '111') {
      _dynamicBackgroundColor = null;
      return;
    }
    if (payload == '112') {
      _dynamicCursorColor = null;
      return;
    }
    if (payload.startsWith('8;')) {
      final parts = payload.split(';');
      if (parts.length >= 3) {
        final url = parts.sublist(2).join(';');
        _activeOsc8Url = url.isEmpty ? null : url;
      } else {
        _activeOsc8Url = null;
      }
      return;
    }
    if (payload.startsWith('52;')) {
      _handleOsc52Clipboard(payload);
      return;
    }
    if (payload.startsWith('1337;File=')) {
      _handleItermImage(payload);
      return;
    }
    if (payload.startsWith('133;')) {
      _handleShellIntegration(payload.substring(4));
      return;
    }
    if (payload.startsWith('0;') ||
        payload.startsWith('1;') ||
        payload.startsWith('2;')) {
      final title = payload.substring(2).trim();
      if (title.isNotEmpty) {
        _titleStack.current = title;
      }
      return;
    }
    if (payload.startsWith('7;')) {
      final url = payload.substring(2).trim();
      if (url.startsWith('file://')) {
        try {
          final uri = Uri.parse(url);
          // 不用 toFilePath():远端 shell 的 OSC 7 带主机名
          // (file://host/path),非 localhost 的 authority 会抛异常
          final path = Uri.decodeComponent(uri.path);
          if (path.isNotEmpty) {
            _setReportedCwd(path);
          }
        } catch (_) {}
      }
      return;
    }
  }

  /// 最近一次提示符起点行(用于把退出码回填到对应命令块)
  int _lastPromptLine = -1;

  /// Shell 集成(OSC 133,FinalTerm/iTerm2/VSCode 通用):
  /// A=提示符起点,B=命令输入起点,C=命令开始执行,D[;code]=命令结束。
  /// 标记命令边界,供「跳转上/下条命令」与退出状态标记使用。
  void _handleShellIntegration(String payload) {
    final marker = payload.isEmpty ? '' : payload[0];
    switch (marker) {
      case 'A':
        // 新命令块的提示符起点
        if (_cursorY >= 0 && _cursorY < _lines.length) {
          _lines[_cursorY].isPromptStart = true;
          _lines[_cursorY].commandExitCode = null;
          _lastPromptLine = _cursorY;
        }
      case 'C':
        // 命令开始执行:此行起为输出。标记供「复制命令输出」界定范围。
        if (_cursorY >= 0 && _cursorY < _lines.length) {
          _lines[_cursorY].isCommandStart = true;
        }
      case 'D':
        // 命令结束,可能带 ;code;把退出码回填到对应命令块的提示符行
        final parts = payload.split(';');
        final code = parts.length > 1 ? int.tryParse(parts[1]) : null;
        if (_lastPromptLine >= 0 && _lastPromptLine < _lines.length) {
          _lines[_lastPromptLine].commandExitCode = code ?? 0;
        }
      default:
        // B / 其它:暂不处理(命令输入起点)
        break;
    }
  }

  /// iTerm2 内联图片:OSC `1337;File=键值对:base64`。
  /// base64 是标准 PNG/JPEG/GIF,交给 Image.memory 解码。
  void _handleItermImage(String payload) {
    try {
      final colon = payload.indexOf(':');
      if (colon < 0) return;
      final b64 = payload.substring(colon + 1).trim();
      if (b64.isEmpty) return;
      final bytes = base64Decode(base64.normalize(b64));
      if (bytes.isEmpty) return;
      // 像素尺寸未知(交给渲染层按可用宽度自适应),用 0 占位
      _placeImage(
        TerminalImage(bytes: bytes, pixelWidth: 0, pixelHeight: 0),
      );
    } catch (_) {
      // 非法 base64 / 解码失败:忽略
    }
  }

  void _handleOscPaletteControl(String payload) {
    final parts = payload.split(';');
    var index = 1;
    while (index + 1 < parts.length) {
      final colorIndex = int.tryParse(parts[index]);
      final value = parts[index + 1].trim();
      if (colorIndex != null && colorIndex >= 0 && colorIndex <= 255) {
        if (value == '?') {
          _sendRawInputToProcess(
            '\x1b]4;$colorIndex;${TerminalPalette.xtermRgb(_palette.ansi256(colorIndex))}\x1b\\',
          );
        } else {
          final color = _parseXtermColor(value);
          if (color != null) {
            _palette.setColor(colorIndex, color);
          }
        }
      }
      index += 2;
    }
  }

  void _handleOscPaletteReset(String payload) {
    final parts = payload.split(';');
    if (parts.length == 1) {
      _palette.clear();
      return;
    }
    for (final part in parts.skip(1)) {
      final colorIndex = int.tryParse(part.trim());
      if (colorIndex != null) {
        _palette.resetColor(colorIndex);
      }
    }
  }

  void _handleOscColorControl(int code, String value) {
    if (value != '?') {
      final color = _parseXtermColor(value);
      if (color == null) return;
      switch (code) {
        case 10:
          _dynamicForegroundColor = color;
        case 11:
          _dynamicBackgroundColor = color;
        case 12:
          _dynamicCursorColor = color;
        default:
          break;
      }
      return;
    }
    final color = switch (code) {
      10 => _dynamicForegroundColor ?? _themeForeground ?? AppTheme.headingColor,
      11 => _dynamicBackgroundColor ?? _themeBackground ?? AppTheme.surfaceColor,
      12 => _dynamicCursorColor ?? _themeCursor ?? AppTheme.brandColor,
      _ => null,
    };
    if (color == null) return;
    _sendRawInputToProcess(
      '\x1b]$code;${TerminalPalette.xtermRgb(color)}\x1b\\',
    );
  }

  Color? _parseXtermColor(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    if (normalized.startsWith('#')) {
      return _parseHexXtermColor(normalized.substring(1));
    }
    final lower = normalized.toLowerCase();
    if (lower.startsWith('rgb:') || lower.startsWith('rgba:')) {
      final components = normalized.substring(normalized.indexOf(':') + 1);
      final parts = components.split('/');
      if (parts.length < 3) return null;
      final red = _parseXtermColorComponent(parts[0]);
      final green = _parseXtermColorComponent(parts[1]);
      final blue = _parseXtermColorComponent(parts[2]);
      if (red == null || green == null || blue == null) return null;
      return Color.fromARGB(255, red, green, blue);
    }
    return switch (lower) {
      'black' => const Color(0xFF000000),
      'red' => const Color(0xFFFF0000),
      'green' => const Color(0xFF00FF00),
      'yellow' => const Color(0xFFFFFF00),
      'blue' => const Color(0xFF0000FF),
      'magenta' => const Color(0xFFFF00FF),
      'cyan' => const Color(0xFF00FFFF),
      'white' => const Color(0xFFFFFFFF),
      _ => null,
    };
  }

  Color? _parseHexXtermColor(String value) {
    final hex = value.trim();
    if (hex.length == 3) {
      final red = int.tryParse('${hex[0]}${hex[0]}', radix: 16);
      final green = int.tryParse('${hex[1]}${hex[1]}', radix: 16);
      final blue = int.tryParse('${hex[2]}${hex[2]}', radix: 16);
      if (red == null || green == null || blue == null) return null;
      return Color.fromARGB(255, red, green, blue);
    }
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      if (value == null) return null;
      return Color(0xFF000000 | value);
    }
    if (hex.length == 12) {
      final red = _parseXtermColorComponent(hex.substring(0, 4));
      final green = _parseXtermColorComponent(hex.substring(4, 8));
      final blue = _parseXtermColorComponent(hex.substring(8, 12));
      if (red == null || green == null || blue == null) return null;
      return Color.fromARGB(255, red, green, blue);
    }
    return null;
  }

  int? _parseXtermColorComponent(String value) {
    final component = value.trim();
    if (component.isEmpty || component.length > 4) return null;
    final parsed = int.tryParse(component, radix: 16);
    if (parsed == null) return null;
    final max = (1 << (component.length * 4)) - 1;
    if (max <= 0) return null;
    return ((parsed.clamp(0, max) / max) * 255).round();
  }

  void _handleOsc52Clipboard(String payload) {
    final parts = payload.split(';');
    if (parts.length < 3) return;
    final encoded = parts.sublist(2).join(';').trim();
    if (encoded.isEmpty || encoded == '?') return;
    if (encoded.length > 1024 * 1024) return;

    try {
      var normalized = encoded.replaceAll(RegExp(r'\s'), '');
      final remainder = normalized.length % 4;
      if (remainder != 0) {
        normalized = normalized.padRight(
          normalized.length + (4 - remainder),
          '=',
        );
      }
      final decoded = utf8.decode(base64.decode(normalized));
      unawaited(Clipboard.setData(ClipboardData(text: decoded)));
    } catch (_) {
      // Ignore invalid OSC 52 payloads; rendering should keep streaming.
    }
  }

  void _trimLines() {
    if (_lines.length > _maxTerminalLines) {
      final removed = _lines.length - _maxTerminalLines;
      _lines.removeRange(0, removed);
      _cursorY = math.max(0, _cursorY - removed);
      _savedCursorY = math.max(0, _savedCursorY - removed);
      // 选区行号随裁剪平移;被裁掉的选区直接失效
      final anchor = _gridSelAnchor;
      final focus = _gridSelFocus;
      if (anchor != null && focus != null) {
        if (anchor.row < removed || focus.row < removed) {
          _clearGridSelection();
        } else {
          _gridSelAnchor = (row: anchor.row - removed, col: anchor.col);
          _gridSelFocus = (row: focus.row - removed, col: focus.col);
        }
      }
    }
  }
}
