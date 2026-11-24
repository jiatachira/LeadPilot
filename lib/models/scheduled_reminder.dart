part of '../main.dart';

class _ScheduledReminder {
  const _ScheduledReminder({
    required this.phoneKey,
    required this.name,
    required this.phone,
    required this.dateTime,
  });

  final String phoneKey;
  final String name;
  final String phone;
  final DateTime dateTime;

  int get groupKey => dateTime.toUtc().millisecondsSinceEpoch;

  Map<String, Object> toJson() => {
    'phoneKey': phoneKey,
    'name': name,
    'phone': phone,
    'dateTime': dateTime.toIso8601String(),
  };

  factory _ScheduledReminder.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Saved call reminder data is invalid.');
    }
    final phoneKey = value['phoneKey']?.toString() ?? '';
    final dateTime = DateTime.tryParse(value['dateTime']?.toString() ?? '');
    if (phoneKey.isEmpty || dateTime == null) {
      throw const FormatException('Saved call reminder data is incomplete.');
    }
    return _ScheduledReminder(
      phoneKey: phoneKey,
      name: value['name']?.toString() ?? '',
      phone: value['phone']?.toString() ?? '',
      dateTime: dateTime,
    );
  }
}

