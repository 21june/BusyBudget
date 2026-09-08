import 'monthly_budget.dart';
import 'recurring_plan.dart';
import 'transaction_entry.dart';

class BackupBundle {
  const BackupBundle({
    required this.entries,
    this.recurringPlans = const [],
    this.assets = const [],
    this.categories = const [],
    this.incomeCategories = const [],
    this.monthlyBudgets = const [],
    this.settings = const {},
    this.formatVersion = 1,
  });

  final List<TransactionEntry> entries;
  final List<RecurringPlan> recurringPlans;
  final List<String> assets;
  final List<String> categories;
  final List<String> incomeCategories;
  final List<MonthlyBudget> monthlyBudgets;
  final Map<String, String> settings;
  final int formatVersion;
}
