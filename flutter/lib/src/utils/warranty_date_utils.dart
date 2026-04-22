import 'dart:math' as math;

DateTime warrantyDateOnly(DateTime date) {
  return DateTime(date.year, date.month, date.day);
}

DateTime addWarrantyYears(DateTime date, int years) {
  final normalizedDate = warrantyDateOnly(date);
  final targetYear = normalizedDate.year + years;
  final lastDayOfTargetMonth = DateTime(
    targetYear,
    normalizedDate.month + 1,
    0,
  ).day;
  final targetDay = math.min(normalizedDate.day, lastDayOfTargetMonth);

  return DateTime(targetYear, normalizedDate.month, targetDay);
}

String formatWarrantyDate(DateTime date) {
  final normalizedDate = warrantyDateOnly(date);
  final month = normalizedDate.month.toString().padLeft(2, '0');
  final day = normalizedDate.day.toString().padLeft(2, '0');

  return '${normalizedDate.year}-$month-$day';
}
