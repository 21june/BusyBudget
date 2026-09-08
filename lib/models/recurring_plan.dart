class RecurringPlan {
  const RecurringPlan({
    required this.planId,
    required this.startDate,
    required this.asset,
    required this.category,
    required this.title,
    required this.amount,
    required this.flow,
    required this.merchant,
    required this.note,
    this.endMonth,
  });

  final String planId;
  final DateTime startDate;
  final DateTime? endMonth;
  final String asset;
  final String category;
  final String title;
  final int amount;
  final String flow;
  final String merchant;
  final String note;

  bool get isActive => endMonth == null;

  Map<String, Object?> toMap() => {
    'plan_id': planId,
    'start_date': _dateKey(startDate),
    'end_month': endMonth == null ? null : _dateKey(endMonth!),
    'asset': asset,
    'category': category,
    'title': title,
    'amount': amount,
    'flow': flow,
    'merchant': merchant,
    'note': note,
  };

  factory RecurringPlan.fromMap(Map<String, Object?> map) => RecurringPlan(
    planId: map['plan_id']! as String,
    startDate: DateTime.parse(map['start_date']! as String),
    endMonth: map['end_month'] == null
        ? null
        : DateTime.parse(map['end_month']! as String),
    asset: map['asset']! as String,
    category: map['category']! as String,
    title: map['title']! as String,
    amount: map['amount']! as int,
    flow: map['flow']! as String,
    merchant: map['merchant']! as String,
    note: map['note']! as String,
  );

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}
