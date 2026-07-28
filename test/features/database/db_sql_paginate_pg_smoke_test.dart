@Tags(['smoke'])
library;

// SQL 编辑器自动分页 + 下滑加载更多的 PostgreSQL 集成冒烟测试 —
// 需要本地 55432 临时 PG:
//   flutter test --run-skipped --tags smoke test/features/database/db_sql_paginate_pg_smoke_test.dart
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/features/database/controller/database_providers.dart';
import 'package:termora/features/database/domain/db_models.dart';

const _dbName = 'paginate_probe';

const _pg = DbConnectionConfig(
  id: 'pg',
  name: 'pg',
  host: 'localhost',
  port: 55432,
  database: _dbName,
  username: 'postgres',
  password: '',
);

Future<Connection> _open(String db) => Connection.open(
  Endpoint(
    host: 'localhost',
    port: 55432,
    database: db,
    username: 'postgres',
    password: '',
  ),
  settings: const ConnectionSettings(sslMode: SslMode.disable),
);

Future<void> _pump([int ms = 20]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Future<DbSessionController> _connectedController(
  ProviderContainer container,
) async {
  for (var i = 0; i < 100; i++) {
    if (container.read(dbConnectionsProvider).isNotEmpty) break;
    await _pump(5);
  }
  final notifier = container.read(dbSessionProvider.notifier);
  await notifier.connect(_pg);
  for (var i = 0; i < 200; i++) {
    if (container.read(dbSessionProvider).sessionFor('pg').status ==
        DbSessionStatus.connected) {
      break;
    }
    await _pump(5);
  }
  expect(
    container.read(dbSessionProvider).sessionFor('pg').status,
    DbSessionStatus.connected,
  );
  return notifier;
}

DbSqlState _sql(ProviderContainer c) =>
    c.read(dbSessionProvider).sessionFor('pg').sql;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final admin = await _open('postgres');
    try {
      await admin.execute('CREATE DATABASE $_dbName');
    } catch (_) {}
    await admin.close();

    final conn = await _open(_dbName);
    await conn.execute('DROP TABLE IF EXISTS big');
    await conn.execute('CREATE TABLE big (id int PRIMARY KEY, v text)');
    await conn.execute(
      "INSERT INTO big SELECT i, 'v'||i FROM generate_series(1, 450) i",
    );
    await conn.close();
  });

  ProviderContainer makeContainer() {
    SharedPreferences.setMockInitialValues({
      'database.connections.v1': jsonEncode([_pg.toJson()]),
    });
    return ProviderContainer();
  }

  test('纯 SELECT 自动分页:首页 200 行 + hasMore,下滑续拉到 450 行封顶', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = await _connectedController(container);

    await notifier.runSql('SELECT * FROM big ORDER BY id');
    var s = _sql(container);
    expect(s.error, isNull);
    expect(s.output!.rows.length, 200);
    expect(s.hasMore, isTrue);
    expect(s.output!.rows.first.first, 1);
    expect(s.output!.rows.last.first, 200);

    // 第 2 页
    await notifier.loadMoreSql();
    s = _sql(container);
    expect(s.output!.rows.length, 400);
    expect(s.hasMore, isTrue);
    expect(s.output!.rows.last.first, 400);

    // 第 3 页(只剩 50 行)→ 封顶,hasMore=false
    await notifier.loadMoreSql();
    s = _sql(container);
    expect(s.output!.rows.length, 450);
    expect(s.hasMore, isFalse);
    expect(s.output!.rows.last.first, 450);

    // 已封顶再调不再增长
    await notifier.loadMoreSql();
    expect(_sql(container).output!.rows.length, 450);
  });

  test('用户自带 LIMIT 被尊重:不自动分页、无 hasMore', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = await _connectedController(container);

    await notifier.runSql('SELECT * FROM big ORDER BY id LIMIT 5');
    final s = _sql(container);
    expect(s.output!.rows.length, 5);
    expect(s.hasMore, isFalse);
    expect(s.baseQuery, isNull);
    // loadMore 对非分页查询是 no-op
    await notifier.loadMoreSql();
    expect(_sql(container).output!.rows.length, 5);
  });

  test('恰好整页(200 行表):不误报 hasMore', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = await _connectedController(container);
    await notifier.runSql('SELECT * FROM big WHERE id <= 200 ORDER BY id');
    final s = _sql(container);
    expect(s.output!.rows.length, 200);
    expect(s.hasMore, isFalse); // 多取 1 行探测:第 201 行不存在
  });

  test('DML(非 SELECT)不被套 LIMIT,正常执行', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = await _connectedController(container);
    await notifier.runSql('UPDATE big SET v = v WHERE id = 1');
    final s = _sql(container);
    expect(s.error, isNull);
    expect(s.hasMore, isFalse);
    expect(s.baseQuery, isNull);
  });
}
