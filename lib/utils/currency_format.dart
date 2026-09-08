import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

class ThousandsSeparatorInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return const TextEditingValue();
    final value = int.tryParse(digits);
    if (value == null) return oldValue;
    final formatted = NumberFormat('#,###').format(value);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String koreanWonTextFromInput(String input) {
  final value = int.tryParse(input.replaceAll(',', ''));
  return value == null ? '' : koreanWonText(value);
}

String koreanWonText(int value) {
  if (value == 0) return '영원';
  const largeUnits = ['', '만', '억', '조', '경'];
  final groups = <int>[];
  var remaining = value.abs();
  while (remaining > 0) {
    groups.add(remaining % 10000);
    remaining ~/= 10000;
  }

  final buffer = StringBuffer(value < 0 ? '마이너스 ' : '');
  for (var index = groups.length - 1; index >= 0; index--) {
    final group = groups[index];
    if (group == 0) continue;
    buffer
      ..write(_fourDigitKorean(group))
      ..write(index < largeUnits.length ? largeUnits[index] : '');
  }
  return '$buffer원';
}

String _fourDigitKorean(int value) {
  const digits = ['', '일', '이', '삼', '사', '오', '육', '칠', '팔', '구'];
  const units = ['천', '백', '십', ''];
  final divisors = [1000, 100, 10, 1];
  final buffer = StringBuffer();
  var remaining = value;
  for (var index = 0; index < divisors.length; index++) {
    final digit = remaining ~/ divisors[index];
    remaining %= divisors[index];
    if (digit == 0) continue;
    if (digit != 1 || units[index].isEmpty) buffer.write(digits[digit]);
    buffer.write(units[index]);
  }
  return buffer.toString();
}
