import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;
import 'package:url_launcher/url_launcher.dart';

const _navy = Color(0xFF142B4A);
const _green = Color(0xFF159A76);
const _canvas = Color(0xFFF4F7FA);
const _muted = Color(0xFF748194);
const String kAppVersion = '1.22.1';
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

Uri smsComposerUri(String phoneNumber, {String? body}) {
  final digits = normalizeContactPhone(phoneNumber);
  final path = digits.isEmpty ? '' : '+$digits';
  if (body != null && body.trim().isNotEmpty) {
    return Uri(
      scheme: 'sms',
      path: path,
      queryParameters: <String, String>{'body': body.trim()},
    );
  }
  return Uri(scheme: 'sms', path: path);
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

DateTime? tryParseDate(dynamic value) {
  if (value == null) return null;
  final str = value.toString().trim();
  if (str.isEmpty) return null;

  final direct = DateTime.tryParse(str);
  if (direct != null) return direct;

  final matchYmdAmPm = RegExp(
    r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})[T\s]+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)$',
    caseSensitive: false,
  ).firstMatch(str);
  if (matchYmdAmPm != null) {
    final year = int.parse(matchYmdAmPm[1]!);
    final month = int.parse(matchYmdAmPm[2]!);
    final day = int.parse(matchYmdAmPm[3]!);
    final rawHour = int.parse(matchYmdAmPm[4]!);
    final minute = int.parse(matchYmdAmPm[5]!);
    final second = int.tryParse(matchYmdAmPm[6] ?? '0') ?? 0;
    final isPm = matchYmdAmPm[7]!.toUpperCase() == 'PM';
    final hour = (rawHour % 12) + (isPm ? 12 : 0);
    return DateTime(year, month, day, hour, minute, second);
  }

  final matchDmy = RegExp(
    r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})(?:[T\s]+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?)?$',
    caseSensitive: false,
  ).firstMatch(str);
  if (matchDmy != null) {
    final day = int.parse(matchDmy[1]!);
    final month = int.parse(matchDmy[2]!);
    final year = int.parse(matchDmy[3]!);
    final rawHour = matchDmy[4] != null ? int.parse(matchDmy[4]!) : 0;
    final minute = matchDmy[5] != null ? int.parse(matchDmy[5]!) : 0;
    final second = matchDmy[6] != null ? int.parse(matchDmy[6]!) : 0;
    final amPm = matchDmy[7]?.toUpperCase();
    final int hour;
    if (amPm != null) {
      hour = (rawHour % 12) + (amPm == 'PM' ? 12 : 0);
    } else {
      hour = rawHour;
    }
    return DateTime(year, month, day, hour, minute, second);
  }

  if (RegExp(r'^\d{10,13}$').hasMatch(str)) {
    final millis = int.tryParse(str);
    if (millis != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        str.length == 10 ? millis * 1000 : millis,
      );
    }
  }

  return null;
}

DateTime _defaultFutureReminder([DateTime? base]) {
  final now = base ?? DateTime.now();
  final target = now.add(const Duration(minutes: 15));
  final remainder = target.minute % 5;
  final roundedMinute = remainder == 0 ? target.minute : target.minute + (5 - remainder);
  if (roundedMinute >= 60) {
    return DateTime(target.year, target.month, target.day, target.hour + 1, roundedMinute - 60);
  }
  return DateTime(target.year, target.month, target.day, target.hour, roundedMinute);
}

DateTime? _parseActivityDate(String value) => tryParseDate(value);

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

class WhatsAppSendPayload {
  const WhatsAppSendPayload({
    required this.message,
    this.documentPaths = const [],
  });

  final String message;
  final List<String> documentPaths;

  bool get hasDocuments => documentPaths.any((p) => p.trim().isNotEmpty);
}

class WhatsAppTemplate {
  const WhatsAppTemplate({
    required this.id,
    required this.name,
    required this.message,
    this.documentPath,
    this.documentName,
  });

  final String id;
  final String name;
  final String message;
  final String? documentPath;
  final String? documentName;

  bool get hasDocument =>
      documentPath != null &&
      documentPath!.trim().isNotEmpty &&
      documentName != null &&
      documentName!.trim().isNotEmpty;

  WhatsAppTemplate copyWith({
    String? id,
    String? name,
    String? message,
    String? documentPath,
    String? documentName,
    bool clearDocument = false,
  }) {
    return WhatsAppTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      message: message ?? this.message,
      documentPath: clearDocument ? null : (documentPath ?? this.documentPath),
      documentName: clearDocument ? null : (documentName ?? this.documentName),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'message': message,
    if (documentPath != null) 'documentPath': documentPath,
    if (documentName != null) 'documentName': documentName,
  };

  factory WhatsAppTemplate.fromJson(Map<String, dynamic> json) {
    return WhatsAppTemplate(
      id: (json['id'] as String?) ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: (json['name'] as String?) ?? '',
      message: (json['message'] as String?) ?? '',
      documentPath: json['documentPath'] as String?,
      documentName: json['documentName'] as String?,
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

const String _defaultCompanyDescription =
    'LNBTI (Lanka Nippon BizTech Institute) - Japanese-based Higher Education Institute in Sri Lanka offering IT & Computing degrees with Japanese language and pathway to careers in Japan.';

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

  Future<String> readGeminiApiKey();

  Future<void> saveGeminiApiKey(String key);

  Future<String> readGeminiModel();

  Future<void> saveGeminiModel(String model);

  Future<String> readCompanyDescription();

  Future<void> saveCompanyDescription(String description);

  Future<bool> readAutoCheckUpdates();

  Future<void> saveAutoCheckUpdates(bool enabled);

  Future<bool> readAutoLogCallDuration();

  Future<void> saveAutoLogCallDuration(bool enabled);
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
  static const _geminiApiKeyKey = 'student_call_gemini_api_key';
  static const _geminiModelKey = 'student_call_gemini_model';
  static const _companyDescriptionKey = 'student_call_company_description';
  static const _autoCheckUpdatesKey = 'student_call_auto_check_updates';
  static const _autoLogCallDurationKey = 'student_call_auto_log_call_duration';
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
  Future<String> readGeminiApiKey() async =>
      await _storage.read(key: _geminiApiKeyKey) ?? '';

  @override
  Future<void> saveGeminiApiKey(String key) =>
      _storage.write(key: _geminiApiKeyKey, value: key.trim());

  @override
  Future<String> readGeminiModel() async =>
      await _storage.read(key: _geminiModelKey) ?? 'gemini-1.5-flash';

  @override
  Future<void> saveGeminiModel(String model) =>
      _storage.write(key: _geminiModelKey, value: model.trim());

  @override
  Future<String> readCompanyDescription() async {
    final value = await _storage.read(key: _companyDescriptionKey);
    if (value == null || value.trim().isEmpty) {
      return _defaultCompanyDescription;
    }
    return value.trim();
  }

  @override
  Future<void> saveCompanyDescription(String description) =>
      _storage.write(
        key: _companyDescriptionKey,
        value: description.trim().isEmpty
            ? _defaultCompanyDescription
            : description.trim(),
      );

  @override
  Future<bool> readAutoCheckUpdates() async {
    final value = await _storage.read(key: _autoCheckUpdatesKey);
    return value != 'false';
  }

  @override
  Future<void> saveAutoCheckUpdates(bool enabled) =>
      _storage.write(key: _autoCheckUpdatesKey, value: enabled.toString());

  @override
  Future<bool> readAutoLogCallDuration() async {
    final value = await _storage.read(key: _autoLogCallDurationKey);
    return value != 'false';
  }

  @override
  Future<void> saveAutoLogCallDuration(bool enabled) =>
      _storage.write(key: _autoLogCallDurationKey, value: enabled.toString());

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
  String geminiApiKey = '';
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

  @override
  Future<String> readGeminiApiKey() async => geminiApiKey;

  @override
  Future<void> saveGeminiApiKey(String key) async {
    geminiApiKey = key.trim();
  }

  String geminiModel = 'gemini-1.5-flash';
  String companyDescription = _defaultCompanyDescription;

  @override
  Future<String> readGeminiModel() async => geminiModel;

  @override
  Future<void> saveGeminiModel(String model) async {
    geminiModel = model.trim();
  }

  @override
  Future<String> readCompanyDescription() async => companyDescription;

  @override
  Future<void> saveCompanyDescription(String description) async {
    companyDescription = description.trim().isEmpty
        ? _defaultCompanyDescription
        : description.trim();
  }

  bool autoCheckUpdates = true;
  bool autoLogCallDuration = true;

  @override
  Future<bool> readAutoCheckUpdates() async => autoCheckUpdates;

  @override
  Future<void> saveAutoCheckUpdates(bool enabled) async {
    autoCheckUpdates = enabled;
  }

  @override
  Future<bool> readAutoLogCallDuration() async => autoLogCallDuration;

  @override
  Future<void> saveAutoLogCallDuration(bool enabled) async {
    autoLogCallDuration = enabled;
  }
}

ThemeMode _themeModeFromName(String? value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

String formatCallDuration(int seconds) {
  if (seconds <= 0) return '0s';
  final mins = seconds ~/ 60;
  final secs = seconds % 60;
  if (mins > 0 && secs > 0) {
    return '$mins min${mins > 1 ? 's' : ''} ${secs.toString().padLeft(2, '0')} sec${secs > 1 ? 's' : ''}';
  } else if (mins > 0) {
    return '$mins min${mins > 1 ? 's' : ''}';
  } else {
    return '$secs sec${secs > 1 ? 's' : ''}';
  }
}

class CallerIdService {
  static const MethodChannel channel =
      MethodChannel('com.example.call_dial/caller_id');

  static Future<Map<String, dynamic>?> getLatestCallLog({String? phone}) async {
    try {
      final res = await channel.invokeMapMethod<String, dynamic>(
        'getLatestCallLog',
        {'phone': phone},
      );
      return res;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> getPendingCallLogs() async {
    try {
      final res = await channel.invokeListMethod<dynamic>('getPendingCallLogs');
      if (res == null) return [];
      return res
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } on MissingPluginException {
      return [];
    } catch (_) {
      return [];
    }
  }

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

  static Future<void> testNotificationBanner() async {
    try {
      await channel.invokeMethod('testNotificationBanner');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final res =
          await channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return res ?? true;
    } on MissingPluginException {
      return true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<void> openAppDetailsSettings() async {
    try {
      await channel.invokeMethod('openAppDetailsSettings');
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

  static Future<int> getCachedCount() async {
    try {
      final res = await channel.invokeMethod<int>('getCachedStudentCount');
      return res ?? 0;
    } on MissingPluginException {
      return 0;
    } catch (_) {
      return 0;
    }
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
    this.updateService,
    this.showSplash = true,
    super.key,
  });

  final http.Client? httpClient;
  final ReminderScheduler? reminderScheduler;
  final AppSettingsStore? settingsStore;
  final DeviceContactsService? deviceContactsService;
  final AppUpdateService? updateService;
  final bool showSplash;

  @override
  State<StudentCallApp> createState() => _StudentCallAppState();
}

class _StudentCallAppState extends State<StudentCallApp> {
  late bool _showSplash = widget.showSplash;
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
      home: _showSplash
          ? AppSplashScreen(
              onFinished: () {
                if (mounted) setState(() => _showSplash = false);
              },
            )
          : _isLoadingSettings
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
              updateService: widget.updateService,
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
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _settingsLoadError = error;
        _isLoadingSettings = false;
      });
    }
  }

  bool _isBiometricRunning = false;

  Future<bool> _tryBiometricLogin() async {
    if (_isBiometricRunning) return false;
    _isBiometricRunning = true;
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
    } finally {
      _isBiometricRunning = false;
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

class LeadPilotAppIcon extends StatelessWidget {
  const LeadPilotAppIcon({
    super.key,
    this.size = 80,
    this.showGlow = true,
  });

  final double size;
  final bool showGlow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.24),
        boxShadow: showGlow
            ? [
                BoxShadow(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                  blurRadius: size * 0.3,
                  spreadRadius: 2,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.25),
                  blurRadius: size * 0.4,
                  spreadRadius: 1,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.asset(
          'assets/images/app_icon.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _LeadPilotVectorPainterWidget(size: size),
        ),
      ),
    );
  }
}

class _LeadPilotVectorPainterWidget extends StatelessWidget {
  const _LeadPilotVectorPainterWidget({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _LeadPilotVectorPainter(),
    );
  }
}

class _LeadPilotVectorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // Background squircle gradient
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [
          Color(0xFF0D142E),
          Color(0xFF171E42),
          Color(0xFF1E143D),
        ],
      ).createShader(rect);

    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(w * 0.22));
    canvas.drawRRect(rrect, bgPaint);

    // Subtle communication radar arcs
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.02
      ..color = const Color(0xFF00F5D4).withValues(alpha: 0.2);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(w * 0.35, h * 0.65), radius: w * 0.32),
      -1.8,
      1.6,
      false,
      arcPaint,
    );

    // Left main wing (Cyan to Teal)
    final nose = Offset(w * 0.80, h * 0.22);
    final leftWing = Offset(w * 0.22, h * 0.48);
    final tailCenter = Offset(w * 0.44, h * 0.60);
    final rightWing = Offset(w * 0.54, h * 0.78);

    final leftWingPath = Path()
      ..moveTo(nose.dx, nose.dy)
      ..lineTo(leftWing.dx, leftWing.dy)
      ..lineTo(tailCenter.dx, tailCenter.dy)
      ..close();

    final leftPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: const [
          Color(0xFF00F5F2),
          Color(0xFF00C7A6),
          Color(0xFF1273BF),
        ],
      ).createShader(leftWingPath.getBounds());
    canvas.drawPath(leftWingPath, leftPaint);

    // Right wing (Violet to Indigo)
    final rightWingPath = Path()
      ..moveTo(nose.dx, nose.dy)
      ..lineTo(tailCenter.dx, tailCenter.dy)
      ..lineTo(rightWing.dx, rightWing.dy)
      ..close();

    final rightPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: const [
          Color(0xFFA761FF),
          Color(0xFF6B2EC9),
          Color(0xFF2E1F73),
        ],
      ).createShader(rightWingPath.getBounds());
    canvas.drawPath(rightWingPath, rightPaint);

    // Center ridge line
    final ridgePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = w * 0.018
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(nose, tailCenter, ridgePaint);

    // AI Star Sparkle at nose
    final starRadius = w * 0.045;
    final starPath = Path()
      ..moveTo(nose.dx, nose.dy - starRadius)
      ..quadraticBezierTo(nose.dx, nose.dy, nose.dx + starRadius, nose.dy)
      ..quadraticBezierTo(nose.dx, nose.dy, nose.dx, nose.dy + starRadius)
      ..quadraticBezierTo(nose.dx, nose.dy, nose.dx - starRadius, nose.dy)
      ..quadraticBezierTo(nose.dx, nose.dy, nose.dx, nose.dy - starRadius)
      ..close();

    canvas.drawCircle(
      nose,
      starRadius * 1.5,
      Paint()..color = const Color(0xFF00F2FE).withValues(alpha: 0.4),
    );
    canvas.drawPath(starPath, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class AppSplashScreen extends StatefulWidget {
  const AppSplashScreen({
    super.key,
    required this.onFinished,
    this.duration = const Duration(milliseconds: 1200),
  });

  final VoidCallback onFinished;
  final Duration duration;

  @override
  State<AppSplashScreen> createState() => _AppSplashScreenState();
}

class _AppSplashScreenState extends State<AppSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _textFadeAnimation;
  late final Animation<Offset> _textSlideAnimation;
  late final Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    _scaleAnimation = Tween<double>(begin: 0.45, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.65, curve: Curves.easeOutBack),
      ),
    );

    _glowAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.2, 0.75, curve: Curves.easeInOut),
      ),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.45, curve: Curves.easeIn),
      ),
    );

    _textFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.85, curve: Curves.easeIn),
      ),
    );

    _textSlideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.35),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.85, curve: Curves.easeOutCubic),
      ),
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onFinished();
      }
    });

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090E1A),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onFinished,
        child: Stack(
          children: [
            // Ambient background gradient glow
            Positioned.fill(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0, -0.15),
                    radius: 0.85,
                    colors: [
                      Color(0xFF162544),
                      Color(0xFF0A1020),
                      Color(0xFF060912),
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Glowing app icon with scale & fade
                      Transform.scale(
                        scale: _scaleAnimation.value,
                        child: Opacity(
                          opacity: _fadeAnimation.value.clamp(0.0, 1.0),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Radial pulse ring
                              Container(
                                width: 140 * _glowAnimation.value,
                                height: 140 * _glowAnimation.value,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF00E5FF).withValues(
                                        alpha: 0.25 * _glowAnimation.value,
                                      ),
                                      blurRadius: 36,
                                      spreadRadius: 8,
                                    ),
                                    BoxShadow(
                                      color: const Color(0xFF8B5CF6).withValues(
                                        alpha: 0.2 * _glowAnimation.value,
                                      ),
                                      blurRadius: 48,
                                      spreadRadius: 12,
                                    ),
                                  ],
                                ),
                              ),
                              const LeadPilotAppIcon(size: 96),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // App Name & Tagline slide and fade
                      SlideTransition(
                        position: _textSlideAnimation,
                        child: FadeTransition(
                          opacity: _textFadeAnimation,
                          child: Column(
                            children: [
                              ShaderMask(
                                shaderCallback: (bounds) => const LinearGradient(
                                  colors: [
                                    Colors.white,
                                    Color(0xFFE2E8F0),
                                    Color(0xFF67E8F9),
                                  ],
                                ).createShader(bounds),
                                child: const Text(
                                  'LeadPilot',
                                  style: TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.2,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'STUDENT LEADS • SMART DIALER',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 2.4,
                                  color: const Color(0xFF67E8F9).withValues(alpha: 0.8),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
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
        if (mounted) _doBiometricAuth(isAutoTrigger: true);
      });
    }
  }

  Future<void> _doBiometricAuth({bool isAutoTrigger = false}) async {
    if (_biometricRunning || widget.onBiometricAuth == null) return;
    setState(() => _biometricRunning = true);
    try {
      final success = await widget.onBiometricAuth!();
      if (!mounted) return;
      setState(() => _biometricRunning = false);
      if (!success) {
        if (isAutoTrigger) {
          // User simply dismissed the prompt to enter PIN or prompt closed cleanly.
          // Do NOT count as a failed attempt or show error text on initial startup.
          return;
        }
        setState(() {
          _biometricFailCount++;
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
          _biometricRunning = false;
          if (!isAutoTrigger) {
            _biometricFailCount++;
            if (_biometricFailCount >= _maxBiometricAttempts) {
              _message = 'Fingerprint failed 3 times. Enter your PIN.';
              _hasError = true;
            } else {
              _message = 'Could not read fingerprint. Try again or enter PIN.';
              _hasError = true;
            }
          }
        });
      }
      return;
    }
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
                                        : () => _doBiometricAuth(isAutoTrigger: false),
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

  Student updateLastComment(String newComment) {
    final trimmed = newComment.trim();

    // 1. Update commentHistory (only the last entry)
    final newHistory = List<String>.of(commentHistory);
    if (newHistory.isNotEmpty) {
      final lastEntry = newHistory.last;
      final separatorIndex = lastEntry.indexOf(' — ');
      if (separatorIndex >= 0) {
        final datePart = lastEntry.substring(0, separatorIndex);
        newHistory[newHistory.length - 1] = '$datePart — $trimmed';
      } else {
        newHistory[newHistory.length - 1] = trimmed;
      }
    } else if (trimmed.isNotEmpty) {
      final formattedNow = _formatReminder(DateTime.now());
      newHistory.add('$formattedNow — $trimmed');
    }

    // 2. Update attempts (only the last attempt with a comment, or the very last attempt)
    final newAttempts = List<CallAttempt>.of(attempts);
    int lastAttemptIndex = -1;
    for (int i = newAttempts.length - 1; i >= 0; i--) {
      if (newAttempts[i].comment.trim().isNotEmpty) {
        lastAttemptIndex = i;
        break;
      }
    }
    if (lastAttemptIndex < 0 && newAttempts.isNotEmpty) {
      lastAttemptIndex = newAttempts.length - 1;
    }

    if (lastAttemptIndex >= 0) {
      final target = newAttempts[lastAttemptIndex];
      newAttempts[lastAttemptIndex] = CallAttempt(
        dateTime: target.dateTime,
        status: target.status,
        comment: trimmed,
      );
    }

    return copyWith(
      comment: trimmed,
      commentHistory: newHistory,
      attempts: newAttempts,
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

typedef StudentHistoryEntry = ({
  DateTime? date,
  String dateLabel,
  int order,
  String status,
  String text,
});

List<StudentHistoryEntry> buildStudentHistoryEntries(Student student) {
  final entries = <StudentHistoryEntry>[];
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
  return entries;
}

String formatStudentHistoryForPrompt(Student student) {
  final entries = buildStudentHistoryEntries(student);
  if (entries.isEmpty) {
    return 'No previous call attempts or historical comments recorded yet.';
  }

  final buffer = StringBuffer();
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final dateStr = entry.dateLabel.isNotEmpty
        ? entry.dateLabel
        : (entry.date != null
            ? _formatReminder(entry.date!)
            : 'Date not recorded');
    final statusStr =
        entry.status.trim().isNotEmpty ? entry.status.trim() : 'Note';
    final commentStr =
        entry.text.trim().isNotEmpty ? entry.text.trim() : '(No remark written)';
    buffer.writeln(
      '${i + 1}. [Date & Time: $dateStr] Call Status: "$statusStr" | Call Remark: "$commentStr"',
    );
  }
  return buffer.toString().trim();
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
  geminiAi,
  companyDescription,
}

enum _StudentCardAction { edit, selectMultiple }

enum _LeadReportAction { notInterested, notPotential, inactive }

class GeminiException implements Exception {
  const GeminiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GeminiModelInfo {
  const GeminiModelInfo({
    required this.id,
    required this.displayName,
    this.description = '',
  });

  final String id;
  final String displayName;
  final String description;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeminiModelInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class GeminiTestResult {
  const GeminiTestResult({
    required this.isSuccess,
    required this.message,
    this.modelName,
    this.statusCode,
    this.availableModels = const [],
  });

  final bool isSuccess;
  final String message;
  final String? modelName;
  final int? statusCode;
  final List<GeminiModelInfo> availableModels;
}

class GeminiService {
  GeminiService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static const List<String> candidateModels = [
    'gemini-1.5-flash',
    'gemini-2.0-flash',
    'gemini-1.5-flash-8b',
    'gemini-1.5-pro',
  ];

  static const List<GeminiModelInfo> defaultModels = [
    GeminiModelInfo(
      id: 'gemini-1.5-flash',
      displayName: 'Gemini 1.5 Flash (Recommended - 100% Free)',
      description: 'Fast, versatile, and generous free tier (1,500 requests/day)',
    ),
    GeminiModelInfo(
      id: 'gemini-2.0-flash',
      displayName: 'Gemini 2.0 Flash (Next-Gen Fast)',
      description: 'Ultra-fast next generation model',
    ),
    GeminiModelInfo(
      id: 'gemini-1.5-flash-8b',
      displayName: 'Gemini 1.5 Flash 8B (High Speed)',
      description: 'Lightweight model built for maximum throughput',
    ),
    GeminiModelInfo(
      id: 'gemini-1.5-pro',
      displayName: 'Gemini 1.5 Pro (Advanced Reasoning)',
      description: 'High capacity model for complex queries',
    ),
  ];

  static String sanitizeApiKey(String raw) {
    var key = raw.trim();
    while ((key.startsWith('"') && key.endsWith('"')) ||
        (key.startsWith("'") && key.endsWith("'")) ||
        (key.startsWith('`') && key.endsWith('`'))) {
      if (key.length <= 1) break;
      key = key.substring(1, key.length - 1).trim();
    }
    final urlMatch = RegExp(r'[?&]key=([a-zA-Z0-9_\-\.]+)').firstMatch(key);
    if (urlMatch != null) {
      key = urlMatch.group(1)!;
    } else if (key.startsWith('key=')) {
      key = key.substring(4);
    } else if (key.startsWith('apiKey=')) {
      key = key.substring(7);
    }
    return key.replaceAll(RegExp(r'\s+'), '');
  }

  static bool looksLikeGoogleApiKey(String key) {
    return (key.startsWith('AIza') || key.startsWith('AQ.')) && key.length >= 25;
  }

  Future<List<GeminiModelInfo>> fetchAvailableModels(String apiKey) async {
    final cleanKey = sanitizeApiKey(apiKey);
    if (cleanKey.isEmpty) return const [];

    for (final apiVersion in ['v1beta', 'v1']) {
      try {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/$apiVersion/models?key=$cleanKey',
        );
        final response = await _client.get(
          url,
          headers: {
            'Accept': 'application/json',
            'x-goog-api-key': cleanKey,
          },
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map && data['models'] is List) {
            final list = <GeminiModelInfo>[];
            for (final item in data['models'] as List) {
              if (item is Map) {
                final rawName = (item['name'] as String?) ?? '';
                final methods = (item['supportedGenerationMethods'] as List?)
                        ?.map((e) => e.toString())
                        .toList() ??
                    [];
                if (methods.isNotEmpty && !methods.contains('generateContent')) {
                  continue;
                }
                final id = rawName.startsWith('models/')
                    ? rawName.substring(7)
                    : rawName;
                if (id.isEmpty) continue;
                final displayName = (item['displayName'] as String?) ?? id;
                final description = (item['description'] as String?) ?? '';

                final lowerId = id.toLowerCase();
                final lowerDisplay = displayName.toLowerCase();
                final lowerDesc = description.toLowerCase();

                // Exclude models that do not produce standard text response
                if (lowerId.contains('embedding') ||
                    lowerId.contains('embed') ||
                    lowerId.contains('aqa') ||
                    lowerId.contains('text-bison') ||
                    lowerId.contains('chat-bison') ||
                    lowerId.contains('tts') ||
                    lowerId.contains('audio') ||
                    lowerId.contains('realtime') ||
                    lowerId.contains('imagen') ||
                    lowerId.contains('image') ||
                    lowerId.contains('vision') ||
                    lowerDesc.contains('audio') ||
                    lowerDesc.contains('speech') ||
                    lowerDisplay.contains('tts')) {
                  continue;
                }

                list.add(GeminiModelInfo(
                  id: id,
                  displayName: displayName,
                  description: description,
                ));
              }
            }
            if (list.isNotEmpty) {
              list.sort((a, b) {
                int score(String id) {
                  final lower = id.toLowerCase();
                  if (lower == 'gemini-1.5-flash') return 0;
                  if (lower == 'gemini-2.0-flash') return 1;
                  if (lower == 'gemini-1.5-flash-8b') return 2;
                  if (lower.contains('1.5-flash')) return 3;
                  if (lower.contains('2.0-flash')) return 4;
                  if (lower.contains('flash') &&
                      !lower.contains('preview') &&
                      !lower.contains('exp')) {
                    return 5;
                  }
                  if (lower.contains('flash')) return 6;
                  if (lower == 'gemini-1.5-pro') return 7;
                  if (lower.contains('pro')) return 8;
                  return 9;
                }

                final sA = score(a.id);
                final sB = score(b.id);
                if (sA != sB) return sA.compareTo(sB);
                return a.displayName.compareTo(b.displayName);
              });
              return list;
            }
          }
        }
      } catch (_) {}
    }
    return const [];
  }

  Future<String> _generateWithPrompt({
    required String apiKey,
    required String prompt,
    String? model,
    double temperature = 0.7,
    int maxOutputTokens = 500,
  }) async {
    final cleanKey = sanitizeApiKey(apiKey);
    if (cleanKey.isEmpty) {
      throw const GeminiException('Please configure a valid Gemini API Key in Settings.');
    }

    String? lastError;

    final modelsToTry = <String>[];
    if (model != null && model.trim().isNotEmpty) {
      modelsToTry.add(model.trim());
    }
    for (final m in candidateModels) {
      if (!modelsToTry.contains(m)) {
        modelsToTry.add(m);
      }
    }

    for (final targetModel in modelsToTry) {
      try {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$targetModel:generateContent?key=$cleanKey',
        );
        final response = await _client.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': cleanKey,
          },
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'temperature': temperature,
              'maxOutputTokens': maxOutputTokens,
            },
          }),
        ).timeout(const Duration(seconds: 25));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final candidates = data['candidates'] as List?;
          if (candidates != null && candidates.isNotEmpty) {
            final content = candidates.first['content'] as Map?;
            final parts = content?['parts'] as List?;
            if (parts != null && parts.isNotEmpty) {
              final text = parts.first['text'] as String?;
              if (text != null && text.trim().isNotEmpty) {
                return text.trim();
              }
            }
          }
          throw const GeminiException(
            'Gemini did not return any message content.',
          );
        }

        String rawApiMessage = '';
        String rawReason = '';
        try {
          final errJson = jsonDecode(response.body);
          if (errJson is Map && errJson['error'] is Map) {
            final err = errJson['error'] as Map;
            rawApiMessage = (err['message'] as String?) ?? '';
            final details = err['details'] as List?;
            if (details != null && details.isNotEmpty) {
              final first = details.first as Map?;
              rawReason = (first?['reason'] as String?) ?? '';
            }
          }
        } catch (_) {}

        final isModelIncompatible = response.statusCode == 404 ||
            (response.statusCode == 400 &&
                (rawApiMessage.toLowerCase().contains('modalities') ||
                    rawApiMessage.toLowerCase().contains('not supported by the model') ||
                    rawApiMessage.toLowerCase().contains('not found') ||
                    rawApiMessage.toLowerCase().contains('unsupported for generatecontent')));

        if (isModelIncompatible) {
          final isApiDisabled = rawApiMessage.contains('is not found for API version') ||
              rawApiMessage.contains('not supported for generateContent') ||
              rawApiMessage.contains('ListModels');
          if (isApiDisabled) {
            lastError =
                'Generative Language API is disabled on this Google project (404).\n\n'
                'Please open Google AI Studio (aistudio.google.com/app/apikey) and click "Create API key in new project" to get an active free key.';
          } else {
            lastError = rawApiMessage.isNotEmpty ? rawApiMessage : 'Model $targetModel not supported.';
          }
          continue;
        }

        if (rawReason == 'ACCESS_TOKEN_TYPE_UNSUPPORTED' ||
            (response.statusCode == 401 && rawApiMessage.contains('API key not valid'))) {
          throw const GeminiException(
            'Google rejected this API Key (ACCESS_TOKEN_TYPE_UNSUPPORTED).\n\n'
            'Please generate an unrestricted key from Google AI Studio:\n'
            '1. Go to aistudio.google.com/app/apikey\n'
            '2. Click "Create API Key" -> "Create API key in new project"\n'
            '3. Copy and paste the new key here.',
          );
        }

        if (response.statusCode == 400 &&
            (rawApiMessage.toLowerCase().contains('api key not valid') ||
                rawApiMessage.toLowerCase().contains('api_key_invalid'))) {
          throw const GeminiException(
            'Invalid API Key: Google rejected this key. Please check your Gemini API key in Settings.',
          );
        }

        if (rawApiMessage.isNotEmpty) {
          throw GeminiException('Gemini API (${response.statusCode}): $rawApiMessage');
        }

        throw GeminiException(
          'Gemini request failed (status ${response.statusCode}). Check your API key or network.',
        );
      } on SocketException {
        throw const GeminiException(
          'No internet connection. Please check your network connection.',
        );
      } on TimeoutException {
        throw const GeminiException(
          'Request timed out. Google servers took too long to respond.',
        );
      } catch (e) {
        if (e is GeminiException) rethrow;
        lastError = e.toString();
      }
    }

    throw GeminiException(
      lastError != null && lastError.isNotEmpty
          ? lastError
          : 'Could not connect to Gemini service. Please check your API key.',
    );
  }

  Future<String> generateFollowUp({
    required String apiKey,
    required Student student,
    String? model,
    String language = 'Sinhala',
    String tone = 'General Follow-up',
    String customInstructions = '',
    String? companyDescription,
  }) async {
    final prompt = _buildPrompt(
      student: student,
      language: language,
      tone: tone,
      customInstructions: customInstructions,
      companyDescription: companyDescription,
    );

    return _generateWithPrompt(
      apiKey: apiKey,
      prompt: prompt,
      model: model,
      temperature: 0.7,
      maxOutputTokens: 500,
    );
  }

  Future<String> polishRemark({
    required String apiKey,
    required String rawRemark,
    String? model,
  }) async {
    final cleanRemark = rawRemark.trim();
    if (cleanRemark.isEmpty) {
      return '';
    }

    final prompt = '''
You are an expert CRM assistant for an educational institute (LNBTI).
A call agent wrote a rough or broken call remark about a student lead.
The agent's input may be in broken English, shorthand notes, or Singlish/Sinhala.

Raw remark from agent:
"$cleanRemark"

TASK:
Rewrite and polish this raw remark into a concise, professional CRM call remark in proper English.

CRITICAL RULES:
1. FACTUAL ACCURACY: Keep the exact meaning, dates, times, next steps, degree interests, and student situation intact. Do NOT invent new facts.
2. GRAMMAR & CLARITY: Correct all grammatical, spelling, capitalization, and phrasing issues.
3. CONCISENESS: Keep it brief and objective (1 to 2 clear sentences max).
4. OUTPUT FORMAT: Return ONLY the polished English remark text. Do not include quotes around the whole text, prefixes like "Polished Remark:", markdown code blocks, or explanations.
''';

    return _generateWithPrompt(
      apiKey: apiKey,
      prompt: prompt,
      model: model,
      temperature: 0.3,
      maxOutputTokens: 200,
    );
  }

  Future<GeminiTestResult> testConnection(
    String apiKey, {
    String? targetModel,
  }) async {
    final cleanKey = sanitizeApiKey(apiKey);
    if (cleanKey.isEmpty) {
      return const GeminiTestResult(
        isSuccess: false,
        message: 'API Key is empty. Please enter your Gemini API key.',
        availableModels: defaultModels,
      );
    }

    // 1. Discover models accessible to this API key
    List<GeminiModelInfo> fetchedModels = [];
    try {
      fetchedModels = await fetchAvailableModels(cleanKey);
    } catch (_) {}

    final availableList = fetchedModels.isNotEmpty ? fetchedModels : defaultModels;

    final modelsToPing = <String>[];
    if (targetModel != null && targetModel.trim().isNotEmpty) {
      modelsToPing.add(targetModel.trim());
    }
    for (final m in availableList) {
      if (!modelsToPing.contains(m.id)) {
        modelsToPing.add(m.id);
      }
    }
    for (final m in candidateModels) {
      if (!modelsToPing.contains(m)) {
        modelsToPing.add(m);
      }
    }

    String? lastErrorMessage;
    int? lastStatusCode;

    for (final model in modelsToPing) {
      try {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$cleanKey',
        );
        final response = await _client.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': cleanKey,
          },
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': 'Ping'}
                ]
              }
            ],
            'generationConfig': {
              'maxOutputTokens': 5,
            },
          }),
        ).timeout(const Duration(seconds: 15));

        lastStatusCode = response.statusCode;

        if (response.statusCode == 200) {
          final matchedName = availableList
                  .where((m) => m.id == model)
                  .firstOrNull
                  ?.displayName ??
              model;
          final modelsCountNote = fetchedModels.isNotEmpty
              ? '\nFound ${fetchedModels.length} models supported by your API key.'
              : '';
          return GeminiTestResult(
            isSuccess: true,
            modelName: model,
            availableModels: availableList,
            statusCode: 200,
            message:
                '✅ Connection successful!\nConnected to Google Gemini ($matchedName).$modelsCountNote\nAI messaging is ready to use.',
          );
        }

        String rawApiMessage = '';
        String rawReason = '';
        try {
          final bodyJson = jsonDecode(response.body);
          if (bodyJson is Map && bodyJson['error'] is Map) {
            final err = bodyJson['error'] as Map;
            rawApiMessage = (err['message'] as String?) ?? '';
            final details = err['details'] as List?;
            if (details != null && details.isNotEmpty) {
              final first = details.first as Map?;
              rawReason = (first?['reason'] as String?) ?? '';
            }
          }
        } catch (_) {}

        final isModelIncompatible = response.statusCode == 404 ||
            (response.statusCode == 400 &&
                (rawApiMessage.toLowerCase().contains('modalities') ||
                    rawApiMessage.toLowerCase().contains('not supported by the model') ||
                    rawApiMessage.toLowerCase().contains('not found') ||
                    rawApiMessage.toLowerCase().contains('unsupported for generatecontent')));

        if (isModelIncompatible) {
          lastErrorMessage = rawApiMessage.isNotEmpty ? rawApiMessage : 'Model $model not supported.';
          continue;
        }

        final isUnsupportedToken = rawReason == 'ACCESS_TOKEN_TYPE_UNSUPPORTED' ||
            (response.statusCode == 401 && rawApiMessage.toLowerCase().contains('unsupported'));

        final isInvalidKey = response.statusCode == 401 ||
            (response.statusCode == 400 &&
                (rawApiMessage.toLowerCase().contains('api key not valid') ||
                    rawApiMessage.toLowerCase().contains('api_key_invalid') ||
                    rawApiMessage.toLowerCase().contains('invalid api key')));

        final isLocationBlocked = rawApiMessage
            .toLowerCase()
            .contains('user location is not supported');
        final isQuotaExhausted = response.statusCode == 429 ||
            rawApiMessage.toLowerCase().contains('resource has been exhausted');

        final buffer = StringBuffer();
        if (isUnsupportedToken) {
          buffer.writeln('❌ Google API Error: ACCESS_TOKEN_TYPE_UNSUPPORTED (401)');
          buffer.writeln();
          buffer.writeln(
            'Google rejected this key because of project API restrictions in Google Cloud / AI Studio.',
          );
          buffer.writeln();
          buffer.writeln('💡 Quick Fix (in 1 minute):');
          buffer.writeln('1. Open Google AI Studio (aistudio.google.com/app/apikey)');
          buffer.writeln('2. Click "Create API Key"');
          buffer.writeln('3. Select "Create API key in new project" (Do not restrict to "Gemini API")');
          buffer.writeln('4. Copy the new key and paste it here.');
        } else if (isInvalidKey) {
          buffer.writeln('❌ Google rejected this API key (Invalid API Key).');
          buffer.writeln();
          if (!looksLikeGoogleApiKey(cleanKey)) {
            buffer.writeln(
              '⚠️ Key format warning: Google Gemini API keys usually start with "AIzaSy..." or "AQ." (~33–39 characters). Make sure you copied the API Key, not the Google Cloud Project ID or Name.',
            );
            buffer.writeln();
          }
          buffer.writeln(
            '• Newly created keys in Google AI Studio often take 30–60 seconds to activate worldwide across Google servers. If you just created it, please wait ~30 seconds and test again.',
          );
          buffer.writeln('• Ensure you copied the entire key without extra text.');
        } else if (isLocationBlocked) {
          buffer.writeln(
            '❌ Region Not Supported: Google Gemini API is currently not available from your IP/region without VPN.',
          );
        } else if (isQuotaExhausted) {
          buffer.writeln(
            '❌ Quota Exceeded (429): Google AI Studio free rate limit reached. Please wait a minute and try again.',
          );
        } else {
          buffer.writeln('❌ Google API Error (Status ${response.statusCode}):');
          if (rawApiMessage.isNotEmpty) {
            buffer.writeln(rawApiMessage);
          } else {
            buffer.writeln('Connection rejected by server.');
          }
        }

        return GeminiTestResult(
          isSuccess: false,
          statusCode: response.statusCode,
          availableModels: availableList,
          message: buffer.toString().trim(),
        );
      } on SocketException {
        return GeminiTestResult(
          isSuccess: false,
          availableModels: availableList,
          message:
              '❌ No internet connection. Could not reach Google servers. Please check your Wi-Fi or mobile data.',
        );
      } on TimeoutException {
        return GeminiTestResult(
          isSuccess: false,
          availableModels: availableList,
          message:
              '❌ Connection timed out. Google servers took too long to respond. Please check your network.',
        );
      } on HandshakeException {
        return GeminiTestResult(
          isSuccess: false,
          availableModels: availableList,
          message:
              '❌ SSL/TLS handshake failed with Google servers. Please verify device date and time.',
        );
      } catch (e) {
        return GeminiTestResult(
          isSuccess: false,
          availableModels: availableList,
          message: '❌ Unexpected error testing connection: $e',
        );
      }
    }

    final isProjectDisabled = lastStatusCode == 404 &&
        (lastErrorMessage?.contains('is not found for API version') == true ||
            lastErrorMessage?.contains('not supported for generateContent') == true ||
            lastErrorMessage?.contains('ListModels') == true);

    if (isProjectDisabled) {
      return GeminiTestResult(
        isSuccess: false,
        statusCode: 404,
        availableModels: availableList,
        message:
            '❌ Google Error: Generative Language API is disabled for this project (404).\n\n'
            'This API key belongs to a Google Cloud project where the Generative Language API has not been activated.\n\n'
            '💡 Simple 30-Second Fix:\n'
            '1. Open Google AI Studio (aistudio.google.com/app/apikey)\n'
            '2. Click the blue "Create API key" button\n'
            '3. Choose "Create API key in new project" (Do NOT choose your existing project)\n'
            '4. Copy the new key and paste it here.',
      );
    }

    return GeminiTestResult(
      isSuccess: false,
      statusCode: lastStatusCode,
      availableModels: availableList,
      message:
          '❌ Could not connect to Gemini models.\n${lastErrorMessage ?? "Please verify your key in Google AI Studio."}\n\n💡 Tip: In Google AI Studio (aistudio.google.com/app/apikey), click "Create API key in new project" to get a clean unrestricted key for Gemini 1.5 Flash.',
    );
  }

  String _buildPrompt({
    required Student student,
    required String language,
    String tone = 'General Follow-up',
    String customInstructions = '',
    String? companyDescription,
  }) {
    final instituteInfo = (companyDescription != null && companyDescription.trim().isNotEmpty)
        ? companyDescription.trim()
        : _defaultCompanyDescription;
    final streak = studentActivityStatus(student).unansweredStreak;
    final streakNote = streak >= 2
        ? ' ($streak x consecutive unanswered attempts)'
        : '';
    final lastNote = student.comment.trim().isNotEmpty
        ? student.comment.trim()
        : (student.commentHistory.isNotEmpty
            ? student.commentHistory.last.trim()
            : 'No call comment yet');
    final examDetails = [student.examType, student.examYear]
        .where((s) => s.trim().isNotEmpty)
        .join(' ');
    final historySummary = formatStudentHistoryForPrompt(student);

    final goalText = customInstructions.trim().isNotEmpty
        ? customInstructions.trim()
        : tone;

    return '''
You are writing a WhatsApp / SMS follow-up message to a student lead on behalf of LNBTI ($instituteInfo).
Act as a warm, approachable, and respectful student advisor / counselor from LNBTI.

Target Student Details:
- Student Name: ${student.name}
- Stream/Class: ${examDetails.isNotEmpty ? examDetails : 'General Course'}
- Current Call Status: ${student.callStatus}$streakNote
- Recent Call Note/Comment: "$lastNote"
- Location/Town: ${student.location.isNotEmpty ? student.location : 'Not specified'}
- Scheduled Next Call: ${student.nextCallDateTime.isNotEmpty ? student.nextCallDateTime : 'None scheduled'}
- Purpose of message: "$goalText"
- Desired Language: $language

Complete Call & Interaction History (Chronological):
$historySummary

CRITICAL GUIDELINES:
1. USE OF COMPLETE CALL HISTORY (DEEP CONTEXTUAL AWARENESS):
   - You MUST carefully read and understand the entire call history above to determine the context of this follow-up.
   - Tailor the message to reflect past interactions accurately:
     * If previous remarks mention specific inquiries (e.g. degree programs, Software Engineering / IT, course fees, Japanese language classes, scholarships, intake dates, or A/L results), naturally reference or address that topic.
     * If the student previously asked for a callback, more time, or details to be sent, follow up warmly on that exact request.
     * If there were multiple missed calls / no-answer attempts, politely mention that you tried calling earlier and want to check in gently without guilt-tripping or being pushy.
     * Do NOT invent details that are not in the history, and do NOT recite the history like a robotic log. Weave the context naturally into a genuine human counselor message.

2. TONE & MANNER (POLITE, RESPECTFUL & APPROACHABLE):
   - Maintain a warm, friendly, and respectful student counseling tone.
   - Balance natural conversational warmth with polite respect. Do NOT be overly stiff/robotic, and do NOT be overly casual/slangy.
   - STRICTLY FORBIDDEN PHRASES:
     * NO archaic or stiff corporate speech (e.g. "ගරු ශිෂ්‍යතුමනි/ශිෂ්‍යාවනි", "මහතාණෙනි", "අප ආයතනය මඟින් දන්වා සිටින්නේ", "Dear Sir/Madam", "Respected Student").
     * NO overly casual buddy slang (strictly FORBIDDEN: "හොඳේ", "hode", "honde", "මචං", "machan", "හරිද", "harida", "onna"). Messages are sent to prospective students and must maintain courteous respect.
   - Start with a natural, polite greeting using their name (e.g., "හායි ${student.name}!", "කොහොමද ${student.name}?", "Hi ${student.name}! 👋").

3. SENDER IDENTITY (LNBTI):
   - Naturally mention LNBTI as an advisor would refer to their campus/team (e.g. "මම LNBTI එකෙන් කතා කරේ / මැසේජ් එකක් දැම්මේ", "LNBTI campus එකෙන්", "just checking in from LNBTI").

4. CONCISENESS (DO NOT OVER-DETAIL):
   - Keep it short, genuine, and light (2 to 3 sentences max).
   - Do NOT dump long course descriptions or heavy marketing text. Get straight to the point politely and leave room for them to reply easily.

5. LANGUAGE & PHRASING:
   - If Language is "Sinhala": Use natural, polite conversational Sinhala (e.g. "පුළුවන් වෙලාවක මැසේජ් එකක් දාන්න හෝ කතා කරන්න", "විස්තර දැනගන්න ඕන නම් අහන්න", "කෝල් එකක් ගන්න බැලුවේ සම්බන්ධ කරගන්න බැරි වුණා"). Strictly do NOT use "හොඳේ".
   - If Language is "Singlish": Use clean, polite conversational Singlish (e.g. "Hi ${student.name}! kohomada? Mama LNBTI eken message kale. Call ekak ganna baluwe connect karaganna bari una. Puluwan welawaka message ekak danna hari call ekak denna 👍"). Strictly do NOT use "hode".
   - If Language is "English": Use warm, polite conversational English (e.g. "Hi ${student.name}! Hope you are doing well. Just checking in from LNBTI. Tried calling you earlier, but couldn't reach you. Please let me know when you're free! 😊").

6. EMOJIS & FORMATTING:
   - Add 1-2 friendly, tasteful emojis (e.g. 👋, 😊, 👍).
   - Return ONLY the final ready-to-send text message. Do not include quotes, markdown code blocks, or introductory explanations.
''';
  }
}

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

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    this.releaseTitle = '',
    this.releaseNotes = '',
    this.downloadUrl = '',
    this.releaseUrl = '',
    this.publishedAt,
    this.apkSize = 0,
  });

  final String currentVersion;
  final String latestVersion;
  final bool hasUpdate;
  final String releaseTitle;
  final String releaseNotes;
  final String downloadUrl;
  final String releaseUrl;
  final DateTime? publishedAt;
  final int apkSize;
}

abstract class VoiceToTextService {
  bool get isAvailable;
  bool get isListening;
  Future<bool> initialize();
  Future<void> listen({
    required void Function(String recognizedWords) onResult,
    void Function(String status)? onStatus,
    void Function(String error)? onError,
    String? localeId,
  });
  Future<void> stop();
  Future<void> cancel();
}

class DefaultVoiceToTextService implements VoiceToTextService {
  DefaultVoiceToTextService({stt.SpeechToText? speech})
      : _speech = speech ?? stt.SpeechToText();

  final stt.SpeechToText _speech;
  bool _initialized = false;
  void Function(String status)? _activeOnStatus;
  void Function(String error)? _activeOnError;

  @override
  bool get isAvailable => _speech.isAvailable;

  @override
  bool get isListening => _speech.isListening;

  @override
  Future<bool> initialize() async {
    if (_initialized && _speech.isAvailable) return true;
    try {
      _initialized = await _speech.initialize(
        onError: (err) {
          debugPrint('SpeechToText error: ${err.errorMsg}');
          _activeOnError?.call(err.errorMsg);
        },
        onStatus: (status) {
          debugPrint('SpeechToText status: $status');
          _activeOnStatus?.call(status);
        },
        debugLogging: false,
      );
      return _initialized;
    } catch (e) {
      debugPrint('SpeechToText init exception: $e');
      return false;
    }
  }

  @override
  Future<void> listen({
    required void Function(String recognizedWords) onResult,
    void Function(String status)? onStatus,
    void Function(String error)? onError,
    String? localeId,
  }) async {
    _activeOnStatus = onStatus;
    _activeOnError = onError;

    final available = await initialize();
    if (!available) {
      onError?.call(
        'Microphone permission or speech recognition is not available.',
      );
      return;
    }

    String effectiveLocale = localeId ?? 'si_LK';

    // Match exact device locale (e.g. si_LK or si-LK, en_US or en-US)
    try {
      final locales = await _speech.locales();
      final prefix = effectiveLocale.split(RegExp('[-_]')).first.toLowerCase();
      final match = locales.firstWhere(
        (l) => l.localeId.toLowerCase().startsWith(prefix),
        orElse: () => stt.LocaleName(effectiveLocale, effectiveLocale),
      );
      effectiveLocale = match.localeId;
    } catch (_) {}

    try {
      await _speech.listen(
        onResult: (result) {
          if (result.recognizedWords.isNotEmpty) {
            onResult(result.recognizedWords);
          }
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 4),
          localeId: effectiveLocale,
          onDevice: false,
        ),
      );
    } catch (e) {
      onError?.call(e.toString());
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    try {
      await _speech.cancel();
    } catch (_) {}
  }
}

class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    this.owner = 'jiatachira',
    this.repo = 'LeadPilot',
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String owner;
  final String repo;

  Future<AppUpdateInfo> checkForUpdates({
    String currentVersion = kAppVersion,
  }) async {
    final url = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/releases/latest',
    );
    final response = await _client.get(
      url,
      headers: {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'LeadPilot-App',
      },
    );

    if (response.statusCode == 404) {
      return AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: currentVersion,
        hasUpdate: false,
        releaseNotes: 'No releases found on GitHub.',
      );
    }

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to check for updates (HTTP ${response.statusCode})',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final tagName = (data['tag_name'] as String? ?? '').trim();
    final cleanLatest =
        tagName.replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
    final hasUpdate = compareVersions(currentVersion, cleanLatest) > 0;

    final assets = (data['assets'] as List<dynamic>?) ?? [];
    String apkDownloadUrl = '';
    int apkSize = 0;
    for (final asset in assets) {
      if (asset is Map<String, dynamic>) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.endsWith('.apk')) {
          apkDownloadUrl = asset['browser_download_url'] as String? ?? '';
          apkSize = (asset['size'] as num?)?.toInt() ?? 0;
          break;
        }
      }
    }

    final htmlUrl =
        data['html_url'] as String? ?? 'https://github.com/$owner/$repo/releases';
    if (apkDownloadUrl.isEmpty) {
      apkDownloadUrl = htmlUrl;
    }

    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: cleanLatest.isNotEmpty ? cleanLatest : tagName,
      hasUpdate: hasUpdate,
      releaseTitle: data['name'] as String? ?? tagName,
      releaseNotes: data['body'] as String? ?? '',
      downloadUrl: apkDownloadUrl,
      releaseUrl: htmlUrl,
      publishedAt: DateTime.tryParse(data['published_at'] as String? ?? ''),
      apkSize: apkSize,
    );
  }

  static int compareVersions(String current, String latest) {
    String clean(String v) =>
        v.trim().toLowerCase().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
    final cParts = clean(current)
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final lParts = clean(latest)
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();

    final maxLen = math.max(cParts.length, lParts.length);
    for (var i = 0; i < maxLen; i++) {
      final c = i < cParts.length ? cParts[i] : 0;
      final l = i < lParts.length ? lParts[i] : 0;
      if (l > c) return 1;
      if (l < c) return -1;
    }
    return 0;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

class AppInstallerService {
  static const _channel = MethodChannel('com.example.call_dial/installer');

  static Future<String> getApkDownloadPath() async {
    if (Platform.isAndroid) {
      try {
        final path = await _channel.invokeMethod<String>('getApkDownloadPath');
        if (path != null && path.isNotEmpty) return path;
      } catch (e) {
        debugPrint('Error getting apk download path: $e');
      }
    }
    final tempDir = Directory.systemTemp;
    return '${tempDir.path}/LeadPilot-update.apk';
  }

  static Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) return true;
    try {
      final allowed =
          await _channel.invokeMethod<bool>('canRequestPackageInstalls');
      return allowed ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openInstallPermissionSettings');
    } catch (_) {}
  }

  static Future<bool> installApk(String filePath) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel
          .invokeMethod<bool>('installApk', {'filePath': filePath});
      return result ?? true;
    } catch (e) {
      debugPrint('Install APK error: $e');
      rethrow;
    }
  }
}

Stream<({int receivedBytes, int totalBytes, double progress})>
    downloadApkWithProgress({
  required String url,
  required String destinationPath,
  http.Client? client,
}) async* {
  final httpClient = client ?? http.Client();
  final request = http.Request('GET', Uri.parse(url));
  request.headers['User-Agent'] = 'LeadPilot-App';
  final response = await httpClient.send(request);

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception('Failed to download APK (HTTP ${response.statusCode})');
  }

  final totalBytes = response.contentLength ?? 0;
  var receivedBytes = 0;
  final file = File(destinationPath);
  if (file.existsSync()) {
    try {
      file.deleteSync();
    } catch (_) {}
  }
  file.createSync(recursive: true);
  final raf = file.openSync(mode: FileMode.write);

  try {
    await for (final chunk in response.stream) {
      raf.writeFromSync(chunk);
      receivedBytes += chunk.length;
      final progress = totalBytes > 0 ? (receivedBytes / totalBytes) : 0.0;
      yield (
        receivedBytes: receivedBytes,
        totalBytes: totalBytes,
        progress: progress,
      );
    }
  } finally {
    try {
      raf.closeSync();
    } catch (_) {}
    if (client == null) {
      httpClient.close();
    }
  }
}

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.updateInfo,
    this.onLaunchUrl,
    this.onInstallApk,
    this.httpClient,
  });

  final AppUpdateInfo updateInfo;
  final Future<void> Function(String url)? onLaunchUrl;
  final Future<void> Function(String filePath)? onInstallApk;
  final http.Client? httpClient;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _isDownloading = false;
  bool _isDownloaded = false;
  double _progress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String? _downloadError;
  String _savedApkPath = '';
  StreamSubscription<dynamic>? _downloadSub;
  bool _needsInstallPermission = false;

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  Future<void> _startDownload() async {
    final downloadUrl = widget.updateInfo.downloadUrl;
    if (!downloadUrl.toLowerCase().endsWith('.apk')) {
      await _openUrl(downloadUrl);
      if (mounted) Navigator.pop(context);
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadError = null;
      _progress = 0.0;
      _receivedBytes = 0;
      _totalBytes = widget.updateInfo.apkSize;
    });

    try {
      final destPath = await AppInstallerService.getApkDownloadPath();
      _savedApkPath = destPath;

      final stream = downloadApkWithProgress(
        url: downloadUrl,
        destinationPath: destPath,
        client: widget.httpClient,
      );

      _downloadSub = stream.listen(
        (data) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = data.receivedBytes;
            _totalBytes = data.totalBytes > 0
                ? data.totalBytes
                : widget.updateInfo.apkSize;
            _progress = data.progress.clamp(0.0, 1.0);
          });
        },
        onError: (err) {
          if (!mounted) return;
          setState(() {
            _isDownloading = false;
            _downloadError = err.toString();
          });
        },
        onDone: () async {
          if (!mounted) return;
          setState(() {
            _isDownloading = false;
            _isDownloaded = true;
            _progress = 1.0;
          });
          await _triggerInstall();
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadError = e.toString();
      });
    }
  }

  Future<void> _triggerInstall() async {
    if (_savedApkPath.isEmpty) return;

    if (widget.onInstallApk != null) {
      await widget.onInstallApk!(_savedApkPath);
      return;
    }

    try {
      final canInstall = await AppInstallerService.canRequestPackageInstalls();
      if (!canInstall) {
        if (mounted) setState(() => _needsInstallPermission = true);
        await AppInstallerService.openInstallPermissionSettings();
        return;
      }
      await AppInstallerService.installApk(_savedApkPath);
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('PERMISSION_REQUIRED')) {
        if (mounted) setState(() => _needsInstallPermission = true);
      } else {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('Installation prompt failed: $e')),
          );
        }
      }
    }
  }

  Future<void> _openUrl(String url) async {
    if (widget.onLaunchUrl != null) {
      await widget.onLaunchUrl!(url);
      return;
    }
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 1. Download in progress view
    if (_isDownloading) {
      return AlertDialog(
        key: const Key('app_update_dialog'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                value: _progress.clamp(0.01, 1.0),
                color: const Color(0xFF00966D),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Downloading Update...',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Downloading LeadPilot v${widget.updateInfo.latestVersion}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: _progress.clamp(0.0, 1.0),
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
              backgroundColor:
                  isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
              color: const Color(0xFF00966D),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(_progress * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF00966D),
                  ),
                ),
                Text(
                  _totalBytes > 0
                      ? '${(_receivedBytes / (1024 * 1024)).toStringAsFixed(1)} / ${(_totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
                      : '${(_receivedBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _downloadSub?.cancel();
              setState(() => _isDownloading = false);
            },
            child: const Text('Cancel Download'),
          ),
        ],
      );
    }

    // 2. Download complete / ready to install view
    if (_isDownloaded) {
      return AlertDialog(
        key: const Key('app_update_dialog'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF00966D).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF00966D),
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Update Ready!',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'LeadPilot v${widget.updateInfo.latestVersion} has finished downloading. Launching package installer to apply update...',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            if (_needsInstallPermission) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3CD),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFFD56B)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.security_rounded,
                      color: Color(0xFF996500),
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Android permission required: Please allow "Install unknown apps" for LeadPilot, then tap Install Now.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF664400),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (_needsInstallPermission)
            TextButton.icon(
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: const Text('Allow in Settings'),
              onPressed: () =>
                  AppInstallerService.openInstallPermissionSettings(),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Dismiss'),
          ),
          FilledButton.icon(
            key: const Key('install_now_button'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00966D),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.system_update_rounded, size: 18),
            label: const Text('Install Now'),
            onPressed: _triggerInstall,
          ),
        ],
      );
    }

    // 3. Initial dialog view with release notes & download size
    return AlertDialog(
      key: const Key('app_update_dialog'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF62D6B0).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.system_update_rounded,
              color: Color(0xFF00966D),
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'New Update Available',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF334155)
                        : const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'v${widget.updateInfo.currentVersion}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward_rounded, size: 16),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00966D),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'v${widget.updateInfo.latestVersion}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            if (widget.updateInfo.apkSize > 0) ...[
              const SizedBox(height: 10),
              Text(
                'Download size: ${(widget.updateInfo.apkSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (_downloadError != null) ...[
              const SizedBox(height: 10),
              Text(
                'Download failed: $_downloadError',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            if (widget.updateInfo.releaseNotes.trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                "What's New:",
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.maxFinite,
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                  ),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    widget.updateInfo.releaseNotes.trim(),
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('update_later_button'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Later'),
        ),
        if (widget.updateInfo.releaseUrl.isNotEmpty &&
            widget.updateInfo.releaseUrl != widget.updateInfo.downloadUrl)
          TextButton(
            key: const Key('update_github_button'),
            onPressed: () => _openUrl(widget.updateInfo.releaseUrl),
            child: const Text('View on GitHub'),
          ),
        FilledButton.icon(
          key: const Key('update_now_button'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF00966D),
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Update Now'),
          onPressed: _startDownload,
        ),
      ],
    );
  }
}

Future<void> showAppUpdateDialog(
  BuildContext context,
  AppUpdateInfo updateInfo, {
  Future<void> Function(String url)? onLaunchUrl,
  Future<void> Function(String filePath)? onInstallApk,
  http.Client? httpClient,
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AppUpdateDialog(
        updateInfo: updateInfo,
        onLaunchUrl: onLaunchUrl,
        onInstallApk: onInstallApk,
        httpClient: httpClient,
      ),
    );

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
    this.updateService,
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
  final AppUpdateService? updateService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  final List<Student> _students = [];
  final Set<String> _selectedStudentKeys = {};
  late final AppSettingsStore _settingsStore =
      widget.settingsStore ?? SecureAppSettingsStore();
  late final AppUpdateService _updateService =
      widget.updateService ?? AppUpdateService();

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

  Student? _pendingCallStudent;
  DateTime? _callStartedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInitialOfflineData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkAndLogCallDuration());
    }
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkAutoUpdatesOnStartup();
    });
  }

  Future<void> _checkAutoUpdatesOnStartup() async {
    try {
      final enabled = await _settingsStore.readAutoCheckUpdates();
      if (!enabled) return;
      final info =
          await _updateService.checkForUpdates(currentVersion: kAppVersion);
      if (info.hasUpdate && mounted) {
        await showAppUpdateDialog(context, info);
      }
    } catch (_) {
      // Silent catch on app startup if offline or failed
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

  void _toggleSelectAll(List<Student> displayedStudents) {
    setState(() {
      final allKeys = displayedStudents.map(_selectionKey).toSet();
      final allSelected = allKeys.isNotEmpty &&
          allKeys.every(_selectedStudentKeys.contains);
      if (allSelected) {
        _selectedStudentKeys.removeAll(allKeys);
        if (_selectedStudentKeys.isEmpty) _isSelectionMode = false;
      } else {
        _isSelectionMode = true;
        _selectedStudentKeys.addAll(allKeys);
      }
    });
  }

  int _compareStudentsByFollowUpDate(Student left, Student right) {
    final leftDate = tryParseDate(left.nextCallDateTime);
    final rightDate = tryParseDate(right.nextCallDateTime);
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
    final leftDate = tryParseDate(left.addedDate);
    final rightDate = tryParseDate(right.addedDate);
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
      final addedDate = tryParseDate(student.addedDate);
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
        final nextCall = tryParseDate(student.nextCallDateTime);
        final today = DateTime.now();
        if (nextCall == null ||
            !nextCall.isBefore(
              DateTime(today.year, today.month, today.day + 1),
            )) {
          return false;
        }
        return !student.attempts.any((attempt) {
          final attemptedAt = tryParseDate(attempt.dateTime);
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
      builder: (_) => _EditStudentSheet(
        student: student,
        settingsStore: _settingsStore,
      ),
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
      final previousCall = tryParseDate(previousStudent.nextCallDateTime);
      final nextCall = tryParseDate(updatedStudent.nextCallDateTime);
      if (nextCall == null || !nextCall.isAfter(DateTime.now())) {
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
      builder: (_) => SettingsHubSheet(
        themeMode: widget.themeMode,
        onThemeModeChanged: _changeThemeMode,
        isSheetConnected: widget.sheetConfig.isNotEmpty,
        hasActiveFilters: _hasActiveFilters,
        biometricEnabled: widget.biometricEnabled,
        onBiometricChanged: widget.onBiometricChanged,
        students: _students,
        settingsStore: _settingsStore,
        updateService: _updateService,
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
      case _SettingsAction.geminiAi:
        await _openGeminiAiSettings();
        break;
      case _SettingsAction.companyDescription:
        await _openCompanyDescriptionDialog();
        break;
    }
  }

  Future<void> _openCompanyDescriptionDialog() async {
    final current = await _settingsStore.readCompanyDescription();
    if (!mounted) return;
    final controller = TextEditingController(text: current);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.business_rounded, color: Color(0xFF8B5CF6)),
            SizedBox(width: 8),
            Text('Company Description'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI uses this description to represent your institute (LNBTI) in generated follow-up messages politely without overwhelming details.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: 'Description about your company',
                  hintText: 'Enter institute details...',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.restart_alt_rounded),
                    tooltip: 'Reset to LNBTI default',
                    onPressed: () => controller.text = _defaultCompanyDescription,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (updated != null && mounted) {
      await _settingsStore.saveCompanyDescription(updated);
      if (!mounted) return;
      _showMessage('Company description saved for AI messaging.');
    }
  }

  Future<void> _openGeminiAiSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ManageGeminiAiSheet(
        settingsStore: _settingsStore,
      ),
    );
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
      final currentStudentsByKey = {
        for (final s in _students) _studentKey(s): s,
      };
      final merged = <String, Student>{};
      for (final student in sheetStudents) {
        final key = _studentKey(student);
        final current = currentStudentsByKey[key];
        if (current != null && isFinalLeadStatus(current.callStatus)) {
          // If the sheet did not mark it final, preserve the locally marked final status (Inactive, Not Interested, Not Potential)
          if (!isFinalLeadStatus(student.callStatus)) {
            merged[key] = student.copyWith(
              callStatus: current.callStatus,
              nextCallDateTime: '',
              comment: current.comment.isNotEmpty
                  ? current.comment
                  : student.comment,
              commentHistory:
                  current.commentHistory.length >= student.commentHistory.length
                      ? current.commentHistory
                      : student.commentHistory,
              attempts: current.attempts.length >= student.attempts.length
                  ? current.attempts
                  : student.attempts,
            );
            continue;
          }
        }

        // Safety rule: if fetched student has >= 6 consecutive unanswered calls, automatically treat as Inactive
        if (!isFinalLeadStatus(student.callStatus) &&
            studentActivityStatus(student).unansweredStreak >= 6) {
          merged[key] = student.copyWith(
            callStatus: 'Inactive',
            nextCallDateTime: '',
          );
          continue;
        }

        merged[key] = student;
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
        final nextCall = tryParseDate(student.nextCallDateTime);
        if (nextCall == null) continue;

        if (!nextCall.isBefore(endOfToday) || !nextCall.isAfter(now)) {
          continue;
        }

        final alreadyAttempted = student.attempts.any((attempt) {
          final attemptedAt = tryParseDate(attempt.dateTime);
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
                  tooltip: students.isNotEmpty &&
                          students.every((s) => _selectedStudentKeys
                              .contains(_selectionKey(s)))
                      ? 'Deselect all'
                      : 'Select all',
                  onPressed: () => _toggleSelectAll(students),
                  icon: Icon(
                    students.isNotEmpty &&
                            students.every((s) => _selectedStudentKeys
                                .contains(_selectionKey(s)))
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                  ),
                ),
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
                  tooltip: 'Select multiple leads',
                  onPressed: () {
                    setState(() {
                      _isSelectionMode = true;
                    });
                  },
                  icon: const Icon(Icons.checklist_rounded),
                ),
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
      bottomNavigationBar: _isSelectionMode
          ? Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('bulk_whatsapp_button'),
                        onPressed: selectedStudents.isEmpty
                            ? null
                            : () => _startBulkWhatsApp(selectedStudents),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF25D366),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const FaIcon(FontAwesomeIcons.whatsapp, size: 18),
                        label: Text(
                          'Bulk WhatsApp (${selectedStudents.length})',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        key: const Key('bulk_sms_button'),
                        onPressed: selectedStudents.isEmpty
                            ? null
                            : () => _startBulkSms(selectedStudents),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.sms_outlined, size: 18),
                        label: Text(
                          'Bulk SMS (${selectedStudents.length})',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
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
      _pendingCallStudent = student;
      _callStartedAt = DateTime.now();
      final launched = await launchUrl(Uri.parse('tel:${student.phone}'));
      if (!launched && mounted) {
        _showMessage('Could not open the phone dialer for ${student.name}.');
      }
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not start the call: $error');
    }
  }

  Future<void> _checkAndLogCallDuration() async {
    // 1. Check if an in-app call was placed to a student
    if (_pendingCallStudent != null && _callStartedAt != null) {
      final student = _pendingCallStudent!;
      final startedAt = _callStartedAt!;
      _pendingCallStudent = null;
      _callStartedAt = null;

      final elapsedSec = DateTime.now().difference(startedAt).inSeconds;
      if (elapsedSec >= 2) {
        // Wait 1s for Android telecom CallLog to flush
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        if (!mounted) return;

        int durationSec = elapsedSec;
        try {
          final log =
              await CallerIdService.getLatestCallLog(phone: student.phone);
          if (log != null && log['duration'] is num) {
            durationSec = (log['duration'] as num).toInt();
          }
        } catch (_) {}

        await _logCallDurationForStudent(student, durationSec);
      }
    }

    // 2. Also check any pending incoming/background calls captured by PhoneStateReceiver
    try {
      final pendingLogs = await CallerIdService.getPendingCallLogs();
      for (final log in pendingLogs) {
        final phone = log['phone']?.toString();
        final duration = (log['duration'] as num?)?.toInt() ?? 0;
        if (phone != null && phone.isNotEmpty) {
          final matchingStudent = _students
              .where((s) =>
                  normalizeContactPhone(s.phone) ==
                  normalizeContactPhone(phone))
              .firstOrNull;
          if (matchingStudent != null) {
            await _logCallDurationForStudent(matchingStudent, duration);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _logCallDurationForStudent(
    Student student,
    int durationSeconds,
  ) async {
    final autoLog = await _settingsStore.readAutoLogCallDuration();
    if (!autoLog) return;

    final durationText = formatCallDuration(durationSeconds);
    final commentText = durationSeconds > 0
        ? '[Call Connected • $durationText]'
        : '[No Answer • 0s]';

    final now = DateTime.now();
    final formattedNow = _formatReminder(now);
    final newHistoryEntry = '$formattedNow — $commentText';

    // Prevent duplicate logging if the exact same comment was just logged
    if (student.commentHistory.isNotEmpty) {
      final last = student.commentHistory.last;
      if (last.contains(commentText)) {
        return;
      }
    }

    final updatedHistory = List<String>.of(student.commentHistory)
      ..add(newHistoryEntry);

    String newStatus = student.callStatus;
    if (durationSeconds > 0) {
      if (newStatus == 'Pending' ||
          newStatus == 'No Answer' ||
          newStatus == 'Not Responding') {
        newStatus = 'Follow-up';
      }
    } else {
      if (newStatus == 'Pending') {
        newStatus = 'No Answer';
      }
    }

    final updatedAttempts = List<CallAttempt>.of(student.attempts)
      ..add(
        CallAttempt(
          dateTime: now.toIso8601String(),
          status: newStatus,
          comment: commentText,
        ),
      );

    final updatedStudent = student.copyWith(
      callStatus: newStatus,
      comment: commentText,
      commentHistory: updatedHistory,
      attempts: updatedAttempts,
    );

    final index = _students.indexWhere(
      (s) =>
          normalizeContactPhone(s.phone) ==
          normalizeContactPhone(student.phone),
    );
    if (index >= 0) {
      if (mounted) {
        setState(() {
          _students[index] = updatedStudent;
        });
      }
      await _settingsStore.saveCachedStudents(_students);

      if (widget.sheetConfig.isNotEmpty) {
        try {
          await widget.sheetService.updateStudentInSheet(
            widget.sheetConfig,
            updatedStudent,
            previousPhone: student.phone,
          );
        } catch (_) {
          await _enqueueOfflineAction(
            QueuedSheetAction(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              action: 'update',
              student: updatedStudent,
              previousPhone: student.phone,
              queuedAt: DateTime.now(),
            ),
          );
        }
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF62D6B0),
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Logged: $commentText for ${student.name}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Add Note',
            textColor: const Color(0xFF62D6B0),
            onPressed: () => _editStudent(updatedStudent),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _startBulkWhatsApp(List<Student> students) async {
    if (students.isEmpty) return;

    final templates = await _settingsStore.readWhatsAppTemplates();
    if (!mounted) return;

    final payload = await showModalBottomSheet<WhatsAppSendPayload>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WhatsAppTemplatePickerSheet(
        student: students.first,
        templates: templates,
        isSms: false,
        isBulk: true,
        onManageTemplates: () async {
          Navigator.pop(context);
          await _openWhatsAppTemplatesSettings();
        },
      ),
    );

    if (payload == null || !mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => BulkDispatchSheet(
        students: students,
        payload: payload,
        isSms: false,
        onDispatch: (student, text) => _dispatchWhatsAppMessage(
          student: student,
          text: text,
          documentPaths: payload.documentPaths,
        ),
      ),
    );
  }

  Future<void> _startBulkSms(List<Student> students) async {
    if (students.isEmpty) return;

    final templates = await _settingsStore.readWhatsAppTemplates();
    if (!mounted) return;

    final payload = await showModalBottomSheet<WhatsAppSendPayload>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WhatsAppTemplatePickerSheet(
        student: students.first,
        templates: templates,
        isSms: true,
        isBulk: true,
        onManageTemplates: () async {
          Navigator.pop(context);
          await _openWhatsAppTemplatesSettings();
        },
      ),
    );

    if (payload == null || !mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => BulkDispatchSheet(
        students: students,
        payload: payload,
        isSms: true,
        onDispatch: (student, text) => _launchSms(
          student.phone,
          text: text,
        ),
      ),
    );
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

    final choice = await showModalBottomSheet<_MessageChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WhatsAppChoiceSheet(student: student),
    );

    if (choice == null || !mounted) return;

    if (choice == _MessageChoice.custom) {
      await _launchWhatsApp(number);
    } else if (choice == _MessageChoice.template) {
      final templates = await _settingsStore.readWhatsAppTemplates();
      if (!mounted) return;
      final selectedPayload =
          await showModalBottomSheet<WhatsAppSendPayload>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => WhatsAppTemplatePickerSheet(
          student: student,
          templates: templates,
          isSms: false,
          onManageTemplates: () async {
            Navigator.pop(context);
            await _openWhatsAppTemplatesSettings();
          },
        ),
      );
      if (selectedPayload != null && mounted) {
        await _dispatchWhatsAppMessage(
          student: student,
          text: selectedPayload.message,
          documentPaths: selectedPayload.documentPaths,
        );
      }
    } else if (choice == _MessageChoice.ai) {
      final apiKey = await _settingsStore.readGeminiApiKey();
      if (!mounted) return;
      final selectedMessage = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => GeminiAiMessageSheet(
          student: student,
          initialApiKey: apiKey,
          settingsStore: _settingsStore,
          isSms: false,
        ),
      );
      if (selectedMessage != null &&
          selectedMessage.trim().isNotEmpty &&
          mounted) {
        await _launchWhatsApp(number, text: selectedMessage.trim());
      }
    }
  }

  Future<void> _dispatchWhatsAppMessage({
    required Student student,
    required String text,
    List<String> documentPaths = const [],
  }) async {
    final number = student.whatsappNumber.trim().isEmpty
        ? student.phone
        : student.whatsappNumber;
    final validDocuments = documentPaths
        .where((path) => path.trim().isNotEmpty && File(path).existsSync())
        .toList();

    if (validDocuments.isNotEmpty) {
      try {
        final xFiles = validDocuments.map((path) => XFile(path)).toList();
        await SharePlus.instance.share(
          ShareParams(
            files: xFiles,
            text: text.trim().isNotEmpty ? text.trim() : null,
            subject: 'Document for ${student.name}',
          ),
        );
      } on Exception catch (error) {
        if (mounted) {
          _showMessage('Could not share documents: $error');
        }
      }
    } else {
      await _launchWhatsApp(
        number,
        text: text.trim().isNotEmpty ? text.trim() : null,
      );
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
    final number = student.phone;
    final digits = normalizeContactPhone(number);
    if (digits.isEmpty) {
      _showMessage('No valid phone number is available for ${student.name}.');
      return;
    }

    final choice = await showModalBottomSheet<_MessageChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SmsChoiceSheet(student: student),
    );

    if (choice == null || !mounted) return;

    if (choice == _MessageChoice.custom) {
      await _launchSms(number);
    } else if (choice == _MessageChoice.template) {
      final templates = await _settingsStore.readWhatsAppTemplates();
      if (!mounted) return;
      final selectedPayload =
          await showModalBottomSheet<WhatsAppSendPayload>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => WhatsAppTemplatePickerSheet(
          student: student,
          templates: templates,
          isSms: true,
          onManageTemplates: () async {
            Navigator.pop(context);
            await _openWhatsAppTemplatesSettings();
          },
        ),
      );
      if (selectedPayload != null && mounted) {
        await _launchSms(number, text: selectedPayload.message);
      }
    } else if (choice == _MessageChoice.ai) {
      final apiKey = await _settingsStore.readGeminiApiKey();
      if (!mounted) return;
      final selectedMessage = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => GeminiAiMessageSheet(
          student: student,
          initialApiKey: apiKey,
          settingsStore: _settingsStore,
          isSms: true,
        ),
      );
      if (selectedMessage != null &&
          selectedMessage.trim().isNotEmpty &&
          mounted) {
        await _launchSms(number, text: selectedMessage.trim());
      }
    }
  }

  Future<void> _launchSms(String number, {String? text}) async {
    try {
      final launched = await launchUrl(
        smsComposerUri(number, body: text),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        _showMessage('Could not open the SMS composer for number $number.');
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
      settingsStore: _settingsStore,
      geminiService: GeminiService(),
      onStudentUpdated: (updatedStudent) async {
        final index = _students.indexWhere(
          (s) =>
              normalizeContactPhone(s.phone) ==
              normalizeContactPhone(student.phone),
        );
        if (index >= 0) {
          setState(() {
            _students[index] = updatedStudent;
          });
          await _settingsStore.saveCachedStudents(_students);
        }
        if (widget.sheetConfig.isNotEmpty) {
          try {
            await widget.sheetService.updateStudentInSheet(
              widget.sheetConfig,
              updatedStudent,
              previousPhone: student.phone,
            );
          } catch (_) {
            await _enqueueOfflineAction(
              QueuedSheetAction(
                id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
                action: 'update',
                student: updatedStudent,
                previousPhone: student.phone,
                queuedAt: DateTime.now(),
              ),
            );
          }
        }
      },
    );
  }
}

Future<void> _showStudentHistory(
  BuildContext context,
  Student student, {
  required String title,
  Future<void> Function(Student updatedStudent)? onStudentUpdated,
  AppSettingsStore? settingsStore,
  GeminiService? geminiService,
  VoiceToTextService? voiceToTextService,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => StudentHistoryDialog(
      student: student,
      title: title,
      onStudentUpdated: onStudentUpdated,
      settingsStore: settingsStore,
      geminiService: geminiService,
      voiceToTextService: voiceToTextService,
    ),
  );
}

class StudentHistoryDialog extends StatefulWidget {
  const StudentHistoryDialog({
    super.key,
    required this.student,
    required this.title,
    this.onStudentUpdated,
    this.settingsStore,
    this.geminiService,
    this.voiceToTextService,
  });

  final Student student;
  final String title;
  final Future<void> Function(Student updatedStudent)? onStudentUpdated;
  final AppSettingsStore? settingsStore;
  final GeminiService? geminiService;
  final VoiceToTextService? voiceToTextService;

  @override
  State<StudentHistoryDialog> createState() => _StudentHistoryDialogState();
}

class _StudentHistoryDialogState extends State<StudentHistoryDialog> {
  late Student _currentStudent = widget.student;
  bool _isSaving = false;

  List<StudentHistoryEntry> _buildEntries(Student student) =>
      buildStudentHistoryEntries(student);

  Future<void> _editLastRemark(String currentText) async {
    final controller = TextEditingController(text: currentText);
    bool isPolishing = false;
    bool isListeningVoice = false;
    String voiceLanguage = 'si';
    String preVoiceText = '';
    final voiceService =
        widget.voiceToTextService ?? DefaultVoiceToTextService();

    final updatedText = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> toggleVoice() async {
            if (isListeningVoice) {
              await voiceService.stop();
              setDialogState(() => isListeningVoice = false);
              return;
            }
            preVoiceText = controller.text;
            setDialogState(() => isListeningVoice = true);
            final localeId = voiceLanguage == 'si' ? 'si_LK' : 'en_US';
            await voiceService.listen(
              localeId: localeId,
              onResult: (words) {
                if (words.trim().isEmpty) return;
                setDialogState(() {
                  final p = preVoiceText.trim();
                  controller.text = p.isEmpty ? words.trim() : '$p ${words.trim()}';
                  controller.selection = TextSelection.fromPosition(
                    TextPosition(offset: controller.text.length),
                  );
                });
              },
              onStatus: (st) {
                if (st == 'notListening' || st == 'done') {
                  setDialogState(() => isListeningVoice = false);
                }
              },
              onError: (err) {
                setDialogState(() => isListeningVoice = false);
              },
            );
          }

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.edit_note_rounded, color: Color(0xFF8B5CF6)),
                SizedBox(width: 8),
                Text('Edit Last Remark', style: TextStyle(fontSize: 18)),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Correct or update the most recent call remark for ${_currentStudent.name}:',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: controller,
                    minLines: 2,
                    maxLines: 4,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Remark / Comment',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (isListeningVoice)
                        Row(
                          children: [
                            const Icon(
                              Icons.fiber_manual_record,
                              color: Colors.redAccent,
                              size: 10,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Listening (${voiceLanguage == 'si' ? 'Sinhala' : 'EN'})...',
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        )
                      else
                        const SizedBox.shrink(),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                              setDialogState(() {
                                voiceLanguage =
                                    voiceLanguage == 'si' ? 'en' : 'si';
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                              child: Text(
                                voiceLanguage == 'si' ? 'සිංහල' : 'EN',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              foregroundColor: isListeningVoice
                                  ? Colors.redAccent
                                  : const Color(0xFF00966D),
                              side: BorderSide(
                                color: isListeningVoice
                                    ? Colors.redAccent
                                    : const Color(0xFF00966D)
                                        .withValues(alpha: 0.6),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: toggleVoice,
                            icon: Icon(
                              isListeningVoice
                                  ? Icons.stop_rounded
                                  : Icons.mic_rounded,
                              size: 13,
                            ),
                            label: Text(
                              isListeningVoice ? 'Stop' : '🎙️ Speak',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              foregroundColor: const Color(0xFF8B5CF6),
                              side: BorderSide(
                                color: const Color(0xFF8B5CF6)
                                    .withValues(alpha: 0.6),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: isPolishing
                                ? null
                                : () async {
                                    final raw = controller.text.trim();
                                    if (raw.isEmpty) return;
                                    final store = widget.settingsStore ??
                                        SecureAppSettingsStore();
                                    final apiKey =
                                        await store.readGeminiApiKey();
                                    if (apiKey.trim().isEmpty) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Please configure Gemini API key in Settings.',
                                            ),
                                            duration: Duration(seconds: 3),
                                          ),
                                        );
                                      }
                                      return;
                                    }
                                    setDialogState(() => isPolishing = true);
                                    try {
                                      final service = widget.geminiService ??
                                          GeminiService();
                                      final model =
                                          await store.readGeminiModel();
                                      final polished =
                                          await service.polishRemark(
                                        apiKey: apiKey,
                                        rawRemark: raw,
                                        model: model,
                                      );
                                      if (polished.isNotEmpty) {
                                        controller.text = polished;
                                        controller.selection =
                                            TextSelection.fromPosition(
                                          TextPosition(offset: polished.length),
                                        );
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content:
                                                Text('Could not polish: $e'),
                                          ),
                                        );
                                      }
                                    } finally {
                                      setDialogState(() => isPolishing = false);
                                    }
                                  },
                            icon: isPolishing
                                ? const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.auto_awesome_rounded,
                                    size: 14,
                                  ),
                            label: Text(
                              isPolishing ? 'Polishing...' : '✨ Polish',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final text = controller.text.trim();
                  Navigator.pop(dialogCtx, text);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    if (updatedText == null || updatedText == currentText.trim()) return;

    setState(() => _isSaving = true);
    final updatedStudent = _currentStudent.updateLastComment(updatedText);
    try {
      if (widget.onStudentUpdated != null) {
        await widget.onStudentUpdated!(updatedStudent);
      }
      setState(() {
        _currentStudent = updatedStudent;
        _isSaving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✨ Last remark updated!'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update remark: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _buildEntries(_currentStudent);
    final lastCommentIndex =
        entries.lastIndexWhere((e) => e.text.trim().isNotEmpty);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: entries.isEmpty && _currentStudent.note.isEmpty
            ? const Text('No call history or comments have been saved.')
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: entries.isEmpty ? 1 : entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 22),
                  itemBuilder: (context, index) {
                    if (entries.isEmpty) return Text(_currentStudent.note);
                    final entry = entries[index];
                    final isLatestComment = (index == lastCommentIndex);

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (entry.status.isNotEmpty ||
                            entry.dateLabel.isNotEmpty ||
                            isLatestComment)
                          Row(
                            children: [
                              if (entry.status.isNotEmpty)
                                Text(
                                  entry.status,
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              if (isLatestComment) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'Latest',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                              const Spacer(),
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
                        if (isLatestComment &&
                            entry.text.trim().isNotEmpty &&
                            widget.onStudentUpdated != null) ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              key: const Key('edit_last_remark_button'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                foregroundColor: const Color(0xFF8B5CF6),
                              ),
                              icon: const Icon(Icons.edit_rounded, size: 14),
                              label: const Text(
                                'Edit last remark',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              onPressed: _isSaving
                                  ? null
                                  : () => _editLastRemark(entry.text),
                            ),
                          ),
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
    );
  }
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
                            if (tryParseDate(student.nextCallDateTime)
                                case final reminder?)
                              _StudentTag(
                                text: !reminder.isAfter(DateTime.now())
                                    ? '⚠️ Overdue · ${_formatReminder(reminder)}'
                                    : 'Call · ${_formatReminder(reminder)}',
                                background: !reminder.isAfter(DateTime.now())
                                    ? (isDark ? const Color(0xFF4A2525) : const Color(0xFFFFEBEB))
                                    : (isDark ? const Color(0xFF44351F) : const Color(0xFFFFF3DF)),
                                foreground: !reminder.isAfter(DateTime.now())
                                    ? (isDark ? const Color(0xFFFF8B8B) : const Color(0xFFD32F2F))
                                    : (isDark ? const Color(0xFFFFC56E) : const Color(0xFF9A5A00)),
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
                                Icons.history_rounded,
                                size: 19,
                              ),
                              tooltip: 'Call history',
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

class EditStudentSheet extends StatefulWidget {
  const EditStudentSheet({
    super.key,
    required this.student,
    this.settingsStore,
    this.geminiService,
    this.voiceToTextService,
  });

  final Student student;
  final AppSettingsStore? settingsStore;
  final GeminiService? geminiService;
  final VoiceToTextService? voiceToTextService;

  @override
  State<EditStudentSheet> createState() => _EditStudentSheetState();
}

typedef _EditStudentSheet = EditStudentSheet;

class _EditStudentSheetState extends State<EditStudentSheet> {
  final _formKey = GlobalKey<FormState>();
  late final AppSettingsStore _settingsStore =
      widget.settingsStore ?? SecureAppSettingsStore();
  late final GeminiService _geminiService =
      widget.geminiService ?? GeminiService();
  late final VoiceToTextService _voiceService =
      widget.voiceToTextService ?? DefaultVoiceToTextService();
  bool _isPolishing = false;
  bool _isListeningVoice = false;
  String _voiceLanguage = 'si';
  String _preVoiceText = '';
  late Student _activeStudent = widget.student;

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
  late DateTime? _nextCallDateTime = tryParseDate(
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
    if (_isListeningVoice) {
      _voiceService.stop();
    }
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
    final history = List<String>.of(_activeStudent.commentHistory);
    final attempts = List<CallAttempt>.of(_activeStudent.attempts);
    final attemptedAt = DateTime.now();
    final callStatus = _callStatus ?? _activeStudent.callStatus;
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

    final hasValidFutureReminder = _nextCallDateTime != null &&
        _nextCallDateTime!.isAfter(DateTime.now());
    final nextCallStr =
        (isFinalLeadStatus(callStatus) || !hasValidFutureReminder)
            ? ''
            : _nextCallDateTime!.toIso8601String();

    return _activeStudent.copyWith(
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
      nextCallDateTime: nextCallStr,
      comment: newComment.isEmpty ? null : newComment,
      commentHistory: history,
      attempts: attempts,
    );
  }

  void _setQuickReminder(Duration offset, [int? targetHour]) {
    final now = DateTime.now();
    DateTime target;
    if (targetHour != null) {
      final tomorrow = now.add(const Duration(days: 1));
      target = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, targetHour, 0);
    } else {
      target = now.add(offset);
      final remainder = target.minute % 5;
      final roundedMinute = remainder == 0 ? target.minute : target.minute + (5 - remainder);
      if (roundedMinute >= 60) {
        target = DateTime(target.year, target.month, target.day, target.hour + 1, roundedMinute - 60);
      } else {
        target = DateTime(target.year, target.month, target.day, target.hour, roundedMinute);
      }
    }
    setState(() => _nextCallDateTime = target);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Next call scheduled: ${_formatReminder(target)}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _pickNextCallDateTime() async {
    if (_isPickingNextCallDateTime) return;
    setState(() => _isPickingNextCallDateTime = true);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final existingReminder = _nextCallDateTime;
    final isExistingFuture = existingReminder != null && existingReminder.isAfter(now);

    final initialPickerDate = isExistingFuture
        ? DateTime(existingReminder.year, existingReminder.month, existingReminder.day)
        : today;

    TimeOfDay initialPickerTime;
    if (isExistingFuture) {
      initialPickerTime = TimeOfDay.fromDateTime(existingReminder);
    } else if (existingReminder != null &&
        combineReminderDateAndTime(today, TimeOfDay.fromDateTime(existingReminder))
            .isAfter(now.add(const Duration(minutes: 5)))) {
      initialPickerTime = TimeOfDay.fromDateTime(existingReminder);
    } else {
      final safeDefault = _defaultFutureReminder(now);
      initialPickerTime = TimeOfDay.fromDateTime(safeDefault);
    }

    try {
      final selectedDate = await showDatePicker(
        context: context,
        initialDate: initialPickerDate.isBefore(today) ? today : initialPickerDate,
        firstDate: today,
        lastDate: DateTime(now.year + 10),
        helpText: 'Select next call date',
      );
      if (!mounted || selectedDate == null) return;

      final selectedTime = await showTimePicker(
        context: context,
        initialTime: initialPickerTime,
        helpText: 'Select next call time',
      );
      if (!mounted || selectedTime == null) return;

      var selectedDateTime = combineReminderDateAndTime(
        selectedDate,
        selectedTime,
      );

      final currentNow = DateTime.now();
      final isSelectedDateToday = selectedDate.year == currentNow.year &&
          selectedDate.month == currentNow.month &&
          selectedDate.day == currentNow.day;

      if (isSelectedDateToday) {
        if (selectedDateTime.isBefore(currentNow) &&
            selectedDateTime.isAfter(currentNow.subtract(const Duration(minutes: 2)))) {
          selectedDateTime = currentNow.add(const Duration(minutes: 2));
        } else if (selectedDateTime.isBefore(currentNow)) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text(
                'That time has already passed today. Choose a later time.',
              ),
            ),
          );
          return;
        }
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
    _activeStudent,
    title: 'Call attempt history',
    settingsStore: _settingsStore,
    geminiService: _geminiService,
    voiceToTextService: _voiceService,
    onStudentUpdated: (updated) async {
      setState(() {
        _activeStudent = updated;
      });
    },
  );

  Future<void> _toggleVoice() async {
    if (_isListeningVoice) {
      await _voiceService.stop();
      if (mounted) setState(() => _isListeningVoice = false);
      return;
    }

    _preVoiceText = _commentController.text;
    setState(() => _isListeningVoice = true);

    final localeId = _voiceLanguage == 'si' ? 'si_LK' : 'en_US';

    await _voiceService.listen(
      localeId: localeId,
      onResult: (words) {
        if (!mounted || words.trim().isEmpty) return;
        setState(() {
          final prefix = _preVoiceText.trim();
          if (prefix.isEmpty) {
            _commentController.text = words.trim();
          } else {
            _commentController.text = '$prefix ${words.trim()}';
          }
          _commentController.selection = TextSelection.fromPosition(
            TextPosition(offset: _commentController.text.length),
          );
        });
      },
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'notListening' || status == 'done') {
          setState(() => _isListeningVoice = false);
        }
      },
      onError: (err) {
        if (!mounted) return;
        setState(() => _isListeningVoice = false);
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.removeCurrentSnackBar();
        messenger?.showSnackBar(
          SnackBar(
            content: Text('Voice input: $err'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      },
    );
  }

  Future<void> _polishRemarkWithAi() async {
    final rawRemark = _commentController.text.trim();
    if (rawRemark.isEmpty) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.removeCurrentSnackBar();
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Please type your raw or draft remark first.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final apiKey = await _settingsStore.readGeminiApiKey();
    if (apiKey.trim().isEmpty) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.removeCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: const Text(
            'Gemini API key not configured. Please add your free key in Settings.',
          ),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () {
              showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => ManageGeminiAiSheet(
                  settingsStore: _settingsStore,
                  geminiService: _geminiService,
                ),
              );
            },
          ),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

    setState(() => _isPolishing = true);
    final originalText = _commentController.text;

    try {
      final model = await _settingsStore.readGeminiModel();
      final polished = await _geminiService.polishRemark(
        apiKey: apiKey,
        rawRemark: rawRemark,
        model: model,
      );

      if (!mounted) return;
      if (polished.isNotEmpty) {
        setState(() {
          _commentController.text = polished;
          _commentController.selection = TextSelection.fromPosition(
            TextPosition(offset: polished.length),
          );
        });

        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.removeCurrentSnackBar();
        messenger?.showSnackBar(
          SnackBar(
            content: const Text('✨ Remark polished into clear English!'),
            behavior: SnackBarBehavior.floating,
            dismissDirection: DismissDirection.horizontal,
            duration: const Duration(seconds: 2),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () {
                messenger.hideCurrentSnackBar();
                setState(() {
                  _commentController.text = originalText;
                  _commentController.selection = TextSelection.fromPosition(
                    TextPosition(offset: originalText.length),
                  );
                });
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.removeCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Could not polish remark: $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isPolishing = false);
      }
    }
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
                        : (_nextCallDateTime != null && _nextCallDateTime!.isBefore(DateTime.now())
                            ? Icons.warning_amber_rounded
                            : Icons.event_available_outlined),
                    color: _nextCallDateTime != null && _nextCallDateTime!.isBefore(DateTime.now())
                        ? const Color(0xFFD32F2F)
                        : null,
                  ),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _isPickingNextCallDateTime
                          ? 'Selecting date & time…'
                          : _nextCallDateTime == null
                          ? 'Next call date & time (optional)'
                          : (_nextCallDateTime!.isBefore(DateTime.now())
                              ? 'Next call · Overdue: ${_formatReminder(_nextCallDateTime!)} (Tap to reschedule)'
                              : 'Next call · ${_formatReminder(_nextCallDateTime!)}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    minimumSize: const Size.fromHeight(54),
                    side: BorderSide(
                      color: _nextCallDateTime != null && _nextCallDateTime!.isBefore(DateTime.now())
                          ? const Color(0xFFD32F2F)
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.add_alarm_rounded, size: 15),
                        label: const Text('+1 hr'),
                        onPressed: () => _setQuickReminder(const Duration(hours: 1)),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(Icons.add_alarm_rounded, size: 15),
                        label: const Text('+3 hrs'),
                        onPressed: () => _setQuickReminder(const Duration(hours: 3)),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(Icons.wb_sunny_outlined, size: 15),
                        label: const Text('Tomorrow 10 AM'),
                        onPressed: () => _setQuickReminder(const Duration(days: 1), 10),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(Icons.brightness_5_rounded, size: 15),
                        label: const Text('Tomorrow 2 PM'),
                        onPressed: () => _setQuickReminder(const Duration(days: 1), 14),
                      ),
                    ],
                  ),
                ),
                if (_nextCallDateTime == null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 6),
                    child: Text(
                      'Optional — leave blank to save without a call reminder.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (_nextCallDateTime != null && _nextCallDateTime!.isBefore(DateTime.now()))
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 4),
                    child: Text(
                      '⚠️ This reminder was for the past. Tap above to reschedule, or save to clear.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
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
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: _isListeningVoice
                          ? Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Colors.redAccent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Listening in ${_voiceLanguage == 'si' ? 'Sinhala' : 'English'}...',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: Colors.redAccent,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              'Draft in Sinhala, Singlish, or English',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                        .withValues(alpha: 0.7),
                                    fontSize: 11,
                                  ),
                            ),
                    ),
                    const SizedBox(width: 4),
                    // Language switcher chip (සිංහල / English)
                    InkWell(
                      key: const Key('voice_language_toggle'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        setState(() {
                          _voiceLanguage = _voiceLanguage == 'si' ? 'en' : 'si';
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          border: Border.all(
                            color: Theme.of(context)
                                .colorScheme
                                .outlineVariant
                                .withValues(alpha: 0.6),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.language_rounded,
                              size: 13,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _voiceLanguage == 'si' ? 'සිංහල' : 'English',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      key: const Key('voice_to_text_button'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        foregroundColor: _isListeningVoice
                            ? Colors.redAccent
                            : const Color(0xFF00966D),
                        side: BorderSide(
                          color: _isListeningVoice
                              ? Colors.redAccent
                              : const Color(0xFF00966D).withValues(alpha: 0.6),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onPressed: _toggleVoice,
                      icon: Icon(
                        _isListeningVoice
                            ? Icons.stop_circle_rounded
                            : Icons.mic_rounded,
                        size: 14,
                      ),
                      label: Text(
                        _isListeningVoice ? 'Stop' : '🎙️ Speak',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      key: const Key('polish_remark_button'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        foregroundColor: const Color(0xFF8B5CF6),
                        side: BorderSide(
                          color: const Color(0xFF8B5CF6).withValues(alpha: 0.6),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onPressed: _isPolishing ? null : _polishRemarkWithAi,
                      icon: _isPolishing
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome_rounded, size: 14),
                      label: Text(
                        _isPolishing ? 'Polishing...' : '✨ Polish',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
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
                          final enteredComment =
                              _commentController.text.trim();
                          final updatedAttempts =
                              List<CallAttempt>.of(updated.attempts);
                          final inactiveComment = enteredComment.isNotEmpty
                              ? enteredComment
                              : 'Marked as Inactive after $nextStreak unanswered calls';
                          if (updatedAttempts.isNotEmpty) {
                            final last = updatedAttempts.last;
                            updatedAttempts[updatedAttempts.length - 1] =
                                CallAttempt(
                              dateTime: last.dateTime,
                              status: 'Inactive',
                              comment: inactiveComment,
                            );
                          } else {
                            updatedAttempts.add(
                              CallAttempt(
                                dateTime: DateTime.now().toIso8601String(),
                                status: 'Inactive',
                                comment: inactiveComment,
                              ),
                            );
                          }

                          final updatedHistory =
                              List<String>.of(updated.commentHistory);
                          final historyEntry =
                              '${_formatReminder(DateTime.now())} — Inactive ($inactiveComment)';
                          if (enteredComment.isNotEmpty &&
                              updatedHistory.isNotEmpty) {
                            updatedHistory[updatedHistory.length - 1] =
                                historyEntry;
                          } else if (!updatedHistory.contains(historyEntry)) {
                            updatedHistory.add(historyEntry);
                          }

                          final inactiveStudent = updated.copyWith(
                            callStatus: 'Inactive',
                            nextCallDateTime: '',
                            comment: inactiveComment,
                            commentHistory: updatedHistory,
                            attempts: updatedAttempts,
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
                            Navigator.of(context).pop(inactiveStudent);
                          }
                          return;
                        }
                      }

                      if (context.mounted) {
                        ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
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

class SettingsHubSheet extends StatefulWidget {
  const SettingsHubSheet({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.isSheetConnected,
    required this.hasActiveFilters,
    required this.biometricEnabled,
    required this.onBiometricChanged,
    this.students = const [],
    this.settingsStore,
    this.updateService,
    super.key,
  });

  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeModeChanged;
  final bool isSheetConnected;
  final bool hasActiveFilters;
  final bool biometricEnabled;
  final Future<void> Function(bool) onBiometricChanged;
  final List<Student> students;
  final AppSettingsStore? settingsStore;
  final AppUpdateService? updateService;

  @override
  State<SettingsHubSheet> createState() => _SettingsHubSheetState();
}

class _SettingsHubSheetState extends State<SettingsHubSheet> {
  bool _callerIdEnabled = true;
  bool _hasOverlayPermission = false;
  bool _hasPhonePermissions = false;
  bool _isIgnoringBattery = true;
  bool _autoLogCallDuration = true;
  int _cachedCount = 0;
  String _geminiApiKey = '';
  bool _autoCheckUpdates = true;
  bool _isCheckingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadCallerIdState();
    _loadGeminiState();
    _loadUpdateState();
  }

  Future<void> _loadUpdateState() async {
    final enabled = await widget.settingsStore?.readAutoCheckUpdates() ?? true;
    if (mounted) {
      setState(() => _autoCheckUpdates = enabled);
    }
  }

  Future<void> _checkForUpdatesManually() async {
    setState(() => _isCheckingUpdate = true);
    try {
      final info = await (widget.updateService ?? AppUpdateService())
          .checkForUpdates(currentVersion: kAppVersion);
      if (!mounted) return;
      if (info.hasUpdate) {
        await showAppUpdateDialog(context, info);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('LeadPilot is up to date (v$kAppVersion).'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not check for updates: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isCheckingUpdate = false);
      }
    }
  }

  Future<void> _loadGeminiState() async {
    final key = await widget.settingsStore?.readGeminiApiKey() ?? '';
    if (mounted) {
      setState(() => _geminiApiKey = key);
    }
  }

  Future<void> _loadCallerIdState() async {
    final enabled = await CallerIdService.isEnabled();
    final hasOverlay = await CallerIdService.canDrawOverlays();
    final hasPhone = await CallerIdService.hasPhonePermissions();
    final isIgnoringBattery =
        await CallerIdService.isIgnoringBatteryOptimizations();
    final autoLog =
        await widget.settingsStore?.readAutoLogCallDuration() ?? true;
    var count = await CallerIdService.getCachedCount();
    if (count == 0 && widget.students.isNotEmpty) {
      await CallerIdService.syncStudents(widget.students);
      count = await CallerIdService.getCachedCount();
    }
    if (mounted) {
      setState(() {
        _callerIdEnabled = enabled;
        _hasOverlayPermission = hasOverlay;
        _hasPhonePermissions = hasPhone;
        _isIgnoringBattery = isIgnoringBattery;
        _autoLogCallDuration = autoLog;
        _cachedCount = count > 0 ? count : widget.students.length;
      });
    }
  }

  Future<void> _requestPermissions() async {
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

    if (widget.students.isNotEmpty) {
      await CallerIdService.syncStudents(widget.students);
    }

    await _loadCallerIdState();
  }

  Future<void> _handleCallerIdToggle(bool enable) async {
    if (enable) {
      await CallerIdService.setEnabled(true);
      await _requestPermissions();
    } else {
      await CallerIdService.setEnabled(false);
      if (mounted) setState(() => _callerIdEnabled = false);
    }
  }

  Future<void> _testCallerIdPopup() async {
    final hasOverlay = await CallerIdService.canDrawOverlays();
    final hasPhone = await CallerIdService.hasPhonePermissions();
    if (!mounted) return;
    if (!hasOverlay || !hasPhone) {
      await _requestPermissions();
      return;
    }
    await CallerIdService.testCallerIdPopup();
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Sample Caller ID popup displayed!'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<void> _testNotificationBanner() async {
    final hasPhone = await CallerIdService.hasPhonePermissions();
    if (!mounted) return;
    if (!hasPhone) {
      await _requestPermissions();
      return;
    }
    await CallerIdService.testNotificationBanner();
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Sample Heads-Up / Lock Screen banner displayed! Check your notifications.',
        ),
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
                      title: const Text('WhatsApp & SMS templates'),
                      subtitle: const Text(
                        'Manage pre-written message templates',
                      ),
                      onTap: () => Navigator.pop(
                        context,
                        _SettingsAction.whatsAppTemplates,
                      ),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.auto_awesome_rounded,
                        color: Color(0xFF8B5CF6),
                      ),
                      title: const Text('Gemini AI Assistant'),
                      subtitle: Text(
                        _geminiApiKey.trim().isEmpty
                            ? 'Connect free API key for smart follow-ups'
                            : 'Connected • Ready for AI messaging',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pop(
                        context,
                        _SettingsAction.geminiAi,
                      ),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.business_rounded,
                        color: Color(0xFF8B5CF6),
                      ),
                      title: const Text('Description about your company'),
                      subtitle: const Text(
                        'Configure institute details (LNBTI) for AI messaging',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pop(
                        context,
                        _SettingsAction.companyDescription,
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
                      subtitle: Text(
                        _callerIdEnabled
                            ? (_hasOverlayPermission && _hasPhonePermissions
                                ? 'Active • $_cachedCount lead(s) cached offline'
                                : 'Permission required for call detection')
                            : 'Disabled',
                      ),
                      value: _callerIdEnabled,
                      onChanged: _handleCallerIdToggle,
                    ),
                    if (_callerIdEnabled && (!_hasOverlayPermission || !_hasPhonePermissions)) ...[
                      Divider(height: 1, indent: 56, color: theme.colorScheme.outlineVariant),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFAA48), size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  'Setup Action Required',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: const Color(0xFFFFAA48),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              !_hasPhonePermissions
                                  ? 'Allow Phone & Call Log permission so LeadPilot can detect caller numbers.'
                                  : 'Allow "Display over other apps" so the popup can show on incoming calls.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            FilledButton.tonalIcon(
                              icon: const Icon(Icons.lock_open_rounded, size: 16),
                              label: const Text('Grant Permissions'),
                              onPressed: _requestPermissions,
                            ),
                          ],
                        ),
                      ),
                    ],
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
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      ListTile(
                        leading: const Icon(Icons.notification_important_rounded),
                        title: const Text('Test Lock Screen & Heads-Up Banner'),
                        subtitle: const Text(
                          'Display a sample calling alert banner',
                        ),
                        onTap: _testNotificationBanner,
                      ),
                      if (!_isIgnoringBattery) ...[
                        Divider(
                          height: 1,
                          indent: 56,
                          color: theme.colorScheme.outlineVariant,
                        ),
                        ListTile(
                          leading: const Icon(
                            Icons.battery_alert_rounded,
                            color: Color(0xFFFFAA48),
                          ),
                          title: const Text('Allow Background Running'),
                          subtitle: const Text(
                            'Exempt from Battery Optimization so detection runs when phone is asleep',
                          ),
                          trailing: FilledButton.tonal(
                            onPressed: () async {
                              await CallerIdService
                                  .requestIgnoreBatteryOptimizations();
                              await Future<void>.delayed(
                                const Duration(seconds: 1),
                              );
                              await _loadCallerIdState();
                            },
                            child: const Text('Allow'),
                          ),
                        ),
                      ],
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      ListTile(
                        leading: const Icon(Icons.app_settings_alt_rounded),
                        title: const Text('Xiaomi / Samsung Background Fix'),
                        subtitle: const Text(
                          'Open App Settings to allow Autostart & Pop-ups in background',
                        ),
                        trailing: Icon(
                          Icons.open_in_new_rounded,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        onTap: () async {
                          await CallerIdService.openAppDetailsSettings();
                        },
                      ),
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.timer_outlined),
                        title: const Text('Auto-log Call Duration'),
                        subtitle: const Text(
                          'Record [Call Connected • 3 mins 45 secs] in lead history after each call',
                        ),
                        value: _autoLogCallDuration,
                        onChanged: (val) async {
                          setState(() => _autoLogCallDuration = val);
                          await widget.settingsStore
                              ?.saveAutoLogCallDuration(val);
                        },
                      ),
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      ListTile(
                        leading: const Icon(Icons.sync_rounded),
                        title: const Text('Re-sync Leads to Phone'),
                        subtitle: Text(
                          '$_cachedCount student lead(s) stored in phone',
                        ),
                        trailing: TextButton(
                          onPressed: () async {
                            if (widget.students.isNotEmpty) {
                              await CallerIdService.syncStudents(
                                widget.students,
                              );
                              await _loadCallerIdState();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${widget.students.length} leads synced for Caller ID!',
                                    ),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text('Sync'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'App Updates',
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
                      leading: const Icon(Icons.system_update_rounded),
                      title: const Text('Check for Updates'),
                      subtitle: Text(
                        _isCheckingUpdate
                            ? 'Checking GitHub for updates...'
                            : 'Current version: v$kAppVersion',
                      ),
                      trailing: _isCheckingUpdate
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : FilledButton.tonal(
                              key: const Key('check_updates_button'),
                              onPressed: _checkForUpdatesManually,
                              child: const Text('Check'),
                            ),
                      onTap: _isCheckingUpdate ? null : _checkForUpdatesManually,
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    SwitchListTile(
                      key: const Key('auto_check_updates_switch'),
                      secondary: const Icon(Icons.autorenew_rounded),
                      title: const Text('Auto-check on Startup'),
                      subtitle: const Text(
                        'Automatically check for new releases when app opens',
                      ),
                      value: _autoCheckUpdates,
                      onChanged: (val) async {
                        setState(() => _autoCheckUpdates = val);
                        await widget.settingsStore?.saveAutoCheckUpdates(val);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'LeadPilot v$kAppVersion',
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

enum _MessageChoice { custom, template, ai }

class WhatsAppChoiceSheet extends StatelessWidget {
  const WhatsAppChoiceSheet({super.key, required this.student});

  final Student student;

  @override
  Widget build(BuildContext context) {
    return MessageChoiceSheet(student: student, isSms: false);
  }
}

class SmsChoiceSheet extends StatelessWidget {
  const SmsChoiceSheet({super.key, required this.student});

  final Student student;

  @override
  Widget build(BuildContext context) {
    return MessageChoiceSheet(student: student, isSms: true);
  }
}

class MessageChoiceSheet extends StatelessWidget {
  const MessageChoiceSheet({
    super.key,
    required this.student,
    this.isSms = false,
  });

  final Student student;
  final bool isSms;

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
                isSms ? 'Send SMS Message' : 'Send WhatsApp Message',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                isSms ? 'SMS to ${student.name}' : 'Message to ${student.name}',
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
                      leading: Icon(
                        isSms ? Icons.sms_outlined : Icons.chat_bubble_outline,
                        color: isSms ? const Color(0xFF2E6FA3) : null,
                      ),
                      title: const Text('Custom'),
                      subtitle: Text(
                        isSms
                            ? 'Open SMS app with a blank message'
                            : 'Open WhatsApp with a blank chat',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () =>
                          Navigator.pop(context, _MessageChoice.custom),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(Icons.text_snippet_outlined),
                      title: const Text('Template'),
                      subtitle:
                          const Text('Choose a pre-written message template'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () =>
                          Navigator.pop(context, _MessageChoice.template),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.auto_awesome_rounded,
                        color: Color(0xFF8B5CF6),
                      ),
                      title: Row(
                        children: [
                          const Text('Generate with AI'),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8B5CF6)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'Gemini',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF8B5CF6),
                              ),
                            ),
                          ),
                        ],
                      ),
                      subtitle: const Text(
                        'Personalized message based on call notes',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pop(context, _MessageChoice.ai),
                    ),
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

class WhatsAppTemplatePickerSheet extends StatefulWidget {
  const WhatsAppTemplatePickerSheet({
    super.key,
    required this.student,
    required this.templates,
    required this.onManageTemplates,
    this.isSms = false,
    this.isBulk = false,
  });

  final Student student;
  final List<WhatsAppTemplate> templates;
  final VoidCallback onManageTemplates;
  final bool isSms;
  final bool isBulk;

  @override
  State<WhatsAppTemplatePickerSheet> createState() =>
      _WhatsAppTemplatePickerSheetState();
}

class _WhatsAppTemplatePickerSheetState
    extends State<WhatsAppTemplatePickerSheet> {
  bool _isMultiSelect = false;
  final Set<String> _selectedTemplateIds = <String>{};

  String _formatMessage(String template) {
    final studentName = widget.student.name.trim();
    return template.replaceAll(
      '{name}',
      studentName.isNotEmpty ? studentName : 'there',
    );
  }

  void _sendSingle(WhatsAppTemplate item) {
    final messageToSend =
        widget.isBulk ? item.message : _formatMessage(item.message);
    final docs =
        (item.hasDocument && !widget.isSms && item.documentPath != null)
            ? [item.documentPath!]
            : <String>[];
    Navigator.pop(
      context,
      WhatsAppSendPayload(
        message: messageToSend,
        documentPaths: docs,
      ),
    );
  }

  void _sendMulti() {
    if (_selectedTemplateIds.isEmpty) return;

    final selected = widget.templates
        .where((t) => _selectedTemplateIds.contains(t.id))
        .toList();
    if (selected.isEmpty) return;

    final combinedMessage = selected
        .map((t) =>
            (widget.isBulk ? t.message : _formatMessage(t.message)).trim())
        .where((msg) => msg.isNotEmpty)
        .join('\n\n');

    final docs = <String>[];
    if (!widget.isSms) {
      for (final t in selected) {
        if (t.hasDocument && t.documentPath != null) {
          final p = t.documentPath!;
          if (!docs.contains(p)) {
            docs.add(p);
          }
        }
      }
    }

    Navigator.pop(
      context,
      WhatsAppSendPayload(
        message: combinedMessage,
        documentPaths: docs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final selectedCount = _selectedTemplateIds.length;
    final selectedDocsCount = widget.isSms
        ? 0
        : widget.templates
            .where((t) =>
                _selectedTemplateIds.contains(t.id) &&
                t.hasDocument &&
                t.documentPath != null)
            .length;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 20,
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
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              'Select Template',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (_isMultiSelect && selectedCount > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '$selectedCount selected',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isMultiSelect
                            ? 'Check templates to combine and send together'
                            : (widget.isSms
                                ? 'Tap a template to send via SMS'
                                : 'Tap a template to send, or choose multi-select'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                FilterChip(
                  selected: _isMultiSelect,
                  showCheckmark: false,
                  avatar: Icon(
                    _isMultiSelect
                        ? Icons.checklist_rtl_rounded
                        : Icons.checklist_rounded,
                    size: 16,
                    color: _isMultiSelect
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.primary,
                  ),
                  label: Text(
                    _isMultiSelect ? 'Done' : 'Multi-Select',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _isMultiSelect
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.primary,
                    ),
                  ),
                  selectedColor: theme.colorScheme.primary,
                  backgroundColor:
                      theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
                  side: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  ),
                  onSelected: (val) {
                    setState(() {
                      _isMultiSelect = val;
                      if (!val) _selectedTemplateIds.clear();
                    });
                  },
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: widget.onManageTemplates,
                  icon: const Icon(Icons.settings_outlined, size: 20),
                  tooltip: 'Manage Templates',
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (widget.templates.isEmpty)
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
                      onPressed: widget.onManageTemplates,
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
                  itemCount: widget.templates.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = widget.templates[index];
                    final preview = _formatMessage(item.message);
                    final isSelected = _selectedTemplateIds.contains(item.id);

                    return Card(
                      color: isSelected
                          ? theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.35)
                          : theme.colorScheme.surfaceContainerLow,
                      margin: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: isSelected
                            ? BorderSide(
                                color: theme.colorScheme.primary,
                                width: 1.5,
                              )
                            : BorderSide(
                                color: theme.colorScheme.outlineVariant
                                    .withValues(alpha: 0.3),
                              ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          if (_isMultiSelect) {
                            setState(() {
                              if (isSelected) {
                                _selectedTemplateIds.remove(item.id);
                              } else {
                                _selectedTemplateIds.add(item.id);
                              }
                            });
                          } else {
                            _sendSingle(item);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  if (_isMultiSelect) ...[
                                    Checkbox(
                                      value: isSelected,
                                      visualDensity: VisualDensity.compact,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      onChanged: (val) {
                                        setState(() {
                                          if (val == true) {
                                            _selectedTemplateIds.add(item.id);
                                          } else {
                                            _selectedTemplateIds.remove(item.id);
                                          }
                                        });
                                      },
                                    ),
                                    const SizedBox(width: 6),
                                  ] else ...[
                                    Icon(
                                      widget.isSms
                                          ? Icons.sms_outlined
                                          : Icons.chat_bubble_outline,
                                      size: 18,
                                      color: widget.isSms
                                          ? const Color(0xFF2E6FA3)
                                          : theme.colorScheme.primary,
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Expanded(
                                    child: Text(
                                      item.name,
                                      style:
                                          theme.textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (!_isMultiSelect)
                                    Icon(
                                      Icons.send_rounded,
                                      size: 16,
                                      color: theme.colorScheme.primary,
                                    ),
                                ],
                              ),
                              if (preview.trim().isNotEmpty) ...[
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
                              if (item.hasDocument && !widget.isSms) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primaryContainer
                                        .withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: theme.colorScheme.primary
                                          .withValues(alpha: 0.3),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.attach_file,
                                        size: 14,
                                        color: theme.colorScheme.primary,
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          item.documentName ?? 'Attached document',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                            color: theme.colorScheme.primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (_isMultiSelect) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _selectedTemplateIds.isEmpty ? null : _sendMulti,
                icon: const Icon(Icons.send_rounded, size: 18),
                label: Text(
                  _selectedTemplateIds.isEmpty
                      ? 'Select templates to send'
                      : 'Send $selectedCount Template${selectedCount > 1 ? "s" : ""}${selectedDocsCount > 0 ? " ($selectedDocsCount with docs)" : ""}',
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _BulkItemStatus { pending, sent, skipped }

class BulkDispatchSheet extends StatefulWidget {
  const BulkDispatchSheet({
    super.key,
    required this.students,
    required this.payload,
    required this.isSms,
    required this.onDispatch,
  });

  final List<Student> students;
  final WhatsAppSendPayload payload;
  final bool isSms;
  final Future<void> Function(Student student, String text) onDispatch;

  @override
  State<BulkDispatchSheet> createState() => _BulkDispatchSheetState();
}

class _BulkDispatchSheetState extends State<BulkDispatchSheet> {
  int _currentIndex = 0;
  final Map<int, _BulkItemStatus> _statuses = {};
  final Map<int, String> _customEdits = {};
  late final TextEditingController _messageController;
  bool _isDone = false;
  bool _isDispatching = false;

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController();
    _syncControllerForCurrentStudent();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  void _syncControllerForCurrentStudent() {
    if (_currentIndex < widget.students.length) {
      final student = widget.students[_currentIndex];
      _messageController.text =
          _customEdits[_currentIndex] ?? _formatForStudent(student);
    }
  }

  int get _sentCount =>
      _statuses.values.where((s) => s == _BulkItemStatus.sent).length;

  int get _skippedCount =>
      _statuses.values.where((s) => s == _BulkItemStatus.skipped).length;

  int get _remainingCount =>
      widget.students.length - (_sentCount + _skippedCount);

  double get _progress => widget.students.isEmpty
      ? 1.0
      : (_sentCount + _skippedCount) / widget.students.length;

  String _formatForStudent(Student student) {
    final sName = student.name.trim();
    final nameToUse = sName.isNotEmpty ? sName : 'there';
    var text = widget.payload.message;
    text = text.replaceAll(
      RegExp(r'\{\s*name\s*\}', caseSensitive: false),
      nameToUse,
    );
    text = text.replaceAll(
      RegExp(r'\{\s*student\s*\}', caseSensitive: false),
      nameToUse,
    );
    text = text.replaceAll(
      RegExp(r'\{\s*student_name\s*\}', caseSensitive: false),
      nameToUse,
    );
    return text;
  }

  void _advanceToNext() {
    int next = -1;
    for (int i = 0; i < widget.students.length; i++) {
      if (!_statuses.containsKey(i)) {
        next = i;
        break;
      }
    }
    if (next != -1) {
      _currentIndex = next;
      _syncControllerForCurrentStudent();
    } else {
      _isDone = true;
    }
  }

  Future<void> _sendCurrent() async {
    if (_isDispatching || _currentIndex >= widget.students.length) return;
    setState(() => _isDispatching = true);

    final student = widget.students[_currentIndex];
    final personalizedText = _messageController.text.trim();

    try {
      await widget.onDispatch(student, personalizedText);
    } finally {
      if (mounted) {
        setState(() {
          _isDispatching = false;
          _statuses[_currentIndex] = _BulkItemStatus.sent;
          _advanceToNext();
        });
      }
    }
  }

  void _skipCurrent() {
    if (_currentIndex >= widget.students.length) return;
    setState(() {
      _statuses[_currentIndex] = _BulkItemStatus.skipped;
      _advanceToNext();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
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
            const SizedBox(height: 14),
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: widget.isSms
                      ? const Color(0xFF2E6FA3).withValues(alpha: 0.15)
                      : const Color(0xFF25D366).withValues(alpha: 0.15),
                  child: widget.isSms
                      ? const Icon(
                          Icons.sms_rounded,
                          size: 18,
                          color: Color(0xFF2E6FA3),
                        )
                      : const FaIcon(
                          FontAwesomeIcons.whatsapp,
                          size: 18,
                          color: Color(0xFF25D366),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.isSms ? 'Bulk SMS Queue' : 'Bulk WhatsApp Queue',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${widget.students.length} students in queue',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Close queue',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(
                  widget.isSms
                      ? const Color(0xFF2E6FA3)
                      : const Color(0xFF25D366),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Sent: $_sentCount • Skipped: $_skippedCount',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  '$_remainingCount remaining',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (_isDone) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      size: 64,
                      color: Color(0xFF25D366),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'All Messages Dispatched!',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Successfully processed ${widget.students.length} student(s) with personalized messages.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 12,
                        ),
                      ),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            ] else ...[
              _buildCurrentStudentCard(context, theme),
              const SizedBox(height: 12),
              Text(
                'Queue Overview (${widget.students.length})',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.students.length,
                  separatorBuilder: (ctx, i) => const SizedBox(height: 6),
                  itemBuilder: (ctx, i) {
                    final student = widget.students[i];
                    final status = _statuses[i] ?? _BulkItemStatus.pending;
                    final isCurrent = i == _currentIndex;

                    Widget statusIcon;
                    String statusLabel;
                    Color statusColor;

                    if (status == _BulkItemStatus.sent) {
                      statusIcon = const Icon(
                        Icons.check_circle,
                        size: 16,
                        color: Color(0xFF25D366),
                      );
                      statusLabel = 'Sent';
                      statusColor = const Color(0xFF25D366);
                    } else if (status == _BulkItemStatus.skipped) {
                      statusIcon = const Icon(
                        Icons.skip_next,
                        size: 16,
                        color: Colors.orange,
                      );
                      statusLabel = 'Skipped';
                      statusColor = Colors.orange;
                    } else if (isCurrent) {
                      statusIcon = Icon(
                        Icons.play_circle_fill,
                        size: 16,
                        color: theme.colorScheme.primary,
                      );
                      statusLabel = 'Current';
                      statusColor = theme.colorScheme.primary;
                    } else {
                      statusIcon = Icon(
                        Icons.radio_button_unchecked,
                        size: 16,
                        color: theme.colorScheme.outline,
                      );
                      statusLabel = 'Pending';
                      statusColor = theme.colorScheme.outline;
                    }

                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        setState(() {
                          _currentIndex = i;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? theme.colorScheme.primaryContainer
                                  .withValues(alpha: 0.3)
                              : theme.colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(10),
                          border: isCurrent
                              ? Border.all(
                                  color: theme.colorScheme.primary,
                                  width: 1.2,
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            statusIcon,
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                student.name,
                                style: TextStyle(
                                  fontWeight: isCurrent
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              statusLabel,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: statusColor,
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
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentStudentCard(BuildContext context, ThemeData theme) {
    final currentStudent = widget.students[_currentIndex];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_currentIndex + 1} of ${widget.students.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              Icon(
                Icons.phone_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                currentStudent.phone,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            currentStudent.name,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (widget.payload.hasDocuments && !widget.isSms) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.attach_file,
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '${widget.payload.documentPaths.length} document(s) attached',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _messageController,
            maxLines: 4,
            onChanged: (val) {
              _customEdits[_currentIndex] = val;
            },
            decoration: InputDecoration(
              isDense: true,
              hintText: '(Document attachment only)',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: theme.colorScheme.primary,
                  width: 1.5,
                ),
              ),
              contentPadding: const EdgeInsets.all(10),
            ),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isDispatching ? null : _sendCurrent,
                  style: FilledButton.styleFrom(
                    backgroundColor: widget.isSms
                        ? const Color(0xFF2E6FA3)
                        : const Color(0xFF25D366),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: widget.isSms
                      ? const Icon(Icons.send_rounded, size: 18)
                      : const FaIcon(FontAwesomeIcons.whatsapp, size: 18),
                  label: Text(
                    'Send to ${currentStudent.name.split(" ").first}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _skipCurrent,
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Skip'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TemplateEditorDialog extends StatefulWidget {
  const _TemplateEditorDialog({
    this.template,
    this.initialName,
    this.initialMessage,
  });

  final WhatsAppTemplate? template;
  final String? initialName;
  final String? initialMessage;

  @override
  State<_TemplateEditorDialog> createState() => _TemplateEditorDialogState();
}

class _TemplateEditorDialogState extends State<_TemplateEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _messageController;
  String? _documentPath;
  String? _documentName;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.template?.name ?? widget.initialName ?? '',
    );
    _messageController = TextEditingController(
      text: widget.template?.message ?? widget.initialMessage ?? '',
    );
    _documentPath = widget.template?.documentPath;
    _documentName = widget.template?.documentName;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _pickDocument() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: [
          'pdf',
          'doc',
          'docx',
          'xls',
          'xlsx',
          'ppt',
          'pptx',
          'txt',
          'png',
          'jpg',
          'jpeg',
        ],
      );
      if (file != null && file.path != null && file.path!.trim().isNotEmpty) {
        setState(() {
          _documentPath = file.path;
          _documentName = file.name;
        });
        _formKey.currentState?.validate();
      }
    } catch (e) {
      debugPrint('Error picking file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not attach file: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(
        widget.template != null
            ? 'Edit Template'
            : (widget.initialMessage != null
                ? 'Save as Template'
                : 'Add Template'),
      ),
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
                decoration: InputDecoration(
                  labelText: 'Message',
                  hintText: 'e.g. Hello {name}, your class starts tomorrow.',
                  helperText: _documentPath != null
                      ? 'Optional when document is attached'
                      : 'Tip: Use {name} for student name',
                  border: const OutlineInputBorder(),
                ),
                maxLines: 4,
                minLines: 2,
                textCapitalization: TextCapitalization.sentences,
                validator: (val) {
                  final hasDoc = _documentPath != null &&
                      _documentPath!.trim().isNotEmpty;
                  if ((val == null || val.trim().isEmpty) && !hasDoc) {
                    return 'Please enter message content or attach a document';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              // Document attachment section for WhatsApp templates
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.attach_file,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Attach Document (WhatsApp)',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Attach a PDF or file to send along with this template on WhatsApp.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_documentPath != null && _documentName != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.description,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _documentName!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Remove document',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () {
                                setState(() {
                                  _documentPath = null;
                                  _documentName = null;
                                });
                                _formKey.currentState?.validate();
                              },
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      OutlinedButton.icon(
                        onPressed: _pickDocument,
                        icon: const Icon(Icons.upload_file, size: 18),
                        label: const Text('Attach Document (PDF, Doc)'),
                      ),
                    ],
                  ],
                ),
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
                documentPath: _documentPath,
                documentName: _documentName,
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
                    'WhatsApp & SMS Templates',
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
              'Pre-written messages for WhatsApp & SMS with {name} placeholder support.',
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
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          item.name,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      if (item.hasDocument) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: theme
                                                .colorScheme.primaryContainer,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.attach_file,
                                                size: 13,
                                                color: theme.colorScheme
                                                    .onPrimaryContainer,
                                              ),
                                              const SizedBox(width: 3),
                                              ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                  maxWidth: 130,
                                                ),
                                                child: Text(
                                                  item.documentName ?? 'Doc',
                                                  style: theme
                                                      .textTheme.labelSmall
                                                      ?.copyWith(
                                                    color: theme.colorScheme
                                                        .onPrimaryContainer,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
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
                            if (item.message.trim().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                item.message,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            if (item.hasDocument) ...[
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(
                                    Icons.description_outlined,
                                    size: 14,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      'File: ${item.documentName}',
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.primary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
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

class ManageGeminiAiSheet extends StatefulWidget {
  const ManageGeminiAiSheet({
    super.key,
    required this.settingsStore,
    this.geminiService,
  });

  final AppSettingsStore settingsStore;
  final GeminiService? geminiService;

  @override
  State<ManageGeminiAiSheet> createState() => _ManageGeminiAiSheetState();
}

class _ManageGeminiAiSheetState extends State<ManageGeminiAiSheet> {
  late final TextEditingController _controller;
  late final TextEditingController _companyController;
  late final GeminiService _geminiService;
  bool _obscure = true;
  bool _isTesting = false;
  String? _testResult;
  bool _isSuccess = false;
  final List<GeminiModelInfo> _availableModels = List.of(GeminiService.defaultModels);
  String _selectedModel = 'gemini-1.5-flash';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _companyController = TextEditingController();
    _geminiService = widget.geminiService ?? GeminiService();
    _loadKeyAndModel();
  }

  Future<void> _loadKeyAndModel() async {
    final key = await widget.settingsStore.readGeminiApiKey();
    final model = await widget.settingsStore.readGeminiModel();
    final company = await widget.settingsStore.readCompanyDescription();
    if (mounted) {
      setState(() {
        _controller.text = key;
        _companyController.text = company;
        _selectedModel = model.isNotEmpty ? model : 'gemini-1.5-flash';
      });
      if (key.isNotEmpty) {
        _fetchModelsQuietly(key);
      }
    }
  }

  Future<void> _fetchModelsQuietly(String key) async {
    try {
      final models = await _geminiService.fetchAvailableModels(key);
      if (models.isNotEmpty && mounted) {
        setState(() {
          final existingIds = _availableModels.map((m) => m.id).toSet();
          for (final m in models) {
            if (!existingIds.contains(m.id)) {
              _availableModels.add(m);
            }
          }
          if (!_availableModels.any((m) => m.id == _selectedModel)) {
            _selectedModel = _availableModels.first.id;
          }
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _controller.dispose();
    _companyController.dispose();
    super.dispose();
  }

  Future<void> _saveKey() async {
    final cleanKey = GeminiService.sanitizeApiKey(_controller.text);
    _controller.text = cleanKey;
    await widget.settingsStore.saveGeminiApiKey(cleanKey);
    await widget.settingsStore.saveGeminiModel(_selectedModel);
    await widget.settingsStore.saveCompanyDescription(_companyController.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cleanKey.isNotEmpty
              ? 'Gemini API Key, Model ($_selectedModel), and Company Description saved!'
              : 'Gemini settings saved.',
        ),
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _testConnection() async {
    final rawKey = _controller.text;
    final cleanKey = GeminiService.sanitizeApiKey(rawKey);
    if (cleanKey != rawKey) {
      _controller.text = cleanKey;
    }

    if (cleanKey.isEmpty) {
      setState(() {
        _testResult = 'Please enter an API Key to test.';
        _isSuccess = false;
      });
      return;
    }
    setState(() {
      _isTesting = true;
      _testResult = null;
    });

    final result = await _geminiService.testConnection(
      cleanKey,
      targetModel: _selectedModel,
    );
    if (!mounted) return;
    setState(() {
      _isTesting = false;
      _isSuccess = result.isSuccess;
      _testResult = result.message;
      if (result.availableModels.isNotEmpty) {
        final existingIds = _availableModels.map((m) => m.id).toSet();
        for (final m in result.availableModels) {
          if (!existingIds.contains(m.id)) {
            _availableModels.add(m);
          }
        }
        if (result.isSuccess && result.modelName != null) {
          _selectedModel = result.modelName!;
        } else if (!_availableModels.any((m) => m.id == _selectedModel)) {
          _selectedModel = _availableModels.first.id;
        }
      }
    });
  }

  Future<void> _openGoogleAiStudio() async {
    final uri = Uri.parse('https://aistudio.google.com/app/apikey');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    final clean = GeminiService.sanitizeApiKey(text);
    if (clean.isNotEmpty) {
      setState(() => _controller.text = clean);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasKey = _controller.text.trim().isNotEmpty;

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
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      color: Color(0xFF8B5CF6),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Gemini AI Assistant',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Connect your free Google Gemini API key',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            hasKey
                                ? Icons.check_circle_rounded
                                : Icons.info_outline_rounded,
                            color: hasKey
                                ? const Color(0xFF159A76)
                                : const Color(0xFF8B5CF6),
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            hasKey ? 'API Key Configured' : '100% Free API Access',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: hasKey
                                  ? const Color(0xFF159A76)
                                  : const Color(0xFF8B5CF6),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Google AI Studio offers 1,500 requests per day for Gemini 1.5 Flash completely free (no credit card required). You can create an API key in under 1 minute.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _openGoogleAiStudio,
                        icon: const Icon(Icons.open_in_new_rounded, size: 16),
                        label: const Text('Get Free Key (Google AI Studio)'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF8B5CF6),
                          side: const BorderSide(color: Color(0xFF8B5CF6)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Gemini API Key',
                  hintText: 'Paste key (starts with AIzaSy...)',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '💡 Gemini API keys start with "AIzaSy..." or "AQ." (100% Free on Gemini 1.5 Flash). Newly created keys can take 30–60s to activate.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.paste_rounded, size: 16),
                    label: const Text('Paste from clipboard'),
                  ),
                  const Spacer(),
                  if (_controller.text.trim().isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() => _controller.clear()),
                      child: const Text('Clear'),
                    ),
                ],
              ),
              if (_availableModels.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey('$_selectedModel-${_availableModels.length}'),
                  initialValue: _availableModels.any((m) => m.id == _selectedModel)
                      ? _selectedModel
                      : _availableModels.first.id,
                  decoration: const InputDecoration(
                    labelText: 'Selected Gemini Model',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.psychology_rounded),
                  ),
                  isExpanded: true,
                  items: _availableModels.map((info) {
                    final isFree = info.id.contains('flash');
                    return DropdownMenuItem<String>(
                      value: info.id,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              info.displayName,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (isFree)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF159A76).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'FREE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF159A76),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (newModel) {
                    if (newModel != null) {
                      setState(() => _selectedModel = newModel);
                    }
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  '⚡ ${_availableModels.length} models accessible to this key. Select your preferred model.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: _companyController,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: 'Description about your company',
                  hintText: 'e.g. LNBTI (Lanka Nippon BizTech Institute)...',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Padding(
                    padding: EdgeInsets.only(bottom: 24),
                    child: Icon(Icons.business_rounded),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.restart_alt_rounded, size: 20),
                    tooltip: 'Reset to LNBTI default',
                    onPressed: () {
                      setState(() {
                        _companyController.text = _defaultCompanyDescription;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '🏢 AI uses this company description to represent LNBTI politely without overloading the message with excessive details.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
              if (_testResult != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _isSuccess
                        ? const Color(0xFF159A76).withValues(alpha: 0.12)
                        : theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isSuccess
                          ? const Color(0xFF159A76).withValues(alpha: 0.3)
                          : theme.colorScheme.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: SelectableText(
                    _testResult!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _isSuccess
                          ? const Color(0xFF159A76)
                          : theme.colorScheme.error,
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isTesting ? null : _testConnection,
                      icon: _isTesting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bolt_rounded, size: 18),
                      label: Text(_isTesting ? 'Testing...' : 'Test Key'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saveKey,
                      icon: const Icon(Icons.save_rounded, size: 18),
                      label: const Text('Save Key'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6),
                        foregroundColor: Colors.white,
                      ),
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

class GeminiAiMessageSheet extends StatefulWidget {
  const GeminiAiMessageSheet({
    super.key,
    required this.student,
    required this.initialApiKey,
    required this.settingsStore,
    this.geminiService,
    this.isSms = false,
  });

  final Student student;
  final String initialApiKey;
  final AppSettingsStore settingsStore;
  final GeminiService? geminiService;
  final bool isSms;

  @override
  State<GeminiAiMessageSheet> createState() => _GeminiAiMessageSheetState();
}

class _GeminiAiMessageSheetState extends State<GeminiAiMessageSheet> {
  late String _apiKey;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _instructionController;
  late final TextEditingController _messageController;
  late final GeminiService _geminiService;

  String _selectedLanguage = 'Sinhala';
  bool _isGenerating = false;
  String? _errorMessage;
  bool _obscureApiKey = true;
  String _companySummary = '';

  final List<String> _languages = const ['Sinhala', 'Singlish', 'English'];

  @override
  void initState() {
    super.initState();
    _apiKey = widget.initialApiKey.trim();
    _apiKeyController = TextEditingController(text: _apiKey);
    _instructionController = TextEditingController();
    _messageController = TextEditingController();
    _geminiService = widget.geminiService ?? GeminiService();
    _loadCompanyInfo();

    final st = widget.student.callStatus.toLowerCase();
    final streak = studentActivityStatus(widget.student).unansweredStreak;
    if (st.contains('no answer') ||
        st.contains('busy') ||
        st.contains('call cut') ||
        streak >= 2) {
      _instructionController.text = 'Follow-up regarding missed call';
    } else if (st.contains('interest') || st.contains('register')) {
      _instructionController.text = 'Follow-up on class details and registration';
    } else {
      _instructionController.text = 'General class follow-up';
    }

    if (_apiKey.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _generateMessage();
      });
    }
  }

  Future<void> _loadCompanyInfo() async {
    final company = await widget.settingsStore.readCompanyDescription();
    if (!mounted) return;
    setState(() {
      _companySummary = company.contains('-')
          ? company.split('-').first.trim()
          : (company.length > 30 ? '${company.substring(0, 30)}...' : company);
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _instructionController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _saveApiKey() async {
    final cleanKey = GeminiService.sanitizeApiKey(_apiKeyController.text);
    _apiKeyController.text = cleanKey;
    if (cleanKey.isEmpty) {
      setState(() => _errorMessage = 'Please paste a valid Gemini API Key.');
      return;
    }
    await widget.settingsStore.saveGeminiApiKey(cleanKey);
    if (!mounted) return;
    setState(() {
      _apiKey = cleanKey;
      _errorMessage = null;
    });
    await _generateMessage();
  }

  Future<void> _generateMessage() async {
    if (_apiKey.isEmpty) return;
    setState(() {
      _isGenerating = true;
      _errorMessage = null;
    });

    try {
      final savedModel = await widget.settingsStore.readGeminiModel();
      final companyDesc = await widget.settingsStore.readCompanyDescription();
      final result = await _geminiService.generateFollowUp(
        apiKey: _apiKey,
        student: widget.student,
        model: savedModel,
        language: _selectedLanguage,
        customInstructions: _instructionController.text.trim(),
        companyDescription: companyDesc,
      );
      if (!mounted) return;
      setState(() {
        _messageController.text = result;
        _isGenerating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isGenerating = false;
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    final clean = GeminiService.sanitizeApiKey(text);
    if (clean.isNotEmpty) {
      _apiKeyController.text = clean;
    }
  }

  Future<void> _openGoogleAiStudio() async {
    final uri = Uri.parse('https://aistudio.google.com/app/apikey');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _copyMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message copied to clipboard!'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _saveAsTemplate() async {
    final currentText = _messageController.text.trim();
    if (currentText.isEmpty) return;

    var templateMsg = currentText;
    final sName = widget.student.name.trim();
    if (sName.isNotEmpty && templateMsg.contains(sName)) {
      templateMsg = templateMsg.replaceFirst(sName, '{name}');
    } else if (sName.isNotEmpty) {
      final firstName = sName.split(RegExp(r'\s+')).first;
      if (firstName.length >= 3 && templateMsg.contains(firstName)) {
        templateMsg = templateMsg.replaceFirst(firstName, '{name}');
      }
    }

    final promptText = _instructionController.text.trim();
    final defaultTitle = promptText.isNotEmpty
        ? 'AI: ${promptText.length > 20 ? "${promptText.substring(0, 20)}..." : promptText}'
        : 'AI Follow-up';

    final newTemplate = await showDialog<WhatsAppTemplate>(
      context: context,
      builder: (_) => _TemplateEditorDialog(
        initialName: defaultTitle,
        initialMessage: templateMsg,
      ),
    );

    if (newTemplate != null && mounted) {
      final list = await widget.settingsStore.readWhatsAppTemplates();
      final updated = List<WhatsAppTemplate>.from(list)..add(newTemplate);
      await widget.settingsStore.saveWhatsAppTemplates(updated);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved "${newTemplate.name}" to WhatsApp Templates!'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
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
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      color: Color(0xFF8B5CF6),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.isSms
                              ? 'Generate SMS with AI'
                              : 'Generate AI Message',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Personalized for ${widget.student.name}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // If API Key is missing, show Setup Card
              if (_apiKey.isEmpty) ...[
                Card(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.key_rounded,
                              color: Color(0xFF8B5CF6),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Gemini API Key Required',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'To generate personalized messages, paste your free Google Gemini API key below. You can get one in seconds from Google AI Studio without a credit card.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _openGoogleAiStudio,
                          icon: const Icon(Icons.open_in_new_rounded, size: 16),
                          label: const Text('Get Free Key (Google AI Studio)'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF8B5CF6),
                            side: const BorderSide(color: Color(0xFF8B5CF6)),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _apiKeyController,
                          obscureText: _obscureApiKey,
                          decoration: InputDecoration(
                            labelText: 'Paste Gemini API Key',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureApiKey
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () => setState(
                                () => _obscureApiKey = !_obscureApiKey,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            TextButton.icon(
                              onPressed: _pasteFromClipboard,
                              icon: const Icon(Icons.paste_rounded, size: 16),
                              label: const Text('Paste'),
                            ),
                            const Spacer(),
                            FilledButton(
                              onPressed: _saveApiKey,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF8B5CF6),
                              ),
                              child: const Text('Save & Generate'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                // Student Context Pill Card
                Card(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${widget.student.name} • ${widget.student.examType} ${widget.student.examYear}'.trim(),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                widget.student.callStatus,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (buildStudentHistoryEntries(widget.student).isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(
                                Icons.history_rounded,
                                size: 14,
                                color: Color(0xFF8B5CF6),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '${buildStudentHistoryEntries(widget.student).length} past interaction(s) analyzed by AI',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: const Color(0xFF8B5CF6),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Latest: "${buildStudentHistoryEntries(widget.student).last.text.isNotEmpty ? buildStudentHistoryEntries(widget.student).last.text : (widget.student.comment.isNotEmpty ? widget.student.comment : "No remark")}"',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ] else if (widget.student.comment.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            '💬 "${widget.student.comment.trim()}"',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(
                              Icons.business_rounded,
                              size: 13,
                              color: Color(0xFF8B5CF6),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                'On behalf of: ${_companySummary.isNotEmpty ? _companySummary : "LNBTI"}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Language selector
                Text(
                  'Language:',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: _languages.map((lang) {
                    final selected = _selectedLanguage == lang;
                    final displayLabel = lang == 'Sinhala' ? 'සිංහල' : lang;
                    return ChoiceChip(
                      label: Text(displayLabel),
                      selected: selected,
                      selectedColor: const Color(0xFF8B5CF6).withValues(alpha: 0.2),
                      labelStyle: TextStyle(
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected
                            ? const Color(0xFF8B5CF6)
                            : theme.colorScheme.onSurface,
                      ),
                      onSelected: (val) {
                        if (val) {
                          setState(() => _selectedLanguage = lang);
                          _generateMessage();
                        }
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),

                // What to generate input area
                Text(
                  'What should this message be about?',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _instructionController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: 'e.g. Follow up on missed call, give fees for A/L 2026 batch...',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Padding(
                      padding: EdgeInsets.only(bottom: 24),
                      child: Icon(Icons.edit_note_rounded),
                    ),
                    suffixIcon: _instructionController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () {
                              _instructionController.clear();
                              setState(() {});
                            },
                          )
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _generateMessage(),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _isGenerating ? null : _generateMessage,
                  icon: _isGenerating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: Text(_isGenerating ? 'Generating...' : 'Generate Message'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8B5CF6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),

                // Error Message if any
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],

                // Loading State or Editable Message
                if (_isGenerating) ...[
                  const SizedBox(height: 20),
                  const Center(
                    child: Column(
                      children: [
                        CircularProgressIndicator(
                          color: Color(0xFF8B5CF6),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Gemini is crafting a personalized message...',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ] else if (_messageController.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Generated Message (Editable):',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _messageController,
                    maxLines: 8,
                    minLines: 4,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isGenerating ? null : _generateMessage,
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text('Regenerate'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _saveAsTemplate,
                          icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                          label: const Text('Save Template'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        onPressed: _copyMessage,
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        tooltip: 'Copy text',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    onPressed: () =>
                        Navigator.pop(context, _messageController.text),
                    icon: widget.isSms
                        ? const Icon(Icons.sms_rounded, size: 18)
                        : const FaIcon(FontAwesomeIcons.whatsapp, size: 18),
                    label: Text(widget.isSms ? 'Send via SMS' : 'Send on WhatsApp'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.isSms
                          ? const Color(0xFF2E6FA3)
                          : const Color(0xFF25D366),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 2,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
