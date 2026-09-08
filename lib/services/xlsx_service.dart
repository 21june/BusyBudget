import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../models/backup_bundle.dart';
import '../models/monthly_budget.dart';
import '../models/recurring_plan.dart';
import '../models/transaction_entry.dart';

class XlsxService {
  static const headers = [
    '날짜',
    '자산',
    '분류',
    '제목',
    '가격(KRW)',
    '수입/지출',
    '업체',
    '기타 메모',
    '거래유형',
    '계획ID',
    '현재회차',
    '전체회차',
  ];

  Uint8List export(List<TransactionEntry> entries) =>
      exportBundle(BackupBundle(entries: entries));

  Uint8List exportBundle(BackupBundle bundle) {
    final excel = Excel.createExcel();
    final sheet = excel['거래내역'];
    excel.delete('Sheet1');
    sheet.appendRow(headers.map(TextCellValue.new).toList());
    for (final e in bundle.entries) {
      sheet.appendRow([
        DateCellValue(year: e.date.year, month: e.date.month, day: e.date.day),
        TextCellValue(e.asset),
        TextCellValue(e.category),
        TextCellValue(e.title),
        IntCellValue(e.amount),
        TextCellValue(e.flow),
        TextCellValue(e.merchant),
        TextCellValue(e.note),
        TextCellValue(e.planType),
        TextCellValue(e.planId ?? ''),
        IntCellValue(e.installmentNo ?? 0),
        IntCellValue(e.installmentTotal ?? 0),
      ]);
    }
    final meta = excel['메타'];
    meta.appendRow([TextCellValue('포맷버전'), IntCellValue(4)]);
    final plans = excel['정기결제'];
    plans.appendRow(
      [
        '계획ID',
        '시작일',
        '해지월',
        '자산',
        '종류',
        '제목',
        '금액',
        '수입/지출',
        '업체',
        '메모',
      ].map(TextCellValue.new).toList(),
    );
    for (final plan in bundle.recurringPlans) {
      plans.appendRow([
        TextCellValue(plan.planId),
        TextCellValue(_dateKey(plan.startDate)),
        TextCellValue(plan.endMonth == null ? '' : _dateKey(plan.endMonth!)),
        TextCellValue(plan.asset),
        TextCellValue(plan.category),
        TextCellValue(plan.title),
        IntCellValue(plan.amount),
        TextCellValue(plan.flow),
        TextCellValue(plan.merchant),
        TextCellValue(plan.note),
      ]);
    }
    _appendSingleColumn(excel['자산'], '자산', bundle.assets);
    _appendSingleColumn(excel['종류'], '종류', bundle.categories);
    _appendSingleColumn(excel['지출종류'], '지출종류', bundle.categories);
    _appendSingleColumn(excel['수입종류'], '수입종류', bundle.incomeCategories);
    final settings = excel['설정'];
    settings.appendRow([TextCellValue('키'), TextCellValue('값')]);
    for (final setting in bundle.settings.entries) {
      settings.appendRow([
        TextCellValue(setting.key),
        TextCellValue(setting.value),
      ]);
    }
    final budgets = excel['월별예산'];
    budgets.appendRow(
      ['월', '종류', '예산(KRW)'].map(TextCellValue.new).toList(),
    );
    for (final budget in bundle.monthlyBudgets) {
      budgets.appendRow([
        TextCellValue(budget.month),
        TextCellValue(budget.category),
        IntCellValue(budget.amount),
      ]);
    }
    final bytes = excel.encode();
    if (bytes == null) throw StateError('XLSX 파일을 만들 수 없습니다.');
    return Uint8List.fromList(bytes);
  }

  List<TransactionEntry> import(Uint8List bytes) => importBundle(bytes).entries;

  BackupBundle importBundle(Uint8List bytes) {
    final excel = Excel.decodeBytes(bytes);
    final entries = _importEntries(excel);
    final plans = <RecurringPlan>[];
    final planSheet = excel.tables['정기결제'];
    if (planSheet != null) {
      for (final row in planSheet.rows.skip(1)) {
        String at(int index) =>
            index < row.length ? _text(row[index]?.value).trim() : '';
        if (at(0).isEmpty) continue;
        plans.add(
          RecurringPlan(
            planId: at(0),
            startDate: DateTime.parse(at(1)),
            endMonth: at(2).isEmpty ? null : DateTime.parse(at(2)),
            asset: at(3),
            category: at(4),
            title: at(5),
            amount: int.parse(at(6).split('.').first),
            flow: at(7),
            merchant: at(8),
            note: at(9),
          ),
        );
      }
    }
    final settings = <String, String>{};
    final settingsSheet = excel.tables['설정'];
    if (settingsSheet != null) {
      for (final row in settingsSheet.rows.skip(1)) {
        if (row.isNotEmpty && _text(row[0]?.value).isNotEmpty) {
          settings[_text(row[0]?.value)] = row.length > 1
              ? _text(row[1]?.value)
              : '';
        }
      }
    }
    final monthlyBudgets = <MonthlyBudget>[];
    final budgetSheet = excel.tables['월별예산'];
    if (budgetSheet != null) {
      final monthPattern = RegExp(r'^\d{4}-(0[1-9]|1[0-2])$');
      for (var rowIndex = 1; rowIndex < budgetSheet.rows.length; rowIndex++) {
        final row = budgetSheet.rows[rowIndex];
        String at(int index) =>
            index < row.length ? _text(row[index]?.value).trim() : '';
        if (at(0).isEmpty && at(1).isEmpty && at(2).isEmpty) continue;
        final month = at(0);
        final category = at(1);
        final amount = _number(row.length > 2 ? row[2]?.value : null);
        if (!monthPattern.hasMatch(month) ||
            category.isEmpty ||
            amount == null ||
            amount <= 0) {
          throw FormatException(
            '월별예산 시트 ${rowIndex + 1}행의 월, 종류 또는 예산이 올바르지 않습니다.',
          );
        }
        monthlyBudgets.add(
          MonthlyBudget(month: month, category: category, amount: amount),
        );
      }
    }
    var formatVersion = _formatVersion(excel);
    if (formatVersion == 1 && (plans.isNotEmpty || settings.isNotEmpty)) {
      formatVersion = 2;
    }
    if (budgetSheet != null && formatVersion < 3) formatVersion = 3;
    return BackupBundle(
      entries: entries,
      recurringPlans: plans,
      assets: _singleColumn(excel.tables['자산']),
      categories: _singleColumn(
        excel.tables['지출종류'] ?? excel.tables['종류'],
      ),
      incomeCategories: _singleColumn(excel.tables['수입종류']),
      monthlyBudgets: monthlyBudgets,
      settings: settings,
      formatVersion: formatVersion,
    );
  }

  List<TransactionEntry> _importEntries(Excel excel) {
    final sheet =
        excel.tables['거래내역'] ??
        excel.tables['편한가계부'] ??
        excel.tables.values.first;
    if (sheet.rows.isEmpty) throw const FormatException('빈 XLSX 파일입니다.');
    final names = sheet.rows.first.map((c) => _text(c?.value)).toList();
    final modern = names.contains('제목');
    final indexes = modern
        ? {
            'date': 0,
            'asset': 1,
            'category': 2,
            'title': 3,
            'amount': 4,
            'flow': 5,
            'merchant': 6,
            'note': 7,
            'type': 8,
            'plan': 9,
            'no': 10,
            'total': 11,
          }
        : {
            'date': 0,
            'asset': 1,
            'category': 2,
            'title': 4,
            'amount': 5,
            'flow': 6,
            'merchant': 7,
          };
    final result = <TransactionEntry>[];
    for (var rowIndex = 1; rowIndex < sheet.rows.length; rowIndex++) {
      final row = sheet.rows[rowIndex];
      String at(String key) =>
          indexes[key] == null || indexes[key]! >= row.length
          ? ''
          : _text(row[indexes[key]!]?.value);
      final rawTitle = at('title').trim();
      final title = rawTitle.isEmpty && !modern
          ? at('category').trim()
          : rawTitle;
      if (title.isEmpty) {
        throw FormatException('${rowIndex + 1}행의 제목이 비어 있습니다.');
      }
      final date = _date(
        indexes['date']! < row.length ? row[indexes['date']!]?.value : null,
      );
      final amount = _number(
        indexes['amount']! < row.length ? row[indexes['amount']!]?.value : null,
      );
      final flow = at('flow').trim();
      if (date == null || amount == null || !{'수입', '지출'}.contains(flow)) {
        throw FormatException(
          '${rowIndex + 1}행의 날짜, 금액 또는 수입/지출 값이 올바르지 않습니다.',
        );
      }
      final match = RegExp(r'\((\d+)/(\d+)\)\s*$').firstMatch(title);
      result.add(
        TransactionEntry(
          date: date,
          asset: at('asset').trim(),
          category: at('category').trim(),
          title: title,
          amount: amount.abs(),
          flow: flow,
          merchant: at('merchant').trim(),
          note: at('note').trim(),
          planType: at('type').isEmpty
              ? (match == null ? 'normal' : 'installment')
              : at('type'),
          planId: at('plan').isEmpty ? null : at('plan'),
          installmentNo:
              _optionalInt(at('no')) ??
              (match == null ? null : int.parse(match.group(1)!)),
          installmentTotal:
              _optionalInt(at('total')) ??
              (match == null ? null : int.parse(match.group(2)!)),
        ),
      );
    }
    if (result.isEmpty) throw const FormatException('가져올 거래가 없습니다.');
    return result;
  }

  static void _appendSingleColumn(
    Sheet sheet,
    String header,
    List<String> values,
  ) {
    sheet.appendRow([TextCellValue(header)]);
    for (final value in values) {
      sheet.appendRow([TextCellValue(value)]);
    }
  }

  static List<String> _singleColumn(Sheet? sheet) => sheet == null
      ? const []
      : sheet.rows
            .skip(1)
            .map((row) => row.isEmpty ? '' : _text(row.first?.value).trim())
            .where((value) => value.isNotEmpty)
            .toList();

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  static String _text(CellValue? value) => switch (value) {
    null => '',
    TextCellValue() => value.value.toString(),
    IntCellValue() => value.value.toString(),
    DoubleCellValue() => value.value.toString(),
    _ => value.toString(),
  };

  static int? _number(CellValue? value) => switch (value) {
    IntCellValue() => value.value,
    DoubleCellValue() => value.value.round(),
    TextCellValue() => int.tryParse(
      value.value.toString().replaceAll(',', '').split('.').first,
    ),
    _ => null,
  };

  static int? _optionalInt(String text) {
    final value = int.tryParse(text.split('.').first);
    return value == 0 ? null : value;
  }

  static int _formatVersion(Excel excel) {
    final sheet = excel.tables['메타'];
    if (sheet == null) return 1;
    for (final row in sheet.rows) {
      if (row.isNotEmpty && _text(row[0]?.value).trim() == '포맷버전') {
        return row.length > 1 ? (_number(row[1]?.value) ?? 1) : 1;
      }
    }
    return 1;
  }

  static DateTime? _date(CellValue? value) {
    if (value is DateCellValue) {
      return DateTime(value.year, value.month, value.day);
    }
    if (value is DateTimeCellValue) return value.asDateTimeLocal();
    if (value is IntCellValue) {
      return DateTime(1899, 12, 30).add(Duration(days: value.value));
    }
    if (value is DoubleCellValue) {
      return DateTime(1899, 12, 30).add(Duration(days: value.value.floor()));
    }
    final text = _text(value).trim();
    return DateTime.tryParse(text);
  }
}
