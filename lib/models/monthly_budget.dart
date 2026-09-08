class MonthlyBudget {
  const MonthlyBudget({
    required this.month,
    required this.category,
    required this.amount,
  });

  final String month;
  final String category;
  final int amount;

  factory MonthlyBudget.fromMap(Map<String, Object?> map) => MonthlyBudget(
    month: map['month']! as String,
    category: map['category']! as String,
    amount: map['amount']! as int,
  );

  Map<String, Object?> toMap() => {
    'month': month,
    'category': category,
    'amount': amount,
  };
}
