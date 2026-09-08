class TransactionEntry {
  const TransactionEntry({
    this.id,
    required this.date,
    required this.asset,
    required this.category,
    required this.title,
    required this.amount,
    required this.flow,
    required this.merchant,
    this.note = '',
    this.planType = 'normal',
    this.planId,
    this.installmentNo,
    this.installmentTotal,
  });

  final int? id;
  final DateTime date;
  final String asset;
  final String category;
  final String title;
  final int amount;
  final String flow;
  final String merchant;
  final String note;
  final String planType;
  final String? planId;
  final int? installmentNo;
  final int? installmentTotal;

  Map<String, Object?> toMap() => {
    'id': id,
    'date': _dateKey(date),
    'asset': asset,
    'category': category,
    'title': title,
    'amount': amount,
    'flow': flow,
    'merchant': merchant,
    'note': note,
    'plan_type': planType,
    'plan_id': planId,
    'installment_no': installmentNo,
    'installment_total': installmentTotal,
  };

  factory TransactionEntry.fromMap(Map<String, Object?> map) =>
      TransactionEntry(
        id: map['id'] as int?,
        date: DateTime.parse(map['date']! as String),
        asset: map['asset']! as String,
        category: map['category']! as String,
        title: map['title']! as String,
        amount: map['amount']! as int,
        flow: map['flow']! as String,
        merchant: (map['merchant'] as String?) ?? '',
        note: (map['note'] as String?) ?? '',
        planType: (map['plan_type'] as String?) ?? 'normal',
        planId: map['plan_id'] as String?,
        installmentNo: map['installment_no'] as int?,
        installmentTotal: map['installment_total'] as int?,
      );

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}
