import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/app_database.dart';
import '../models/backup_bundle.dart';
import 'xlsx_service.dart';

Uint8List _createWorkbook(BackupBundle bundle) =>
    XlsxService().exportBundle(bundle);

class AutoBackupService {
  AutoBackupService._();

  static final instance = AutoBackupService._();

  static const intervalSetting = 'auto_backup_interval_days';
  static const lastAtSetting = 'last_auto_backup_at';
  static const lastFileSetting = 'last_auto_backup_file';
  static const lastErrorSetting = 'last_auto_backup_error';

  final _db = AppDatabase.instance;
  Future<File?>? _runningBackup;

  Future<Directory> backupDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      p.join(documents.path, 'BusyBudget', 'backups'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<int> intervalDays() async =>
      int.tryParse(await _db.setting(intervalSetting) ?? '') ?? 0;

  Future<void> setIntervalDays(int days) =>
      _db.saveSetting(intervalSetting, days.toString());

  Future<File?> runIfDue() async {
    final interval = await intervalDays();
    if (interval <= 0) return null;
    final lastValue = await _db.setting(lastAtSetting);
    final last = lastValue == null ? null : DateTime.tryParse(lastValue);
    if (last != null &&
        DateTime.now().difference(last) < Duration(days: interval)) {
      return null;
    }
    return createBackup();
  }

  Future<File?> createBackup() {
    final active = _runningBackup;
    if (active != null) return active;
    final operation = _createBackup();
    _runningBackup = operation;
    return operation.whenComplete(() => _runningBackup = null);
  }

  Future<File?> _createBackup() async {
    try {
      final now = DateTime.now();
      final directory = await backupDirectory();
      final filename =
          'busy_budget_auto_${DateFormat('yyyyMMdd_HHmmss').format(now)}.xlsx';
      final destination = File(p.join(directory.path, filename));
      final temporary = File('${destination.path}.tmp');
      final bundle = await _db.backupBundle();
      final bytes = await compute(_createWorkbook, bundle);
      await temporary.writeAsBytes(bytes, flush: true);
      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
      await _db.saveSetting(lastAtSetting, now.toIso8601String());
      await _db.saveSetting(lastFileSetting, filename);
      await _db.saveSetting(lastErrorSetting, '');
      return destination;
    } catch (error) {
      await _db.saveSetting(lastErrorSetting, error.toString());
      rethrow;
    }
  }

  Future<List<File>> filesOlderThan(int days) async {
    final directory = await backupDirectory();
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final files = <File>[];
    await for (final entity in directory.list()) {
      if (entity is! File ||
          !p.basename(entity.path).startsWith('busy_budget_auto_') ||
          p.extension(entity.path).toLowerCase() != '.xlsx') {
        continue;
      }
      if ((await entity.lastModified()).isBefore(cutoff)) files.add(entity);
    }
    return files;
  }

  Future<int> deleteOlderThan(int days) async {
    final files = await filesOlderThan(days);
    var deleted = 0;
    for (final file in files) {
      if (await file.exists()) {
        await file.delete();
        deleted++;
      }
    }
    return deleted;
  }
}
