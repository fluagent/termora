import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/remote/domain/ssh_host.dart';

void main() {
  const host = SshHost(
    id: '1',
    name: 'server',
    host: 'www.yuyabot.com',
    user: 'root',
    keyPath: r'D:\Github_Project\yuyabot.pem',
  );

  test('uses cmd-compatible key quoting and disables muxing on Windows', () {
    final command = host.sshCommand();

    if (Platform.isWindows) {
      expect(command, contains('-i D:/Github_Project/yuyabot.pem'));
      expect(command, isNot(contains('ControlMaster=')));
      expect(command, isNot(contains('ControlPath=')));
      expect(command, isNot(contains('ControlPersist=')));
    }
  });
}
