import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;
import 'package:url_launcher/url_launcher.dart';

const _navy = Color(0xFF142B4A);
const _green = Color(0xFF159A76);
const _canvas = Color(0xFFF4F7FA);
const _muted = Color(0xFF748194);
const _defaultWhatsAppCountryCode = '94';
final _appNavigatorKey = GlobalKey<NavigatorState>();
final _pendingReminderPopups = <Student>[];
bool _isShowingReminderPopup = false;

// ── Ringtone service ──────────────────────────────────────────────────────────
// Android native ringtone play/stop via MethodChannel.
// On non-Android platforms the calls are silently ignored.
const _ringtoneChannel = MethodChannel('com.example.call_dial/ringtone');

Future<void> _playReminderRingtone() async {
  try {
    await _ringtoneChannel.invokeMethod<void>('playRingtone');
  } on PlatformException catch (e) {
    debugPrint('Could not play ringtone: $e');
  } on MissingPluginException {
    // Not on Android or channel not registered – ignore silently.
  }
}

Future<void> _stopReminderRingtone() async {
  try {
    await _ringtoneChannel.invokeMethod<void>('stopRingtone');
  } on PlatformException catch (e) {
    debugPrint('Could not stop ringtone: $e');
  } on MissingPluginException {
    // Not on Android or channel not registered – ignore silently.
  }
}

const reminderSnoozeDuration = Duration(minutes: 5);
const studentReminderActions = <AndroidNotificationAction>[
  AndroidNotificationAction(
    'call_student',
    'Call',
    showsUserInterface: true,
    cancelNotification: true,
  ),
  AndroidNotificationAction(
    'snooze_reminder',
    'Snooze 5 min',
    showsUserInterface: false,
    cancelNotification: true,
  ),
];

DateTime snoozedReminderDateTime(DateTime now) =>
    now.add(reminderSnoozeDuration);

DateTime combineReminderDateAndTime(
  DateTime selectedDate,
  TimeOfDay selectedTime,
) => DateTime(
  selectedDate.year,
  selectedDate.month,
  selectedDate.day,
  selectedTime.hour,
  selectedTime.minute,
);

bool isReminderDateTimeInFuture(DateTime dateTime, {required DateTime now}) =>
    dateTime.isAfter(now);

final _studentReminderCategory = DarwinNotificationCategory(
  'student_call_reminder',
  actions: [
    DarwinNotificationAction.plain(
      'call_student',
      'Call',
      options: {DarwinNotificationActionOption.foreground},
    ),
    DarwinNotificationAction.plain('snooze_reminder', 'Snooze 5 min'),
  ],
);

String _defaultSheetName(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return 'Google Sheet';
  final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  final id = parts.length >= 3 ? parts[2] : uri.host;
  final shortId = id.length > 10 ? id.substring(0, 10) : id;
  return 'Google Sheet $shortId';
}

Uri whatsAppChatUri(String phoneNumber, {String? text}) {
  final trimmed = phoneNumber.trim();
  var digits = trimmed.replaceAll(RegExp(r'\D'), '');
  if (trimmed.startsWith('00')) {
    digits = digits.startsWith('00') ? digits.substring(2) : digits;
  } else if (trimmed.startsWith('+')) {
    // Keep the international country code without the leading plus.
  } else if (digits.startsWith('0')) {
    digits = '$_defaultWhatsAppCountryCode${digits.substring(1)}';
  }
  return Uri.https(
    'wa.me',
    '/$digits',
    (text != null && text.trim().isNotEmpty) ? {'text': text.trim()} : null,
  );
}

String normalizeContactPhone(String phoneNumber) {
  var digits = phoneNumber.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (digits.startsWith('0') && digits.length == 10) {
    digits = '$_defaultWhatsAppCountryCode${digits.substring(1)}';
  }
  return digits;
}

Uri smsComposerUri(String phoneNumber) {
  final digits = normalizeContactPhone(phoneNumber);
  return Uri(scheme: 'sms', path: digits.isEmpty ? '' : '+$digits');
}

bool isNotInterestedStatus(String status) =>
    status.trim().toLowerCase() == 'not interested';

bool isNotPotentialStatus(String status) {
  return switch (status.trim().toLowerCase()) {
    'not potential' || 'not protencial' || 'not pretencial' => true,
    _ => false,
  };
}

bool isInactiveStatus(String status) =>
    status.trim().toLowerCase() == 'inactive';

bool isFinalLeadStatus(String status) =>
    isNotInterestedStatus(status) ||
    isNotPotentialStatus(status) ||
    isInactiveStatus(status);

enum StudentActivityLevel { active, cooling, inactive, unknown }

class StudentActivityStatus {
  const StudentActivityStatus({
    required this.level,
    this.unansweredStreak = 0,
    required this.daysSinceConnection,
    required this.hasSuccessfulConnection,
  });

  final StudentActivityLevel level;
  final int unansweredStreak;
  final int? daysSinceConnection;
  final bool hasSuccessfulConnection;

  Color get color => switch (level) {
    StudentActivityLevel.active => const Color(0xFF159A76),
    StudentActivityLevel.cooling => const Color(0xFFE58A18),
    StudentActivityLevel.inactive => const Color(0xFFD64545),
    StudentActivityLevel.unknown => const Color(0xFF8993A1),
  };

  String get label => switch (level) {
    StudentActivityLevel.active => 'Active',
    StudentActivityLevel.cooling =>
      unansweredStreak > 0 ? '${unansweredStreak}x No answer' : '${daysSinceConnection}d',
    StudentActivityLevel.inactive =>
      unansweredStreak > 0 ? '${unansweredStreak}x No answer' : '${daysSinceConnection}d',
    StudentActivityLevel.unknown => 'No calls',
  };

  String get description => switch (level) {
    StudentActivityLevel.active =>
      hasSuccessfulConnection
          ? 'Connected recently'
          : 'Call attempt within the last 2 days',
    StudentActivityLevel.cooling =>
      unansweredStreak > 0
          ? '$unansweredStreak consecutive unanswered calls'
          : 'No connection for $daysSinceConnection days',
    StudentActivityLevel.inactive =>
      unansweredStreak > 0
          ? '$unansweredStreak consecutive unanswered calls'
          : 'No connection for $daysSinceConnection days',
    StudentActivityLevel.unknown => 'No call history yet',
  };
}

StudentActivityStatus studentActivityStatus(Student student, {DateTime? now}) {
  final failedConnectionDates = <DateTime>[];
  final successfulConnectionDates = <DateTime>[];
  final callEvents = <({DateTime? date, String status, String comment})>[];
  final seenComments = <String>{};

  for (final attempt in student.attempts) {
    final date = DateTime.tryParse(attempt.dateTime);
    final comment = attempt.comment.trim();
    if (comment.isNotEmpty) seenComments.add(comment.toLowerCase());
    if (date != null) {
      if (_isUnansweredCall(attempt.status, attempt.comment)) {
        failedConnectionDates.add(date);
      } else if (_isConnectedCall(attempt.status)) {
        successfulConnectionDates.add(date);
      }
    }
    callEvents.add((
      date: date,
      status: attempt.status,
      comment: attempt.comment,
    ));
  }

  for (final entry in student.commentHistory) {
    final separator = entry.indexOf(' — ');
    final comment = separator < 0
        ? entry.trim()
        : entry.substring(separator + 3).trim();
    if (comment.isEmpty) continue;
    if (seenComments.contains(comment.toLowerCase())) continue;
    seenComments.add(comment.toLowerCase());

    final date = separator < 0
        ? DateTime.tryParse(student.addedDate)
        : _parseActivityDate(entry.substring(0, separator).trim());

    if (date != null) {
      if (_isUnansweredCall('', comment)) {
        failedConnectionDates.add(date);
      }
    }
    callEvents.add((
      date: date,
      status: '',
      comment: comment,
    ));
  }

  if (student.attempts.isEmpty && student.commentHistory.isEmpty) {
    final date = DateTime.tryParse(student.addedDate);
    if (_isUnansweredCall(student.callStatus, student.comment)) {
      if (date != null) failedConnectionDates.add(date);
      callEvents.add((
        date: date,
        status: student.callStatus,
        comment: student.comment,
      ));
    } else if (_isConnectedCall(student.callStatus)) {
      if (date != null) successfulConnectionDates.add(date);
      callEvents.add((
        date: date,
        status: student.callStatus,
        comment: student.comment,
      ));
    }
  }

  if (callEvents.isEmpty &&
      failedConnectionDates.isEmpty &&
      successfulConnectionDates.isEmpty) {
    return const StudentActivityStatus(
      level: StudentActivityLevel.unknown,
      unansweredStreak: 0,
      daysSinceConnection: null,
      hasSuccessfulConnection: false,
    );
  }

  callEvents.sort((a, b) {
    if (a.date != null && b.date != null) {
      return a.date!.compareTo(b.date!);
    }
    return 0;
  });

  int unansweredStreak = 0;
  for (final event in callEvents.reversed) {
    if (_isUnansweredCall(event.status, event.comment)) {
      unansweredStreak++;
    } else if (_isConnectedCall(event.status)) {
      break;
    } else {
      break;
    }
  }

  DateTime? lastConnection;
  if (successfulConnectionDates.isNotEmpty) {
    lastConnection = successfulConnectionDates.reduce(
      (left, right) => left.isAfter(right) ? left : right,
    );
  } else if (failedConnectionDates.isNotEmpty) {
    lastConnection = failedConnectionDates.reduce(
      (left, right) => left.isBefore(right) ? left : right,
    );
  }

  int? days;
  if (lastConnection != null) {
    final currentDate = _dateOnly(now ?? DateTime.now());
    final connectionDate = _dateOnly(lastConnection);
    days = currentDate
        .difference(connectionDate)
        .inDays
        .clamp(0, 100000)
        .toInt();
  }

  final effectiveDays = days ?? 0;
  final StudentActivityLevel level;
  if (unansweredStreak >= 5 || (lastConnection != null && effectiveDays >= 5)) {
    level = StudentActivityLevel.inactive;
  } else if (unansweredStreak >= 3 || (lastConnection != null && effectiveDays >= 3)) {
    level = StudentActivityLevel.cooling;
  } else if (successfulConnectionDates.isNotEmpty || callEvents.isNotEmpty) {
    level = StudentActivityLevel.active;
  } else {
    level = StudentActivityLevel.unknown;
  }

  return StudentActivityStatus(
    level: level,
    unansweredStreak: unansweredStreak,
    daysSinceConnection: days,
    hasSuccessfulConnection: successfulConnectionDates.isNotEmpty,
  );
}

bool _isUnansweredCall(String status, String comment) {
  final text = '$status $comment'.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]+'),
    ' ',
  );
  return text.contains('no answer') ||
      text.contains('not responding') ||
      text.contains('not reachable') ||
      text.contains('unreachable') ||
      text.contains('did not answer') ||
      text.contains('didn t answer') ||
      text.contains('could not connect') ||
      text.contains('couldn t connect') ||
      text.contains('not connected') ||
      text.contains('no response') ||
      text.contains('call cut') ||
      text.contains('line busy');
}

bool _isConnectedCall(String status) => const {
  'answered',
  'very interested',
  'interested',
  'minimal interested',
  'not interested',
  'not potential',
  'inactive',
  'call back',
  'future',
}.contains(status.trim().toLowerCase());

DateTime? _parseActivityDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed != null) return parsed;
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})\s+(\d{1,2}):(\d{2})\s+(AM|PM)$',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return null;
  final hour = int.parse(match[4]!);
  final adjustedHour = hour % 12 + (match[6]!.toUpperCase() == 'PM' ? 12 : 0);
  return DateTime(
    int.parse(match[1]!),
    int.parse(match[2]!),
    int.parse(match[3]!),
    adjustedHour,
    int.parse(match[5]!),
  );
}

int allocateReminderNotificationId(String phoneNumber, Set<int> usedIds) {
  final key = normalizeContactPhone(phoneNumber);
  if (key.isEmpty) {
    throw ArgumentError.value(
      phoneNumber,
      'phoneNumber',
      'Must contain digits',
    );
  }
  var candidate = 0x811c9dc5;
  for (final codeUnit in key.codeUnits) {
    candidate = ((candidate ^ codeUnit) * 0x01000193) & 0x7fffffff;
  }
  if (candidate == 0) candidate = 1;
  while (usedIds.contains(candidate)) {
    candidate = candidate == 0x7fffffff ? 1 : candidate + 1;
  }
  return candidate;
}

String buildReminderGroupBody(
  Iterable<({String name, String phone})> reminders,
) {
  return reminders
      .map((reminder) => '${reminder.name} (${reminder.phone})')
      .join('\n');
}

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

class LinkedSheet {
  const LinkedSheet({required this.name, required this.url});

  final String name;
  final String url;

  Map<String, String> toJson() => {'name': name, 'url': url};

  @override
  bool operator ==(Object other) =>
      other is LinkedSheet && other.name == name && other.url == url;

  @override
  int get hashCode => Object.hash(name, url);

  factory LinkedSheet.fromJson(dynamic value, {int index = 0}) {
    if (value is String) {
      return LinkedSheet(name: 'Google Sheet ${index + 1}', url: value);
    }
    if (value is Map<String, dynamic>) {
      final url = value['url']?.toString().trim() ?? '';
      final name = value['name']?.toString().trim() ?? '';
      if (url.isEmpty) {
        throw const FormatException('A saved sheet must include its URL.');
      }
      return LinkedSheet(
        name: name.isEmpty ? 'Google Sheet ${index + 1}' : name,
        url: url,
      );
    }
    throw const FormatException('Saved linked sheet data is invalid.');
  }
}

class WhatsAppTemplate {
  const WhatsAppTemplate({
    required this.id,
    required this.name,
    required this.message,
  });

  final String id;
  final String name;
  final String message;

  WhatsAppTemplate copyWith({
    String? id,
    String? name,
    String? message,
  }) {
    return WhatsAppTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      message: message ?? this.message,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'message': message,
  };

  factory WhatsAppTemplate.fromJson(Map<String, dynamic> json) {
    return WhatsAppTemplate(
      id: (json['id'] as String?) ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: (json['name'] as String?) ?? '',
      message: (json['message'] as String?) ?? '',
    );
  }

  static const List<WhatsAppTemplate> defaultTemplates = [
    WhatsAppTemplate(
      id: 'default_1',
      name: 'General Follow-up',
      message: 'Hello {name}, following up on our recent conversation.',
    ),
    WhatsAppTemplate(
      id: 'default_2',
      name: 'Course Details',
      message:
          'Hello {name}, here are the details for the course you inquired about.',
    ),
  ];
}

class SaveContactsResult {
  const SaveContactsResult({
    this.saved = 0,
    this.alreadySaved = 0,
    this.failedNames = const [],
    this.permissionDenied = false,
    this.permissionPermanentlyDenied = false,
  });

  final int saved;
  final int alreadySaved;
  final List<String> failedNames;
  final bool permissionDenied;
  final bool permissionPermanentlyDenied;
}

abstract interface class DeviceContactsService {
  Future<SaveContactsResult> saveMissingStudents(List<Student> students);
}

class NativeDeviceContactsService implements DeviceContactsService {
  const NativeDeviceContactsService();

  @override
  Future<SaveContactsResult> saveMissingStudents(List<Student> students) async {
    final permission = await FlutterContacts.permissions.request(
      PermissionType.readWrite,
    );
    if (permission != PermissionStatus.granted &&
        permission != PermissionStatus.limited) {
      return SaveContactsResult(
        permissionDenied: true,
        permissionPermanentlyDenied:
            permission == PermissionStatus.permanentlyDenied ||
            permission == PermissionStatus.restricted,
      );
    }

    final existingContacts = await FlutterContacts.getAll(
      properties: const {ContactProperty.phone},
    );
    final savedNumbers = <String>{
      for (final contact in existingContacts)
        for (final phone in contact.phones)
          if (normalizeContactPhone(phone.number).isNotEmpty)
            normalizeContactPhone(phone.number),
    };

    var saved = 0;
    var alreadySaved = 0;
    final failedNames = <String>[];
    for (final student in students) {
      final number = normalizeContactPhone(student.phone);
      if (number.isEmpty || !savedNumbers.add(number)) {
        alreadySaved++;
        continue;
      }

      final nameParts = student.name.trim().split(RegExp(r'\s+'));
      final contact = Contact(
        name: Name(
          first: nameParts.first,
          last: nameParts.length > 1 ? nameParts.skip(1).join(' ') : null,
        ),
        phones: [Phone(number: student.phone)],
      );
      try {
        await FlutterContacts.create(contact);
        saved++;
      } on Exception {
        failedNames.add(student.name);
      }
    }
    return SaveContactsResult(
      saved: saved,
      alreadySaved: alreadySaved,
      failedNames: failedNames,
    );
  }
}

abstract interface class AppSettingsStore {
  Future<String?> readPin();

  Future<void> savePin(String pin);

  Future<String> readSheetConfig();

  Future<String> readSheetName();

  Future<List<LinkedSheet>> readLinkedSheets();

  Future<void> saveSheetConfig(String url, {String name = ''});

  Future<ThemeMode> readThemeMode();

  Future<void> saveThemeMode(ThemeMode mode);

  Future<bool> readBiometricEnabled();

  Future<void> saveBiometricEnabled(bool enabled);

  Future<List<QueuedSheetAction>> readOfflineQueue();

  Future<void> saveOfflineQueue(List<QueuedSheetAction> queue);

  Future<List<Student>> readCachedStudents();

  Future<void> saveCachedStudents(List<Student> students);

  Future<List<WhatsAppTemplate>> readWhatsAppTemplates();

  Future<void> saveWhatsAppTemplates(List<WhatsAppTemplate> templates);
}

class SecureAppSettingsStore implements AppSettingsStore {
  SecureAppSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _pinKey = 'student_call_pin';
  static const _sheetConfigKey = 'student_call_sheet_config';
  static const _sheetNameKey = 'student_call_sheet_name';
  static const _linkedSheetsKey = 'student_call_linked_sheets';
  static const _themeModeKey = 'student_call_theme_mode';
  static const _biometricEnabledKey = 'student_call_biometric_enabled';
  static const _offlineQueueKey = 'student_call_offline_queue';
  static const _cachedStudentsKey = 'student_call_cached_students';
  static const _whatsAppTemplatesKey = 'student_call_whatsapp_templates';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> readPin() => _storage.read(key: _pinKey);

  @override
  Future<void> savePin(String pin) => _storage.write(key: _pinKey, value: pin);

  @override
  Future<String> readSheetConfig() async =>
      await _storage.read(key: _sheetConfigKey) ?? '';

  @override
  Future<String> readSheetName() async =>
      await _storage.read(key: _sheetNameKey) ?? '';

  @override
  Future<List<LinkedSheet>> readLinkedSheets() async {
    final saved = await _storage.read(key: _linkedSheetsKey);
    if (saved == null || saved.isEmpty) return const [];
    final decoded = jsonDecode(saved);
    if (decoded is! List) {
      throw const FormatException('Saved linked sheets data is invalid.');
    }
    return decoded
        .asMap()
        .entries
        .map((entry) => LinkedSheet.fromJson(entry.value, index: entry.key))
        .toList();
  }

  @override
  Future<ThemeMode> readThemeMode() async =>
      _themeModeFromName(await _storage.read(key: _themeModeKey));

  @override
  Future<void> saveThemeMode(ThemeMode mode) =>
      _storage.write(key: _themeModeKey, value: mode.name);

  @override
  Future<bool> readBiometricEnabled() async {
    final val = await _storage.read(key: _biometricEnabledKey);
    return val == 'true';
  }

  @override
  Future<void> saveBiometricEnabled(bool enabled) =>
      _storage.write(key: _biometricEnabledKey, value: enabled.toString());

  @override
  Future<List<QueuedSheetAction>> readOfflineQueue() async {
    final saved = await _storage.read(key: _offlineQueueKey);
    if (saved == null || saved.isEmpty) return const [];
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((item) => QueuedSheetAction.fromJson(item))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> saveOfflineQueue(List<QueuedSheetAction> queue) =>
      _storage.write(
        key: _offlineQueueKey,
        value: jsonEncode(queue.map((item) => item.toJson()).toList()),
      );

  @override
  Future<List<Student>> readCachedStudents() async {
    final saved = await _storage.read(key: _cachedStudentsKey);
    if (saved == null || saved.isEmpty) return const [];
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((item) => Student.fromJson(item))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> saveCachedStudents(List<Student> students) async {
    await _storage.write(
      key: _cachedStudentsKey,
      value: jsonEncode(students.map((s) => s.toJson()).toList()),
    );
    unawaited(CallerIdService.syncStudents(students));
  }

  @override
  Future<List<WhatsAppTemplate>> readWhatsAppTemplates() async {
    final saved = await _storage.read(key: _whatsAppTemplatesKey);
    if (saved == null) {
      return WhatsAppTemplate.defaultTemplates;
    }
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) return WhatsAppTemplate.defaultTemplates;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((item) => WhatsAppTemplate.fromJson(item))
          .toList();
    } catch (_) {
      return WhatsAppTemplate.defaultTemplates;
    }
  }

  @override
  Future<void> saveWhatsAppTemplates(List<WhatsAppTemplate> templates) =>
      _storage.write(
        key: _whatsAppTemplatesKey,
        value: jsonEncode(templates.map((t) => t.toJson()).toList()),
      );

  @override
  Future<void> saveSheetConfig(String url, {String name = ''}) async {
    final normalizedUrl = url.trim();
    final linkedSheets = await readLinkedSheets();
    final normalizedName = name.trim().isEmpty
        ? _defaultSheetName(normalizedUrl)
        : name.trim();
    final duplicateName = linkedSheets.any(
      (sheet) =>
          sheet.url != normalizedUrl &&
          sheet.name.toLowerCase() == normalizedName.toLowerCase(),
    );
    if (duplicateName) {
      throw StateError(
        'A linked sheet already uses the name "$normalizedName".',
      );
    }
    final updatedSheets = <LinkedSheet>[
      LinkedSheet(name: normalizedName, url: normalizedUrl),
      ...linkedSheets.where((sheet) => sheet.url != normalizedUrl),
    ];
    await _storage.write(key: _sheetConfigKey, value: normalizedUrl);
    await _storage.write(key: _sheetNameKey, value: normalizedName);
    await _storage.write(
      key: _linkedSheetsKey,
      value: jsonEncode(updatedSheets.map((sheet) => sheet.toJson()).toList()),
    );
  }
}

class MemoryAppSettingsStore implements AppSettingsStore {
  String? pin;
  String sheetConfig = '';
  String sheetName = '';
  ThemeMode themeMode = ThemeMode.system;
  bool biometricEnabled = false;
  final List<LinkedSheet> linkedSheets = [];

  @override
  Future<String?> readPin() async => pin;

  @override
  Future<void> savePin(String value) async {
    pin = value;
  }

  @override
  Future<String> readSheetConfig() async => sheetConfig;

  @override
  Future<String> readSheetName() async => sheetName;

  @override
  Future<List<LinkedSheet>> readLinkedSheets() async =>
      List<LinkedSheet>.of(linkedSheets);

  @override
  Future<void> saveSheetConfig(String url, {String name = ''}) async {
    sheetConfig = url.trim();
    sheetName = name.trim().isEmpty
        ? _defaultSheetName(sheetConfig)
        : name.trim();
    linkedSheets.removeWhere((sheet) => sheet.url == sheetConfig);
    linkedSheets.insert(0, LinkedSheet(name: sheetName, url: sheetConfig));
  }

  @override
  Future<ThemeMode> readThemeMode() async => themeMode;

  @override
  Future<void> saveThemeMode(ThemeMode mode) async {
    themeMode = mode;
  }

  @override
  Future<bool> readBiometricEnabled() async => biometricEnabled;

  @override
  Future<void> saveBiometricEnabled(bool enabled) async {
    biometricEnabled = enabled;
  }

  final List<QueuedSheetAction> offlineQueue = [];
  final List<Student> cachedStudents = [];
  List<WhatsAppTemplate>? whatsAppTemplates;

  @override
  Future<List<QueuedSheetAction>> readOfflineQueue() async =>
      List.of(offlineQueue);

  @override
  Future<void> saveOfflineQueue(List<QueuedSheetAction> queue) async {
    offlineQueue
      ..clear()
      ..addAll(queue);
  }

  @override
  Future<List<Student>> readCachedStudents() async => List.of(cachedStudents);

  @override
  Future<void> saveCachedStudents(List<Student> students) async {
    cachedStudents
      ..clear()
      ..addAll(students);
    unawaited(CallerIdService.syncStudents(students));
  }

  @override
  Future<List<WhatsAppTemplate>> readWhatsAppTemplates() async =>
      List.of(whatsAppTemplates ?? WhatsAppTemplate.defaultTemplates);

  @override
  Future<void> saveWhatsAppTemplates(List<WhatsAppTemplate> templates) async {
    whatsAppTemplates = List.of(templates);
  }
}

ThemeMode _themeModeFromName(String? value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

class CallerIdService {
  static const MethodChannel channel =
      MethodChannel('com.example.call_dial/caller_id');

  static Future<bool> isEnabled() async {
    try {
      final res = await channel.invokeMethod<bool>('isCallerIdEnabled');
      return res ?? true;
    } on MissingPluginException {
      return true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    try {
      await channel.invokeMethod('setCallerIdEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<bool> canDrawOverlays() async {
    try {
      final res = await channel.invokeMethod<bool>('canDrawOverlays');
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestOverlayPermission() async {
    try {
      await channel.invokeMethod('requestOverlayPermission');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<bool> hasPhonePermissions() async {
    try {
      final res = await channel.invokeMethod<bool>('hasPhonePermissions');
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestPhonePermissions() async {
    try {
      final res = await channel.invokeMethod<bool>('requestPhonePermissions');
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> testCallerIdPopup() async {
    try {
      await channel.invokeMethod('testCallerIdPopup');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<void> dismissOverlay() async {
    try {
      await channel.invokeMethod('dismissOverlay');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<void> syncStudents(List<Student> students) async {
    try {
      final payload = students.map((s) {
        final activity = studentActivityStatus(s);
        final latestComment = s.commentHistory.isNotEmpty
            ? s.commentHistory.last.trim()
            : s.comment.trim();
        return {
          'name': s.name,
          'phone': s.phone,
          'whatsappNumber': s.whatsappNumber,
          'status': s.callStatus,
          'location': s.location,
          'examType': s.examType,
          'examYear': s.examYear,
          'lastComment': latestComment,
          'streak': activity.unansweredStreak,
        };
      }).toList();

      await channel.invokeMethod('syncCallerIdData', {'students': payload});
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }
}

abstract interface class ReminderScheduler {
  Future<bool> canScheduleExactAlarms();

  Future<bool> requestExactAlarmsPermission();

  Future<void> scheduleStudentReminder(Student student, DateTime dateTime);

  Future<void> cancelStudentReminder(Student student);

  Future<bool> isStudentReminderScheduled(Student student, [DateTime? dateTime]);
}

class LocalReminderService implements ReminderScheduler {
  LocalReminderService({
    FlutterLocalNotificationsPlugin? plugin,
    FlutterSecureStorage? storage,
  }) : _plugin = plugin ?? _defaultPlugin,
       _storage = storage ?? const FlutterSecureStorage();

  static const _channelId = 'student_call_alarm_v2';
  static const _channelName = 'Call reminder alarms';
  static const _notificationIdsKey = 'student_call_notification_ids';
  static const _scheduledRemindersKey = 'student_call_scheduled_reminders';
  static final FlutterLocalNotificationsPlugin _defaultPlugin =
      FlutterLocalNotificationsPlugin();
  static Future<void>? _initialization;
  final FlutterLocalNotificationsPlugin _plugin;
  final FlutterSecureStorage _storage;
  Map<String, int>? _notificationIds;
  Future<void> _notificationIdQueue = Future<void>.value();
  Future<void> _reminderUpdateQueue = Future<void>.value();

  static Future<void> initialize([FlutterLocalNotificationsPlugin? plugin]) {
    final notificationPlugin = plugin ?? _defaultPlugin;
    return _initialization ??= notificationPlugin
        .initialize(
          settings: InitializationSettings(
            android: const AndroidInitializationSettings('ic_notification'),
            iOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestBadgePermission: false,
              requestSoundPermission: false,
              notificationCategories: [_studentReminderCategory],
            ),
          ),
          onDidReceiveNotificationResponse: _handleReminderNotificationResponse,
          onDidReceiveBackgroundNotificationResponse:
              _handleBackgroundReminderNotificationResponse,
        )
        .then((initialized) async {
          if (initialized == false) {
            throw StateError('Local notifications could not be initialized.');
          }
          final launchDetails = await notificationPlugin
              .getNotificationAppLaunchDetails();
          final response = launchDetails?.notificationResponse;
          if (launchDetails?.didNotificationLaunchApp == true &&
              response != null) {
            _handleReminderNotificationResponse(response);
          }
        });
  }

  @override
  Future<bool> canScheduleExactAlarms() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await android?.canScheduleExactNotifications() ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<bool> requestExactAlarmsPermission() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await android?.requestExactAlarmsPermission() ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> scheduleStudentReminder(
    Student student,
    DateTime dateTime,
  ) async {
    await initialize(_plugin);
    if (!dateTime.isAfter(DateTime.now())) {
      throw StateError(
        'The selected reminder time has passed. Choose a later time today '
        'or a future date.',
      );
    }

    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final notificationsGranted = await android
        ?.requestNotificationsPermission();
    if (notificationsGranted == false) {
      throw StateError('Notification permission was not granted.');
    }

    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    final iosPermissionGranted = await ios?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
    if (iosPermissionGranted == false) {
      throw StateError('Notification permission was not granted.');
    }

    final notificationId = await _notificationId(student);
    await _cancelLegacyNotificationIfPresent(student, notificationId);
    final groupKey = _reminderGroupKey(dateTime);
    await _plugin.zonedSchedule(
      id: notificationId,
      title: 'Upcoming Call Reminder 📞',
      body: 'Time to call ${student.name} (${student.phone})!',
      scheduledDate: timezone.TZDateTime.from(dateTime.toUtc(), timezone.UTC),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Reminders for scheduled student calls.',
          groupKey: groupKey,
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
          ongoing: true,
          playSound: true,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          actions: studentReminderActions,
        ),
        iOS: const DarwinNotificationDetails(
          categoryIdentifier: 'student_call_reminder',
          presentAlert: true,
          presentBanner: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: jsonEncode({'name': student.name, 'phone': student.phone}),
    );
    await _saveScheduledReminder(student, dateTime);
  }

  @override
  Future<void> cancelStudentReminder(Student student) async {
    await initialize(_plugin);
    final notificationId = await _notificationId(student);
    await _plugin.cancel(id: notificationId);
    await _cancelLegacyNotificationIfPresent(student, notificationId);
    await _removeScheduledReminder(student);
  }

  @override
  Future<bool> isStudentReminderScheduled(
    Student student, [
    DateTime? dateTime,
  ]) async {
    final phoneKey = normalizeContactPhone(student.phone);
    if (phoneKey.isEmpty) return false;
    final reminders = await _readScheduledReminders();
    final reminder = reminders[phoneKey];
    if (reminder == null) return false;
    if (dateTime != null) {
      return reminder.dateTime.isAtSameMomentAs(dateTime) &&
          reminder.dateTime.isAfter(DateTime.now());
    }
    return reminder.dateTime.isAfter(DateTime.now());
  }

  Future<int> _notificationId(Student student) async {
    final key = normalizeContactPhone(student.phone);
    if (key.isEmpty) {
      throw ArgumentError.value(
        student.phone,
        'student.phone',
        'Must contain digits',
      );
    }
    return _notificationIdForKey(key);
  }

  Future<int> _notificationIdForKey(String key) async {
    final previous = _notificationIdQueue;
    final release = Completer<void>();
    _notificationIdQueue = release.future;
    await previous;
    try {
      final ids = _notificationIds ??= await _readNotificationIds();
      final existingId = ids[key];
      if (existingId != null) return existingId;

      final id = allocateReminderNotificationId(key, ids.values.toSet());
      ids[key] = id;
      await _storage.write(key: _notificationIdsKey, value: jsonEncode(ids));
      return id;
    } finally {
      release.complete();
    }
  }

  Future<void> _saveScheduledReminder(
    Student student,
    DateTime dateTime,
  ) async {
    final previous = _reminderUpdateQueue;
    final release = Completer<void>();
    _reminderUpdateQueue = release.future;
    await previous;
    try {
      final reminders = await _readScheduledReminders();
      final phoneKey = normalizeContactPhone(student.phone);
      final existing = reminders[phoneKey];
      final affectedGroups = <int>{
        if (existing != null) existing.groupKey,
        dateTime.toUtc().millisecondsSinceEpoch,
      };
      reminders[phoneKey] = _ScheduledReminder(
        phoneKey: phoneKey,
        name: student.name,
        phone: student.phone,
        dateTime: dateTime,
      );
      await _writeScheduledReminders(reminders);
      await _refreshReminderGroupSummaries(reminders, affectedGroups);
    } finally {
      release.complete();
    }
  }

  Future<void> _removeScheduledReminder(Student student) async {
    final phoneKey = normalizeContactPhone(student.phone);
    if (phoneKey.isEmpty) return;
    final previous = _reminderUpdateQueue;
    final release = Completer<void>();
    _reminderUpdateQueue = release.future;
    await previous;
    try {
      final reminders = await _readScheduledReminders();
      final existing = reminders.remove(phoneKey);
      if (existing == null) return;
      await _writeScheduledReminders(reminders);
      await _refreshReminderGroupSummaries(reminders, {existing.groupKey});
    } finally {
      release.complete();
    }
  }

  Future<Map<String, _ScheduledReminder>> _readScheduledReminders() async {
    final saved = await _storage.read(key: _scheduledRemindersKey);
    if (saved == null || saved.isEmpty) return {};
    final decoded = jsonDecode(saved);
    if (decoded is! List) {
      throw const FormatException('Saved call reminder list is invalid.');
    }
    final reminders = <String, _ScheduledReminder>{};
    for (final item in decoded) {
      final reminder = _ScheduledReminder.fromJson(item);
      reminders[reminder.phoneKey] = reminder;
    }
    return reminders;
  }

  Future<void> _writeScheduledReminders(
    Map<String, _ScheduledReminder> reminders,
  ) => _storage.write(
    key: _scheduledRemindersKey,
    value: jsonEncode(
      reminders.values.map((reminder) => reminder.toJson()).toList(),
    ),
  );

  Future<void> _refreshReminderGroupSummaries(
    Map<String, _ScheduledReminder> reminders,
    Set<int> affectedGroups,
  ) async {
    if (!Platform.isAndroid) return;

    for (final groupTimestamp in affectedGroups) {
      final notificationId = await _notificationIdForKey(
        'reminder-group:$groupTimestamp',
      );
      final groupReminders =
          reminders.values
              .where((reminder) => reminder.groupKey == groupTimestamp)
              .toList()
            ..sort((left, right) => left.name.compareTo(right.name));
      if (groupReminders.length < 2) {
        await _plugin.cancel(id: notificationId);
        continue;
      }

      final title = '${groupReminders.length} scheduled calls';
      final body = buildReminderGroupBody(
        groupReminders.map(
          (reminder) => (name: reminder.name, phone: reminder.phone),
        ),
      );
      final dateTime = groupReminders.first.dateTime;
      final groupKey = _reminderGroupKey(dateTime);
      await _plugin.zonedSchedule(
        id: notificationId,
        title: title,
        body: body,
        scheduledDate: timezone.TZDateTime.from(dateTime.toUtc(), timezone.UTC),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'Grouped reminders for simultaneous calls.',
            groupKey: groupKey,
            setAsGroupSummary: true,
            onlyAlertOnce: true,
            styleInformation: BigTextStyleInformation(
              body,
              contentTitle: title,
              summaryText: 'Student call reminders',
            ),
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    }
  }

  static String _reminderGroupKey(DateTime dateTime) =>
      'student-call-${dateTime.toUtc().millisecondsSinceEpoch}';

  Future<void> _cancelLegacyNotificationIfPresent(
    Student student,
    int notificationId,
  ) async {
    final legacyId = _legacyNotificationId(student);
    if (legacyId == notificationId) return;
    final pending = await _plugin.pendingNotificationRequests();
    final legacyRequestExists = pending.any(
      (request) =>
          request.id == legacyId &&
          (request.body?.contains('(${student.phone})') ?? false),
    );
    if (legacyRequestExists) await _plugin.cancel(id: legacyId);
  }

  Future<Map<String, int>> _readNotificationIds() async {
    final saved = await _storage.read(key: _notificationIdsKey);
    if (saved == null || saved.isEmpty) return {};
    final decoded = jsonDecode(saved);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Saved reminder IDs are invalid.');
    }
    final ids = <String, int>{};
    final usedIds = <int>{};
    for (final entry in decoded.entries) {
      final parsedId = int.tryParse(entry.value.toString());
      if (parsedId == null || parsedId <= 0 || !usedIds.add(parsedId)) {
        continue;
      }
      ids[entry.key] = parsedId;
    }
    return ids;
  }

  static int _legacyNotificationId(Student student) {
    return student.phone.codeUnits.fold<int>(
      0,
      (value, codeUnit) => (value * 31 + codeUnit) & 0x7fffffff,
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  timezone.setLocalLocation(timezone.UTC);
  await LocalReminderService.initialize();
  runApp(const StudentCallApp());
}

void _handleReminderNotificationResponse(NotificationResponse response) {
  final student = _studentFromReminderPayload(response.payload);
  if (student == null) return;

  if (response.actionId == 'call_student') {
    unawaited(_callStudentFromReminder(student));
  } else if (response.actionId == 'snooze_reminder') {
    unawaited(_snoozeReminder(student));
  } else {
    _queueReminderPopup(student);
  }
}

void _queueReminderPopup(Student student) {
  _pendingReminderPopups.add(student);
  _showNextReminderPopup();
}

void _showNextReminderPopup() {
  final context = _appNavigatorKey.currentContext;
  if (_isShowingReminderPopup ||
      _pendingReminderPopups.isEmpty ||
      context == null) {
    return;
  }

  final student = _pendingReminderPopups.removeAt(0);
  _isShowingReminderPopup = true;

  // 🔔 Start ringing when the popup appears.
  unawaited(_playReminderRingtone());

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.alarm_rounded, color: _green, size: 36),
        title: const Text('Upcoming Call Reminder'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              student.name,
              textAlign: TextAlign.center,
              style: Theme.of(dialogContext).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(student.phone),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              unawaited(_stopReminderRingtone()); // 🔕 Stop ring on snooze
              Navigator.of(dialogContext).pop();
              await _snoozeReminder(student);
            },
            icon: const Icon(Icons.snooze_rounded),
            label: const Text('Snooze 5 min'),
          ),
          FilledButton.icon(
            onPressed: () async {
              unawaited(_stopReminderRingtone()); // 🔕 Stop ring on call
              Navigator.of(dialogContext).pop();
              await _callStudentFromReminder(student);
            },
            icon: const Icon(Icons.call_rounded),
            label: const Text('Call'),
          ),
        ],
      ),
    ).then((_) {
      // 🔕 Also stop ring if dialog dismissed by any other means.
      unawaited(_stopReminderRingtone());
      _isShowingReminderPopup = false;
      _showNextReminderPopup();
    }),
  );
}

@pragma('vm:entry-point')
void _handleBackgroundReminderNotificationResponse(
  NotificationResponse response,
) async {
  if (response.actionId != 'snooze_reminder') return;
  WidgetsFlutterBinding.ensureInitialized();
  final student = _studentFromReminderPayload(response.payload);
  if (student != null) await _snoozeReminder(student);
}

Student? _studentFromReminderPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) return null;
    final name = decoded['name']?.toString().trim() ?? '';
    final phone = decoded['phone']?.toString().trim() ?? '';
    if (name.isEmpty || phone.isEmpty) return null;
    return Student(name: name, phone: phone);
  } on FormatException catch (error) {
    debugPrint('Invalid student reminder payload: $error');
    return null;
  }
}

Future<void> _callStudentFromReminder(Student student) async {
  try {
    final launched = await launchUrl(Uri.parse('tel:${student.phone}'));
    if (!launched) {
      debugPrint('Could not open the phone dialer for ${student.name}.');
    }
  } on Exception catch (error) {
    debugPrint('Could not start the reminder call: $error');
  }
}

Future<void> _snoozeReminder(Student student) async {
  try {
    await LocalReminderService().scheduleStudentReminder(
      student,
      snoozedReminderDateTime(DateTime.now()),
    );
  } on Exception catch (error) {
    debugPrint('Could not snooze the reminder for ${student.name}: $error');
  }
}

class StudentCallApp extends StatefulWidget {
  const StudentCallApp({
    this.httpClient,
    this.reminderScheduler,
    this.settingsStore,
    this.deviceContactsService,
    super.key,
  });

  final http.Client? httpClient;
  final ReminderScheduler? reminderScheduler;
  final AppSettingsStore? settingsStore;
  final DeviceContactsService? deviceContactsService;

  @override
  State<StudentCallApp> createState() => _StudentCallAppState();
}

class _StudentCallAppState extends State<StudentCallApp> {
  String? _pin;
  String _sheetConfig = '';
  String _sheetName = '';
  List<LinkedSheet> _linkedSheets = const [];
  ThemeMode _themeMode = ThemeMode.system;
  bool _isFirstTime = true;
  bool _isAuthenticated = false;
  bool _isLoadingSettings = true;
  bool _biometricEnabled = false;
  Object? _settingsLoadError;
  late final AppSettingsStore _settingsStore =
      widget.settingsStore ?? SecureAppSettingsStore();
  late final GoogleSheetService _sheetService = GoogleSheetService(
    client: widget.httpClient,
  );
  late final ReminderScheduler _reminderScheduler =
      widget.reminderScheduler ?? LocalReminderService();
  final _localAuth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
  }

  @override
  void dispose() {
    _sheetService.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lightColorScheme = ColorScheme.fromSeed(
      seedColor: _navy,
      primary: _navy,
      secondary: _green,
      surface: Colors.white,
    );
    final darkColorScheme = ColorScheme.fromSeed(
      seedColor: _green,
      brightness: Brightness.dark,
      primary: const Color(0xFFB7C9E0),
      secondary: const Color(0xFF62D6B0),
      surface: const Color(0xFF1B2733),
    );

    return MaterialApp(
      title: 'LeadPilot',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: lightColorScheme,
        scaffoldBackgroundColor: _canvas,
        appBarTheme: const AppBarTheme(
          backgroundColor: _canvas,
          foregroundColor: _navy,
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 17,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE5EAF0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE5EAF0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: _green, width: 1.5),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: darkColorScheme,
        scaffoldBackgroundColor: const Color(0xFF101820),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF101820),
          foregroundColor: Color(0xFFE6EDF5),
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1B2733),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 17,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF344453)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF344453)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF62D6B0), width: 1.5),
          ),
        ),
      ),
      home: _isLoadingSettings
          ? const _AppStartupScreen()
          : _settingsLoadError != null
          ? _SettingsLoadErrorScreen(
              message: _settingsLoadError.toString(),
              onRetry: _loadSavedSettings,
            )
          : _isAuthenticated
          ? HomeScreen(
              sheetConfig: _sheetConfig,
              sheetName: _sheetName,
              linkedSheets: _linkedSheets,
              sheetService: _sheetService,
              reminderScheduler: _reminderScheduler,
              deviceContactsService:
                  widget.deviceContactsService ??
                  const NativeDeviceContactsService(),
              themeMode: _themeMode,
              onLogout: _lockApp,
              onSaveSheetConfig: _saveSheetConfig,
              onThemeModeChanged: _saveThemeMode,
              biometricEnabled: _biometricEnabled,
              onBiometricChanged: _saveBiometricEnabled,
              settingsStore: _settingsStore,
            )
          : PinScreen(
              key: ValueKey(_isFirstTime),
              isFirstTime: _isFirstTime,
              storedPin: _pin,
              biometricEnabled: _biometricEnabled && !_isFirstTime,
              onBiometricAuth: _tryBiometricLogin,
              onPinCreated: _savePin,
              onAuthenticated: _unlockApp,
            ),
    );
  }

  Future<void> _loadSavedSettings() async {
    setState(() {
      _isLoadingSettings = true;
      _settingsLoadError = null;
    });
    try {
      final values = await Future.wait<Object?>([
        _settingsStore.readPin(),
        _settingsStore.readSheetConfig(),
        _settingsStore.readSheetName(),
        _settingsStore.readLinkedSheets(),
        _settingsStore.readThemeMode(),
        _settingsStore.readBiometricEnabled(),
      ]);
      if (!mounted) return;
      final savedPin = values[0] as String?;
      final savedSheetConfig = values[1] as String;
      final linkedSheets = values[3] as List<LinkedSheet>;
      final savedSheetName = values[2] as String;
      final biometricEnabled = values[5] as bool;
      setState(() {
        _pin = savedPin;
        _isFirstTime = savedPin == null;
        _sheetConfig = savedSheetConfig;
        _sheetName = savedSheetName.isNotEmpty
            ? savedSheetName
            : linkedSheets
                      .where((sheet) => sheet.url == savedSheetConfig)
                      .firstOrNull
                      ?.name ??
                  '';
        _linkedSheets = linkedSheets;
        _themeMode = values[4] as ThemeMode;
        _biometricEnabled = biometricEnabled;
        _isLoadingSettings = false;
      });
      // Auto-trigger biometric on startup if enabled and PIN is set.
      if (biometricEnabled && savedPin != null) {
        unawaited(_tryBiometricLogin());
      }
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _settingsLoadError = error;
        _isLoadingSettings = false;
      });
    }
  }

  Future<bool> _tryBiometricLogin() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      if (!canCheck && !isDeviceSupported) {
        debugPrint('Device does not support biometric check');
        return false;
      }
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Scan your fingerprint to log in to LeadPilot',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      if (authenticated && mounted) {
        _unlockApp();
        return true;
      }
      return false;
    } on PlatformException catch (error) {
      debugPrint('Biometric authentication failed: $error');
      return false;
    } catch (error) {
      debugPrint('Unexpected biometric error: $error');
      return false;
    }
  }

  Future<void> _savePin(String pin) async {
    await _settingsStore.savePin(pin);
    if (!mounted) return;
    setState(() {
      _pin = pin;
      _isFirstTime = false;
      _isAuthenticated = true;
    });
  }

  void _unlockApp() {
    setState(() => _isAuthenticated = true);
  }

  void _lockApp() {
    setState(() => _isAuthenticated = false);
  }

  Future<void> _saveBiometricEnabled(bool enabled) async {
    await _settingsStore.saveBiometricEnabled(enabled);
    if (!mounted) return;
    setState(() => _biometricEnabled = enabled);
  }

  Future<void> _saveSheetConfig(LinkedSheet config) async {
    await _settingsStore.saveSheetConfig(config.url, name: config.name);
    final linkedSheets = await _settingsStore.readLinkedSheets();
    if (!mounted) return;
    setState(() {
      _sheetConfig = config.url;
      _sheetName = config.name;
      _linkedSheets = linkedSheets;
    });
  }

  Future<void> _saveThemeMode(ThemeMode mode) async {
    await _settingsStore.saveThemeMode(mode);
    if (!mounted) return;
    setState(() => _themeMode = mode);
  }
}

class _AppStartupScreen extends StatelessWidget {
  const _AppStartupScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: CircularProgressIndicator(color: _green)),
  );
}

class _SettingsLoadErrorScreen extends StatelessWidget {
  const _SettingsLoadErrorScreen({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline_rounded, color: _navy, size: 40),
            const SizedBox(height: 14),
            const Text(
              'Could not load secure app settings',
              style: TextStyle(
                color: _navy,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            ElevatedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    ),
  );
}

class PinScreen extends StatefulWidget {
  const PinScreen({
    required this.isFirstTime,
    required this.storedPin,
    required this.onPinCreated,
    required this.onAuthenticated,
    this.biometricEnabled = false,
    this.onBiometricAuth,
    super.key,
  });

  final bool isFirstTime;
  final String? storedPin;
  final Future<void> Function(String) onPinCreated;
  final VoidCallback onAuthenticated;
  final bool biometricEnabled;
  final Future<bool> Function()? onBiometricAuth;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _enteredPin = '';
  String? _setupPin;
  String? _message;
  bool _hasError = false;
  bool _showSuccess = false;
  bool _isSavingPin = false;
  // Fingerprint: how many times biometric failed — after 3 show PIN only.
  int _biometricFailCount = 0;
  bool _biometricRunning = false;

  static const _maxBiometricAttempts = 3;

  bool get _showBiometricButton =>
      widget.biometricEnabled &&
      !widget.isFirstTime &&
      _biometricFailCount < _maxBiometricAttempts;

  @override
  void initState() {
    super.initState();
    // Auto-trigger biometric prompt when screen appears (if enabled).
    if (widget.biometricEnabled && !widget.isFirstTime) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _doBiometricAuth();
      });
    }
  }

  Future<void> _doBiometricAuth() async {
    if (_biometricRunning || widget.onBiometricAuth == null) return;
    setState(() => _biometricRunning = true);
    try {
      final success = await widget.onBiometricAuth!();
      if (!mounted) return;
      if (!success) {
        setState(() {
          _biometricFailCount++;
          _biometricRunning = false;
          if (_biometricFailCount >= _maxBiometricAttempts) {
            _message = 'Fingerprint failed 3 times. Enter your PIN.';
            _hasError = true;
          } else {
            _message =
                'Fingerprint not recognised. '
                '${_maxBiometricAttempts - _biometricFailCount} tries left.';
            _hasError = true;
          }
        });
        return;
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _biometricFailCount++;
          _biometricRunning = false;
          if (_biometricFailCount >= _maxBiometricAttempts) {
            _message = 'Fingerprint failed 3 times. Enter your PIN.';
            _hasError = true;
          } else {
            _message = 'Could not read fingerprint. Try again or enter PIN.';
            _hasError = true;
          }
        });
      }
      return;
    }
    if (mounted) setState(() => _biometricRunning = false);
  }

  String get _heading {
    if (!widget.isFirstTime) {
      return _showBiometricButton
          ? 'Welcome Back'
          : 'Welcome Back - Enter PIN';
    }
    return _setupPin == null ? 'Create Your 4-Digit PIN' : 'Confirm Your PIN';
  }

  String get _subtitle {
    if (!widget.isFirstTime) {
      return _showBiometricButton
          ? 'Use fingerprint or enter your PIN.'
          : 'Enter your PIN to access your directory.';
    }
    return _setupPin == null
        ? 'Set up a secure PIN to protect your student directory.'
        : 'Enter your new PIN once more to confirm.';
  }

  void _addDigit(String digit) {
    if (_enteredPin.length == 4 || _isSavingPin) return;
    setState(() {
      _enteredPin += digit;
      _message = null;
      _hasError = false;
      _showSuccess = false;
    });
    if (_enteredPin.length == 4) unawaited(_submitPin());
  }

  Future<void> _submitPin() async {
    if (widget.isFirstTime) {
      if (_setupPin == null) {
        setState(() {
          _setupPin = _enteredPin;
          _enteredPin = '';
          _message = 'PIN saved. Enter it again to confirm.';
          _showSuccess = true;
        });
        return;
      }

      if (_enteredPin != _setupPin) {
        _showPinError('PINs do not match. Please try again.');
        return;
      }

      setState(() {
        _isSavingPin = true;
        _message = 'Saving your PIN securely…';
      });
      try {
        await widget.onPinCreated(_enteredPin);
      } on Exception catch (error) {
        if (mounted) _showPinError('Could not save your PIN: $error');
      } finally {
        if (mounted) setState(() => _isSavingPin = false);
      }
      return;
    }

    if (_enteredPin != widget.storedPin) {
      _showPinError('That PIN isn’t correct. Please try again.');
      return;
    }

    widget.onAuthenticated();
  }

  void _showPinError(String message) {
    setState(() {
      _enteredPin = '';
      _message = message;
      _hasError = true;
      _showSuccess = false;
    });
  }

  void _deleteDigit() {
    if (_enteredPin.isEmpty || _isSavingPin) return;
    setState(() {
      _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
      _message = null;
      _hasError = false;
      _showSuccess = false;
    });
  }

  void _clearPin() {
    if (_enteredPin.isEmpty || _isSavingPin) return;
    setState(() {
      _enteredPin = '';
      _message = null;
      _hasError = false;
      _showSuccess = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFEAF1F8), Color(0xFFF7FAFC), Color(0xFFEAF5F1)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 390),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const _BrandHeader(),
                        const SizedBox(height: 32),
                        Card(
                          elevation: 8,
                          shadowColor: _navy.withValues(alpha: 0.09),
                          color: Colors.white.withValues(alpha: 0.94),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
                            child: Column(
                              children: [
                                Text(
                                  _heading,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(
                                        color: _navy,
                                        fontWeight: FontWeight.w800,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _subtitle,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: _muted,
                                    height: 1.4,
                                  ),
                                ),
                                const SizedBox(height: 26),
                                _PinIndicators(
                                  count: _enteredPin.length,
                                  hasError: _hasError,
                                  showSuccess: _showSuccess,
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  height: 22,
                                  child: Text(
                                    _message ?? ' ',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _hasError
                                          ? const Color(0xFFC94343)
                                          : _green,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _PinKeypad(
                                  onDigit: _addDigit,
                                  onClear: _clearPin,
                                  onBackspace: _deleteDigit,
                                ),
                                // 🔑 Fingerprint button — shown when biometric
                                // is enabled and hasn't failed 3 times yet.
                                if (_showBiometricButton) ...[
                                  const SizedBox(height: 18),
                                  TextButton.icon(
                                    onPressed: _biometricRunning
                                        ? null
                                        : _doBiometricAuth,
                                    icon: _biometricRunning
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: _green,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.fingerprint_rounded,
                                            size: 28,
                                            color: _green,
                                          ),
                                    label: Text(
                                      _biometricRunning
                                          ? 'Scanning…'
                                          : 'Use Fingerprint',
                                      style: const TextStyle(
                                        color: _green,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        const Text(
                          'Your student directory, protected.',
                          style: TextStyle(color: _muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinIndicators extends StatelessWidget {
  const _PinIndicators({
    required this.count,
    required this.hasError,
    required this.showSuccess,
  });

  final int count;
  final bool hasError;
  final bool showSuccess;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final isFilled = index < count;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 48,
          height: 54,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: isFilled ? const Color(0xFFE9F6F1) : const Color(0xFFF7F9FB),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: hasError
                  ? const Color(0xFFC94343)
                  : isFilled || showSuccess
                  ? _green
                  : const Color(0xFFE4EAF0),
              width: isFilled || showSuccess ? 1.5 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: isFilled ? 11 : 9,
            width: isFilled ? 11 : 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isFilled || showSuccess ? _green : const Color(0xFFD8E0E8),
            ),
          ),
        );
      }),
    );
  }
}

class _PinKeypad extends StatelessWidget {
  const _PinKeypad({
    required this.onDigit,
    required this.onClear,
    required this.onBackspace,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onClear;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    final keys = <Widget>[
      for (var digit = 1; digit <= 9; digit++)
        _DigitKey(label: '$digit', onPressed: () => onDigit('$digit')),
      _UtilityKey(label: 'Clear', onPressed: onClear),
      _DigitKey(label: '0', onPressed: () => onDigit('0')),
      _UtilityKey(
        icon: Icons.backspace_outlined,
        label: 'Delete',
        onPressed: onBackspace,
      ),
    ];

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 12,
      childAspectRatio: 1.42,
      children: keys,
    );
  }
}

class _DigitKey extends StatelessWidget {
  const _DigitKey({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF5F8FA),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onPressed,
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: _navy,
              fontSize: 23,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _UtilityKey extends StatelessWidget {
  const _UtilityKey({required this.label, required this.onPressed, this.icon});

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: _muted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: icon == null
          ? Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            )
          : Icon(icon, size: 21, semanticLabel: label),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 72,
          width: 72,
          decoration: BoxDecoration(
            color: _navy,
            borderRadius: BorderRadius.circular(23),
            boxShadow: [
              BoxShadow(
                color: _navy.withValues(alpha: 0.18),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Icon(
            Icons.school_rounded,
            color: Colors.white,
            size: 36,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'LeadPilot',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: _navy,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }
}

class CallAttempt {
  const CallAttempt({
    required this.dateTime,
    required this.status,
    required this.comment,
  });

  final String dateTime;
  final String status;
  final String comment;

  factory CallAttempt.fromJson(Map<String, dynamic> json) {
    final dateTime = json['dateTime']?.toString() ?? '';
    final status = json['status']?.toString() ?? '';
    if (dateTime.isEmpty || status.isEmpty) {
      throw const FormatException(
        'Each call attempt must include a timestamp and status.',
      );
    }
    return CallAttempt(
      dateTime: dateTime,
      status: status,
      comment: json['comment']?.toString() ?? '',
    );
  }

  Map<String, String> toJson() => {
    'dateTime': dateTime,
    'status': status,
    'comment': comment,
  };
}

class Student {
  const Student({
    required this.name,
    required this.phone,
    this.source = '',
    this.addedDate = '',
    this.location = '',
    this.examType = '',
    this.examYear = '',
    this.olEnglish = '',
    this.olMaths = '',
    this.whatsappNumber = '',
    this.whatsappSameAsContact = false,
    this.callStatus = 'Pending',
    this.nextCallDateTime = '',
    this.comment = '',
    this.commentHistory = const [],
    this.attempts = const [],
    this.note = '',
  });

  final String name;
  final String phone;
  final String source;
  final String addedDate;
  final String location;
  final String examType;
  final String examYear;
  final String olEnglish;
  final String olMaths;
  final String whatsappNumber;
  final bool whatsappSameAsContact;
  final String callStatus;
  final String nextCallDateTime;
  final String comment;
  final List<String> commentHistory;
  final List<CallAttempt> attempts;
  final String note;

  factory Student.fromJson(Map<String, dynamic> json) {
    final name = json['name']?.toString().trim() ?? '';
    final phone = (json['contact'] ?? json['phone'])?.toString().trim() ?? '';
    if (name.isEmpty || phone.isEmpty) {
      throw const FormatException(
        'Each student must include a non-empty name and contact.',
      );
    }
    return Student(
      name: name,
      phone: phone,
      source: json['source']?.toString() ?? '',
      addedDate: (json['addedDate'] ?? json['date'])?.toString() ?? '',
      location: json['location']?.toString() ?? '',
      examType: json['examType']?.toString() ?? '',
      examYear: (json['examYear'] ?? json['age'])?.toString() ?? '',
      olEnglish: json['olEnglish']?.toString() ?? '',
      olMaths: json['olMaths']?.toString() ?? '',
      whatsappNumber: json['whatsappNumber']?.toString() ?? '',
      whatsappSameAsContact:
          json['whatsappSameAsContact'] == true ||
          json['whatsappSameAsContact']?.toString().toLowerCase() == 'true',
      callStatus: json['callStatus']?.toString() ?? 'Pending',
      nextCallDateTime: json['nextCallDateTime']?.toString() ?? '',
      comment: json['comment']?.toString() ?? '',
      commentHistory: json['commentHistory'] is List
          ? (json['commentHistory'] as List)
                .map((item) => item.toString())
                .toList()
          : const [],
      attempts: json['attempts'] is List
          ? (json['attempts'] as List).map((item) {
              if (item is! Map<String, dynamic>) {
                throw const FormatException(
                  'Call attempt records must be JSON objects.',
                );
              }
              return CallAttempt.fromJson(item);
            }).toList()
          : const [],
    );
  }

  Student copyWith({
    String? name,
    String? phone,
    String? location,
    String? examType,
    String? examYear,
    String? olEnglish,
    String? olMaths,
    String? whatsappNumber,
    bool? whatsappSameAsContact,
    String? callStatus,
    String? nextCallDateTime,
    String? comment,
    List<String>? commentHistory,
    List<CallAttempt>? attempts,
  }) {
    return Student(
      name: name ?? this.name,
      phone: phone ?? this.phone,
      source: source,
      addedDate: addedDate,
      location: location ?? this.location,
      examType: examType ?? this.examType,
      examYear: examYear ?? this.examYear,
      olEnglish: olEnglish ?? this.olEnglish,
      olMaths: olMaths ?? this.olMaths,
      whatsappNumber: whatsappNumber ?? this.whatsappNumber,
      whatsappSameAsContact:
          whatsappSameAsContact ?? this.whatsappSameAsContact,
      callStatus: callStatus ?? this.callStatus,
      nextCallDateTime: nextCallDateTime ?? this.nextCallDateTime,
      comment: comment ?? this.comment,
      commentHistory: commentHistory ?? this.commentHistory,
      attempts: attempts ?? this.attempts,
      note: note,
    );
  }

  String get initials => name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .take(2)
      .map((part) => part[0].toUpperCase())
      .join();

  Map<String, dynamic> toJson() => {
    'name': name,
    'contact': phone,
    'source': source,
    'addedDate': addedDate,
    'location': location,
    'examType': examType,
    'examYear': examYear,
    'olEnglish': olEnglish,
    'olMaths': olMaths,
    'whatsappNumber': whatsappNumber,
    'whatsappSameAsContact': whatsappSameAsContact,
    'callStatus': callStatus,
    'nextCallDateTime': nextCallDateTime,
    'comment': comment,
    'commentHistory': commentHistory,
    'attempts': attempts.map((attempt) => attempt.toJson()).toList(),
    'note': note,
  };
}

class QueuedSheetAction {
  const QueuedSheetAction({
    required this.id,
    required this.action,
    required this.student,
    this.previousPhone,
    required this.queuedAt,
  });

  final String id;
  final String action;
  final Student student;
  final String? previousPhone;
  final DateTime queuedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'action': action,
    'student': student.toJson(),
    'previousPhone': previousPhone,
    'queuedAt': queuedAt.toIso8601String(),
  };

  factory QueuedSheetAction.fromJson(Map<String, dynamic> json) {
    return QueuedSheetAction(
      id: json['id']?.toString() ?? '',
      action: json['action']?.toString() ?? 'update',
      student: Student.fromJson(json['student'] as Map<String, dynamic>),
      previousPhone: json['previousPhone']?.toString(),
      queuedAt: DateTime.tryParse(json['queuedAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

String _formatReminder(DateTime dateTime) {
  final hour = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
  final minute = dateTime.minute.toString().padLeft(2, '0');
  final meridiem = dateTime.hour < 12 ? 'AM' : 'PM';
  return '${dateTime.year.toString().padLeft(4, '0')}-'
      '${dateTime.month.toString().padLeft(2, '0')}-'
      '${dateTime.day.toString().padLeft(2, '0')} '
      '${hour.toString().padLeft(2, '0')}:$minute $meridiem';
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _formatFilterDate(DateTime? date) {
  if (date == null) return 'Any date';
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

String studentsToCsv(List<Student> students) {
  const headers = [
    'Name',
    'Contact',
    'Source',
    'Added Date',
    'Exam Type',
    'Exam Year',
    'Location',
    'O/L English',
    'O/L Maths',
    'WhatsApp Number',
    'Call Status',
    'Next Call Date & Time',
    'Latest Comment',
    'Comment History',
    'Call Attempts',
  ];

  String cell(Object? value) =>
      '"${(value?.toString() ?? '').replaceAll('"', '""')}"';

  final rows = <List<String>>[
    headers,
    for (final student in students)
      [
        student.name,
        student.phone,
        student.source,
        student.addedDate,
        student.examType,
        student.examYear,
        student.location,
        student.olEnglish,
        student.olMaths,
        student.whatsappNumber,
        student.callStatus,
        student.nextCallDateTime,
        student.comment,
        student.commentHistory.join('\n'),
        student.attempts
            .map(
              (attempt) =>
                  '${attempt.dateTime} | ${attempt.status} | ${attempt.comment}',
            )
            .join('\n'),
      ],
  ];
  return '${rows.map((row) => row.map(cell).join(',')).join('\r\n')}\r\n';
}

enum _LeadFilter { all, newLeads, todayFollowUp }

class _LeadFilterSelection {
  const _LeadFilterSelection({this.callStatus, this.dateFrom, this.dateTo});

  final String? callStatus;
  final DateTime? dateFrom;
  final DateTime? dateTo;
}

enum _SettingsAction {
  sheetSync,
  filters,
  export,
  reports,
  saveContacts,
  whatsAppTemplates,
}

enum _StudentCardAction { edit, selectMultiple }

enum _LeadReportAction { notInterested, notPotential, inactive }

class SheetApiException implements Exception {
  const SheetApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GoogleSheetService {
  GoogleSheetService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  static const _timeout = Duration(seconds: 20);

  Future<List<Student>> fetchStudentsFromSheet(String webAppUrl) async {
    final response = await _client
        .get(
          _endpoint(webAppUrl),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SheetApiException(
        'Sheet request failed with HTTP ${response.statusCode}.',
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const SheetApiException(
        'The web app returned invalid JSON. Return a JSON list of students.',
      );
    }

    final dynamic rows;
    if (decoded is List<dynamic>) {
      rows = decoded;
    } else if (decoded is Map<String, dynamic>) {
      rows = decoded['students'] ?? decoded['data'];
    } else {
      rows = null;
    }

    if (rows is! List<dynamic>) {
      throw const SheetApiException(
        'Expected a JSON list or an object containing a "students" list.',
      );
    }

    return rows.map((row) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('Student rows must be JSON objects.');
      }
      return Student.fromJson(row);
    }).toList();
  }

  Future<void> addStudentToSheet(String webAppUrl, Student student) =>
      _sendStudent(webAppUrl, student, action: 'add');

  Future<void> updateStudentInSheet(
    String webAppUrl,
    Student student, {
    String? previousPhone,
  }) => _sendStudent(
    webAppUrl,
    student,
    action: 'update',
    previousContact: previousPhone ?? student.phone,
  );

  Future<void> _sendStudent(
    String webAppUrl,
    Student student, {
    required String action,
    String? previousContact,
  }) async {
    final response = await _client
        .post(
          _endpoint(webAppUrl),
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'text/plain; charset=utf-8',
          },
          body: jsonEncode({
            'action': action,
            'name': student.name,
            'contact': student.phone,
            if (action == 'update')
              'previousContact': previousContact ?? student.phone,
            'source': student.source,
            'addedDate': student.addedDate,
            'location': student.location,
            'examType': student.examType,
            'examYear': student.examYear,
            'olEnglish': student.olEnglish,
            'olMaths': student.olMaths,
            'whatsappNumber': student.whatsappNumber,
            'whatsappSameAsContact': student.whatsappSameAsContact,
            'callStatus': student.callStatus,
            'nextCallDateTime': student.nextCallDateTime,
            'comment': student.comment,
            'commentHistory': student.commentHistory,
            'attempts': student.attempts
                .map((attempt) => attempt.toJson())
                .toList(),
            if (student.attempts.isNotEmpty)
              'latestAttempt': student.attempts.last.toJson(),
          }),
        )
        .timeout(_timeout);
    final redirectLocation = Uri.tryParse(response.headers['location'] ?? '');
    final redirectHost = redirectLocation?.host.toLowerCase() ?? '';
    final isAppsScriptContentRedirect =
        (response.statusCode == 302 ||
            response.statusCode == 303 ||
            response.statusCode == 307) &&
        (redirectHost == 'script.googleusercontent.com' ||
            redirectHost.endsWith('.googleusercontent.com') ||
            redirectHost.endsWith('google.com'));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Apps Script executes doPost before redirecting ContentService output.
      if (isAppsScriptContentRedirect) return;
      throw SheetApiException(
        'Could not ${action == 'add' ? 'add' : 'update'} the student in the sheet '
        '(HTTP ${response.statusCode}).',
      );
    }

    final body = response.body.trim();
    if (body.startsWith('{')) {
      final dynamic result;
      try {
        result = jsonDecode(body);
      } on FormatException {
        throw const SheetApiException(
          'The web app returned invalid JSON after saving the student.',
        );
      }
      if (result is Map<String, dynamic> && result['success'] == false) {
        throw SheetApiException(
          result['error']?.toString() ??
              'The sheet rejected the student ${action == 'add' ? 'addition' : 'update'}.',
        );
      }
    }
  }

  Uri _endpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !uri.path.endsWith('/exec')) {
      throw const SheetApiException(
        'Enter a valid HTTPS Google Apps Script Web App URL ending in /exec.',
      );
    }
    return uri;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.sheetConfig,
    required this.sheetName,
    required this.linkedSheets,
    required this.sheetService,
    required this.reminderScheduler,
    required this.deviceContactsService,
    required this.themeMode,
    required this.onLogout,
    required this.onSaveSheetConfig,
    required this.onThemeModeChanged,
    required this.biometricEnabled,
    required this.onBiometricChanged,
    this.settingsStore,
    super.key,
  });

  final String sheetConfig;
  final String sheetName;
  final List<LinkedSheet> linkedSheets;
  final GoogleSheetService sheetService;
  final ReminderScheduler reminderScheduler;
  final DeviceContactsService deviceContactsService;
  final ThemeMode themeMode;
  final VoidCallback onLogout;
  final Future<void> Function(LinkedSheet) onSaveSheetConfig;
  final Future<void> Function(ThemeMode) onThemeModeChanged;
  final bool biometricEnabled;
  final Future<void> Function(bool) onBiometricChanged;
  final AppSettingsStore? settingsStore;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchController = TextEditingController();
  final List<Student> _students = [];
  final Set<String> _selectedStudentKeys = {};
  late final AppSettingsStore _settingsStore =
      widget.settingsStore ?? SecureAppSettingsStore();

  List<QueuedSheetAction> _offlineQueue = [];
  Timer? _offlineQueueRetryTimer;
  bool _isFlushingQueue = false;

  String _query = '';
  _LeadFilter _leadFilter = _LeadFilter.all;
  String _syncStatus = 'Not connected';
  bool _isSyncing = false;
  bool _hasSynced = false;
  int _syncGeneration = 0;
  String? _lastSyncTime;
  String? _statusFilter;
  DateTime? _dateFrom;
  DateTime? _dateTo;
  bool _isSelectionMode = false;

  @override
  void initState() {
    super.initState();
    _loadInitialOfflineData();
  }

  Future<void> _loadInitialOfflineData() async {
    try {
      final cached = await _settingsStore.readCachedStudents();
      final queue = await _settingsStore.readOfflineQueue();
      if (!mounted) return;
      setState(() {
        _offlineQueue = queue;
        if (cached.isNotEmpty) {
          final merged = <String, Student>{
            for (final s in cached) _studentKey(s): s,
          };
          for (final q in queue) {
            merged[_studentKey(q.student)] = q.student;
          }
          _students
            ..clear()
            ..addAll(merged.values);
        }
        if (queue.isNotEmpty) {
          _syncStatus = '${queue.length} offline change(s) queued';
        }
      });
      if (queue.isNotEmpty) {
        _startOfflineQueueTimer();
      }
      if (_students.isNotEmpty) {
        unawaited(CallerIdService.syncStudents(_students));
      }
    } catch (_) {}

    if (widget.sheetConfig.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncWithGoogleSheet();
      });
    }
  }

  @override
  void dispose() {
    _offlineQueueRetryTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _startOfflineQueueTimer() {
    _offlineQueueRetryTimer?.cancel();
    _offlineQueueRetryTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) {
        if (mounted && _offlineQueue.isNotEmpty && !_isSyncing) {
          _flushOfflineQueue();
        }
      },
    );
  }

  void _stopOfflineQueueTimer() {
    _offlineQueueRetryTimer?.cancel();
    _offlineQueueRetryTimer = null;
  }

  Future<void> _enqueueOfflineAction(QueuedSheetAction action) async {
    final phoneKey = normalizeContactPhone(action.student.phone);
    final previousPhoneKey = action.previousPhone != null
        ? normalizeContactPhone(action.previousPhone!)
        : null;

    final existingIndex = _offlineQueue.indexWhere((item) {
      final itemPhone = normalizeContactPhone(item.student.phone);
      return itemPhone == phoneKey ||
          (previousPhoneKey != null && itemPhone == previousPhoneKey);
    });

    if (existingIndex >= 0) {
      final existing = _offlineQueue[existingIndex];
      final preservedAction = existing.action == 'add' ? 'add' : action.action;
      _offlineQueue[existingIndex] = QueuedSheetAction(
        id: existing.id,
        action: preservedAction,
        student: action.student,
        previousPhone: existing.previousPhone ?? action.previousPhone,
        queuedAt: DateTime.now(),
      );
    } else {
      _offlineQueue.add(action);
    }

    await _settingsStore.saveOfflineQueue(_offlineQueue);
    await _settingsStore.saveCachedStudents(_students);
    _startOfflineQueueTimer();

    if (mounted) {
      setState(() {
        _syncStatus = '${_offlineQueue.length} offline change(s) queued';
      });
    }
  }

  Future<int> _flushOfflineQueue() async {
    if (_isFlushingQueue ||
        _offlineQueue.isEmpty ||
        widget.sheetConfig.isEmpty) {
      return 0;
    }
    _isFlushingQueue = true;
    var syncedCount = 0;
    final remainingQueue = List<QueuedSheetAction>.of(_offlineQueue);

    for (final item in _offlineQueue) {
      try {
        if (item.action == 'add') {
          await widget.sheetService.addStudentToSheet(
            widget.sheetConfig,
            item.student,
          );
        } else {
          await widget.sheetService.updateStudentInSheet(
            widget.sheetConfig,
            item.student,
            previousPhone: item.previousPhone,
          );
        }
        remainingQueue.remove(item);
        syncedCount++;
      } catch (_) {
        // Network still unavailable or rejected; break out so we retry later
        break;
      }
    }

    _offlineQueue = remainingQueue;
    await _settingsStore.saveOfflineQueue(_offlineQueue);
    _isFlushingQueue = false;

    if (syncedCount > 0 && mounted) {
      setState(() {
        if (_offlineQueue.isEmpty) {
          _stopOfflineQueueTimer();
          _syncStatus =
              'All offline changes synced! · ${_formattedSyncTime()}';
        } else {
          _syncStatus = '${_offlineQueue.length} offline change(s) queued';
        }
      });
      await _settingsStore.saveCachedStudents(_students);
    }
    return syncedCount;
  }

  List<Student> get _filteredStudents {
    final query = _query.trim().toLowerCase();
    final statusFilter = _statusFilter?.trim().toLowerCase();
    final filtered = _students
        .where(
          (student) =>
              (!isFinalLeadStatus(student.callStatus) ||
                  (statusFilter != null &&
                      statusFilter ==
                          student.callStatus.trim().toLowerCase())) &&
              _matchesLeadFilter(student) &&
              (query.isEmpty || _matchesSearch(student, query)),
        )
        .toList();
    filtered.sort(
      _leadFilter == _LeadFilter.todayFollowUp
          ? _compareStudentsByFollowUpDate
          : _compareStudentsByNewestDate,
    );
    return filtered;
  }

  List<Student> get _selectedStudents => _students
      .where(
        (student) =>
            !isFinalLeadStatus(student.callStatus) &&
            _selectedStudentKeys.contains(_selectionKey(student)),
      )
      .toList();

  String _selectionKey(Student student) {
    final phone = normalizeContactPhone(student.phone);
    return phone.isEmpty ? student.name.trim().toLowerCase() : phone;
  }

  void _startSelection(Student student) {
    setState(() {
      _isSelectionMode = true;
      _selectedStudentKeys.add(_selectionKey(student));
    });
  }

  void _toggleStudentSelection(Student student) {
    final key = _selectionKey(student);
    setState(() {
      if (_selectedStudentKeys.contains(key)) {
        _selectedStudentKeys.remove(key);
        if (_selectedStudentKeys.isEmpty) _isSelectionMode = false;
      } else {
        _isSelectionMode = true;
        _selectedStudentKeys.add(key);
      }
    });
  }

  void _clearStudentSelection() {
    setState(() {
      _isSelectionMode = false;
      _selectedStudentKeys.clear();
    });
  }

  int _compareStudentsByFollowUpDate(Student left, Student right) {
    final leftDate = DateTime.tryParse(left.nextCallDateTime);
    final rightDate = DateTime.tryParse(right.nextCallDateTime);
    if (leftDate == null || rightDate == null) {
      if (leftDate == null && rightDate != null) return 1;
      if (rightDate == null && leftDate != null) return -1;
      return _students.indexOf(left).compareTo(_students.indexOf(right));
    }
    final dateComparison = leftDate.compareTo(rightDate);
    return dateComparison != 0
        ? dateComparison
        : _students.indexOf(left).compareTo(_students.indexOf(right));
  }

  int _compareStudentsByNewestDate(Student left, Student right) {
    final leftDate = DateTime.tryParse(left.addedDate);
    final rightDate = DateTime.tryParse(right.addedDate);
    if (leftDate == null || rightDate == null) {
      if (leftDate == null && rightDate != null) return 1;
      if (rightDate == null && leftDate != null) return -1;
      return _students.indexOf(left).compareTo(_students.indexOf(right));
    }
    final dateComparison = rightDate.compareTo(leftDate);
    return dateComparison != 0
        ? dateComparison
        : _students.indexOf(left).compareTo(_students.indexOf(right));
  }

  bool _matchesLeadFilter(Student student) {
    final normalizedStatus = student.callStatus.trim().toLowerCase();
    if (_statusFilter != null &&
        normalizedStatus != _statusFilter!.toLowerCase()) {
      return false;
    }

    final from = _dateFrom;
    final to = _dateTo;
    if (from != null || to != null) {
      final addedDate = DateTime.tryParse(student.addedDate);
      if (addedDate == null) return false;
      final day = DateTime(addedDate.year, addedDate.month, addedDate.day);
      if (from != null && day.isBefore(_dateOnly(from))) return false;
      if (to != null && day.isAfter(_dateOnly(to))) return false;
    }

    switch (_leadFilter) {
      case _LeadFilter.all:
        return true;
      case _LeadFilter.newLeads:
        return student.callStatus.trim().toLowerCase() == 'pending';
      case _LeadFilter.todayFollowUp:
        final nextCall = DateTime.tryParse(student.nextCallDateTime);
        final today = DateTime.now();
        if (nextCall == null ||
            !nextCall.isBefore(
              DateTime(today.year, today.month, today.day + 1),
            )) {
          return false;
        }
        return !student.attempts.any((attempt) {
          final attemptedAt = DateTime.tryParse(attempt.dateTime);
          return attemptedAt != null && !attemptedAt.isBefore(nextCall);
        });
    }
  }

  bool _matchesSearch(Student student, String query) {
    final searchableText = <String>[
      student.name,
      student.phone,
      student.location,
      student.callStatus,
      student.comment,
      ...student.commentHistory,
      ...student.attempts.expand(
        (attempt) => [attempt.status, attempt.comment],
      ),
    ];
    return searchableText.any((value) => value.toLowerCase().contains(query));
  }

  Future<void> _addStudent() async {
    final entries = await showModalBottomSheet<List<Student>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddStudentSheet(),
    );
    if (entries == null || entries.isEmpty || !mounted) return;

    setState(() => _students.insertAll(0, entries));
    if (widget.sheetConfig.isEmpty) {
      _showMessage(
        '${entries.length} student(s) saved locally. Configure the Google Sheet URL to sync.',
      );
      return;
    }

    setState(() {
      _isSyncing = true;
      _syncStatus = 'Sending students…';
    });

    final failures = <String>[];
    for (final student in entries) {
      try {
        await widget.sheetService.addStudentToSheet(
          widget.sheetConfig,
          student,
        );
      } on SheetApiException catch (error) {
        failures.add('${student.name}: ${error.message}');
        await _enqueueOfflineAction(
          QueuedSheetAction(
            id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
            action: 'add',
            student: student,
            queuedAt: DateTime.now(),
          ),
        );
      } on http.ClientException catch (error) {
        failures.add('${student.name}: network error (${error.message})');
        await _enqueueOfflineAction(
          QueuedSheetAction(
            id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
            action: 'add',
            student: student,
            queuedAt: DateTime.now(),
          ),
        );
      } on TimeoutException {
        failures.add('${student.name}: request timed out');
        await _enqueueOfflineAction(
          QueuedSheetAction(
            id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
            action: 'add',
            student: student,
            queuedAt: DateTime.now(),
          ),
        );
      } on FormatException catch (error) {
        failures.add('${student.name}: ${error.message}');
        await _enqueueOfflineAction(
          QueuedSheetAction(
            id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
            action: 'add',
            student: student,
            queuedAt: DateTime.now(),
          ),
        );
      } on Exception catch (error) {
        failures.add('${student.name}: $error');
        await _enqueueOfflineAction(
          QueuedSheetAction(
            id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
            action: 'add',
            student: student,
            queuedAt: DateTime.now(),
          ),
        );
      }
    }
    await _settingsStore.saveCachedStudents(_students);

    if (!mounted) return;
    if (failures.isEmpty) {
      setState(() {
        _isSyncing = false;
        _hasSynced = true;
        _lastSyncTime = _formattedSyncTime();
        _syncStatus = 'Synced · $_lastSyncTime';
      });
      _showMessage('Student(s) saved and synced to Google Sheet!');
    } else {
      setState(() {
        _isSyncing = false;
        _hasSynced = false;
        _syncStatus = 'Sync failed';
      });
      _showMessage(
        '${failures.length} of ${entries.length} student(s) could not be synced. '
        'They remain in the local list. ${failures.join(' • ')}',
      );
    }
  }

  Future<void> _editStudent(Student student) async {
    final updatedStudent = await showModalBottomSheet<Student>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditStudentSheet(student: student),
    );
    if (updatedStudent == null || !mounted) return;

    final index = _students.indexOf(student);
    if (index < 0) return;
    setState(() {
      _students[index] = updatedStudent;
    });

    await _updateStudentReminder(student, updatedStudent);
    if (!mounted) return;

    if (widget.sheetConfig.isEmpty) {
      _showMessage('Student details updated on this device.');
      await _settingsStore.saveCachedStudents(_students);
      return;
    }

    setState(() {
      _isSyncing = true;
      _syncStatus = 'Updating student…';
    });
    try {
      await widget.sheetService.updateStudentInSheet(
        widget.sheetConfig,
        updatedStudent,
        previousPhone: student.phone,
      );
      if (!mounted) return;
      _offlineQueue.removeWhere((item) =>
          normalizeContactPhone(item.student.phone) ==
          normalizeContactPhone(student.phone));
      await _settingsStore.saveOfflineQueue(_offlineQueue);
      await _settingsStore.saveCachedStudents(_students);

      setState(() {
        _isSyncing = false;
        _hasSynced = true;
        _lastSyncTime = _formattedSyncTime();
        if (_offlineQueue.isEmpty) {
          _syncStatus = 'Synced · $_lastSyncTime';
        } else {
          _syncStatus = '${_offlineQueue.length} offline change(s) queued';
        }
      });
      _showMessage('Student details updated and synced to Google Sheets.');
    } catch (error) {
      if (!mounted) return;
      await _enqueueOfflineAction(
        QueuedSheetAction(
          id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
          action: 'update',
          student: updatedStudent,
          previousPhone: student.phone,
          queuedAt: DateTime.now(),
        ),
      );
      setState(() {
        _isSyncing = false;
        _hasSynced = false;
        _syncStatus = 'Sync failed';
      });
      _showMessage(
        'Details updated locally, but could not be synced. $error',
      );
    } finally {
      if (mounted && _isSyncing) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  Future<void> _updateStudentReminder(
    Student previousStudent,
    Student updatedStudent,
  ) async {
    try {
      final previousCall = DateTime.tryParse(previousStudent.nextCallDateTime);
      final nextCall = DateTime.tryParse(updatedStudent.nextCallDateTime);
      if (nextCall == null) {
        if (previousCall != null) {
          await widget.reminderScheduler.cancelStudentReminder(previousStudent);
        }
      } else {
        if (!await _ensureExactAlarmPermission()) return;
        final contactChanged =
            normalizeContactPhone(previousStudent.phone) !=
            normalizeContactPhone(updatedStudent.phone);
        if (previousCall != null &&
            (previousCall != nextCall || contactChanged)) {
          await widget.reminderScheduler.cancelStudentReminder(previousStudent);
        }
        try {
          await widget.reminderScheduler.scheduleStudentReminder(
            updatedStudent,
            nextCall,
          );
        } on PlatformException catch (error) {
          if (error.code != 'exact_alarms_not_permitted' ||
              !await _ensureExactAlarmPermission(forceRequest: true)) {
            rethrow;
          }
          await widget.reminderScheduler.scheduleStudentReminder(
            updatedStudent,
            nextCall,
          );
        }
      }
    } on StateError catch (error) {
      if (mounted) {
        _showMessage(
          'Student saved, but reminder was not set. ${error.message}',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        _showMessage(
          error.code == 'exact_alarms_not_permitted'
              ? 'Exact alarm access is still off. Allow it in Android Settings, then save the reminder again.'
              : 'Student saved, but Android could not set the reminder (${error.code}).',
        );
      }
    } on Exception catch (error) {
      if (mounted) {
        _showMessage('Student saved, but reminder was not set. $error');
      }
    }
  }

  Future<bool> _ensureExactAlarmPermission({bool forceRequest = false}) async {
    if (!forceRequest &&
        await widget.reminderScheduler.canScheduleExactAlarms()) {
      return true;
    }
    if (!mounted) return false;

    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.alarm_rounded, color: _green),
        title: const Text('Allow exact call reminders'),
        content: const Text(
          'Android requires the “Alarms & reminders” permission to notify you '
          'at the exact time selected. Tap below, then allow this app in the '
          'Android Settings screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (openSettings != true || !mounted) return false;

    final granted = await widget.reminderScheduler
        .requestExactAlarmsPermission();
    if (!granted && mounted) {
      _showMessage(
        'Exact alarm access was not enabled. Allow it in Android Settings and try again.',
      );
    }
    return granted;
  }

  Future<void> _openSettings() async {
    final action = await showModalBottomSheet<_SettingsAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SettingsHubSheet(
        themeMode: widget.themeMode,
        onThemeModeChanged: _changeThemeMode,
        isSheetConnected: widget.sheetConfig.isNotEmpty,
        hasActiveFilters: _hasActiveFilters,
        biometricEnabled: widget.biometricEnabled,
        onBiometricChanged: widget.onBiometricChanged,
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _SettingsAction.sheetSync:
        await _openSheetSyncSettings();
        break;
      case _SettingsAction.filters:
        await _openLeadFilters();
        break;
      case _SettingsAction.export:
        await _exportStudentsToCsv(_filteredStudents);
        break;
      case _SettingsAction.reports:
        await _openLeadReports();
        break;
      case _SettingsAction.saveContacts:
        await _saveVisibleContacts();
        break;
      case _SettingsAction.whatsAppTemplates:
        await _openWhatsAppTemplatesSettings();
        break;
    }
  }

  Future<void> _openWhatsAppTemplatesSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ManageWhatsAppTemplatesSheet(
        settingsStore: _settingsStore,
      ),
    );
  }

  Future<void> _openSheetSyncSettings() async {
    final savedConfig = await showModalBottomSheet<LinkedSheet>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SheetSettingsSheet(
        initialUrl: widget.sheetConfig,
        initialName: widget.sheetName,
        savedSheets: widget.linkedSheets,
        isConnected: _hasSynced,
      ),
    );
    if (savedConfig == null || !mounted) return;

    try {
      await widget.onSaveSheetConfig(savedConfig);
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not save this linked sheet: $error');
      return;
    }
    if (!mounted) return;
    await _syncWithGoogleSheet(url: savedConfig.url);
  }

  Future<void> _openLeadFilters() async {
    final filters = await showModalBottomSheet<_LeadFilterSelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LeadFilterSheet(
        initialStatus: _statusFilter,
        initialDateFrom: _dateFrom,
        initialDateTo: _dateTo,
      ),
    );
    if (filters == null || !mounted) return;
    setState(() {
      _statusFilter = filters.callStatus;
      _dateFrom = filters.dateFrom;
      _dateTo = filters.dateTo;
    });
  }

  Future<void> _openLeadReports() async {
    final action = await showModalBottomSheet<_LeadReportAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LeadReportsSheet(
        notInterestedCount: _students
            .where((student) => isNotInterestedStatus(student.callStatus))
            .length,
        notPotentialCount: _students
            .where((student) => isNotPotentialStatus(student.callStatus))
            .length,
        inactiveCount: _students
            .where((student) => isInactiveStatus(student.callStatus))
            .length,
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case _LeadReportAction.notInterested:
        await _exportStudentsToCsv(
          _students
              .where((student) => isNotInterestedStatus(student.callStatus))
              .toList(),
          fileName: 'not_interested_students.csv',
          title: 'Not Interested report',
          emptyMessage: 'There are no students in this report to export.',
        );
      case _LeadReportAction.notPotential:
        await _exportStudentsToCsv(
          _students
              .where((student) => isNotPotentialStatus(student.callStatus))
              .toList(),
          fileName: 'not_potential_students.csv',
          title: 'Not Potential report',
          emptyMessage: 'There are no students in this report to export.',
        );
      case _LeadReportAction.inactive:
        await _exportStudentsToCsv(
          _students
              .where((student) => isInactiveStatus(student.callStatus))
              .toList(),
          fileName: 'inactive_students.csv',
          title: 'Inactive report',
          emptyMessage: 'There are no students in this report to export.',
        );
    }
  }

  bool get _hasActiveFilters =>
      _statusFilter != null || _dateFrom != null || _dateTo != null;

  Future<void> _changeThemeMode(ThemeMode mode) async {
    try {
      await widget.onThemeModeChanged(mode);
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not save theme setting: $error');
    }
  }

  Future<void> _syncWithGoogleSheet({String? url}) async {
    final endpoint = (url ?? widget.sheetConfig).trim();
    if (endpoint.isEmpty) {
      if (mounted) {
        setState(() {
          _syncStatus = 'Not connected';
          _hasSynced = false;
          _lastSyncTime = null;
        });
      }
      return;
    }

    final syncGeneration = ++_syncGeneration;
    setState(() {
      _isSyncing = true;
      _syncStatus = 'Syncing…';
    });
    try {
      await _flushOfflineQueue();

      final sheetStudents = await widget.sheetService.fetchStudentsFromSheet(
        endpoint,
      );
      if (!mounted || syncGeneration != _syncGeneration) return;
      final merged = <String, Student>{};
      for (final student in sheetStudents) {
        merged[_studentKey(student)] = student;
      }
      for (final queued in _offlineQueue) {
        merged[_studentKey(queued.student)] = queued.student;
      }
      setState(() {
        _isSelectionMode = false;
        _selectedStudentKeys.clear();
        _students
          ..clear()
          ..addAll(merged.values);
        _isSyncing = false;
        _hasSynced = true;
        _lastSyncTime = _formattedSyncTime();
        if (_offlineQueue.isEmpty) {
          _syncStatus = 'Synced · $_lastSyncTime';
        } else {
          _syncStatus =
              'Synced · $_lastSyncTime (${_offlineQueue.length} offline queued)';
        }
      });
      await _settingsStore.saveCachedStudents(_students);
      unawaited(_autoScheduleTodayFollowUps(merged.values));
    } on SheetApiException catch (error) {
      if (syncGeneration == _syncGeneration) _showSyncFailure(error.message);
    } on http.ClientException catch (error) {
      if (syncGeneration == _syncGeneration) {
        _showSyncFailure('Network error: ${error.message}');
      }
    } on TimeoutException {
      if (syncGeneration == _syncGeneration) {
        _showSyncFailure('The Google Sheet request timed out.');
      }
    } on FormatException catch (error) {
      if (syncGeneration == _syncGeneration) {
        _showSyncFailure('Invalid student data: ${error.message}');
      }
    } on Exception catch (error) {
      if (syncGeneration == _syncGeneration) {
        _showSyncFailure('Could not sync with the Google Sheet: $error');
      }
    }
  }

  Future<void> _autoScheduleTodayFollowUps(Iterable<Student> students) async {
    try {
      final now = DateTime.now();
      final endOfToday = DateTime(now.year, now.month, now.day + 1);

      final canSchedule =
          await widget.reminderScheduler.canScheduleExactAlarms();
      if (!canSchedule) return;

      for (final student in students) {
        if (isFinalLeadStatus(student.callStatus)) continue;
        final nextCall = DateTime.tryParse(student.nextCallDateTime);
        if (nextCall == null) continue;

        if (!nextCall.isBefore(endOfToday) || !nextCall.isAfter(now)) {
          continue;
        }

        final alreadyAttempted = student.attempts.any((attempt) {
          final attemptedAt = DateTime.tryParse(attempt.dateTime);
          return attemptedAt != null && !attemptedAt.isBefore(nextCall);
        });
        if (alreadyAttempted) continue;

        final isScheduled = await widget.reminderScheduler
            .isStudentReminderScheduled(student, nextCall);
        if (!isScheduled) {
          try {
            await widget.reminderScheduler.scheduleStudentReminder(
              student,
              nextCall,
            );
          } on Exception catch (error) {
            debugPrint(
              'Could not auto-schedule reminder for ${student.name}: $error',
            );
          }
        }
      }
    } on Exception catch (error) {
      debugPrint('Error while auto-scheduling today reminders: $error');
    }
  }

  String _studentKey(Student student) {
    final digits = student.phone.replaceAll(RegExp(r'\D'), '');
    return digits.isEmpty ? student.name.trim().toLowerCase() : digits;
  }

  String _formattedSyncTime() {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  void _showSyncFailure(String message) {
    if (!mounted) return;
    setState(() {
      _isSyncing = false;
      _hasSynced = false;
      if (_offlineQueue.isNotEmpty) {
        _syncStatus = 'Sync failed (${_offlineQueue.length} offline queued)';
      } else {
        _syncStatus = 'Sync failed';
      }
    });
    _showMessage(message);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _leadFilterChip({required String label, required _LeadFilter filter}) {
    final selected = _leadFilter == filter;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => setState(() => _leadFilter = filter),
      selectedColor: _navy,
      backgroundColor: Theme.of(context).colorScheme.surface,
      side: BorderSide(
        color: selected
            ? _navy
            : isDark
            ? const Color(0xFF344453)
            : const Color(0xFFE0E6EC),
      ),
      labelStyle: TextStyle(
        color: selected
            ? Colors.white
            : Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
  }

  Future<void> _exportStudentsToCsv(
    List<Student> students, {
    String fileName = 'student_leads.csv',
    String title = 'Export student leads',
    String emptyMessage = 'No students match the current filters to export.',
  }) async {
    if (students.isEmpty) {
      _showMessage(emptyMessage);
      return;
    }

    final csv = studentsToCsv(students);
    final bytes = Uint8List.fromList(utf8.encode('\uFEFF$csv'));
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: 'text/csv', name: fileName)],
          fileNameOverrides: [fileName],
          title: title,
          subject: title,
          text: '${students.length} student record(s)',
          downloadFallbackEnabled: true,
        ),
      );
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not export CSV: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final students = _filteredStudents;
    final selectedStudents = _selectedStudents;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: _isSelectionMode
            ? IconButton(
                tooltip: 'Cancel selection',
                onPressed: _clearStudentSelection,
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        title: _isSelectionMode
            ? Text('${selectedStudents.length} selected')
            : const Text(
                'LeadPilot',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
        actions: _isSelectionMode
            ? [
                IconButton(
                  tooltip: 'Export selected contacts',
                  onPressed: selectedStudents.isEmpty
                      ? null
                      : () => _exportStudentsToCsv(selectedStudents),
                  icon: const Icon(Icons.file_download_outlined),
                ),
                IconButton(
                  tooltip: 'Save selected contacts',
                  onPressed: selectedStudents.isEmpty
                      ? null
                      : _saveSelectedContacts,
                  icon: const Icon(Icons.contact_phone_outlined),
                ),
                const SizedBox(width: 8),
              ]
            : [
                IconButton(
                  tooltip: 'Settings',
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
                IconButton(
                  tooltip: 'Lock app',
                  onPressed: widget.onLogout,
                  icon: const Icon(Icons.lock_outline_rounded),
                ),
                const SizedBox(width: 8),
              ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          onChanged: (value) => setState(() => _query = value),
                          decoration: InputDecoration(
                            hintText: 'Search name, status, phone or comments',
                            hintStyle: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 14,
                            ),
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear search',
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _query = '');
                                    },
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 15,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _leadFilterChip(
                          label: 'All Leads',
                          filter: _LeadFilter.all,
                        ),
                        const SizedBox(width: 8),
                        _leadFilterChip(
                          label: 'New Leads',
                          filter: _LeadFilter.newLeads,
                        ),
                        const SizedBox(width: 8),
                        _leadFilterChip(
                          label: 'Today Follow-up',
                          filter: _LeadFilter.todayFollowUp,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SyncStatusRow(
                    status: _syncStatus,
                    isSyncing: _isSyncing,
                    isConnected: _hasSynced,
                    lastSyncTime: _lastSyncTime,
                    offlineQueueCount: _offlineQueue.length,
                    onSync: () => _syncWithGoogleSheet(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Your students',
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface,
                                        fontWeight: FontWeight.w800,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${_students.length} contacts • Keep in touch',
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF17382F)
                                  : const Color(0xFFEAF6F2),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.circle,
                                  size: 8,
                                  color: _green,
                                ),
                                const SizedBox(width: 7),
                                Text(
                                  '${students.length} shown',
                                  style: const TextStyle(
                                    color: _green,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: students.isEmpty
                          ? _EmptySearchState(
                              isSearching:
                                  _query.isNotEmpty ||
                                  _leadFilter != _LeadFilter.all ||
                                  _hasActiveFilters,
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(18, 0, 18, 96),
                              itemCount: students.length,
                              itemBuilder: (context, index) => StudentCard(
                                student: students[index],
                                isSelectionMode: _isSelectionMode,
                                isSelected: _selectedStudentKeys.contains(
                                  _selectionKey(students[index]),
                                ),
                                onTap: () => _isSelectionMode
                                    ? _toggleStudentSelection(students[index])
                                    : _editStudent(students[index]),
                                onLongPress: () => _isSelectionMode
                                    ? _toggleStudentSelection(students[index])
                                    : _showStudentActions(students[index]),
                                onCall: () => _callStudent(students[index]),
                                onWhatsApp: () =>
                                    _openWhatsAppChat(students[index]),
                                onSms: () => _sendStudentSms(students[index]),
                                onNote: () => _showStudentNote(students[index]),
                                onSaveContact: () =>
                                    _saveStudentContact(students[index]),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _isSelectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _addStudent,
              backgroundColor: _green,
              foregroundColor: Colors.white,
              elevation: 4,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text(
                'Add student',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
    );
  }

  Future<void> _callStudent(Student student) async {
    try {
      final launched = await launchUrl(Uri.parse('tel:${student.phone}'));
      if (!launched && mounted) {
        _showMessage('Could not open the phone dialer for ${student.name}.');
      }
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not start the call: $error');
    }
  }

  Future<void> _openWhatsAppChat(Student student) async {
    final number = student.whatsappNumber.trim().isEmpty
        ? student.phone
        : student.whatsappNumber;
    final digits = normalizeContactPhone(number);
    if (digits.isEmpty) {
      _showMessage(
        'No valid WhatsApp number is available for ${student.name}.',
      );
      return;
    }

    final choice = await showModalBottomSheet<_WhatsAppChoice>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _WhatsAppChoiceSheet(student: student),
    );

    if (choice == null || !mounted) return;

    if (choice == _WhatsAppChoice.custom) {
      await _launchWhatsApp(number);
    } else if (choice == _WhatsAppChoice.template) {
      final templates = await _settingsStore.readWhatsAppTemplates();
      if (!mounted) return;
      final selectedMessage = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _WhatsAppTemplatePickerSheet(
          student: student,
          templates: templates,
          onManageTemplates: () async {
            Navigator.pop(context);
            await _openWhatsAppTemplatesSettings();
          },
        ),
      );
      if (selectedMessage != null && mounted) {
        await _launchWhatsApp(number, text: selectedMessage);
      }
    }
  }

  Future<void> _launchWhatsApp(String number, {String? text}) async {
    try {
      final launched = await launchUrl(
        whatsAppChatUri(number, text: text),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        _showMessage('Could not open WhatsApp.');
      }
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not open WhatsApp: $error');
    }
  }

  Future<void> _sendStudentSms(Student student) async {
    if (normalizeContactPhone(student.phone).isEmpty) {
      _showMessage('No valid phone number is available for ${student.name}.');
      return;
    }

    try {
      final launched = await launchUrl(
        smsComposerUri(student.phone),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        _showMessage('Could not open the SMS composer for ${student.name}.');
      }
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not open SMS: $error');
    }
  }

  Future<void> _saveVisibleContacts() async {
    final students = _filteredStudents;
    if (students.isEmpty) {
      _showMessage('There are no displayed contacts to save.');
      return;
    }
    await _saveContacts(students);
  }

  Future<void> _saveSelectedContacts() async {
    final students = _selectedStudents;
    if (students.isEmpty) {
      _showMessage('Select at least one contact first.');
      return;
    }
    await _saveContacts(students);
  }

  Future<void> _saveContacts(List<Student> students) async {
    try {
      final result = await widget.deviceContactsService.saveMissingStudents(
        students,
      );
      await _showContactSaveResult(result);
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not save contacts: $error');
    }
  }

  Future<void> _showStudentActions(Student student) async {
    final action = await showModalBottomSheet<_StudentCardAction>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () =>
                    Navigator.pop(sheetContext, _StudentCardAction.edit),
              ),
              ListTile(
                leading: const Icon(Icons.checklist_rounded),
                title: const Text('Select multiple'),
                subtitle: const Text('Select contacts to save or export'),
                onTap: () => Navigator.pop(
                  sheetContext,
                  _StudentCardAction.selectMultiple,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _StudentCardAction.edit:
        await _editStudent(student);
        break;
      case _StudentCardAction.selectMultiple:
        _startSelection(student);
        break;
    }
  }

  Future<void> _saveStudentContact(Student student) async {
    await _saveContacts([student]);
  }

  Future<void> _showContactSaveResult(SaveContactsResult result) async {
    if (!mounted) return;
    if (result.permissionDenied) {
      final openSettings = result.permissionPermanentlyDenied
          ? await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('Contacts permission required'),
                content: const Text(
                  'Allow Contacts access in your device settings to check '
                  'saved numbers and add missing contacts.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Open settings'),
                  ),
                ],
              ),
            )
          : false;
      if (openSettings == true) {
        await FlutterContacts.permissions.openSettings();
      } else if (!result.permissionPermanentlyDenied && mounted) {
        _showMessage('Contacts permission was not granted.');
      }
      return;
    }

    final summary = <String>[
      if (result.saved > 0) '${result.saved} contact(s) saved',
      if (result.alreadySaved > 0)
        '${result.alreadySaved} already saved or duplicate',
      if (result.failedNames.isNotEmpty)
        '${result.failedNames.length} failed: ${result.failedNames.join(', ')}',
    ];
    _showMessage(
      summary.isEmpty ? 'No contacts needed saving.' : summary.join(' · '),
    );
  }

  void _showStudentNote(Student student) {
    _showStudentHistory(
      context,
      student,
      title: 'Call history · ${student.name}',
    );
  }
}

Future<void> _showStudentHistory(
  BuildContext context,
  Student student, {
  required String title,
}) {
  final entries =
      <
        ({
          DateTime? date,
          String dateLabel,
          int order,
          String status,
          String text,
        })
      >[];
  final attemptCommentCounts = <String, int>{};
  var order = 0;
  for (final attempt in student.attempts) {
    final date = DateTime.tryParse(attempt.dateTime);
    final text = attempt.comment.trim();
    if (text.isNotEmpty) {
      attemptCommentCounts.update(
        text,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    entries.add((
      date: date,
      dateLabel: date == null ? attempt.dateTime : _formatReminder(date),
      order: order++,
      status: attempt.status,
      text: text,
    ));
  }

  for (final entry in student.commentHistory) {
    final separator = entry.indexOf(' — ');
    final text = separator < 0
        ? entry.trim()
        : entry.substring(separator + 3).trim();
    if (text.isEmpty) continue;
    final duplicateCount = attemptCommentCounts[text] ?? 0;
    if (duplicateCount > 0) {
      attemptCommentCounts[text] = duplicateCount - 1;
      continue;
    }
    final dateLabel = separator < 0 ? '' : entry.substring(0, separator);
    final date = dateLabel.length >= 10
        ? DateTime.tryParse(dateLabel.substring(0, 10))
        : null;
    entries.add((
      date: date,
      dateLabel: dateLabel,
      order: order++,
      status: '',
      text: text,
    ));
  }
  final currentComment = student.comment.trim();
  if (currentComment.isNotEmpty &&
      !entries.any((entry) => entry.text == currentComment)) {
    entries.add((
      date: null,
      dateLabel: '',
      order: order++,
      status: student.callStatus,
      text: currentComment,
    ));
  }
  entries.sort((left, right) {
    if (left.date == null && right.date != null) return 1;
    if (right.date == null && left.date != null) return -1;
    final dateComparison = left.date?.compareTo(right.date!) ?? 0;
    return dateComparison != 0
        ? dateComparison
        : left.order.compareTo(right.order);
  });

  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 440,
        child: entries.isEmpty && student.note.isEmpty
            ? const Text('No call history or comments have been saved.')
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: entries.isEmpty ? 1 : entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 22),
                  itemBuilder: (context, index) {
                    if (entries.isEmpty) return Text(student.note);
                    final entry = entries[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (entry.status.isNotEmpty ||
                            entry.dateLabel.isNotEmpty)
                          Row(
                            children: [
                              if (entry.status.isNotEmpty)
                                Expanded(
                                  child: Text(
                                    entry.status,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              if (entry.dateLabel.isNotEmpty)
                                Text(
                                  entry.dateLabel,
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        if (entry.text.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(entry.text),
                        ],
                      ],
                    );
                  },
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _LeadFilterSheet extends StatefulWidget {
  const _LeadFilterSheet({
    required this.initialStatus,
    required this.initialDateFrom,
    required this.initialDateTo,
  });

  final String? initialStatus;
  final DateTime? initialDateFrom;
  final DateTime? initialDateTo;

  @override
  State<_LeadFilterSheet> createState() => _LeadFilterSheetState();
}

class _LeadFilterSheetState extends State<_LeadFilterSheet> {
  static const _statuses = [
    'Pending',
    'Very Interested',
    'Interested',
    'Minimal Interested',
    'Inactive',
    'Answered',
    'No Answer',
    'Not Responding',
    'Wrong number',
    'Call Cut',
    'Line Busy',
    'Call Back',
    'Future',
  ];

  late String? _status = widget.initialStatus;
  late DateTime? _dateFrom = widget.initialDateFrom;
  late DateTime? _dateTo = widget.initialDateTo;
  String? _dateError;

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _dateFrom : _dateTo;
    final selected = await showDatePicker(
      context: context,
      initialDate: initial ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: isStart ? 'Select start date' : 'Select end date',
    );
    if (!mounted || selected == null) return;
    setState(() {
      if (isStart) {
        _dateFrom = _dateOnly(selected);
      } else {
        _dateTo = _dateOnly(selected);
      }
      _dateError = null;
    });
  }

  void _selectQuickDate(String period) {
    final now = DateTime.now();
    final today = _dateOnly(now);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final monthStart = DateTime(today.year, today.month);
    setState(() {
      switch (period) {
        case 'Today':
          _dateFrom = today;
          _dateTo = today;
        case 'This week':
          _dateFrom = weekStart;
          _dateTo = today;
        case 'This month':
          _dateFrom = monthStart;
          _dateTo = today;
      }
      _dateError = null;
    });
  }

  void _apply() {
    if (_dateFrom != null && _dateTo != null && _dateFrom!.isAfter(_dateTo!)) {
      setState(() => _dateError = 'Start date must be on or before end date.');
      return;
    }
    Navigator.of(context).pop(
      _LeadFilterSelection(
        callStatus: _status,
        dateFrom: _dateFrom,
        dateTo: _dateTo,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = Theme.of(context).colorScheme.surface;
    final textColor = Theme.of(context).colorScheme.onSurface;

    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  height: 4,
                  width: 40,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF526170)
                        : const Color(0xFFDDE3E9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Filter students',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(color: textColor, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey(_status ?? 'all-statuses'),
                initialValue: _status,
                decoration: const InputDecoration(
                  labelText: 'Call status',
                  prefixIcon: Icon(Icons.call_outlined),
                ),
                hint: const Text('All statuses'),
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('All statuses'),
                  ),
                  ..._statuses.map(
                    (status) => DropdownMenuItem<String>(
                      value: status,
                      child: Text(status),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _status = value),
              ),
              const SizedBox(height: 18),
              Text(
                'Added date range',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: textColor, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickDate(isStart: true),
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text(
                        'From · ${_formatFilterDate(_dateFrom)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickDate(isStart: false),
                      icon: const Icon(Icons.event_outlined),
                      label: Text(
                        'To · ${_formatFilterDate(_dateTo)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    label: const Text('Today'),
                    onPressed: () => _selectQuickDate('Today'),
                  ),
                  ActionChip(
                    label: const Text('This week'),
                    onPressed: () => _selectQuickDate('This week'),
                  ),
                  ActionChip(
                    label: const Text('This month'),
                    onPressed: () => _selectQuickDate('This month'),
                  ),
                ],
              ),
              if (_dateError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _dateError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => setState(() {
                        _status = null;
                        _dateFrom = null;
                        _dateTo = null;
                        _dateError = null;
                      }),
                      child: const Text('Clear filters'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _apply,
                      child: const Text('Apply filters'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StudentCard extends StatelessWidget {
  const StudentCard({
    required this.student,
    required this.onTap,
    required this.onLongPress,
    required this.onCall,
    required this.onWhatsApp,
    required this.onSms,
    required this.onNote,
    required this.onSaveContact,
    this.isSelectionMode = false,
    this.isSelected = false,
    super.key,
  });

  final Student student;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onCall;
  final VoidCallback onWhatsApp;
  final VoidCallback onSms;
  final VoidCallback onNote;
  final VoidCallback onSaveContact;
  final bool isSelectionMode;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activity = studentActivityStatus(student);
    final statusColor = switch (student.callStatus) {
      'Very Interested' || 'Interested' || 'Answered' => _green,
      'Minimal Interested' ||
      'No Answer' ||
      'Not Responding' ||
      'Line Busy' ||
      'Call Back' ||
      'Future' => const Color(0xFFB36B16),
      'Not Interested' ||
      'Not Potential' ||
      'Not Protencial' ||
      'Wrong number' ||
      'Call Cut' => const Color(0xFFB54747),
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1.5,
      shadowColor: _navy.withValues(alpha: 0.07),
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: isDark
              ? const Color(0xFF344453)
              : const Color(0xFFF0F2F5),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isSelectionMode ? onLongPress : onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Badge(
                isLabelVisible:
                    !isSelectionMode && activity.unansweredStreak >= 3,
                alignment: Alignment.topRight,
                backgroundColor: activity.unansweredStreak >= 5
                    ? const Color(0xFFD64545)
                    : const Color(0xFFE58A18),
                largeSize: 18,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                label: Text(
                  '${activity.unansweredStreak}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 10,
                    color: Colors.white,
                  ),
                ),
                child: CircleAvatar(
                  radius: 25,
                  backgroundColor: isSelectionMode && isSelected
                      ? _green
                      : isDark
                      ? const Color(0xFF17382F)
                      : const Color(0xFFEAF3F1),
                  child: isSelectionMode
                      ? Icon(
                          isSelected
                              ? Icons.check_rounded
                              : Icons.circle_outlined,
                          color: isSelected
                              ? Colors.white
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        )
                      : Text(
                          student.initials,
                          style: const TextStyle(
                            color: _green,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      student.name,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.phone_outlined,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            student.phone,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (student.source.isNotEmpty ||
                        student.addedDate.isNotEmpty ||
                        student.location.isNotEmpty ||
                        student.examType.isNotEmpty ||
                        student.callStatus.isNotEmpty ||
                        student.nextCallDateTime.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (student.source.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF17382F)
                                      : const Color(0xFFEAF6F2),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  student.source,
                                  style: const TextStyle(
                                    color: _green,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            if (student.examType.isNotEmpty)
                              _StudentTag(
                                text: student.examType,
                                background: isDark
                                    ? const Color(0xFF2B3947)
                                    : const Color(0xFFEEF1F7),
                                foreground: Theme.of(context)
                                    .colorScheme
                                    .onSurface,
                              ),
                            if (student.examYear.isNotEmpty)
                              _StudentTag(
                                text: 'Exam ${student.examYear}',
                                background: isDark
                                    ? const Color(0xFF2B3947)
                                    : const Color(0xFFF1F4F8),
                                foreground: Theme.of(context)
                                    .colorScheme
                                    .onSurface,
                              ),
                            if (student.location.isNotEmpty)
                              _StudentTag(
                                text: student.location,
                                background: isDark
                                    ? const Color(0xFF17382F)
                                    : const Color(0xFFEAF3F1),
                                foreground: _green,
                              ),
                            if (student.callStatus.isNotEmpty)
                              _StudentTag(
                                text: student.callStatus,
                                background: statusColor.withValues(alpha: 0.12),
                                foreground: statusColor,
                              ),
                            if (activity.unansweredStreak >= 3)
                              _StudentTag(
                                text: activity.unansweredStreak >= 5
                                    ? '🚨 ${activity.unansweredStreak}x No Answer'
                                    : '⚠️ ${activity.unansweredStreak}x No Answer',
                                background: activity.color.withValues(alpha: 0.15),
                                foreground: activity.color,
                              ),
                            if (DateTime.tryParse(student.nextCallDateTime)
                                case final reminder?)
                              _StudentTag(
                                text: 'Call · ${_formatReminder(reminder)}',
                                background: isDark
                                    ? const Color(0xFF44351F)
                                    : const Color(0xFFFFF3DF),
                                foreground: isDark
                                    ? const Color(0xFFFFC56E)
                                    : const Color(0xFF9A5A00),
                              ),
                            if (student.addedDate.isNotEmpty)
                              Text(
                                student.addedDate,
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  fontSize: 10,
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (!isSelectionMode) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _QuickActionButton(
                              icon: const Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 19,
                              ),
                              tooltip: 'Comments',
                              onPressed: onNote,
                              backgroundColor: isDark
                                  ? const Color(0xFF2B3947)
                                  : const Color(0xFFF2F5F8),
                              foregroundColor: Theme.of(context)
                                  .colorScheme
                                  .onSurface,
                            ),
                            const SizedBox(width: 8),
                            _QuickActionButton(
                              icon: const FaIcon(
                                FontAwesomeIcons.whatsapp,
                                size: 19,
                              ),
                              tooltip: 'Open WhatsApp chat',
                              onPressed: onWhatsApp,
                              backgroundColor: isDark
                                  ? const Color(0xFF17382F)
                                  : const Color(0xFFE9F6F1),
                              foregroundColor: _green,
                            ),
                            const SizedBox(width: 6),
                            _QuickActionButton(
                              icon: const Icon(Icons.sms_outlined, size: 19),
                              tooltip: 'Send SMS',
                              onPressed: onSms,
                              backgroundColor: isDark
                                  ? const Color(0xFF1F3548)
                                  : const Color(0xFFEAF2FA),
                              foregroundColor: const Color(0xFF2E6FA3),
                            ),
                            const SizedBox(width: 6),
                            _QuickActionButton(
                              icon: const Icon(Icons.call_rounded, size: 19),
                              tooltip: 'Call student',
                              onPressed: onCall,
                              backgroundColor: isDark
                                  ? const Color(0xFF17382F)
                                  : const Color(0xFFE9F6F1),
                              foregroundColor: _green,
                            ),
                            const SizedBox(width: 6),
                            _QuickActionButton(
                              icon: const Icon(
                                Icons.person_add_alt_1_rounded,
                                size: 19,
                              ),
                              tooltip: 'Save contact',
                              onPressed: onSaveContact,
                              backgroundColor: isDark
                                  ? const Color(0xFF17382F)
                                  : const Color(0xFFE9F6F1),
                              foregroundColor: _green,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StudentTag extends StatelessWidget {
  const _StudentTag({
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: foreground,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SyncStatusRow extends StatelessWidget {
  const _SyncStatusRow({
    required this.status,
    required this.isSyncing,
    required this.isConnected,
    required this.lastSyncTime,
    required this.onSync,
    this.offlineQueueCount = 0,
  });

  final String status;
  final bool isSyncing;
  final bool isConnected;
  final String? lastSyncTime;
  final VoidCallback onSync;
  final int offlineQueueCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasPendingOffline = offlineQueueCount > 0;
    final color = isSyncing
        ? theme.colorScheme.primary
        : hasPendingOffline
        ? const Color(0xFFE58A18)
        : isConnected
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isDark
                  ? hasPendingOffline
                        ? const Color(0xFF382914)
                        : isConnected
                        ? const Color(0xFF17382F)
                        : const Color(0xFF263440)
                  : hasPendingOffline
                  ? const Color(0xFFFEF6EC)
                  : isConnected
                  ? const Color(0xFFEAF6F2)
                  : const Color(0xFFF0F3F6),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                if (isSyncing)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  )
                else
                  Icon(
                    hasPendingOffline
                        ? Icons.cloud_upload_outlined
                        : isConnected
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    size: 17,
                    color: color,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (hasPendingOffline) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE58A18).withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$offlineQueueCount queued',
                      style: const TextStyle(
                        color: Color(0xFFE58A18),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ] else if (lastSyncTime != null && isConnected) ...[
                  const SizedBox(width: 6),
                  Text(
                    lastSyncTime!,
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: isSyncing ? null : onSync,
          icon: const Icon(Icons.sync_rounded, size: 17),
          label: const Text('Sync now'),
          style: TextButton.styleFrom(
            foregroundColor: _green,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ],
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        fixedSize: const Size(40, 40),
        padding: EdgeInsets.zero,
      ),
      icon: icon,
    );
  }
}

class _EmptySearchState extends StatelessWidget {
  const _EmptySearchState({required this.isSearching});

  final bool isSearching;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_search_rounded,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
            ),
            const SizedBox(height: 12),
            Text(
              isSearching ? 'No students found' : 'No students yet',
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              isSearching
                  ? 'Try another name or phone number.'
                  : 'Tap Add student to add your first contact.',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditStudentSheet extends StatefulWidget {
  const _EditStudentSheet({required this.student});

  final Student student;

  @override
  State<_EditStudentSheet> createState() => _EditStudentSheetState();
}

class _EditStudentSheetState extends State<_EditStudentSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(text: widget.student.name);
  late final _phoneController = TextEditingController(
    text: widget.student.phone,
  );
  late final _examYearController = TextEditingController(
    text: widget.student.examYear,
  );
  late final _locationController = TextEditingController(
    text: widget.student.location,
  );
  late final _englishController = TextEditingController(
    text: widget.student.olEnglish,
  );
  late final _mathsController = TextEditingController(
    text: widget.student.olMaths,
  );
  late final _whatsappController = TextEditingController(
    text: widget.student.whatsappNumber,
  );
  late final _commentController = TextEditingController(text: '');

  static const _examTypes = ['O/L', 'A/L'];
  static const _callStatuses = [
    'Very Interested',
    'Interested',
    'Minimal Interested',
    'Not Interested',
    'Not Potential',
    'Inactive',
    'Answered',
    'No Answer',
    'Not Responding',
    'Wrong number',
    'Call Cut',
    'Line Busy',
    'Call Back',
    'Future',
  ];

  late String? _examType = _examTypes.contains(widget.student.examType)
      ? widget.student.examType
      : null;
  late String? _callStatus = _callStatuses.contains(widget.student.callStatus)
      ? widget.student.callStatus
      : null;
  late bool _sameAsContact =
      widget.student.whatsappSameAsContact ||
      widget.student.whatsappNumber == widget.student.phone;
  late DateTime? _nextCallDateTime = DateTime.tryParse(
    widget.student.nextCallDateTime,
  );
  bool _isPickingNextCallDateTime = false;

  @override
  void initState() {
    super.initState();
    if (_sameAsContact) _whatsappController.text = widget.student.phone;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _examYearController.dispose();
    _locationController.dispose();
    _englishController.dispose();
    _mathsController.dispose();
    _whatsappController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  Student _updatedStudent() {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final newComment = _commentController.text.trim();
    final history = List<String>.of(widget.student.commentHistory);
    final attempts = List<CallAttempt>.of(widget.student.attempts);
    final attemptedAt = DateTime.now();
    final callStatus = _callStatus ?? widget.student.callStatus;
    if (newComment.isNotEmpty) {
      history.add('${_formatReminder(DateTime.now())} — $newComment');
    }
    attempts.add(
      CallAttempt(
        dateTime: attemptedAt.toIso8601String(),
        status: callStatus,
        comment: newComment,
      ),
    );

    return widget.student.copyWith(
      name: name,
      phone: phone,
      examType: _examType ?? '',
      examYear: _examYearController.text.trim(),
      location: _locationController.text.trim(),
      olEnglish: _englishController.text.trim().toUpperCase(),
      olMaths: _mathsController.text.trim().toUpperCase(),
      whatsappNumber: _sameAsContact ? phone : _whatsappController.text.trim(),
      whatsappSameAsContact: _sameAsContact,
      callStatus: callStatus,
      nextCallDateTime: isFinalLeadStatus(callStatus)
          ? ''
          : _nextCallDateTime?.toIso8601String() ?? '',
      comment: newComment.isEmpty ? null : newComment,
      commentHistory: history,
      attempts: attempts,
    );
  }

  Future<void> _pickNextCallDateTime() async {
    if (_isPickingNextCallDateTime) return;
    setState(() => _isPickingNextCallDateTime = true);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final defaultReminder = now.add(const Duration(minutes: 1));
    final existingReminder = _nextCallDateTime;
    final pickerInitialDateTime =
        existingReminder != null && existingReminder.isAfter(now)
        ? existingReminder
        : defaultReminder;
    final preferredDate = existingReminder ?? pickerInitialDateTime;
    try {
      final selectedDate = await showDatePicker(
        context: context,
        initialDate: preferredDate.isBefore(today) ? today : preferredDate,
        firstDate: today,
        lastDate: DateTime(now.year + 10),
        helpText: 'Select next call date',
      );
      if (!mounted || selectedDate == null) return;

      final selectedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(pickerInitialDateTime),
        helpText: 'Select next call time',
      );
      if (!mounted || selectedTime == null) return;

      final selectedDateTime = combineReminderDateAndTime(
        selectedDate,
        selectedTime,
      );
      if (!isReminderDateTimeInFuture(selectedDateTime, now: DateTime.now())) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'That time has already passed today. Choose a later time.',
            ),
          ),
        );
        return;
      }
      setState(() => _nextCallDateTime = selectedDateTime);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('Could not open the call reminder picker: $error'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPickingNextCallDateTime = false);
      }
    }
  }

  Future<void> _showCommentHistory() => _showStudentHistory(
    context,
    widget.student,
    title: 'Call attempt history',
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4,
                    width: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDDE3E9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Update ${widget.student.name}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Update these details on the existing student record.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  key: const ValueKey('edit-name-input'),
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Student name',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a student name'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('edit-phone-input'),
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Contact number',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                  validator: (value) =>
                      value == null || normalizeContactPhone(value).isEmpty
                      ? 'Enter a valid contact number'
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _examType,
                  decoration: const InputDecoration(
                    labelText: 'Exam type',
                    prefixIcon: Icon(Icons.school_outlined),
                  ),
                  hint: const Text('Select exam type'),
                  items: _examTypes
                      .map(
                        (type) =>
                            DropdownMenuItem(value: type, child: Text(type)),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => _examType = value),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _examYearController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Exam Year',
                    hintText: 'e.g. 2026',
                    prefixIcon: Icon(Icons.calendar_today_outlined),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) return null;
                    if (!RegExp(r'^\d{4}$').hasMatch(value.trim())) {
                      return 'Enter a 4-digit exam year';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _locationController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Location / City',
                    prefixIcon: Icon(Icons.location_city_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _englishController,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'O/L English',
                          hintText: 'A / B / C / S',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _mathsController,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'O/L Maths',
                          hintText: 'A / B / C / S',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _whatsappController,
                  keyboardType: TextInputType.phone,
                  enabled: !_sameAsContact,
                  decoration: const InputDecoration(
                    labelText: 'WhatsApp number',
                    prefixIcon: Icon(Icons.chat_outlined),
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _sameAsContact,
                    activeColor: _green,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      'Same as contact number',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onChanged: (value) {
                      final checked = value ?? false;
                      setState(() {
                        _sameAsContact = checked;
                        if (checked) {
                          _whatsappController.text = widget.student.phone;
                        } else if (_whatsappController.text ==
                            widget.student.phone) {
                          _whatsappController.clear();
                        }
                      });
                    },
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _callStatus,
                  decoration: const InputDecoration(
                    labelText: 'Call status',
                    prefixIcon: Icon(Icons.call_outlined),
                  ),
                  hint: const Text('Select call status'),
                  items: _callStatuses
                      .map(
                        (status) => DropdownMenuItem(
                          value: status,
                          child: Text(status),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _callStatus = value;
                      if (isFinalLeadStatus(value)) {
                        _nextCallDateTime = null;
                      }
                    });
                  },
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isPickingNextCallDateTime
                      ? null
                      : _pickNextCallDateTime,
                  icon: Icon(
                    _isPickingNextCallDateTime
                        ? Icons.hourglass_top_rounded
                        : Icons.event_available_outlined,
                  ),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _isPickingNextCallDateTime
                          ? 'Selecting date & time…'
                          : _nextCallDateTime == null
                          ? 'Next call date & time (optional)'
                          : 'Next call · ${_formatReminder(_nextCallDateTime!)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    minimumSize: const Size.fromHeight(54),
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                if (_nextCallDateTime == null)
                  Padding(
                    padding: EdgeInsets.only(left: 4, top: 6),
                    child: Text(
                      'Optional — leave blank to save without a call reminder.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (_nextCallDateTime != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setState(() => _nextCallDateTime = null),
                      child: const Text('Clear reminder'),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'New call remark',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _showCommentHistory,
                      icon: const Icon(Icons.history_rounded, size: 18),
                      label: const Text('View History'),
                    ),
                  ],
                ),
                TextFormField(
                  controller: _commentController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Call remark (optional)',
                    alignLabelWithHint: true,
                    prefixIcon: Padding(
                      padding: EdgeInsets.only(bottom: 24),
                      child: Icon(Icons.notes_outlined),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      if (!_formKey.currentState!.validate()) return;
                      final updated = _updatedStudent();
                      final currentStreak =
                          studentActivityStatus(widget.student).unansweredStreak;
                      final isNewAttemptUnanswered = _isUnansweredCall(
                        updated.callStatus,
                        updated.comment,
                      );

                      if (currentStreak >= 5 && isNewAttemptUnanswered) {
                        final nextStreak = currentStreak + 1;
                        final moveToInactive = await showDialog<bool>(
                          context: context,
                          builder: (dialogCtx) => AlertDialog(
                            title: const Text('Move to Inactive?'),
                            content: Text(
                              '${widget.student.name} has not answered $nextStreak consecutive times. Move to \'Inactive\'?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogCtx, false),
                                child: const Text('Keep Active'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor:
                                      Theme.of(context).colorScheme.error,
                                ),
                                onPressed: () => Navigator.pop(dialogCtx, true),
                                child: const Text('Move to Inactive'),
                              ),
                            ],
                          ),
                        );

                        if (moveToInactive == true) {
                          final inactiveStudent = updated.copyWith(
                            callStatus: 'Inactive',
                            nextCallDateTime: '',
                          );
                          if (context.mounted) {
                            Navigator.of(context).pop(inactiveStudent);
                          }
                          return;
                        }
                      }

                      if (context.mounted) {
                        Navigator.of(context).pop(updated);
                      }
                    },
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Update Details'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _green,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddStudentSheet extends StatefulWidget {
  const _AddStudentSheet();

  @override
  State<_AddStudentSheet> createState() => _AddStudentSheetState();
}

class _AddStudentSheetState extends State<_AddStudentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _entriesController = TextEditingController();
  static const _sources = ['Facebook', 'Hotline', 'Database', 'WhatsApp'];
  String _source = 'Facebook';

  @override
  void dispose() {
    _entriesController.dispose();
    super.dispose();
  }

  String? _validateEntries(String? value) {
    final lines = (value ?? '')
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return 'Enter at least one student.';

    for (var index = 0; index < lines.length; index++) {
      final separator = lines[index].indexOf('-');
      if (separator <= 0 ||
          separator == lines[index].length - 1 ||
          lines[index].substring(0, separator).trim().isEmpty ||
          lines[index].substring(separator + 1).trim().isEmpty) {
        return 'Line ${index + 1}: use Name - Contact Number.';
      }
    }
    return null;
  }

  List<Student> _parseEntries() {
    final now = DateTime.now();
    final addedDate =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';

    return _entriesController.text
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .map((line) {
          final separator = line.indexOf('-');
          return Student(
            name: line.substring(0, separator).trim(),
            phone: line.substring(separator + 1).trim(),
            source: _source,
            addedDate: addedDate,
          );
        })
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4,
                    width: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDDE3E9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'Add New Student',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Add one contact per line using Name - Contact Number.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _entriesController,
                  autofocus: true,
                  minLines: 4,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    alignLabelWithHint: true,
                    labelText: 'Student names and contact numbers',
                    hintText:
                        'Achira Maneth - 0701061244\nMia Patel - 555-0104',
                    prefixIcon: Padding(
                      padding: EdgeInsets.only(bottom: 58),
                      child: Icon(Icons.people_outline_rounded),
                    ),
                  ),
                  validator: _validateEntries,
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: _source,
                  decoration: const InputDecoration(
                    labelText: 'Data source',
                    prefixIcon: Icon(Icons.source_outlined),
                  ),
                  items: _sources
                      .map(
                        (source) => DropdownMenuItem(
                          value: source,
                          child: Text(source),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _source = value);
                  },
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onSurface,
                            side: BorderSide(
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: () {
                            if (!_formKey.currentState!.validate()) return;
                            Navigator.of(context).pop(_parseEntries());
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _green,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text(
                            'Save Student(s)',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LeadReportsSheet extends StatelessWidget {
  const _LeadReportsSheet({
    required this.notInterestedCount,
    required this.notPotentialCount,
    required this.inactiveCount,
  });

  final int notInterestedCount;
  final int notPotentialCount;
  final int inactiveCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Lead reports',
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Export closed leads as separate CSV reports.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.surfaceContainerLow,
              child: Column(
                children: [
                  _reportTile(
                    context,
                    title: 'Not Interested',
                    count: notInterestedCount,
                    action: _LeadReportAction.notInterested,
                  ),
                  Divider(
                    height: 1,
                    indent: 56,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  _reportTile(
                    context,
                    title: 'Not Potential',
                    count: notPotentialCount,
                    action: _LeadReportAction.notPotential,
                  ),
                  Divider(
                    height: 1,
                    indent: 56,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  _reportTile(
                    context,
                    title: 'Inactive (Unreachable)',
                    count: inactiveCount,
                    action: _LeadReportAction.inactive,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportTile(
    BuildContext context, {
    required String title,
    required int count,
    required _LeadReportAction action,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        Icons.file_download_outlined,
        color: count == 0 ? theme.colorScheme.onSurfaceVariant : _green,
      ),
      title: Text(title),
      subtitle: Text('$count student(s) · Export CSV'),
      enabled: count > 0,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: count == 0 ? null : () => Navigator.pop(context, action),
    );
  }
}

class _SettingsHubSheet extends StatefulWidget {
  const _SettingsHubSheet({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.isSheetConnected,
    required this.hasActiveFilters,
    required this.biometricEnabled,
    required this.onBiometricChanged,
  });

  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeModeChanged;
  final bool isSheetConnected;
  final bool hasActiveFilters;
  final bool biometricEnabled;
  final Future<void> Function(bool) onBiometricChanged;

  @override
  State<_SettingsHubSheet> createState() => _SettingsHubSheetState();
}

class _SettingsHubSheetState extends State<_SettingsHubSheet> {
  bool _callerIdEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadCallerIdState();
  }

  Future<void> _loadCallerIdState() async {
    final enabled = await CallerIdService.isEnabled();
    if (mounted) {
      setState(() => _callerIdEnabled = enabled);
    }
  }

  Future<void> _handleCallerIdToggle(bool enable) async {
    if (enable) {
      final hasOverlay = await CallerIdService.canDrawOverlays();
      if (!mounted) return;
      if (!hasOverlay) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (dialogCtx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.layers_outlined, color: Color(0xFF62D6B0)),
                SizedBox(width: 8),
                Text('Display Over Apps'),
              ],
            ),
            content: const Text(
              'To show the Caller ID popup when a student calls, LeadPilot needs the "Display over other apps" permission.\n\nPlease enable it on the next screen.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogCtx, true),
                child: const Text('Grant Permission'),
              ),
            ],
          ),
        );
        if (proceed == true) {
          await CallerIdService.requestOverlayPermission();
        }
      }

      final hasPhone = await CallerIdService.hasPhonePermissions();
      if (!hasPhone) {
        await CallerIdService.requestPhonePermissions();
      }

      await CallerIdService.setEnabled(true);
      if (mounted) setState(() => _callerIdEnabled = true);
    } else {
      await CallerIdService.setEnabled(false);
      if (mounted) setState(() => _callerIdEnabled = false);
    }
  }

  Future<void> _testCallerIdPopup() async {
    final hasOverlay = await CallerIdService.canDrawOverlays();
    if (!mounted) return;
    if (!hasOverlay) {
      await _handleCallerIdToggle(true);
      return;
    }
    await CallerIdService.testCallerIdPopup();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Sample Caller ID popup displayed!'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  height: 4,
                  width: 40,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF526170)
                        : const Color(0xFFDDE3E9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Settings',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Appearance',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<ThemeMode>(
                key: ValueKey(widget.themeMode),
                initialValue: widget.themeMode,
                decoration: const InputDecoration(
                  labelText: 'Theme',
                  prefixIcon: Icon(Icons.palette_outlined),
                ),
                items: const [
                  DropdownMenuItem(
                    value: ThemeMode.system,
                    child: Text('System default'),
                  ),
                  DropdownMenuItem(
                    value: ThemeMode.light,
                    child: Text('Light'),
                  ),
                  DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                ],
                onChanged: (mode) {
                  if (mode != null) unawaited(widget.onThemeModeChanged(mode));
                },
              ),
              const SizedBox(height: 20),
              Text(
                'Student data',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    ListTile(
                      leading: Badge(
                        isLabelVisible: widget.hasActiveFilters,
                        child: const Icon(Icons.tune_rounded),
                      ),
                      title: const Text('Filter by date and call status'),
                      subtitle: const Text(
                        'Choose a date range and status such as No Answer',
                      ),
                      onTap: () =>
                          Navigator.pop(context, _SettingsAction.filters),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(Icons.assessment_outlined),
                      title: const Text('Lead reports'),
                      subtitle: const Text(
                        'Export Not Interested and Not Potential separately',
                      ),
                      onTap: () =>
                          Navigator.pop(context, _SettingsAction.reports),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(Icons.file_download_outlined),
                      title: const Text('Download CSV report'),
                      subtitle: const Text(
                        'Export the students matching your current filters',
                      ),
                      onTap: () =>
                          Navigator.pop(context, _SettingsAction.export),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(Icons.contact_phone_outlined),
                      title: const Text('Save contacts'),
                      subtitle: const Text(
                        'Save displayed contacts and skip numbers already saved',
                      ),
                      onTap: () =>
                          Navigator.pop(context, _SettingsAction.saveContacts),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(Icons.chat_outlined),
                      title: const Text('WhatsApp templates'),
                      subtitle: const Text(
                        'Manage pre-written message templates',
                      ),
                      onTap: () => Navigator.pop(
                        context,
                        _SettingsAction.whatsAppTemplates,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Sync and storage',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: ListTile(
                  leading: const Icon(Icons.cloud_sync_outlined),
                  title: const Text('Google Sheets Sync'),
                  subtitle: Text(
                    widget.isSheetConnected
                        ? 'Sheet URL and linked sheets'
                        : 'Link a Google Apps Script Web App',
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onTap: () =>
                      Navigator.pop(context, _SettingsAction.sheetSync),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Security',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: SwitchListTile(
                  secondary: const Icon(Icons.fingerprint_rounded),
                  title: const Text('Fingerprint Login'),
                  subtitle: const Text(
                    'Use fingerprint to log in instead of PIN',
                  ),
                  value: widget.biometricEnabled,
                  onChanged: (val) => unawaited(widget.onBiometricChanged(val)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Caller ID',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.phone_in_talk_rounded),
                      title: const Text('Incoming Caller ID Popup'),
                      subtitle: const Text(
                        'Show offline student details when a registered lead calls',
                      ),
                      value: _callerIdEnabled,
                      onChanged: _handleCallerIdToggle,
                    ),
                    if (_callerIdEnabled) ...[
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      ListTile(
                        leading: const Icon(Icons.preview_rounded),
                        title: const Text('Preview / Test Popup'),
                        subtitle: const Text(
                          'Display a sample floating card over the screen',
                        ),
                        onTap: _testCallerIdPopup,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'LeadPilot v1.11.0',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetSettingsSheet extends StatefulWidget {
  const _SheetSettingsSheet({
    required this.initialUrl,
    required this.initialName,
    required this.savedSheets,
    required this.isConnected,
  });

  final String initialUrl;
  final String initialName;
  final List<LinkedSheet> savedSheets;
  final bool isConnected;

  @override
  State<_SheetSettingsSheet> createState() => _SheetSettingsSheetState();
}

class _SheetSettingsSheetState extends State<_SheetSettingsSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController = TextEditingController(
    text: widget.initialUrl,
  );
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName,
  );
  late LinkedSheet? _selectedSavedSheet = widget.savedSheets
      .where((sheet) => sheet.url == widget.initialUrl)
      .firstOrNull;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4,
                    width: 40,
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF526170)
                          : const Color(0xFFDDE3E9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Google Sheets Sync',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    _ConnectionBadge(isConnected: widget.isConnected),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Connect your Google Apps Script Web App to sync student contacts.',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 18),
                if (widget.savedSheets.isNotEmpty) ...[
                  DropdownButtonFormField<LinkedSheet>(
                    initialValue: _selectedSavedSheet,
                    decoration: const InputDecoration(
                      labelText: 'Previously linked sheets',
                      prefixIcon: Icon(Icons.history_rounded),
                    ),
                    hint: const Text('Choose a saved sheet'),
                    items: widget.savedSheets
                        .map(
                          (sheet) => DropdownMenuItem<LinkedSheet>(
                            value: sheet,
                            child: Text(
                              sheet.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (sheet) {
                      if (sheet == null) return;
                      setState(() {
                        _selectedSavedSheet = sheet;
                        _nameController.text = sheet.name;
                        _urlController.text = sheet.url;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  key: const ValueKey('sheet-name-input'),
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Sheet name',
                    hintText: 'e.g. 2026 A/L Leads',
                    prefixIcon: Icon(Icons.label_outline_rounded),
                  ),
                  validator: (value) => value?.trim().isNotEmpty == true
                      ? widget.savedSheets.any(
                              (sheet) =>
                                  sheet.url != _urlController.text.trim() &&
                                  sheet.name.toLowerCase() ==
                                      value!.trim().toLowerCase(),
                            )
                            ? 'Another linked sheet already uses this name'
                            : null
                      : 'Enter a name for this sheet',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('sheet-url-input'),
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: (_) {
                    if (_selectedSavedSheet != null &&
                        _urlController.text != _selectedSavedSheet!.url) {
                      setState(() => _selectedSavedSheet = null);
                    }
                    
                  },
                  decoration: const InputDecoration(
                    labelText: 'Google Apps Script Web App URL',
                    hintText: 'https://script.google.com/macros/s/.../exec',
                    prefixIcon: Icon(Icons.link_rounded),
                  ),
                  validator: (value) {
                    final uri = Uri.tryParse(value?.trim() ?? '');
                    if (uri == null ||
                        uri.scheme != 'https' ||
                        uri.host.isEmpty ||
                        !uri.path.endsWith('/exec')) {
                      return 'Enter a valid HTTPS Web App URL ending in /exec';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.brightness == Brightness.dark
                        ? const Color(0xFF24323E)
                        : const Color(0xFFF3F7F9),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Setup instructions',
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 7),
                      Text(
                        'Deploy your Apps Script as a Web App and paste its /exec URL. '
                        'GET should return a JSON list of {name, contact} records. '
                        'POST should read the JSON request body with name and contact. '
                        'Restrict access appropriately and validate writes in your script.',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurface,
                            side: BorderSide(
                              color: theme.colorScheme.outlineVariant,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (!_formKey.currentState!.validate()) return;
                            Navigator.of(context).pop(
                              LinkedSheet(
                                name: _nameController.text.trim(),
                                url: _urlController.text.trim(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.sync_rounded, size: 18),
                          label: const Text('Save & Sync'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _green,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.isConnected});

  final bool isConnected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final color = isConnected
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isDark
            ? isConnected
                  ? const Color(0xFF17382F)
                  : const Color(0xFF263440)
            : isConnected
            ? const Color(0xFFEAF6F2)
            : const Color(0xFFF0F3F6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isConnected ? Icons.check_circle_rounded : Icons.circle_outlined,
            color: color,
            size: 14,
          ),
          const SizedBox(width: 5),
          Text(
            isConnected ? 'Connected' : 'Not connected',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

enum _WhatsAppChoice { custom, template }

class _WhatsAppChoiceSheet extends StatelessWidget {
  const _WhatsAppChoiceSheet({required this.student});

  final Student student;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                height: 4,
                width: 40,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF526170)
                      : const Color(0xFFDDE3E9),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Send WhatsApp Message',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Message to ${student.name}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            Card(
              color: theme.colorScheme.surfaceContainerLow,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: const Text('Custom'),
                    subtitle: const Text('Open WhatsApp with a blank chat'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pop(context, _WhatsAppChoice.custom),
                  ),
                  Divider(
                    height: 1,
                    indent: 56,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  ListTile(
                    leading: const Icon(Icons.text_snippet_outlined),
                    title: const Text('Template'),
                    subtitle: const Text('Choose a pre-written message template'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pop(context, _WhatsAppChoice.template),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WhatsAppTemplatePickerSheet extends StatelessWidget {
  const _WhatsAppTemplatePickerSheet({
    required this.student,
    required this.templates,
    required this.onManageTemplates,
  });

  final Student student;
  final List<WhatsAppTemplate> templates;
  final VoidCallback onManageTemplates;

  String _formatMessage(String template) {
    final studentName = student.name.trim();
    return template.replaceAll(
      '{name}',
      studentName.isNotEmpty ? studentName : 'there',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                height: 4,
                width: 40,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF526170)
                      : const Color(0xFFDDE3E9),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Select Template',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Tap a template to send to ${student.name}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: onManageTemplates,
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Manage'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (templates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Icon(
                      Icons.text_snippet_outlined,
                      size: 48,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No templates found',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: onManageTemplates,
                      icon: const Icon(Icons.add),
                      label: const Text('Create Template'),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: templates.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = templates[index];
                    final preview = _formatMessage(item.message);
                    return Card(
                      color: theme.colorScheme.surfaceContainerLow,
                      margin: EdgeInsets.zero,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.pop(context, preview),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.chat_bubble_outline,
                                    size: 18,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      item.name,
                                      style:
                                          theme.textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    Icons.send_rounded,
                                    size: 16,
                                    color: theme.colorScheme.primary,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                preview,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TemplateEditorDialog extends StatefulWidget {
  const _TemplateEditorDialog({this.template});

  final WhatsAppTemplate? template;

  @override
  State<_TemplateEditorDialog> createState() => _TemplateEditorDialogState();
}

class _TemplateEditorDialogState extends State<_TemplateEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _messageController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.template?.name ?? '');
    _messageController =
        TextEditingController(text: widget.template?.message ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.template == null ? 'Add Template' : 'Edit Template'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Template Name',
                  hintText: 'e.g. Class Follow-up',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.sentences,
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter a template name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _messageController,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  hintText: 'e.g. Hello {name}, your class starts tomorrow.',
                  helperText: 'Tip: Use {name} for student name',
                  border: OutlineInputBorder(),
                ),
                maxLines: 4,
                minLines: 2,
                textCapitalization: TextCapitalization.sentences,
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter message content';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState?.validate() ?? false) {
              final result = WhatsAppTemplate(
                id: widget.template?.id ??
                    DateTime.now().millisecondsSinceEpoch.toString(),
                name: _nameController.text.trim(),
                message: _messageController.text.trim(),
              );
              Navigator.pop(context, result);
            }
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ManageWhatsAppTemplatesSheet extends StatefulWidget {
  const _ManageWhatsAppTemplatesSheet({required this.settingsStore});

  final AppSettingsStore settingsStore;

  @override
  State<_ManageWhatsAppTemplatesSheet> createState() =>
      _ManageWhatsAppTemplatesSheetState();
}

class _ManageWhatsAppTemplatesSheetState
    extends State<_ManageWhatsAppTemplatesSheet> {
  List<WhatsAppTemplate> _templates = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    final list = await widget.settingsStore.readWhatsAppTemplates();
    if (mounted) {
      setState(() {
        _templates = List.of(list);
        _isLoading = false;
      });
    }
  }

  Future<void> _saveTemplates() async {
    await widget.settingsStore.saveWhatsAppTemplates(_templates);
  }

  Future<void> _addOrEditTemplate([WhatsAppTemplate? existing]) async {
    final saved = await showDialog<WhatsAppTemplate>(
      context: context,
      builder: (_) => _TemplateEditorDialog(template: existing),
    );

    if (saved != null && mounted) {
      setState(() {
        if (existing == null) {
          _templates.add(saved);
        } else {
          final index = _templates.indexWhere((t) => t.id == existing.id);
          if (index != -1) {
            _templates[index] = saved;
          }
        }
      });
      await _saveTemplates();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              existing == null ? 'Template added' : 'Template updated',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _deleteTemplate(WhatsAppTemplate template) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Delete Template'),
        content: Text('Are you sure you want to delete "${template.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() {
        _templates.removeWhere((t) => t.id == template.id);
      });
      await _saveTemplates();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Template deleted'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                height: 4,
                width: 40,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF526170)
                      : const Color(0xFFDDE3E9),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'WhatsApp Templates',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => _addOrEditTemplate(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Pre-written messages with {name} placeholder support.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (_isLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_templates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Column(
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 48,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No templates yet',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tap "Add" to create your first WhatsApp template.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _templates.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = _templates[index];
                    return Card(
                      color: theme.colorScheme.surfaceContainerLow,
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    item.name,
                                    style:
                                        theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 20,
                                  ),
                                  tooltip: 'Edit template',
                                  onPressed: () => _addOrEditTemplate(item),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                    color: theme.colorScheme.error,
                                  ),
                                  tooltip: 'Delete template',
                                  onPressed: () => _deleteTemplate(item),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.message,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
