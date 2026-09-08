import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'data/app_database.dart';
import 'models/backup_bundle.dart';
import 'models/recurring_plan.dart';
import 'models/transaction_entry.dart';
import 'services/xlsx_service.dart';
import 'utils/currency_format.dart';

BackupBundle _parseXlsxInBackground(Uint8List bytes) =>
    XlsxService().importBundle(bytes);

Uint8List _exportXlsxInBackground(BackupBundle bundle) =>
    XlsxService().exportBundle(bundle);

String _displayOption(String value) => switch (value) {
  '카드' => 'Card',
  '현금' => 'Cash',
  '식비' => 'Food',
  '급여' => 'Salary',
  _ => value.trim().isEmpty ? '?' : value,
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ko_KR');
  runApp(const BusyBudgetApp());
}

class BusyBudgetApp extends StatefulWidget {
  const BusyBudgetApp({super.key});

  @override
  State<BusyBudgetApp> createState() => _BusyBudgetAppState();
}

class _BusyBudgetAppState extends State<BusyBudgetApp> {
  var themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final saved = await AppDatabase.instance.setting('theme_mode');
    if (!mounted) return;
    setState(() {
      themeMode = switch (saved) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    });
  }

  Future<void> _changeThemeMode(ThemeMode value) async {
    setState(() => themeMode = value);
    await AppDatabase.instance.saveSetting('theme_mode', value.name);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Busy Budget',
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('ko', 'KR'), Locale('en', 'US')],
    themeMode: themeMode,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff3267e3),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff7f8fc),
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
    ),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff7c9cff),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xff101318),
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
    ),
    home: LedgerHome(
      themeMode: themeMode,
      onThemeModeChanged: _changeThemeMode,
    ),
  );
}

class LedgerHome extends StatefulWidget {
  const LedgerHome({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  @override
  State<LedgerHome> createState() => _LedgerHomeState();
}

class _LedgerHomeState extends State<LedgerHome> {
  final db = AppDatabase.instance;
  final searchController = SearchController();
  final searchFocusNode = FocusNode();
  final ledgerScrollController = ScrollController();
  final todaySectionKey = GlobalKey();
  Timer? searchDebounce;
  var positionedInitialMonth = false;
  var loadGeneration = 0;
  var tab = 0;
  var month = DateTime(DateTime.now().year, DateTime.now().month);
  var query = '';
  var entries = <TransactionEntry>[];
  var loading = true;
  var searchAsset = '';
  var searchCategory = '';
  var searchFlow = '';
  DateTime? searchStartDate;
  DateTime? searchEndDate;
  int? searchMinimumAmount;
  int? searchMaximumAmount;
  var searchOrder = 'newest';
  var assets = <String>[];
  var categories = <String>[];

  @override
  void initState() {
    super.initState();
    _load();
    _loadOptions();
  }

  @override
  void dispose() {
    searchDebounce?.cancel();
    searchController.dispose();
    searchFocusNode.dispose();
    ledgerScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    final loadedAssets = await db.optionNames('asset');
    final loadedCategories = await db.optionNames('category');
    if (!mounted) return;
    setState(() {
      assets = loadedAssets;
      categories = loadedCategories;
    });
  }

  Future<void> _refreshData() async {
    await Future.wait([_load(), _loadOptions()]);
  }

  Future<void> _load({bool showLoading = true}) async {
    final generation = ++loadGeneration;
    if (showLoading && mounted) setState(() => loading = true);
    final rows = await db.list(
      query: query,
      month: tab == 1 ? null : month,
      startDate: tab == 1 ? searchStartDate : null,
      endDate: tab == 1 ? searchEndDate : null,
      minimumAmount: tab == 1 ? searchMinimumAmount : null,
      maximumAmount: tab == 1 ? searchMaximumAmount : null,
      asset: tab == 1 && searchAsset.isNotEmpty ? searchAsset : null,
      category: tab == 1 && searchCategory.isNotEmpty ? searchCategory : null,
      flow: tab == 1 && searchFlow.isNotEmpty ? searchFlow : null,
      order: tab == 1 ? searchOrder : 'newest',
    );
    if (mounted && generation == loadGeneration) {
      setState(() {
        entries = rows;
        loading = false;
      });
      _scheduleInitialTodayPosition();
    }
  }

  void _scheduleInitialTodayPosition() {
    final now = DateTime.now();
    if (positionedInitialMonth ||
        tab != 0 ||
        month.year != now.year ||
        month.month != now.month ||
        entries.isEmpty) {
      return;
    }
    positionedInitialMonth = true;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _positionToday(animate: false),
    );
  }

  Future<void> _positionToday({required bool animate}) async {
    if (!mounted || !ledgerScrollController.hasClients || entries.isEmpty) {
      return;
    }
    final now = DateTime.now();
    var targetIndex = entries.indexWhere((entry) => _sameDay(entry.date, now));
    targetIndex = targetIndex < 0
        ? entries.indexWhere((entry) => !entry.date.isAfter(now))
        : targetIndex;
    if (targetIndex < 0) targetIndex = 0;
    var estimatedOffset = 0.0;
    for (var index = 0; index < targetIndex; index++) {
      estimatedOffset += 80;
      if (index == 0 ||
          !_sameDay(entries[index - 1].date, entries[index].date)) {
        estimatedOffset += 36;
      }
    }
    final offset = estimatedOffset
        .clamp(0, ledgerScrollController.position.maxScrollExtent)
        .toDouble();
    if (animate) {
      await ledgerScrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      ledgerScrollController.jumpTo(offset);
    }
    if (!mounted) return;
    final targetContext = todaySectionKey.currentContext;
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        alignment: 0,
        duration: animate ? const Duration(milliseconds: 180) : Duration.zero,
      );
    }
  }

  Future<void> _returnToToday() async {
    final now = DateTime.now();
    if (month.year != now.year || month.month != now.month) {
      month = DateTime(now.year, now.month);
      await _load();
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _positionToday(animate: false),
      );
      return;
    }
    await _positionToday(animate: true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(['Transactions', 'Search', 'Statistics', 'Settings'][tab]),
      centerTitle: false,
      actions: tab < 3
          ? [
              IconButton(
                onPressed: () async {
                  await showDialog(
                    context: context,
                    builder: (_) => EntryDialog(db: db),
                  );
                  await _refreshData();
                },
                icon: const Icon(Icons.add_circle_outline),
              ),
            ]
          : null,
    ),
    body: SafeArea(
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : _body(),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (value) {
        if (value == tab) {
          if (value == 0) unawaited(_returnToToday());
          return;
        }
        setState(() => tab = value);
        if (value != 1) {
          query = '';
          searchController.clear();
          searchDebounce?.cancel();
        }
        _load();
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.calendar_month_outlined),
          selectedIcon: Icon(Icons.calendar_month),
          label: 'Transactions',
        ),
        NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
        NavigationDestination(
          icon: Icon(Icons.pie_chart_outline),
          selectedIcon: Icon(Icons.pie_chart),
          label: 'Statistics',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: 'Settings',
        ),
      ],
    ),
    floatingActionButton: tab < 2
        ? FloatingActionButton(
            onPressed: () async {
              await showDialog(
                context: context,
                builder: (_) => EntryDialog(db: db),
              );
              await _refreshData();
            },
            child: const Icon(Icons.add),
          )
        : null,
  );

  Widget _body() => switch (tab) {
    0 => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity.abs() < 250) return;
        _moveMonth(velocity < 0 ? 1 : -1);
      },
      child: _listPage(search: false),
    ),
    1 => _listPage(search: true),
    2 => StatsPage(db: db, entries: entries, month: month, onMonth: _moveMonth),
    _ => SettingsPage(
      db: db,
      onChanged: _refreshData,
      themeMode: widget.themeMode,
      onThemeModeChanged: widget.onThemeModeChanged,
    ),
  };

  void _moveMonth(int offset) {
    month = DateTime(month.year, month.month + offset);
    _load();
  }

  Widget _monthHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed: () => _moveMonth(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        Text(
          DateFormat('MMMM yyyy', 'en_US').format(month),
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        IconButton(
          onPressed: () => _moveMonth(1),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );

  Widget _listPage({required bool search}) {
    final income = entries
        .where((e) => e.flow == '수입')
        .fold<int>(0, (a, b) => a + b.amount);
    final expense = entries
        .where((e) => e.flow == '지출')
        .fold<int>(0, (a, b) => a + b.amount);
    final dailyTotals = <String, ({int income, int expense})>{};
    if (!search) {
      for (final entry in entries) {
        final key = DateFormat('yyyy-MM-dd').format(entry.date);
        final current = dailyTotals[key] ?? (income: 0, expense: 0);
        dailyTotals[key] = entry.flow == '수입'
            ? (income: current.income + entry.amount, expense: current.expense)
            : (income: current.income, expense: current.expense + entry.amount);
      }
    }
    return Column(
      children: [
        if (search)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SearchBar(
              controller: searchController,
              focusNode: searchFocusNode,
              hintText: '제목·업체·메모·자산·종류 검색',
              leading: const Icon(Icons.search),
              trailing: [
                if (query.isNotEmpty)
                  IconButton(
                    tooltip: '검색어 지우기',
                    onPressed: () {
                      searchController.clear();
                      setState(() => query = '');
                      _load(showLoading: false);
                      searchFocusNode.requestFocus();
                    },
                    icon: const Icon(Icons.close),
                  ),
                Badge(
                  isLabelVisible: _searchFilterCount > 0,
                  label: Text('$_searchFilterCount'),
                  child: IconButton(
                    tooltip: '검색 필터',
                    onPressed: _showSearchFilters,
                    icon: const Icon(Icons.tune),
                  ),
                ),
              ],
              onChanged: (v) {
                query = v;
                searchDebounce?.cancel();
                searchDebounce = Timer(
                  const Duration(milliseconds: 250),
                  () => _load(showLoading: false),
                );
              },
            ),
          )
        else
          _monthHeader(),
        if (search)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                Text(
                  '검색 결과 ${entries.length}건',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (query.isNotEmpty || _searchFilterCount > 0)
                  TextButton.icon(
                    onPressed: _clearSearch,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('전체 초기화'),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(child: _summary('Income', income, Colors.blue)),
              const SizedBox(width: 10),
              Expanded(child: _summary('Expenses', expense, Colors.red)),
              const SizedBox(width: 10),
              Expanded(
                child: _summary('Balance', income - expense, Colors.teal),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.receipt_long_outlined, size: 48),
                      const SizedBox(height: 12),
                      const Text('No transactions to display.'),
                      if (!search) ...[
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () async {
                            await showDialog(
                              context: context,
                              builder: (_) => EntryDialog(db: db),
                            );
                            await _refreshData();
                          },
                          icon: const Icon(Icons.add),
                          label: const Text('Add first transaction'),
                        ),
                      ],
                    ],
                  ),
                )
              : ListView.separated(
                  controller: search ? null : ledgerScrollController,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    final showDayHeader =
                        !search &&
                        (i == 0 || !_sameDay(entries[i - 1].date, e.date));
                    final isInitialTarget =
                        !search &&
                        showDayHeader &&
                        (_sameDay(e.date, DateTime.now()) ||
                            (!entries.any(
                                  (entry) =>
                                      _sameDay(entry.date, DateTime.now()),
                                ) &&
                                !e.date.isAfter(DateTime.now()) &&
                                (i == 0 ||
                                    entries[i - 1].date.isAfter(
                                      DateTime.now(),
                                    ))));
                    return Column(
                      key: isInitialTarget ? todaySectionKey : null,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showDayHeader)
                          _dayHeader(
                            e.date,
                            dailyTotals[DateFormat('yyyy-MM-dd')
                                .format(e.date)]!,
                          ),
                        Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Text(
                                _displayOption(e.category).characters.first,
                              ),
                            ),
                            title: Text(
                              e.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              search
                                  ? '${DateFormat('MMM d', 'en_US').format(e.date)} · ${_displayOption(e.asset)} · ${e.merchant}'
                                  : '${_displayOption(e.asset)} · ${e.merchant}',
                            ),
                            trailing: Text(
                              '${e.flow == '지출' ? '-' : '+'}${NumberFormat('#,###').format(e.amount)} KRW',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: e.flow == '지출'
                                    ? Colors.red
                                    : Colors.blue,
                              ),
                            ),
                            onTap: () async {
                              await showDialog(
                                context: context,
                                builder: (_) => EntryDialog(db: db, entry: e),
                              );
                              await _refreshData();
                            },
                            onLongPress: () => _deleteEntry(e),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _dayHeader(DateTime date, ({int income, int expense}) totals) {
    final income = totals.income;
    final expense = totals.expense;
    final isToday = _sameDay(date, DateTime.now());
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Container(
        padding: isToday
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
            : EdgeInsets.zero,
        decoration: isToday
            ? BoxDecoration(
                color: colors.primaryContainer,
                border: Border.all(color: colors.primary, width: 1.5),
                borderRadius: BorderRadius.circular(12),
              )
            : null,
        child: Row(
          children: [
            if (isToday) ...[
              Icon(Icons.today, size: 18, color: colors.primary),
              const SizedBox(width: 7),
            ],
            Flexible(
              child: Text(
                '${isToday ? 'Today · ' : ''}${DateFormat('EEEE, MMM d', 'en_US').format(date)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isToday ? colors.onPrimaryContainer : null,
                ),
              ),
            ),
            const Spacer(),
            if (income > 0)
              Text(
                '+${NumberFormat('#,###').format(income)}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Colors.blue),
              ),
            if (income > 0 && expense > 0) const SizedBox(width: 8),
            if (expense > 0)
              Text(
                '-${NumberFormat('#,###').format(expense)}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Colors.red),
              ),
          ],
        ),
      ),
    );
  }

  static bool _sameDay(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;

  int get _searchFilterCount => [
    searchAsset.isNotEmpty,
    searchCategory.isNotEmpty,
    searchFlow.isNotEmpty,
    searchStartDate != null,
    searchEndDate != null,
    searchMinimumAmount != null,
    searchMaximumAmount != null,
    searchOrder != 'newest',
  ].where((active) => active).length;

  void _clearSearch() {
    searchDebounce?.cancel();
    searchController.clear();
    setState(() {
      query = '';
      searchAsset = '';
      searchCategory = '';
      searchFlow = '';
      searchStartDate = null;
      searchEndDate = null;
      searchMinimumAmount = null;
      searchMaximumAmount = null;
      searchOrder = 'newest';
    });
    _load(showLoading: false);
  }

  Future<void> _deleteEntry(TransactionEntry entry) async {
    final isInstallment =
        entry.planType == 'installment' &&
        entry.planId != null &&
        entry.installmentNo != null;
    final isRecurring =
        entry.planType.startsWith('recurring') && entry.planId != null;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('거래 삭제'),
        content: Text('${entry.title} 거래의 삭제 범위를 선택하세요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'single'),
            child: const Text('이 거래만'),
          ),
          if (isInstallment)
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'remaining'),
              child: const Text('이후 할부 전체'),
            ),
          if (isRecurring)
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'plan'),
              child: const Text('정기결제 전체'),
            ),
        ],
      ),
    );
    if (action == null) return;
    if (action == 'remaining') {
      await db.deleteInstallmentsFrom(entry.planId!, entry.installmentNo!);
    } else if (action == 'plan') {
      await db.deleteRecurringPlan(entry.planId!);
    } else {
      await db.delete(entry.id!);
    }
    await _refreshData();
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${entry.title} 삭제 완료'),
        action: action == 'single'
            ? SnackBarAction(
                label: '실행 취소',
                onPressed: () async {
                  await db.restoreDeletedEntry(entry);
                  await _refreshData();
                },
              )
            : null,
      ),
    );
  }

  Future<void> _showSearchFilters() async {
    var selectedAsset = searchAsset;
    var selectedCategory = searchCategory;
    var selectedFlow = searchFlow;
    var selectedStartDate = searchStartDate;
    var selectedEndDate = searchEndDate;
    var selectedOrder = searchOrder;
    final minimumController = TextEditingController(
      text: searchMinimumAmount == null
          ? ''
          : NumberFormat('#,###').format(searchMinimumAmount),
    );
    final maximumController = TextEditingController(
      text: searchMaximumAmount == null
          ? ''
          : NumberFormat('#,###').format(searchMaximumAmount),
    );
    final apply = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('검색 필터', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    initialValue: selectedFlow,
                    decoration: const InputDecoration(labelText: '수입/지출'),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('전체')),
                      DropdownMenuItem(value: '수입', child: Text('수입')),
                      DropdownMenuItem(value: '지출', child: Text('지출')),
                    ],
                    onChanged: (value) =>
                        setSheetState(() => selectedFlow = value ?? ''),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedAsset,
                    decoration: const InputDecoration(labelText: '자산'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('전체')),
                      ...assets.map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      ),
                    ],
                    onChanged: (value) =>
                        setSheetState(() => selectedAsset = value ?? ''),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedCategory,
                    decoration: const InputDecoration(labelText: '종류'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('전체')),
                      ...categories.map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      ),
                    ],
                    onChanged: (value) =>
                        setSheetState(() => selectedCategory = value ?? ''),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final value = await showDatePicker(
                              context: context,
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                              initialDate: selectedStartDate ?? DateTime.now(),
                            );
                            if (value != null) {
                              setSheetState(() {
                                selectedStartDate = value;
                                if (selectedEndDate != null &&
                                    selectedEndDate!.isBefore(value)) {
                                  selectedEndDate = null;
                                }
                              });
                            }
                          },
                          icon: const Icon(Icons.date_range),
                          label: Text(
                            selectedStartDate == null
                                ? '시작일'
                                : DateFormat('yyyy-MM-dd')
                                      .format(selectedStartDate!),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final value = await showDatePicker(
                              context: context,
                              firstDate: selectedStartDate ?? DateTime(2000),
                              lastDate: DateTime(2100),
                              initialDate:
                                  selectedEndDate ??
                                  selectedStartDate ??
                                  DateTime.now(),
                            );
                            if (value != null) {
                              setSheetState(() => selectedEndDate = value);
                            }
                          },
                          icon: const Icon(Icons.event),
                          label: Text(
                            selectedEndDate == null
                                ? '종료일'
                                : DateFormat('yyyy-MM-dd')
                                      .format(selectedEndDate!),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: minimumController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [ThousandsSeparatorInputFormatter()],
                          decoration: const InputDecoration(labelText: '최소 금액'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: maximumController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [ThousandsSeparatorInputFormatter()],
                          decoration: const InputDecoration(labelText: '최대 금액'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedOrder,
                    decoration: const InputDecoration(labelText: '정렬'),
                    items: const [
                      DropdownMenuItem(value: 'newest', child: Text('최신순')),
                      DropdownMenuItem(value: 'oldest', child: Text('오래된순')),
                      DropdownMenuItem(
                        value: 'amountHigh',
                        child: Text('금액 높은순'),
                      ),
                      DropdownMenuItem(
                        value: 'amountLow',
                        child: Text('금액 낮은순'),
                      ),
                    ],
                    onChanged: (value) =>
                        setSheetState(() => selectedOrder = value ?? 'newest'),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => setSheetState(() {
                          selectedAsset = '';
                          selectedCategory = '';
                          selectedFlow = '';
                          selectedStartDate = null;
                          selectedEndDate = null;
                          selectedOrder = 'newest';
                          minimumController.clear();
                          maximumController.clear();
                        }),
                        child: const Text('초기화'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.pop(sheetContext, true),
                        child: const Text('적용'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final minimum = int.tryParse(minimumController.text.replaceAll(',', ''));
    final maximum = int.tryParse(maximumController.text.replaceAll(',', ''));
    minimumController.dispose();
    maximumController.dispose();
    if (apply != true || !mounted) return;
    setState(() {
      searchAsset = selectedAsset;
      searchCategory = selectedCategory;
      searchFlow = selectedFlow;
      searchStartDate = selectedStartDate;
      searchEndDate = selectedEndDate;
      searchMinimumAmount = minimum;
      searchMaximumAmount = maximum;
      searchOrder = selectedOrder;
    });
    await _load();
  }

  Widget _summary(String label, int value, Color color) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          FittedBox(
            child: Text(
              NumberFormat('#,###').format(value),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    ),
  );
}

class EntryDialog extends StatefulWidget {
  const EntryDialog({super.key, required this.db, this.entry});
  final AppDatabase db;
  final TransactionEntry? entry;
  @override
  State<EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<EntryDialog> {
  final form = GlobalKey<FormState>();
  late final TextEditingController title;
  late final TextEditingController merchant;
  late final TextEditingController amount;
  late final TextEditingController note;
  late final TextEditingController installmentCount;
  late DateTime date;
  late String flow;
  late String asset;
  late String category;
  var assets = <String>['카드', '현금'];
  var categories = <String>['식비'];
  var type = 'normal';
  var recurringActive = false;
  var duplicating = false;

  bool get isEditing => widget.entry != null && !duplicating;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    title = TextEditingController(text: entry?.title ?? '');
    merchant = TextEditingController(text: entry?.merchant ?? '');
    amount = TextEditingController(
      text: entry == null ? '' : NumberFormat('#,###').format(entry.amount),
    );
    note = TextEditingController(text: entry?.note ?? '');
    installmentCount = TextEditingController(text: '2');
    date = entry?.date ?? DateTime.now();
    flow = entry?.flow ?? '지출';
    asset = entry?.asset ?? '카드';
    category = entry?.category ?? '식비';
    assets = {asset, '카드', '현금'}.toList();
    categories = {category, flow == '수입' ? '월급' : '식비'}.toList();
    _loadOptions();
    _loadRecurringStatus();
  }

  Future<void> _loadRecurringStatus() async {
    final active = await widget.db.isRecurringActive(widget.entry?.planId);
    if (mounted) setState(() => recurringActive = active);
  }

  Future<void> _loadOptions() async {
    final loadedAssets = await widget.db.optionNames('asset');
    final loadedCategories = await widget.db.optionNames(
      'category',
      flow: flow,
    );
    if (!mounted) return;
    setState(() {
      assets = {...loadedAssets, asset}.toList();
      categories = {...loadedCategories, category}.toList();
    });
  }

  Future<void> _changeFlow(String value) async {
    final loaded = await widget.db.optionNames('category', flow: value);
    if (!mounted) return;
    setState(() {
      flow = value;
      categories = loaded.isEmpty ? [value == '수입' ? '월급' : '식비'] : loaded;
      if (!categories.contains(category)) category = categories.first;
    });
  }

  @override
  void dispose() {
    title.dispose();
    merchant.dispose();
    amount.dispose();
    note.dispose();
    installmentCount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(isEditing ? '거래 수정' : '거래 입력'),
    content: SizedBox(
      width: 460,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: '지출', label: Text('지출')),
                  ButtonSegment(value: '수입', label: Text('수입')),
                ],
                selected: {flow},
                onSelectionChanged: (v) => _changeFlow(v.first),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(DateFormat('yyyy-MM-dd').format(date)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final value = await showDatePicker(
                    context: context,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                    initialDate: date,
                  );
                  if (value != null) setState(() => date = value);
                },
              ),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField(
                      initialValue: asset,
                      decoration: const InputDecoration(labelText: '자산'),
                      items: assets
                          .map(
                            (v) => DropdownMenuItem(value: v, child: Text(v)),
                          )
                          .toList(),
                      onChanged: (v) => asset = v!,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('$flow-$category'),
                      initialValue: category,
                      decoration: const InputDecoration(labelText: '종류'),
                      items: categories
                          .map(
                            (v) => DropdownMenuItem(value: v, child: Text(v)),
                          )
                          .toList(),
                      onChanged: (v) => category = v!,
                    ),
                  ),
                ],
              ),
              _autocomplete('제목', title, 'title'),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: amount,
                    keyboardType: TextInputType.number,
                    inputFormatters: [ThousandsSeparatorInputFormatter()],
                    decoration: const InputDecoration(labelText: '가격(KRW)'),
                    validator: (v) =>
                        int.tryParse((v ?? '').replaceAll(',', '')) == null
                        ? '숫자를 입력하세요.'
                        : null,
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: amount,
                    builder: (context, value, _) => Padding(
                      padding: const EdgeInsets.only(top: 4, left: 12),
                      child: Text(
                        koreanWonTextFromInput(value.text),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              _autocomplete('업체', merchant, 'merchant'),
              TextFormField(
                controller: note,
                decoration: const InputDecoration(labelText: '기타 메모'),
              ),
              if (!isEditing) ...[
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  key: ValueKey(type == 'installment'),
                  initialValue: type == 'installment'
                      ? 'installment'
                      : 'normal',
                  decoration: const InputDecoration(labelText: '결제 방식'),
                  items: const [
                    DropdownMenuItem(value: 'normal', child: Text('일반')),
                    DropdownMenuItem(value: 'installment', child: Text('할부')),
                  ],
                  onChanged: (v) => setState(() => type = v!),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('정기결제'),
                  subtitle: const Text('해지할 때까지 시작일부터 매달 자동으로 추가합니다.'),
                  value: type == 'recurring',
                  onChanged: (enabled) =>
                      setState(() => type = enabled ? 'recurring' : 'normal'),
                ),
                if (type == 'installment')
                  TextFormField(
                    controller: installmentCount,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(2),
                    ],
                    decoration: const InputDecoration(
                      labelText: '할부 개월',
                      suffixText: '개월',
                    ),
                    validator: (value) {
                      final count = int.tryParse(value ?? '');
                      return count == null || count < 2
                          ? '2~99 사이의 숫자를 입력하세요.'
                          : null;
                    },
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
    actions: [
      if (isEditing)
        TextButton.icon(
          onPressed: _prepareDuplicate,
          icon: const Icon(Icons.copy_outlined),
          label: const Text('복사해서 새 거래'),
        ),
      if (isEditing && widget.entry?.planType == 'recurring' && recurringActive)
        TextButton(onPressed: _cancelRecurring, child: const Text('정기결제 해지')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(onPressed: _save, child: const Text('저장')),
    ],
  );

  Widget _autocomplete(
    String label,
    TextEditingController controller,
    String field,
  ) => Autocomplete<String>(
    initialValue: controller.value,
    optionsBuilder: (value) async => widget.db.suggestions(field, value.text),
    onSelected: (value) {
      controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    },
    fieldViewBuilder: (_, inner, focus, submit) {
      return TextFormField(
        controller: inner,
        focusNode: focus,
        onChanged: (value) {
          controller.value = TextEditingValue(
            text: value,
            selection: TextSelection.collapsed(offset: value.length),
          );
        },
        decoration: InputDecoration(labelText: label),
        validator: label == '제목'
            ? (v) => (v ?? '').trim().isEmpty ? '제목을 입력하세요.' : null
            : null,
      );
    },
  );

  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    final entry = TransactionEntry(
      id: isEditing ? widget.entry?.id : null,
      date: date,
      asset: asset,
      category: category,
      title: title.text.trim(),
      amount: int.parse(amount.text.replaceAll(',', '')),
      flow: flow,
      merchant: merchant.text.trim(),
      note: note.text.trim(),
      planType: isEditing ? widget.entry!.planType : 'normal',
      planId: isEditing ? widget.entry?.planId : null,
      installmentNo: isEditing ? widget.entry?.installmentNo : null,
      installmentTotal: isEditing ? widget.entry?.installmentTotal : null,
    );
    if (isEditing) {
      if (widget.entry?.planType == 'installment' &&
          widget.entry?.planId != null) {
        final scope = await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('할부 수정 범위'),
            content: const Text('변경 내용을 어디까지 적용할까요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('취소'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'single'),
                child: const Text('이 회차만'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, 'remaining'),
                child: const Text('이후 할부 전체'),
              ),
            ],
          ),
        );
        if (scope == null) return;
        if (scope == 'remaining') {
          await widget.db.updateInstallmentsFrom(entry);
        } else {
          await widget.db.save(entry);
        }
      } else if (widget.entry?.planType == 'recurring' && recurringActive) {
        final scope = await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('정기결제 수정 범위'),
            content: const Text('변경 내용을 어디까지 적용할까요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('취소'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'single'),
                child: const Text('이 거래만'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, 'future'),
                child: const Text('이후 전체'),
              ),
            ],
          ),
        );
        if (scope == null) return;
        if (scope == 'future') {
          await widget.db.updateRecurringFrom(entry, widget.entry!.date);
        } else {
          await widget.db.save(entry);
        }
      } else {
        await widget.db.save(entry);
      }
    } else if (type == 'installment') {
      await widget.db.addInstallments(entry, int.parse(installmentCount.text));
    } else if (type == 'recurring') {
      await widget.db.addRecurring(entry);
    } else {
      await widget.db.save(entry);
    }
    if (mounted) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.pop(context, true);
      messenger?.showSnackBar(
        SnackBar(content: Text(duplicating ? '새 거래를 저장했습니다.' : '거래를 저장했습니다.')),
      );
    }
  }

  void _prepareDuplicate() {
    setState(() {
      duplicating = true;
      date = DateTime.now();
      type = 'normal';
      installmentCount.text = '2';
    });
  }

  Future<void> _cancelRecurring() async {
    final planId = widget.entry?.planId;
    if (planId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('정기결제 해지'),
        content: Text(
          '${DateFormat('yyyy년 M월', 'ko').format(date)} 결제를 마지막으로 '
          '정기결제를 해지할까요?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('해지'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.db.cancelRecurring(planId, date);
    if (mounted) Navigator.pop(context);
  }
}

class MonthlyBudgetDialog extends StatefulWidget {
  const MonthlyBudgetDialog({super.key, required this.db, required this.month});

  final AppDatabase db;
  final DateTime month;

  @override
  State<MonthlyBudgetDialog> createState() => _MonthlyBudgetDialogState();
}

class _MonthlyBudgetDialogState extends State<MonthlyBudgetDialog> {
  final amount = TextEditingController();
  final totalAmount = TextEditingController();
  var categories = <String>[];
  var budgets = <String, int>{};
  String? selectedCategory;
  var loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    amount.dispose();
    totalAmount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      widget.db.optionNames('category', flow: '지출'),
      widget.db.monthlyBudgets(widget.month),
      widget.db.monthlyTotalBudget(widget.month),
    ]);
    if (!mounted) return;
    final loadedCategories = results[0] as List<String>;
    setState(() {
      categories = loadedCategories;
      budgets = results[1] as Map<String, int>;
      final total = results[2] as int?;
      totalAmount.text = total == null
          ? ''
          : NumberFormat('#,###').format(total);
      selectedCategory ??= categories.firstOrNull;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${DateFormat('yyyy년 M월').format(widget.month)} 예산'),
    content: SizedBox(
      width: 480,
      height: 430,
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: totalAmount,
                        keyboardType: TextInputType.number,
                        inputFormatters: [ThousandsSeparatorInputFormatter()],
                        decoration: const InputDecoration(labelText: '전체 월 예산'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saveTotal,
                      child: const Text('저장'),
                    ),
                    IconButton(
                      tooltip: '전체 예산 삭제',
                      onPressed: _deleteTotal,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedCategory,
                  decoration: const InputDecoration(labelText: '종류'),
                  items: categories
                      .map(
                        (category) => DropdownMenuItem(
                          value: category,
                          child: Text(category),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => selectedCategory = value,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: amount,
                        keyboardType: TextInputType.number,
                        inputFormatters: [ThousandsSeparatorInputFormatter()],
                        decoration: const InputDecoration(labelText: '예산 금액'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _save, child: const Text('저장')),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _copyPreviousMonth,
                    icon: const Icon(Icons.content_copy_outlined),
                    label: const Text('지난달 예산 가져오기'),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                Expanded(
                  child: budgets.isEmpty
                      ? const Center(child: Text('설정된 예산이 없습니다.'))
                      : ListView.builder(
                          itemCount: budgets.length,
                          itemBuilder: (_, index) {
                            final budget = budgets.entries.elementAt(index);
                            return ListTile(
                              title: Text(budget.key),
                              onTap: () {
                                setState(() {
                                  selectedCategory = budget.key;
                                  amount.text = NumberFormat('#,###')
                                      .format(budget.value);
                                });
                              },
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${NumberFormat('#,###').format(budget.value)}원',
                                  ),
                                  IconButton(
                                    tooltip: '예산 삭제',
                                    onPressed: () => _delete(budget.key),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('닫기'),
      ),
    ],
  );

  Future<void> _save() async {
    final value = int.tryParse(amount.text.replaceAll(',', ''));
    if (selectedCategory == null || value == null || value <= 0) return;
    await widget.db.saveMonthlyBudget(widget.month, selectedCategory!, value);
    amount.clear();
    await _load();
  }

  Future<void> _delete(String category) async {
    await widget.db.deleteMonthlyBudget(widget.month, category);
    await _load();
  }

  Future<void> _saveTotal() async {
    final value = int.tryParse(totalAmount.text.replaceAll(',', ''));
    if (value == null || value <= 0) return;
    await widget.db.saveMonthlyTotalBudget(widget.month, value);
    await _load();
  }

  Future<void> _deleteTotal() async {
    await widget.db.deleteMonthlyTotalBudget(widget.month);
    totalAmount.clear();
    await _load();
  }

  Future<void> _copyPreviousMonth() async {
    final previous = DateTime(widget.month.year, widget.month.month - 1);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('지난달 예산 가져오기'),
        content: Text(
          '${DateFormat('yyyy년 M월').format(previous)} 예산을 가져옵니다.\n'
          '같은 종류의 현재 예산은 지난달 금액으로 덮어씁니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('가져오기'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final count = await widget.db.copyPreviousMonthBudgets(widget.month);
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 0 ? '지난달에 설정된 예산이 없습니다.' : '지난달 예산 $count건을 가져왔습니다.',
        ),
      ),
    );
  }
}

class StatsPage extends StatefulWidget {
  const StatsPage({
    super.key,
    required this.db,
    required this.entries,
    required this.month,
    required this.onMonth,
  });
  final AppDatabase db;
  final List<TransactionEntry> entries;
  final DateTime month;
  final ValueChanged<int> onMonth;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  late int year;
  late Future<List<TransactionEntry>> annualEntries;
  late Future<List<TransactionEntry>> previousMonthEntries;
  late Future<Map<String, int>> budgets;
  late Future<int?> totalBudget;
  late Future<int?> previousTotalBudget;
  late Future<({int installment, int recurring})> plannedAmounts;

  @override
  void initState() {
    super.initState();
    year = widget.month.year;
    annualEntries = widget.db.listYear(year);
    previousMonthEntries = _loadPreviousMonth();
    budgets = widget.db.monthlyBudgets(widget.month);
    totalBudget = widget.db.monthlyTotalBudget(widget.month);
    previousTotalBudget = widget.db.monthlyTotalBudget(
      DateTime(widget.month.year, widget.month.month - 1),
    );
    plannedAmounts = widget.db.plannedAmounts(widget.month);
  }

  @override
  void didUpdateWidget(covariant StatsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.month.year != widget.month.year ||
        oldWidget.month.month != widget.month.month) {
      previousMonthEntries = _loadPreviousMonth();
      budgets = widget.db.monthlyBudgets(widget.month);
      totalBudget = widget.db.monthlyTotalBudget(widget.month);
      previousTotalBudget = widget.db.monthlyTotalBudget(
        DateTime(widget.month.year, widget.month.month - 1),
      );
      plannedAmounts = widget.db.plannedAmounts(widget.month);
    }
  }

  Future<List<TransactionEntry>> _loadPreviousMonth() => widget.db.list(
    month: DateTime(widget.month.year, widget.month.month - 1),
  );

  void _moveYear(int offset) {
    setState(() {
      year += offset;
      annualEntries = widget.db.listYear(year);
    });
  }

  @override
  Widget build(BuildContext context) {
    final categories = <String, int>{};
    for (final e in widget.entries.where((e) => e.flow == '지출')) {
      categories.update(
        e.category,
        (v) => v + e.amount,
        ifAbsent: () => e.amount,
      );
    }
    final categoryItems = categories.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = categories.values.fold<int>(0, (a, b) => a + b);
    final currentIncome = widget.entries
        .where((entry) => entry.flow == '수입')
        .fold<int>(0, (sum, entry) => sum + entry.amount);
    final currentExpense = widget.entries
        .where((entry) => entry.flow == '지출')
        .fold<int>(0, (sum, entry) => sum + entry.amount);
    final assetIncome = <String, int>{};
    final assetExpense = <String, int>{};
    for (final entry in widget.entries) {
      final target = entry.flow == '수입' ? assetIncome : assetExpense;
      target.update(
        entry.asset,
        (value) => value + entry.amount,
        ifAbsent: () => entry.amount,
      );
    }
    final assetNames = {...assetIncome.keys, ...assetExpense.keys}.toList()
      ..sort(
        (first, second) =>
            ((assetIncome[second] ?? 0) + (assetExpense[second] ?? 0))
                .compareTo(
                  (assetIncome[first] ?? 0) + (assetExpense[first] ?? 0),
                ),
      );
    final colors = [
      Colors.blue,
      Colors.orange,
      Colors.teal,
      Colors.purple,
      Colors.red,
      Colors.green,
      Colors.amber,
      Colors.indigo,
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: () => widget.onMonth(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              DateFormat('MMMM yyyy', 'en_US').format(widget.month),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            IconButton(
              onPressed: () => widget.onMonth(1),
              icon: const Icon(Icons.chevron_right),
            ),
            IconButton(
              tooltip: 'Monthly budget',
              onPressed: _manageBudgets,
              icon: const Icon(Icons.account_balance_wallet_outlined),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _showPeriodStats,
            icon: const Icon(Icons.date_range_outlined),
            label: const Text('Custom date range'),
          ),
        ),
        FutureBuilder<List<TransactionEntry>>(
          future: previousMonthEntries,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const SizedBox(
                height: 84,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final previousIncome = snapshot.data!
                .where((entry) => entry.flow == '수입')
                .fold<int>(0, (sum, entry) => sum + entry.amount);
            final previousExpense = snapshot.data!
                .where((entry) => entry.flow == '지출')
                .fold<int>(0, (sum, entry) => sum + entry.amount);
            return Row(
              children: [
                Expanded(
                  child: _comparisonCard(
                    'Income',
                    currentIncome,
                    previousIncome,
                    Colors.blue,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _comparisonCard(
                    'Expenses',
                    currentExpense,
                    previousExpense,
                    Colors.red,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        FutureBuilder<({int installment, int recurring})>(
          future: plannedAmounts,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const SizedBox.shrink();
            return _plannedAmountCard(snapshot.data!);
          },
        ),
        if (assetNames.isNotEmpty) ...[
          const SizedBox(height: 12),
          _assetSection(assetNames, assetIncome, assetExpense),
        ],
        const SizedBox(height: 20),
        SizedBox(
          height: 260,
          child: total == 0
              ? const Center(child: Text('No expense data for this month.'))
              : PieChart(
                  PieChartData(
                    centerSpaceRadius: 52,
                    sectionsSpace: 2,
                    sections: categoryItems.asMap().entries.map((item) {
                      final i = item.key;
                      final e = item.value;
                      return PieChartSectionData(
                        value: e.value.toDouble(),
                        title: '${(e.value / total * 100).round()}%',
                        color: colors[i % colors.length],
                        radius: 75,
                        titleStyle: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      );
                    }).toList(),
                  ),
                ),
        ),
        const SizedBox(height: 20),
        ...categoryItems.asMap().entries.map(
          (item) => ListTile(
            leading: CircleAvatar(
              radius: 7,
              backgroundColor: colors[item.key % colors.length],
            ),
            title: Text(_displayOption(item.value.key)),
            trailing: Text(
              '${NumberFormat('#,###').format(item.value.value)} KRW',
            ),
            onTap: () => _showCategoryDetails(item.value.key),
          ),
        ),
        FutureBuilder<Map<String, int>>(
          future: budgets,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const SizedBox.shrink();
            return FutureBuilder<List<Object?>>(
              future: Future.wait<Object?>([
                totalBudget,
                previousTotalBudget,
                previousMonthEntries,
              ]),
              builder: (context, totals) {
                if (!totals.hasData) return const SizedBox.shrink();
                final previousEntries =
                    totals.data![2] as List<TransactionEntry>;
                final previousExpense = previousEntries
                    .where((entry) => entry.flow == '지출')
                    .fold<int>(0, (sum, entry) => sum + entry.amount);
                if (snapshot.data!.isEmpty && totals.data![0] == null) {
                  return const SizedBox.shrink();
                }
                return _budgetSection(
                  snapshot.data!,
                  categories,
                  totals.data![0] as int?,
                  totals.data![1] as int?,
                  currentExpense,
                  previousExpense,
                );
              },
            );
          },
        ),
        const SizedBox(height: 28),
        const Divider(),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: () => _moveYear(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              '$year Monthly Trend',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            IconButton(
              onPressed: () => _moveYear(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FutureBuilder<List<TransactionEntry>>(
          future: annualEntries,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const SizedBox(
                height: 260,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _annualChart(snapshot.data!);
          },
        ),
      ],
    );
  }

  Widget _plannedAmountCard(({int installment, int recurring}) amounts) {
    final total = amounts.installment + amounts.recurring;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.event_repeat_outlined),
                const SizedBox(width: 10),
                Text(
                  'Planned Fixed Expenses',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  '${NumberFormat('#,###').format(total)} KRW',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: Text('Installments')),
                Text(
                  '${NumberFormat('#,###').format(amounts.installment)} KRW',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Expanded(child: Text('Recurring')),
                Text('${NumberFormat('#,###').format(amounts.recurring)} KRW'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _assetSection(
    List<String> names,
    Map<String, int> income,
    Map<String, int> expense,
  ) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_outlined),
              const SizedBox(width: 10),
              Text(
                'Cash Flow by Account',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...names.map((name) {
            final incoming = income[name] ?? 0;
            final outgoing = expense[name] ?? 0;
            final net = incoming - outgoing;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      _displayOption(name),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      '+${NumberFormat('#,###').format(incoming)}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.blue),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      '-${NumberFormat('#,###').format(outgoing)}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      '${net >= 0 ? '+' : ''}${NumberFormat('#,###').format(net)}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: net >= 0 ? Colors.teal : Colors.red,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          const Divider(),
          const Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text('Income', style: TextStyle(color: Colors.blue)),
              SizedBox(width: 18),
              Text('Expenses', style: TextStyle(color: Colors.red)),
              SizedBox(width: 18),
              Text('Net'),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _budgetSection(
    Map<String, int> configured,
    Map<String, int> spending,
    int? totalBudget,
    int? previousBudget,
    int currentExpense,
    int previousExpense,
  ) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('월 예산', style: Theme.of(context).textTheme.titleMedium),
          if (totalBudget != null) ...[
            const SizedBox(height: 12),
            _totalBudgetProgress(
              totalBudget,
              previousBudget,
              currentExpense,
              previousExpense,
            ),
            if (configured.isNotEmpty) const Divider(height: 28),
          ],
          const SizedBox(height: 12),
          ...configured.entries.map((budget) {
            final spent = spending[budget.key] ?? 0;
            final ratio = spent / budget.value;
            final difference = budget.value - spent;
            final exceeded = difference < 0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(budget.key)),
                      Text(
                        '${NumberFormat('#,###').format(spent)} / '
                        '${NumberFormat('#,###').format(budget.value)}원',
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: ratio.clamp(0, 1),
                    color: exceeded ? Colors.red : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    exceeded
                        ? '${NumberFormat('#,###').format(-difference)}원 초과'
                        : '${NumberFormat('#,###').format(difference)}원 남음',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: exceeded ? Colors.red : null),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    ),
  );

  Widget _totalBudgetProgress(
    int budget,
    int? previousBudget,
    int spent,
    int previousSpent,
  ) {
    final ratio = spent / budget;
    final color = ratio >= 1
        ? Colors.red
        : ratio >= .8
        ? Colors.orange
        : Colors.teal;
    final budgetChange = previousBudget == null || previousBudget == 0
        ? '비교 없음'
        : '${((budget - previousBudget) / previousBudget * 100).toStringAsFixed(1)}%';
    final spendingChange = previousSpent == 0
        ? (spent == 0 ? '0%' : '신규')
        : '${((spent - previousSpent) / previousSpent * 100) >= 0 ? '+' : ''}'
              '${((spent - previousSpent) / previousSpent * 100).toStringAsFixed(1)}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${NumberFormat('#,###').format(spent)} / '
                '${NumberFormat('#,###').format(budget)}원',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Text(
              '${(ratio * 100).toStringAsFixed(1)}%',
              style: TextStyle(color: color),
            ),
          ],
        ),
        const SizedBox(height: 7),
        LinearProgressIndicator(value: ratio.clamp(0, 1), color: color),
        const SizedBox(height: 7),
        Text(
          ratio >= 1
              ? '${NumberFormat('#,###').format(spent - budget)}원 초과'
              : ratio >= .8
              ? '예산의 80% 이상을 사용했습니다.'
              : '${NumberFormat('#,###').format(budget - spent)}원 남음',
          style: TextStyle(color: color),
        ),
        Text(
          '전월 대비 예산 $budgetChange · 지출 $spendingChange',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Future<void> _manageBudgets() async {
    await showDialog<void>(
      context: context,
      builder: (_) => MonthlyBudgetDialog(db: widget.db, month: widget.month),
    );
    if (!mounted) return;
    setState(() {
      budgets = widget.db.monthlyBudgets(widget.month);
      totalBudget = widget.db.monthlyTotalBudget(widget.month);
      previousTotalBudget = widget.db.monthlyTotalBudget(
        DateTime(widget.month.year, widget.month.month - 1),
      );
    });
  }

  Future<void> _showPeriodStats() => showDialog<void>(
    context: context,
    builder: (_) => PeriodStatsDialog(db: widget.db),
  );

  Widget _comparisonCard(String label, int current, int previous, Color color) {
    final change = previous == 0
        ? (current == 0 ? '0%' : 'New')
        : '${((current - previous) / previous * 100) >= 0 ? '+' : ''}'
              '${((current - previous) / previous * 100).toStringAsFixed(1)}%';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: color)),
            const SizedBox(height: 4),
            FittedBox(
              child: Text(
                '${NumberFormat('#,###').format(current)} KRW',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Text(
              'vs. last month: $change',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCategoryDetails(String category) async {
    final items = widget.entries
        .where((entry) => entry.flow == '지출' && entry.category == category)
        .toList();
    final sum = items.fold<int>(0, (value, entry) => value + entry.amount);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$category 상세'),
        content: SizedBox(
          width: 500,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${items.length}건 · ${NumberFormat('#,###').format(sum)}원',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final entry = items[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(entry.title),
                      subtitle: Text(
                        '${DateFormat('M월 d일').format(entry.date)} · ${entry.merchant}',
                      ),
                      trailing: Text(
                        '${NumberFormat('#,###').format(entry.amount)}원',
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Widget _annualChart(List<TransactionEntry> entries) {
    final income = List<int>.filled(12, 0);
    final expense = List<int>.filled(12, 0);
    for (final entry in entries) {
      final values = entry.flow == '수입' ? income : expense;
      values[entry.date.month - 1] += entry.amount;
    }
    final hasData =
        income.any((value) => value > 0) || expense.any((value) => value > 0);
    if (!hasData) {
      return const SizedBox(
        height: 260,
        child: Center(child: Text('연간 통계가 없습니다.')),
      );
    }
    final maxValue = [...income, ...expense].reduce((a, b) => a > b ? a : b);
    return Column(
      children: [
        SizedBox(
          height: 280,
          child: BarChart(
            BarChartData(
              maxY: maxValue * 1.15,
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                      BarTooltipItem(
                        '${group.x + 1}월 ${rodIndex == 0 ? '수입' : '지출'}\n'
                        '${NumberFormat('#,###').format(rod.toY.round())}원',
                        const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                ),
              ),
              alignment: BarChartAlignment.spaceAround,
              gridData: const FlGridData(drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (value, meta) =>
                        Text('${value.toInt() + 1}'),
                  ),
                ),
              ),
              barGroups: List.generate(
                12,
                (index) => BarChartGroupData(
                  x: index,
                  barsSpace: 2,
                  barRods: [
                    BarChartRodData(
                      toY: income[index].toDouble(),
                      width: 6,
                      color: Colors.blue,
                      borderRadius: BorderRadius.zero,
                    ),
                    BarChartRodData(
                      toY: expense[index].toDouble(),
                      width: 6,
                      color: Colors.red,
                      borderRadius: BorderRadius.zero,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.circle, size: 12, color: Colors.blue),
            SizedBox(width: 5),
            Text('수입'),
            SizedBox(width: 18),
            Icon(Icons.circle, size: 12, color: Colors.red),
            SizedBox(width: 5),
            Text('지출'),
          ],
        ),
      ],
    );
  }
}

class PeriodStatsDialog extends StatefulWidget {
  const PeriodStatsDialog({super.key, required this.db});

  final AppDatabase db;

  @override
  State<PeriodStatsDialog> createState() => _PeriodStatsDialogState();
}

class _PeriodStatsDialogState extends State<PeriodStatsDialog> {
  late DateTime start;
  late DateTime end;
  var entries = <TransactionEntry>[];
  var loading = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    start = DateTime(now.year, now.month, 1);
    end = now;
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final result = await widget.db.list(startDate: start, endDate: end);
    if (!mounted) return;
    setState(() {
      entries = result;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final income = entries
        .where((entry) => entry.flow == '수입')
        .fold<int>(0, (sum, entry) => sum + entry.amount);
    final expense = entries
        .where((entry) => entry.flow == '지출')
        .fold<int>(0, (sum, entry) => sum + entry.amount);
    final categories = <String, int>{};
    for (final entry in entries.where((entry) => entry.flow == '지출')) {
      categories.update(
        entry.category,
        (value) => value + entry.amount,
        ifAbsent: () => entry.amount,
      );
    }
    final topCategories = categories.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return AlertDialog(
      title: const Text('기간 직접 분석'),
      content: SizedBox(
        width: 520,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _dateButton(true)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('~'),
                ),
                Expanded(child: _dateButton(false)),
              ],
            ),
            const SizedBox(height: 16),
            if (loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else ...[
              Text(
                '${entries.length}건 · 수입 ${NumberFormat('#,###').format(income)}원 · '
                '지출 ${NumberFormat('#,###').format(expense)}원',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Text(
                '순액 ${NumberFormat('#,###').format(income - expense)}원',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: income - expense >= 0 ? Colors.teal : Colors.red,
                ),
              ),
              const Divider(height: 28),
              Text('지출 상위 종류', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Expanded(
                child: topCategories.isEmpty
                    ? const Center(child: Text('해당 기간의 지출이 없습니다.'))
                    : ListView.builder(
                        itemCount: topCategories.length,
                        itemBuilder: (_, index) {
                          final item = topCategories[index];
                          return ListTile(
                            dense: true,
                            leading: Text('${index + 1}'),
                            title: Text(item.key.isEmpty ? '미지정' : item.key),
                            trailing: Text(
                              '${NumberFormat('#,###').format(item.value)}원',
                            ),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    );
  }

  Widget _dateButton(bool isStart) => OutlinedButton.icon(
    onPressed: () async {
      final current = isStart ? start : end;
      final picked = await showDatePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        initialDate: current,
      );
      if (picked == null) return;
      if (isStart) {
        start = picked;
        if (end.isBefore(start)) end = start;
      } else {
        end = picked;
        if (start.isAfter(end)) start = end;
      }
      await _load();
    },
    icon: const Icon(Icons.calendar_today_outlined),
    label: Text(DateFormat('yyyy-MM-dd').format(isStart ? start : end)),
  );
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.db,
    required this.onChanged,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final AppDatabase db;
  final Future<void> Function() onChanged;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.brightness_6_outlined),
                  SizedBox(width: 12),
                  Text('화면 테마'),
                ],
              ),
              const SizedBox(height: 14),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.settings_brightness),
                    label: Text('시스템'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('라이트'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('다크'),
                  ),
                ],
                selected: {themeMode},
                onSelectionChanged: (selection) =>
                    onThemeModeChanged(selection.first),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('자산 관리'),
              subtitle: const Text('카드, 현금 등 결제 자산을 관리합니다.'),
              onTap: () async {
                await showDialog<void>(
                  context: context,
                  builder: (_) => OptionManagerDialog(db: db, type: 'asset'),
                );
                await onChanged();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.category_outlined),
              title: const Text('지출 종류 관리'),
              subtitle: const Text('지출 거래의 종류를 관리합니다.'),
              onTap: () async {
                await showDialog<void>(
                  context: context,
                  builder: (_) =>
                      OptionManagerDialog(db: db, type: 'category', flow: '지출'),
                );
                await onChanged();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.savings_outlined),
              title: const Text('수입 종류 관리'),
              subtitle: const Text('수입 거래의 종류를 관리합니다.'),
              onTap: () async {
                await showDialog<void>(
                  context: context,
                  builder: (_) =>
                      OptionManagerDialog(db: db, type: 'category', flow: '수입'),
                );
                await onChanged();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.autorenew),
              title: const Text('정기결제 관리'),
              subtitle: const Text('정기결제 상태를 확인하고 해지하거나 재활성화합니다.'),
              onTap: () async {
                await showDialog<void>(
                  context: context,
                  builder: (_) => RecurringManagerDialog(db: db),
                );
                await onChanged();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('XLSX 전체 백업'),
              subtitle: FutureBuilder<List<String?>>(
                future: Future.wait([
                  db.setting('last_backup_at'),
                  db.setting('last_backup_file'),
                ]),
                builder: (_, snapshot) {
                  final values = snapshot.data;
                  return Text(
                    values != null && values[0] != null
                        ? '최근: ${values[0]} · ${values[1] ?? 'XLSX'} · v4'
                        : '백업 기록 없음 · 포맷 v4',
                  );
                },
              ),
              onTap: () => _backup(context),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.restore_page_outlined),
              title: const Text('XLSX로 전체 복원'),
              subtitle: const Text('검증 후 기존 거래를 모두 교체합니다.'),
              onTap: () => _restore(context),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                '가계부 데이터 초기화',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              subtitle: const Text('거래·정기결제·예산·자산·종류를 모두 삭제합니다.'),
              onTap: () => _clearAllData(context),
            ),
          ],
        ),
      ),
    ],
  );

  Future<void> _backup(BuildContext context) async {
    var progressOpen = false;
    try {
      progressOpen = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const PopScope(
            canPop: false,
            child: AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 24),
                  Expanded(child: Text('전체 거래를 XLSX로 만들고 있습니다.')),
                ],
              ),
            ),
          ),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final bundle = await db.backupBundle();
      final bytes = await compute(_exportXlsxInBackground, bundle);
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      progressOpen = false;

      final savedPath = await FilePicker.saveFile(
        dialogTitle: '가계부 백업 저장',
        fileName: '가계부_${DateFormat('yyyyMMdd').format(DateTime.now())}.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        bytes: bytes,
      );
      if (savedPath == null) return;
      await db.saveSetting(
        'last_backup_at',
        DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()),
      );
      await db.saveSetting(
        'last_backup_file',
        savedPath.pathSegments.isEmpty ? 'XLSX' : savedPath.pathSegments.last,
      );
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('백업 완료'),
            content: Text(
              '전체 거래 ${bundle.entries.length}건과 정기결제·월별 예산·설정을 XLSX로 저장했습니다.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('확인'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        if (progressOpen) {
          Navigator.of(context, rootNavigator: true).pop();
          progressOpen = false;
        }
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('백업 실패: $e')));
      }
    }
  }

  Future<void> _restore(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('전체 복원'),
        content: const Text('파일 검증에 성공하면 현재 거래를 모두 지우고 XLSX 내용으로 교체합니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('파일 선택'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    var progressOpen = false;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (files.isEmpty) return;

      if (!context.mounted) return;
      progressOpen = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const PopScope(
            canPop: false,
            child: AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 24),
                  Expanded(child: Text('XLSX 내용을 검증하고 있습니다.')),
                ],
              ),
            ),
          ),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final bytes = await files.single.readAsBytes();
      final bundle = await compute(
        _parseXlsxInBackground,
        Uint8List.fromList(bytes),
      );
      final currentCount = await db.transactionCount();
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      progressOpen = false;

      final replace = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('복원 내용 확인'),
          content: Text(
            '파일: ${files.single.name}\n\n'
            '현재 로컬 거래: $currentCount건\n'
            '복원할 거래: ${bundle.entries.length}건\n'
            '정기결제 계획: ${bundle.recurringPlans.length}건\n'
            '${bundle.formatVersion >= 3 ? '월별 예산: ${bundle.monthlyBudgets.length}건\n' : '월별 예산: 기존 데이터 유지\n'}\n'
            '계속하면 현재 거래를 위 내용으로 교체합니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('교체하고 복원'),
            ),
          ],
        ),
      );
      if (replace != true || !context.mounted) return;

      progressOpen = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const PopScope(
            canPop: false,
            child: AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 24),
                  Expanded(child: Text('로컬 데이터를 교체하고 있습니다.')),
                ],
              ),
            ),
          ),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      final databaseCount = await db.restoreBundle(bundle);
      final restoredTheme = bundle.settings['theme_mode'];
      if (restoredTheme != null) {
        onThemeModeChanged(switch (restoredTheme) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        });
      }
      await onChanged();
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        progressOpen = false;
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('복원 완료'),
            content: Text(
              '기존 거래를 모두 교체했습니다.\n\n'
              '엑셀 전체 거래: ${bundle.entries.length}건\n'
              '현재 로컬 DB 거래: $databaseCount건'
              '${bundle.formatVersion >= 3 ? '\n복원된 월별 예산: ${bundle.monthlyBudgets.length}건' : '\n이전 형식 백업: 기존 월별 예산 유지'}',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('확인'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        if (progressOpen) {
          Navigator.of(context, rootNavigator: true).pop();
          progressOpen = false;
        }
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('복원 실패(기존 데이터 유지): $e')));
      }
    }
  }

  Future<void> _clearAllData(BuildContext context) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('가계부 데이터 초기화'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '모든 거래, 정기결제, 월별 예산과 사용자 자산·종류가 삭제됩니다. '
              '이 작업은 취소할 수 없습니다. 먼저 백업하는 것을 권장합니다.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: '확인을 위해 초기화 입력'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          ListenableBuilder(
            listenable: controller,
            builder: (_, _) => FilledButton(
              onPressed: controller.text.trim() == '초기화'
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('모두 삭제'),
            ),
          ),
        ],
      ),
    );
    controller.dispose();
    if (confirmed != true) return;
    await db.clearLedgerData();
    await onChanged();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('가계부 데이터를 초기화했습니다.')));
  }
}

class RecurringManagerDialog extends StatefulWidget {
  const RecurringManagerDialog({super.key, required this.db});

  final AppDatabase db;

  @override
  State<RecurringManagerDialog> createState() => _RecurringManagerDialogState();
}

class _RecurringManagerDialogState extends State<RecurringManagerDialog> {
  var plans = <RecurringPlan>[];
  var loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await widget.db.recurringPlans();
    if (!mounted) return;
    setState(() {
      plans = result;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('정기결제 관리'),
    content: SizedBox(
      width: 520,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.62,
        ),
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : plans.isEmpty
            ? const Center(child: Text('등록된 정기결제가 없습니다.'))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Chip(
                        label: Text(
                          '활성 ${plans.where((plan) => plan.isActive).length}건',
                        ),
                      ),
                      Chip(
                        label: Text(
                          '해지 ${plans.where((plan) => !plan.isActive).length}건',
                        ),
                      ),
                      Chip(
                        label: Text(
                          '활성 월 합계 ${NumberFormat('#,###').format(plans.where((plan) => plan.isActive).fold<int>(0, (sum, plan) => sum + plan.amount))}원',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: plans.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final plan = plans[index];
                        final status = plan.isActive
                            ? '활성'
                            : '${DateFormat('yyyy년 M월', 'ko').format(plan.endMonth!)} 해지';
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            plan.isActive ? Icons.autorenew : Icons.event_busy,
                            color: plan.isActive
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outline,
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  plan.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${NumberFormat('#,###').format(plan.amount)}원',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            '$status · ${DateFormat('yyyy-MM-dd').format(plan.startDate)} 시작\n'
                            '${plan.asset} · ${plan.category}'
                            '${plan.merchant.isEmpty ? '' : ' · ${plan.merchant}'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: plan.isActive ? '해지' : '재활성화',
                            onPressed: () => plan.isActive
                                ? _cancel(plan)
                                : _reactivate(plan),
                            icon: Icon(
                              plan.isActive
                                  ? Icons.stop_circle_outlined
                                  : Icons.play_circle_outline,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('닫기'),
      ),
    ],
  );

  Future<void> _cancel(RecurringPlan plan) async {
    final now = DateTime.now();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('정기결제 해지'),
        content: Text(
          '${plan.title} 정기결제를 ${DateFormat('yyyy년 M월', 'ko').format(now)}을 '
          '마지막으로 해지할까요?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('해지'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.db.cancelRecurring(plan.planId, now);
    await _load();
  }

  Future<void> _reactivate(RecurringPlan plan) async {
    await widget.db.reactivateRecurring(plan.planId);
    await _load();
  }
}

class OptionManagerDialog extends StatefulWidget {
  const OptionManagerDialog({
    super.key,
    required this.db,
    required this.type,
    this.flow,
  });

  final AppDatabase db;
  final String type;
  final String? flow;

  @override
  State<OptionManagerDialog> createState() => _OptionManagerDialogState();
}

class _OptionManagerDialogState extends State<OptionManagerDialog> {
  final controller = TextEditingController();
  var values = <String>[];
  var loading = true;

  String get label => widget.type == 'asset' ? '자산' : '${widget.flow} 종류';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final result = await widget.db.optionNames(widget.type, flow: widget.flow);
    if (!mounted) return;
    setState(() {
      values = result;
      loading = false;
    });
  }

  Future<void> _add() async {
    final value = controller.text.trim();
    if (value.isEmpty) return;
    await widget.db.addOption(widget.type, value, flow: widget.flow);
    controller.clear();
    await _load();
  }

  Future<void> _delete(String value) async {
    final deleted = await widget.db.deleteOption(
      widget.type,
      value,
      flow: widget.flow,
    );
    if (!mounted) return;
    if (!deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('기존 거래에서 사용하는 $label은 삭제할 수 없습니다.')),
      );
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('$label 관리'),
    content: SizedBox(
      width: 420,
      height: 480,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(labelText: '새 $label'),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _add, icon: const Icon(Icons.add)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    itemCount: values.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) => ListTile(
                      title: Text(values[index]),
                      trailing: IconButton(
                        tooltip: '삭제',
                        onPressed: () => _delete(values[index]),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('완료'),
      ),
    ],
  );
}
