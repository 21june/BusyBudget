import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/transaction_entry.dart';
import '../models/recurring_plan.dart';
import '../models/backup_bundle.dart';
import '../models/monthly_budget.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getApplicationDocumentsDirectory();
    _database = await openDatabase(
      p.join(dir.path, 'ledger.db'),
      version: 7,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE transactions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            asset TEXT NOT NULL,
            category TEXT NOT NULL,
            title TEXT NOT NULL,
            amount INTEGER NOT NULL CHECK(amount >= 0),
            flow TEXT NOT NULL CHECK(flow IN ('수입','지출')),
            merchant TEXT NOT NULL DEFAULT '',
            note TEXT NOT NULL DEFAULT '',
            plan_type TEXT NOT NULL DEFAULT 'normal',
            plan_id TEXT,
            installment_no INTEGER,
            installment_total INTEGER
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_transactions_date ON transactions(date)',
        );
        await db.execute(
          'CREATE INDEX idx_transactions_title ON transactions(title)',
        );
        await db.execute(
          'CREATE INDEX idx_transactions_plan ON transactions(plan_id)',
        );
        await _createOptionsTables(db);
        await _createRecurringPlansTable(db);
        await _createSettingsTable(db);
        await _createBudgetsTable(db);
        await _createSearchIndexes(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await _createOptionsTables(db);
        if (oldVersion < 3) await _createRecurringPlansTable(db);
        if (oldVersion < 4) await _createSettingsTable(db);
        if (oldVersion < 5) await _createBudgetsTable(db);
        if (oldVersion < 6) await _createSearchIndexes(db);
        if (oldVersion < 7) await _migrateCategoryFlow(db);
      },
    );
    return _database!;
  }

  Future<List<TransactionEntry>> list({
    String query = '',
    DateTime? month,
    DateTime? startDate,
    DateTime? endDate,
    int? minimumAmount,
    int? maximumAmount,
    String? asset,
    String? category,
    String? flow,
    String order = 'newest',
  }) async {
    final db = await database;
    await _materializeRecurringPayments(db, DateTime.now());
    final where = <String>[];
    final args = <Object?>[];
    if (query.trim().isNotEmpty) {
      final pattern = '%${query.trim().toLowerCase()}%';
      where.add('''
        (
          LOWER(title) LIKE ? OR
          LOWER(merchant) LIKE ? OR
          LOWER(note) LIKE ? OR
          LOWER(asset) LIKE ? OR
          LOWER(category) LIKE ? OR
          CAST(amount AS TEXT) LIKE ? OR
          date LIKE ?
        )
      ''');
      args.addAll(List<Object?>.filled(7, pattern));
    }
    if (month != null) {
      final next = DateTime(month.year, month.month + 1);
      where.add('date >= ? AND date < ?');
      args
        ..add(_dateKey(DateTime(month.year, month.month)))
        ..add(_dateKey(next));
    }
    if (startDate != null) {
      where.add('date >= ?');
      args.add(_dateKey(startDate));
    }
    if (endDate != null) {
      where.add('date < ?');
      args.add(_dateKey(endDate.add(const Duration(days: 1))));
    }
    if (minimumAmount != null) {
      where.add('amount >= ?');
      args.add(minimumAmount);
    }
    if (maximumAmount != null) {
      where.add('amount <= ?');
      args.add(maximumAmount);
    }
    if (asset != null) {
      where.add('asset = ?');
      args.add(asset);
    }
    if (category != null) {
      where.add('category = ?');
      args.add(category);
    }
    if (flow != null) {
      where.add('flow = ?');
      args.add(flow);
    }
    final rows = await db.query(
      'transactions',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args,
      orderBy: switch (order) {
        'oldest' => 'date ASC, id ASC',
        'amountHigh' => 'amount DESC, date DESC, id DESC',
        'amountLow' => 'amount ASC, date DESC, id DESC',
        _ => 'date DESC, id DESC',
      },
    );
    return rows.map(TransactionEntry.fromMap).toList();
  }

  Future<List<TransactionEntry>> listYear(int year) async {
    final db = await database;
    await _materializeRecurringPayments(db, DateTime.now());
    final rows = await db.query(
      'transactions',
      where: 'date >= ? AND date < ?',
      whereArgs: [
        '${year.toString().padLeft(4, '0')}-01-01',
        '${year + 1}-01-01',
      ],
      orderBy: 'date ASC, id ASC',
    );
    return rows.map(TransactionEntry.fromMap).toList();
  }

  Future<void> save(TransactionEntry entry) async {
    final db = await database;
    final map = entry.toMap()..remove('id');
    await db.transaction((txn) async {
      if (entry.id == null) {
        await txn.insert('transactions', map);
      } else {
        await txn.update(
          'transactions',
          map,
          where: 'id = ?',
          whereArgs: [entry.id],
        );
      }
      await _ensureOption(txn, 'assets', entry.asset);
      await _ensureOption(txn, 'categories', entry.category, flow: entry.flow);
    });
  }

  Future<void> addInstallments(TransactionEntry base, int count) async {
    final db = await database;
    final planId = DateTime.now().microsecondsSinceEpoch.toString();
    final each = base.amount ~/ count;
    final remainder = base.amount % count;
    await db.transaction((txn) async {
      await _ensureOption(txn, 'assets', base.asset);
      await _ensureOption(txn, 'categories', base.category, flow: base.flow);
      for (var i = 0; i < count; i++) {
        final value = TransactionEntry(
          date: DateTime(base.date.year, base.date.month + i, base.date.day),
          asset: base.asset,
          category: base.category,
          title: '${base.title}(${i + 1}/$count)',
          amount: each + (i == count - 1 ? remainder : 0),
          flow: base.flow,
          merchant: base.merchant,
          note: base.note,
          planType: 'installment',
          planId: planId,
          installmentNo: i + 1,
          installmentTotal: count,
        );
        await txn.insert('transactions', value.toMap()..remove('id'));
      }
    });
  }

  Future<void> updateInstallmentsFrom(TransactionEntry entry) async {
    final planId = entry.planId;
    final currentNo = entry.installmentNo;
    final total = entry.installmentTotal;
    if (planId == null || currentNo == null || total == null) {
      throw ArgumentError('할부 계획 정보가 없습니다.');
    }
    final db = await database;
    final baseTitle = entry.title
        .replaceFirst(RegExp(r'\(\d+/\d+\)\s*$'), '')
        .trim();
    await db.transaction((txn) async {
      await _ensureOption(txn, 'assets', entry.asset);
      await _ensureOption(txn, 'categories', entry.category, flow: entry.flow);
      final rows = await txn.query(
        'transactions',
        columns: ['id', 'installment_no'],
        where: 'plan_id = ? AND plan_type = ? AND installment_no >= ?',
        whereArgs: [planId, 'installment', currentNo],
        orderBy: 'installment_no',
      );
      for (final row in rows) {
        final installmentNo = row['installment_no']! as int;
        final updated = TransactionEntry(
          date: _monthlyDate(entry.date, installmentNo - currentNo),
          asset: entry.asset,
          category: entry.category,
          title: '$baseTitle($installmentNo/$total)',
          amount: entry.amount,
          flow: entry.flow,
          merchant: entry.merchant,
          note: entry.note,
          planType: 'installment',
          planId: planId,
          installmentNo: installmentNo,
          installmentTotal: total,
        );
        await txn.update(
          'transactions',
          updated.toMap()..remove('id'),
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    });
  }

  Future<void> addRecurring(TransactionEntry base) async {
    final db = await database;
    final planId = DateTime.now().microsecondsSinceEpoch.toString();
    await db.transaction((txn) async {
      await _ensureOption(txn, 'assets', base.asset);
      await _ensureOption(txn, 'categories', base.category, flow: base.flow);
      await txn.insert('recurring_plans', {
        'plan_id': planId,
        'start_date': _dateKey(base.date),
        'end_month': null,
        'asset': base.asset,
        'category': base.category,
        'title': base.title,
        'amount': base.amount,
        'flow': base.flow,
        'merchant': base.merchant,
        'note': base.note,
      });
      await _materializeRecurringPayments(txn, DateTime.now());
    });
  }

  Future<bool> isRecurringActive(String? planId) async {
    if (planId == null) return false;
    final rows = await (await database).query(
      'recurring_plans',
      columns: ['end_month'],
      where: 'plan_id = ?',
      whereArgs: [planId],
      limit: 1,
    );
    return rows.isNotEmpty && rows.single['end_month'] == null;
  }

  Future<List<RecurringPlan>> recurringPlans() async {
    final db = await database;
    await _materializeRecurringPayments(db, DateTime.now());
    final rows = await db.query(
      'recurring_plans',
      orderBy: 'CASE WHEN end_month IS NULL THEN 0 ELSE 1 END, start_date DESC',
    );
    return rows.map(RecurringPlan.fromMap).toList();
  }

  Future<void> updateRecurringFrom(
    TransactionEntry entry,
    DateTime fromDate,
  ) async {
    final planId = entry.planId;
    if (planId == null) throw ArgumentError('정기결제 계획 ID가 없습니다.');
    final db = await database;
    final fromMonth = DateTime(fromDate.year, fromDate.month);
    await db.transaction((txn) async {
      await _ensureOption(txn, 'assets', entry.asset);
      await _ensureOption(txn, 'categories', entry.category, flow: entry.flow);
      await txn.update(
        'recurring_plans',
        {
          'start_date': _dateKey(entry.date),
          'asset': entry.asset,
          'category': entry.category,
          'title': entry.title,
          'amount': entry.amount,
          'flow': entry.flow,
          'merchant': entry.merchant,
          'note': entry.note,
        },
        where: 'plan_id = ?',
        whereArgs: [planId],
      );
      await txn.delete(
        'transactions',
        where: 'plan_id = ? AND plan_type = ? AND date >= ?',
        whereArgs: [planId, 'recurring', _dateKey(fromMonth)],
      );
      await _materializeRecurringPayments(txn, DateTime.now());
    });
  }

  Future<void> reactivateRecurring(String planId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        'recurring_plans',
        {'end_month': null},
        where: 'plan_id = ?',
        whereArgs: [planId],
      );
      await txn.update(
        'transactions',
        {'plan_type': 'recurring'},
        where: 'plan_id = ? AND plan_type = ?',
        whereArgs: [planId, 'recurring_ended'],
      );
      await _materializeRecurringPayments(txn, DateTime.now());
    });
  }

  Future<void> cancelRecurring(String planId, DateTime lastMonth) async {
    final db = await database;
    final month = DateTime(lastMonth.year, lastMonth.month);
    final nextMonth = DateTime(month.year, month.month + 1);
    await db.transaction((txn) async {
      await txn.update(
        'recurring_plans',
        {'end_month': _dateKey(month)},
        where: 'plan_id = ?',
        whereArgs: [planId],
      );
      await txn.update(
        'transactions',
        {'plan_type': 'recurring_ended'},
        where: 'plan_id = ? AND plan_type = ?',
        whereArgs: [planId, 'recurring'],
      );
      await txn.delete(
        'transactions',
        where: 'plan_id = ? AND plan_type = ? AND date >= ?',
        whereArgs: [planId, 'recurring_ended', _dateKey(nextMonth)],
      );
    });
  }

  Future<void> delete(int id) async =>
      (await database).delete('transactions', where: 'id = ?', whereArgs: [id]);

  Future<void> restoreDeletedEntry(TransactionEntry entry) async {
    await (await database).insert(
      'transactions',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteInstallmentsFrom(String planId, int installmentNo) async {
    await (await database).delete(
      'transactions',
      where: 'plan_id = ? AND plan_type = ? AND installment_no >= ?',
      whereArgs: [planId, 'installment', installmentNo],
    );
  }

  Future<void> deleteRecurringPlan(String planId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'transactions',
        where: 'plan_id = ?',
        whereArgs: [planId],
      );
      await txn.delete(
        'recurring_plans',
        where: 'plan_id = ?',
        whereArgs: [planId],
      );
    });
  }

  Future<String?> setting(String key) async {
    final rows = await (await database).query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value']! as String;
  }

  Future<void> saveSetting(String key, String value) async {
    await (await database).insert('app_settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, int>> monthlyBudgets(DateTime month) async {
    final rows = await (await database).query(
      'monthly_budgets',
      where: 'month = ?',
      whereArgs: [_monthKey(month)],
      orderBy: 'category',
    );
    return {
      for (final row in rows) row['category']! as String: row['amount']! as int,
    };
  }

  Future<int?> monthlyTotalBudget(DateTime month) async {
    final value = await setting('total_budget_${_monthKey(month)}');
    return value == null ? null : int.tryParse(value);
  }

  Future<void> saveMonthlyTotalBudget(DateTime month, int amount) =>
      saveSetting('total_budget_${_monthKey(month)}', amount.toString());

  Future<void> deleteMonthlyTotalBudget(DateTime month) async {
    await (await database).delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['total_budget_${_monthKey(month)}'],
    );
  }

  Future<({int installment, int recurring})> plannedAmounts(
    DateTime month,
  ) async {
    final db = await database;
    final start = DateTime(month.year, month.month);
    final next = DateTime(month.year, month.month + 1);
    final installmentRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(amount), 0) AS total
      FROM transactions
      WHERE plan_type = 'installment' AND flow = '지출'
        AND date >= ? AND date < ?
      ''',
      [_dateKey(start), _dateKey(next)],
    );
    final planRows = await db.query(
      'recurring_plans',
      where:
          "flow = '지출' AND start_date < ? "
          'AND (end_month IS NULL OR end_month >= ?)',
      whereArgs: [_dateKey(next), _dateKey(start)],
    );
    var recurring = 0;
    for (final plan in planRows) {
      final planStart = DateTime.parse(plan['start_date']! as String);
      final offset =
          (start.year - planStart.year) * 12 + start.month - planStart.month;
      if (offset < 0) continue;
      final occurrence = _monthlyDate(planStart, offset);
      if (occurrence.isBefore(next)) recurring += plan['amount']! as int;
    }
    return (
      installment: installmentRows.first['total']! as int,
      recurring: recurring,
    );
  }

  Future<void> saveMonthlyBudget(
    DateTime month,
    String category,
    int amount,
  ) async {
    await (await database).insert('monthly_budgets', {
      'month': _monthKey(month),
      'category': category,
      'amount': amount,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteMonthlyBudget(DateTime month, String category) async {
    await (await database).delete(
      'monthly_budgets',
      where: 'month = ? AND category = ?',
      whereArgs: [_monthKey(month), category],
    );
  }

  Future<int> transactionCount() async {
    final rows = await (await database).rawQuery(
      'SELECT COUNT(*) AS value FROM transactions',
    );
    return rows.first['value']! as int;
  }

  Future<void> clearLedgerData() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('recurring_plans');
      await txn.delete('transactions');
      await txn.delete('monthly_budgets');
      await txn.delete(
        'app_settings',
        where: 'key LIKE ?',
        whereArgs: ['total_budget_%'],
      );
      await txn.delete('assets');
      await txn.delete('categories');
      await txn.insert('assets', {'name': '카드', 'sort_order': 1});
      await txn.insert('assets', {'name': '현금', 'sort_order': 2});
      await txn.insert('categories', {
        'name': '식비',
        'flow': '지출',
        'sort_order': 1,
      });
      await txn.insert('categories', {
        'name': '월급',
        'flow': '수입',
        'sort_order': 1,
      });
    });
  }

  Future<int> copyPreviousMonthBudgets(DateTime month) async {
    final db = await database;
    final previous = DateTime(month.year, month.month - 1);
    final rows = await db.query(
      'monthly_budgets',
      where: 'month = ?',
      whereArgs: [_monthKey(previous)],
    );
    final previousTotal = await monthlyTotalBudget(previous);
    if (rows.isEmpty && previousTotal == null) return 0;
    await db.transaction((txn) async {
      for (final row in rows) {
        await txn.insert('monthly_budgets', {
          'month': _monthKey(month),
          'category': row['category'],
          'amount': row['amount'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (previousTotal != null) {
        await txn.insert('app_settings', {
          'key': 'total_budget_${_monthKey(month)}',
          'value': previousTotal.toString(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    return rows.length + (previousTotal == null ? 0 : 1);
  }

  Future<BackupBundle> backupBundle() async {
    final db = await database;
    final settingRows = await db.query('app_settings');
    final budgetRows = await db.query(
      'monthly_budgets',
      orderBy: 'month, category',
    );
    return BackupBundle(
      entries: await list(),
      recurringPlans: await recurringPlans(),
      assets: await optionNames('asset'),
      categories: await optionNames('category', flow: '지출'),
      incomeCategories: await optionNames('category', flow: '수입'),
      monthlyBudgets: budgetRows.map(MonthlyBudget.fromMap).toList(),
      settings: {
        for (final row in settingRows)
          row['key']! as String: row['value']! as String,
      },
      formatVersion: 4,
    );
  }

  Future<List<String>> optionNames(String type, {String? flow}) async {
    final table = _optionTable(type);
    final field = type == 'asset' ? 'asset' : 'category';
    final db = await database;
    final flowFilter = type == 'category' && flow != null;
    final rows = await db.rawQuery('''
      SELECT name
      FROM (
        SELECT name, sort_order FROM $table
        ${flowFilter ? 'WHERE flow = ?' : ''}
        UNION ALL
        SELECT DISTINCT $field AS name, 2147483647 AS sort_order
        FROM transactions
        WHERE $field <> '' ${flowFilter ? 'AND flow = ?' : ''}
      )
      GROUP BY name
      ORDER BY MIN(sort_order), name
    ''', flowFilter ? [flow, flow] : null);
    return rows.map((row) => row['name']! as String).toList();
  }

  Future<void> addOption(String type, String name, {String? flow}) async {
    final value = name.trim();
    if (value.isEmpty) return;
    final table = _optionTable(type);
    final db = await database;
    final nextRows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_order), 0) + 1 AS value FROM $table'
      '${type == 'category' ? ' WHERE flow = ?' : ''}',
      type == 'category' ? [flow ?? '지출'] : null,
    );
    final next = nextRows.first['value']! as int;
    await db.insert(table, {
      'name': value,
      if (type == 'category') 'flow': flow ?? '지출',
      'sort_order': next,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<bool> deleteOption(String type, String name, {String? flow}) async {
    final table = _optionTable(type);
    final field = type == 'asset' ? 'asset' : 'category';
    final db = await database;
    final flowFilter = type == 'category' ? (flow ?? '지출') : null;
    final usedRows = await db.rawQuery(
      'SELECT COUNT(*) AS value FROM transactions WHERE $field = ?'
      '${flowFilter == null ? '' : ' AND flow = ?'}',
      [name, ...?(flowFilter == null ? null : [flowFilter])],
    );
    final used = usedRows.first['value']! as int;
    if (used > 0) return false;
    await db.delete(
      table,
      where: 'name = ?${flowFilter == null ? '' : ' AND flow = ?'}',
      whereArgs: [name, ...?(flowFilter == null ? null : [flowFilter])],
    );
    return true;
  }

  Future<List<String>> suggestions(String field, String query) async {
    if (field != 'title' && field != 'merchant') throw ArgumentError(field);
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT $field AS value, COUNT(*) AS frequency, MAX(date) AS recent
      FROM transactions
      WHERE $field <> '' AND LOWER($field) LIKE ?
      GROUP BY $field
      ORDER BY CASE WHEN LOWER($field) LIKE ? THEN 0 ELSE 1 END,
               frequency DESC, recent DESC
      LIMIT 8
    ''',
      ['%${query.toLowerCase()}%', '${query.toLowerCase()}%'],
    );
    return rows.map((e) => e['value']! as String).toList();
  }

  Future<int> replaceAll(List<TransactionEntry> entries) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('recurring_plans');
      await txn.delete('transactions');
      final batch = txn.batch();
      for (final entry in entries) {
        batch.insert('transactions', entry.toMap()..remove('id'));
      }
      await batch.commit(noResult: true);
      for (final asset in entries.map((entry) => entry.asset).toSet()) {
        await _ensureOption(txn, 'assets', asset);
      }
      for (final entry in entries) {
        await _ensureOption(
          txn,
          'categories',
          entry.category,
          flow: entry.flow,
        );
      }
      await _restoreActiveRecurringPlans(txn);
      await _materializeRecurringPayments(txn, DateTime.now());
    });
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS transaction_count FROM transactions',
    );
    return result.first['transaction_count']! as int;
  }

  Future<int> restoreBundle(BackupBundle bundle) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('recurring_plans');
      await txn.delete('transactions');
      await txn.delete('assets');
      await txn.delete('categories');
      if (bundle.formatVersion >= 3) {
        await txn.delete('monthly_budgets');
      }
      final batch = txn.batch();
      for (final entry in bundle.entries) {
        batch.insert('transactions', entry.toMap()..remove('id'));
      }
      await batch.commit(noResult: true);
      for (final asset in bundle.assets) {
        await _ensureOption(txn, 'assets', asset);
      }
      for (final category in bundle.categories) {
        await _ensureOption(txn, 'categories', category, flow: '지출');
      }
      for (final category in bundle.incomeCategories) {
        await _ensureOption(txn, 'categories', category, flow: '수입');
      }
      for (final asset in bundle.entries.map((entry) => entry.asset).toSet()) {
        await _ensureOption(txn, 'assets', asset);
      }
      for (final entry in bundle.entries) {
        await _ensureOption(
          txn,
          'categories',
          entry.category,
          flow: entry.flow,
        );
      }
      if (bundle.recurringPlans.isEmpty) {
        await _restoreActiveRecurringPlans(txn);
      } else {
        for (final plan in bundle.recurringPlans) {
          await txn.insert('recurring_plans', plan.toMap());
          await _ensureOption(
            txn,
            'categories',
            plan.category,
            flow: plan.flow,
          );
        }
      }
      await _ensureOption(txn, 'categories', '식비', flow: '지출');
      await _ensureOption(txn, 'categories', '월급', flow: '수입');
      for (final setting in bundle.settings.entries) {
        await txn.insert('app_settings', {
          'key': setting.key,
          'value': setting.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (bundle.formatVersion >= 3) {
        for (final budget in bundle.monthlyBudgets) {
          await txn.insert('monthly_budgets', budget.toMap());
        }
      }
      await _materializeRecurringPayments(txn, DateTime.now());
    });
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS transaction_count FROM transactions',
    );
    return result.first['transaction_count']! as int;
  }

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  static String _monthKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}';

  static Future<void> _ensureOption(
    DatabaseExecutor db,
    String table,
    String rawName,
    {String? flow}
  ) async {
    final name = rawName.trim();
    if (name.isEmpty) return;
    final nextRows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_order), 0) + 1 AS value FROM $table'
      '${flow == null ? '' : ' WHERE flow = ?'}',
      flow == null ? null : [flow],
    );
    await db.insert(table, {
      'name': name,
      ...?(flow == null ? null : {'flow': flow}),
      'sort_order': nextRows.first['value']! as int,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> _materializeRecurringPayments(
    DatabaseExecutor db,
    DateTime through,
  ) async {
    final plans = await db.query('recurring_plans');
    for (final plan in plans) {
      final start = DateTime.parse(plan['start_date']! as String);
      final endText = plan['end_month'] as String?;
      final endMonth = endText == null ? null : DateTime.parse(endText);
      final lastMonth =
          endMonth == null ||
              DateTime(
                endMonth.year,
                endMonth.month,
              ).isAfter(DateTime(through.year, through.month))
          ? DateTime(through.year, through.month)
          : DateTime(endMonth.year, endMonth.month);
      final monthCount =
          (lastMonth.year - start.year) * 12 + lastMonth.month - start.month;
      for (var offset = 0; offset <= monthCount; offset++) {
        final occurrence = _monthlyDate(start, offset);
        if (occurrence.isAfter(through)) break;
        final entry = TransactionEntry(
          date: occurrence,
          asset: plan['asset']! as String,
          category: plan['category']! as String,
          title: plan['title']! as String,
          amount: plan['amount']! as int,
          flow: plan['flow']! as String,
          merchant: plan['merchant']! as String,
          note: plan['note']! as String,
          planType: 'recurring',
          planId: plan['plan_id']! as String,
        );
        await db.insert(
          'transactions',
          entry.toMap()..remove('id'),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
  }

  static DateTime _monthlyDate(DateTime start, int offset) {
    final firstOfMonth = DateTime(start.year, start.month + offset);
    final lastDay = DateTime(firstOfMonth.year, firstOfMonth.month + 1, 0).day;
    return DateTime(
      firstOfMonth.year,
      firstOfMonth.month,
      start.day > lastDay ? lastDay : start.day,
    );
  }

  static String _optionTable(String type) => switch (type) {
    'asset' => 'assets',
    'category' => 'categories',
    _ => throw ArgumentError.value(type, 'type'),
  };

  static Future<void> _createOptionsTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS assets(
        name TEXT PRIMARY KEY,
        sort_order INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS categories(
        name TEXT NOT NULL,
        flow TEXT NOT NULL CHECK(flow IN ('수입','지출')),
        sort_order INTEGER NOT NULL,
        PRIMARY KEY(name, flow)
      )
    ''');
    await db.execute('''
      INSERT OR IGNORE INTO assets(name, sort_order)
      SELECT asset, MIN(id) FROM transactions WHERE asset <> '' GROUP BY asset
    ''');
    await db.execute('''
      INSERT OR IGNORE INTO categories(name, flow, sort_order)
      SELECT category, flow, MIN(id) FROM transactions
      WHERE category <> '' GROUP BY category, flow
    ''');
    await db.insert('assets', {
      'name': '카드',
      'sort_order': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('assets', {
      'name': '현금',
      'sort_order': 2,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('categories', {
      'name': '식비',
      'flow': '지출',
      'sort_order': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('categories', {
      'name': '월급',
      'flow': '수입',
      'sort_order': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> _migrateCategoryFlow(DatabaseExecutor db) async {
    final columns = await db.rawQuery('PRAGMA table_info(categories)');
    if (columns.any((column) => column['name'] == 'flow')) return;
    await db.execute('''
      CREATE TABLE categories_v7(
        name TEXT NOT NULL,
        flow TEXT NOT NULL CHECK(flow IN ('수입','지출')),
        sort_order INTEGER NOT NULL,
        PRIMARY KEY(name, flow)
      )
    ''');
    await db.execute('''
      INSERT OR IGNORE INTO categories_v7(name, flow, sort_order)
      SELECT category, flow, MIN(id)
      FROM transactions WHERE category <> ''
      GROUP BY category, flow
    ''');
    await db.execute('''
      INSERT OR IGNORE INTO categories_v7(name, flow, sort_order)
      SELECT name, '지출', sort_order FROM categories
    ''');
    await db.execute('DROP TABLE categories');
    await db.execute('ALTER TABLE categories_v7 RENAME TO categories');
    await db.insert('categories', {
      'name': '식비',
      'flow': '지출',
      'sort_order': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('categories', {
      'name': '월급',
      'flow': '수입',
      'sort_order': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> _createRecurringPlansTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recurring_plans(
        plan_id TEXT PRIMARY KEY,
        start_date TEXT NOT NULL,
        end_month TEXT,
        asset TEXT NOT NULL,
        category TEXT NOT NULL,
        title TEXT NOT NULL,
        amount INTEGER NOT NULL CHECK(amount >= 0),
        flow TEXT NOT NULL CHECK(flow IN ('수입','지출')),
        merchant TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_recurring_plan_date
      ON transactions(plan_id, date)
      WHERE plan_type = 'recurring' AND plan_id IS NOT NULL
    ''');
    await _restoreActiveRecurringPlans(db);
  }

  static Future<void> _createSettingsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createBudgetsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS monthly_budgets(
        month TEXT NOT NULL,
        category TEXT NOT NULL,
        amount INTEGER NOT NULL CHECK(amount > 0),
        PRIMARY KEY(month, category)
      )
    ''');
  }

  static Future<void> _createSearchIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_transactions_category ON transactions(category)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_transactions_asset ON transactions(asset)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_transactions_flow ON transactions(flow)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_transactions_amount ON transactions(amount)',
    );
  }

  static Future<void> _restoreActiveRecurringPlans(DatabaseExecutor db) async {
    await db.execute('''
      INSERT OR IGNORE INTO recurring_plans(
        plan_id, start_date, end_month, asset, category, title,
        amount, flow, merchant, note
      )
      SELECT
        plan_id, MIN(date), NULL, asset, category, title,
        amount, flow, merchant, note
      FROM transactions
      WHERE plan_type = 'recurring' AND plan_id IS NOT NULL
      GROUP BY plan_id
    ''');
  }
}
