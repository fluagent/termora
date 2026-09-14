import 'dart:io';

import 'package:termora/core/l10n/app_l10n.dart';
/// 一条已保存的 SSH 主机配置(WindTerm 式会话管理器的最小字段集)
class SshHost {
  const SshHost({
    required this.id,
    required this.name,
    this.host = '',
    this.port = 22,
    this.user = '',
    this.keyPath = '',
    this.extraArgs = '',
    this.group = '',
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String user;

  /// 所属分组(会话管理器文件夹);空 = 未分组
  final String group;

  /// 私钥路径(空则走默认 ~/.ssh 或密码交互,由系统 OpenSSH 处理)
  final String keyPath;

  /// 追加到 ssh 命令的原样参数(如 -J jump@bastion)
  final String extraArgs;

  /// user@host 形式的连接目标(user 为空时只有 host)
  String get target => user.isEmpty ? host : '$user@$host';

  /// 组装交给终端会话运行的 ssh 命令。
  /// Windows 的 cmd.exe 不识别 POSIX 单引号，且 Windows OpenSSH 的
  /// ControlPath/ControlMaster 兼容性不稳定。因此在 Windows 上以 cmd
  /// 语法引用本地路径，并禁用连接复用。
  String sshCommand() {
    final isWindows = Platform.isWindows;
    final parts = <String>[
      'ssh',
      '-o', 'ServerAliveInterval=30',
      if (!isWindows) ...[
        '-o', 'ControlMaster=auto',
        '-o', 'ControlPath=~/.termora/cm-%C',
        '-o', 'ControlPersist=10m',
      ],
      if (port != 22) ...['-p', '$port'],
      if (keyPath.isNotEmpty)
        ...['-i', _quote(_sshPath(keyPath, isWindows: isWindows), isWindows: isWindows)],
      if (extraArgs.trim().isNotEmpty) extraArgs.trim(),
      _quote(target, isWindows: isWindows),
    ];
    return parts.join(' ');
  }

  static String _quote(String value, {required bool isWindows}) {
    if (value.isEmpty) return value;
    // 无特殊字符时保持可读。
    if (RegExp(r"^[A-Za-z0-9@._\-/~:]+$").hasMatch(value)) return value;
    // cmd.exe 不把单引号当作引号，会把它传入 ssh 的 -i 路径中。
    // Windows 文件名不能含双引号，因此这里无需处理嵌入双引号的路径。
    if (isWindows) return '"$value"';
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  /// Windows OpenSSH 接受驱动器路径中的正斜杠（如 D:/keys/id.pem）。
  /// 这能避免经过终端 PTY/cmd.exe 时，反斜杠被当成转义字符或被改写。
  static String _sshPath(String value, {required bool isWindows}) =>
      isWindows ? value.replaceAll(r'\', '/') : value;

  SshHost copyWith({
    String? name,
    String? host,
    int? port,
    String? user,
    String? keyPath,
    String? extraArgs,
    String? group,
  }) {
    return SshHost(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      user: user ?? this.user,
      keyPath: keyPath ?? this.keyPath,
      extraArgs: extraArgs ?? this.extraArgs,
      group: group ?? this.group,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'user': user,
    'keyPath': keyPath,
    'extraArgs': extraArgs,
    'group': group,
  };

  factory SshHost.fromJson(Map<String, dynamic> json) => SshHost(
    id: json['id'] as String,
    name: json['name'] as String? ?? tr('未命名主机'),
    host: json['host'] as String? ?? '',
    port: (json['port'] as num?)?.toInt() ?? 22,
    user: json['user'] as String? ?? '',
    keyPath: json['keyPath'] as String? ?? '',
    extraArgs: json['extraArgs'] as String? ?? '',
    group: json['group'] as String? ?? '',
  );
}
