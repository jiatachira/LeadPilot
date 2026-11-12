import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;
import 'package:url_launcher/url_launcher.dart';

const _navy = Color(0xFF142B4A);
const _green = Color(0xFF159A76);
const _canvas = Color(0xFFF4F7FA);
const _muted = Color(0xFF748194);
const _defaultWhatsAppCountryCode = '94';

String _defaultSheetName(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return 'Google Sheet';
  final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  final id = parts.length >= 3 ? parts[2] : uri.host;
  final shortId = id.length > 10 ? id.substring(0, 10) : id;
  return 'Google Sheet $shortId';
}

Uri whatsAppChatUri(String phoneNumber) {
  final trimmed = phoneNumber.trim();
  var digits = trimmed.replaceAll(RegExp(r'\D'), '');
  if (trimmed.startsWith('00')) {
    digits = digits.startsWith('00') ? digits.substring(2) : digits;
  } else if (trimmed.startsWith('+')) {
    // Keep the international country code without the leading plus.
  } else if (digits.startsWith('0')) {
    digits = '$_defaultWhatsAppCountryCode${digits.substring(1)}';
  }
  return Uri.https('wa.me', '/$digits');
}

String normalizeContactPhone(String phoneNumber) {
  var digits = phoneNumber.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (digits.startsWith('0') && digits.length == 10) {
    digits = '$_defaultWhatsAppCountryCode${digits.substring(1)}';
  }
  return digits;
}

enum StudentActivityLevel { active, cooling, inactive, unknown }

class StudentActivityStatus {
  const StudentActivityStatus({
    required this.level,
    required this.daysSinceConnection,
    required this.hasSuccessfulConnection,
  });

  final StudentActivityLevel level;
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
    StudentActivityLevel.cooling => '${daysSinceConnection}d',
    StudentActivityLevel.inactive => '${daysSinceConnection}d',
    StudentActivityLevel.unknown => 'No calls',
  };

  String get description => switch (level) {
    StudentActivityLevel.active =>
      hasSuccessfulConnection
          ? 'Connected within the last 2 days'
          : 'Call attempt within the last 2 days',
    StudentActivityLevel.cooling =>
      'No connection for $daysSinceConnection days',
    StudentActivityLevel.inactive =>
      'No connection for $daysSinceConnection days',
    StudentActivityLevel.unknown => 'No call history yet',
  };
}

StudentActivityStatus studentActivityStatus(Student student, {DateTime? now}) {
  final failedConnectionDates = <DateTime>[];
  final successfulConnectionDates = <DateTime>[];

  for (final attempt in student.attempts) {
    final date = DateTime.tryParse(attempt.dateTime);
    if (date == null) continue;
    if (_isUnansweredCall(attempt.status, attempt.comment)) {
      failedConnectionDates.add(date);
    } else if (_isConnectedCall(attempt.status)) {
      successfulConnectionDates.add(date);
    }
  }

  for (final entry in student.commentHistory) {
    final separator = entry.indexOf(' — ');
    if (separator < 0) {
      if (_isUnansweredCall('', entry)) {
        final date = DateTime.tryParse(student.addedDate);
        if (date != null) failedConnectionDates.add(date);
      }
      continue;
    }
    final comment = entry.substring(separator + 3).trim();
    if (!_isUnansweredCall('', comment)) continue;
    final date = _parseActivityDate(entry.substring(0, separator).trim());
    if (date != null) failedConnectionDates.add(date);
  }

  if (student.attempts.isEmpty && student.commentHistory.isEmpty) {
    final date = DateTime.tryParse(student.addedDate);
    if (_isUnansweredCall(student.callStatus, student.comment) &&
        date != null) {
      failedConnectionDates.add(date);
    } else if (_isConnectedCall(student.callStatus) && date != null) {
      successfulConnectionDates.add(date);
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

  if (lastConnection == null) {
    return const StudentActivityStatus(
      level: StudentActivityLevel.unknown,
      daysSinceConnection: null,
      hasSuccessfulConnection: false,
    );
  }

  final currentDate = _dateOnly(now ?? DateTime.now());
  final connectionDate = _dateOnly(lastConnection);
  final days = currentDate
      .difference(connectionDate)
      .inDays
      .clamp(0, 100000)
      .toInt();
  return StudentActivityStatus(
    level: days >= 5
        ? StudentActivityLevel.inactive
        : days >= 3
        ? StudentActivityLevel.cooling
        : StudentActivityLevel.active,
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
}

class SecureAppSettingsStore implements AppSettingsStore {
  SecureAppSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _pinKey = 'student_call_pin';
  static const _sheetConfigKey = 'student_call_sheet_config';
  static const _sheetNameKey = 'student_call_sheet_name';
  static const _linkedSheetsKey = 'student_call_linked_sheets';
  static const _themeModeKey = 'student_call_theme_mode';
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
}

ThemeMode _themeModeFromName(String? value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

abstract interface class ReminderScheduler {
  Future<bool> canScheduleExactAlarms();

  Future<bool> requestExactAlarmsPermission();

  Future<void> scheduleStudentReminder(Student student, DateTime dateTime);

  Future<void> cancelStudentReminder(Student student);
}

class LocalReminderService implements ReminderScheduler {
  LocalReminderService({
    FlutterLocalNotificationsPlugin? plugin,
    FlutterSecureStorage? storage,
  }) : _plugin = plugin ?? _defaultPlugin,
       _storage = storage ?? const FlutterSecureStorage();

  static const _channelId = 'student_call_reminders';
  static const _channelName = 'Student call reminders';
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
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('ic_notification'),
            iOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestBadgePermission: false,
              requestSoundPermission: false,
            ),
          ),
        )
        .then((initialized) {
          if (initialized == false) {
            throw StateError('Local notifications could not be initialized.');
          }
        });
  }

  @override
  Future<bool> canScheduleExactAlarms() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.canScheduleExactNotifications() ?? true;
  }

  @override
  Future<bool> requestExactAlarmsPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.requestExactAlarmsPermission() ?? true;
  }

  @override
  Future<void> scheduleStudentReminder(
    Student student,
    DateTime dateTime,
  ) async {
    await initialize(_plugin);
    if (!dateTime.isAfter(DateTime.now())) {
      throw StateError('Choose a future date and time for the reminder.');
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
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  timezone.setLocalLocation(timezone.UTC);
  runApp(const StudentCallApp());
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
  Object? _settingsLoadError;
  late final AppSettingsStore _settingsStore =
      widget.settingsStore ?? SecureAppSettingsStore();
  late final GoogleSheetService _sheetService = GoogleSheetService(
    client: widget.httpClient,
  );
  late final ReminderScheduler _reminderScheduler =
      widget.reminderScheduler ?? LocalReminderService();

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
            )
          : PinScreen(
              key: ValueKey(_isFirstTime),
              isFirstTime: _isFirstTime,
              storedPin: _pin,
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
      ]);
      if (!mounted) return;
      final savedPin = values[0] as String?;
      final savedSheetConfig = values[1] as String;
      final linkedSheets = values[3] as List<LinkedSheet>;
      final savedSheetName = values[2] as String;
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
    super.key,
  });

  final bool isFirstTime;
  final String? storedPin;
  final Future<void> Function(String) onPinCreated;
  final VoidCallback onAuthenticated;

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

  String get _heading {
    if (!widget.isFirstTime) return 'Welcome Back - Enter PIN';
    return _setupPin == null ? 'Create Your 4-Digit PIN' : 'Confirm Your PIN';
  }

  String get _subtitle {
    if (!widget.isFirstTime) return 'Enter your PIN to access your directory.';
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

enum _SettingsAction { sheetSync, filters, export, saveContacts }

enum _StudentCardAction { edit, saveContact, selectMultiple }

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
    final isAppsScriptContentRedirect =
        (response.statusCode == 302 || response.statusCode == 303) &&
        redirectLocation?.host == 'script.googleusercontent.com';
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

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchController = TextEditingController();
  final List<Student> _students = [];
  final Set<String> _selectedStudentKeys = {};

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
    if (widget.sheetConfig.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncWithGoogleSheet();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Student> get _filteredStudents {
    final query = _query.trim().toLowerCase();
    final filtered = _students
        .where(
          (student) =>
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
      .where((student) => _selectedStudentKeys.contains(_selectionKey(student)))
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
      } on http.ClientException catch (error) {
        failures.add('${student.name}: network error (${error.message})');
      } on TimeoutException {
        failures.add('${student.name}: request timed out');
      } on FormatException catch (error) {
        failures.add('${student.name}: ${error.message}');
      } on Exception catch (error) {
        failures.add('${student.name}: $error');
      }
    }

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
      setState(() {
        _isSyncing = false;
        _hasSynced = true;
        _lastSyncTime = _formattedSyncTime();
        _syncStatus = 'Synced · $_lastSyncTime';
      });
      _showMessage('Student details updated and synced to Google Sheets.');
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _isSyncing = false;
        _hasSynced = false;
        _syncStatus = 'Sync failed';
      });
      _showMessage('Details updated locally, but could not be synced. $error');
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
      case _SettingsAction.saveContacts:
        await _saveVisibleContacts();
        break;
    }
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
      final sheetStudents = await widget.sheetService.fetchStudentsFromSheet(
        endpoint,
      );
      if (!mounted || syncGeneration != _syncGeneration) return;
      final merged = <String, Student>{};
      for (final student in sheetStudents) {
        merged[_studentKey(student)] = student;
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
        _syncStatus = 'Synced · $_lastSyncTime';
      });
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
      _syncStatus = 'Sync failed';
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

  Future<void> _exportStudentsToCsv(List<Student> students) async {
    if (students.isEmpty) {
      _showMessage('No students match the current filters to export.');
      return;
    }

    final csv = studentsToCsv(students);
    final bytes = Uint8List.fromList(utf8.encode('\uFEFF$csv'));
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes,
              mimeType: 'text/csv',
              name: 'student_leads.csv',
            ),
          ],
          fileNameOverrides: const ['student_leads.csv'],
          title: 'Export student leads',
          subject: 'Student leads CSV',
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
                                onNote: () => _showStudentNote(students[index]),
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

    try {
      final launched = await launchUrl(
        whatsAppChatUri(number),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        _showMessage('Could not open a WhatsApp chat for ${student.name}.');
      }
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not open WhatsApp: $error');
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
                leading: const Icon(Icons.person_add_alt_1_rounded),
                title: const Text('Save contact'),
                onTap: () =>
                    Navigator.pop(sheetContext, _StudentCardAction.saveContact),
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
      case _StudentCardAction.saveContact:
        await _saveStudentContact(student);
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
    final comments =
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
      if (attempt.comment.trim().isEmpty) continue;
      final date = DateTime.tryParse(attempt.dateTime);
      final text = attempt.comment.trim();
      attemptCommentCounts.update(
        text,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      comments.add((
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
      comments.add((
        date: date,
        dateLabel: dateLabel,
        order: order++,
        status: '',
        text: text,
      ));
    }
    if (student.comment.trim().isNotEmpty &&
        !comments.any((comment) => comment.text == student.comment.trim())) {
      comments.add((
        date: null,
        dateLabel: '',
        order: order++,
        status: student.callStatus,
        text: student.comment.trim(),
      ));
    }
    comments.sort((left, right) {
      if (left.date == null && right.date != null) return 1;
      if (right.date == null && left.date != null) return -1;
      final dateComparison = left.date?.compareTo(right.date!) ?? 0;
      return dateComparison != 0
          ? dateComparison
          : left.order.compareTo(right.order);
    });

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Comments · ${student.name}'),
        content: SizedBox(
          width: 440,
          child: comments.isEmpty && student.note.isEmpty
              ? const Text('No comments have been saved for this student.')
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: comments.isEmpty ? 1 : comments.length,
                    separatorBuilder: (_, _) => const Divider(height: 22),
                    itemBuilder: (context, index) {
                      if (comments.isEmpty) return Text(student.note);
                      final comment = comments[index];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (comment.status.isNotEmpty)
                                Expanded(
                                  child: Text(
                                    comment.status,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              if (comment.dateLabel.isNotEmpty)
                                Text(
                                  comment.dateLabel,
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(comment.text),
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
    'Not Interested',
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
    required this.onNote,
    this.isSelectionMode = false,
    this.isSelected = false,
    super.key,
  });

  final Student student;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onCall;
  final VoidCallback onWhatsApp;
  final VoidCallback onNote;
  final bool isSelectionMode;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activity = studentActivityStatus(student);
    final hasActivityStatus = activity.level != StudentActivityLevel.unknown;
    final statusColor = switch (student.callStatus) {
      'Very Interested' || 'Interested' || 'Answered' => _green,
      'Minimal Interested' ||
      'No Answer' ||
      'Not Responding' ||
      'Line Busy' ||
      'Call Back' ||
      'Future' => const Color(0xFFB36B16),
      'Not Interested' ||
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
          color: hasActivityStatus
              ? activity.color
              : isDark
              ? const Color(0xFF344453)
              : const Color(0xFFF0F2F5),
          width: hasActivityStatus ? 1.5 : 1,
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
              CircleAvatar(
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
                              icon: Icons.chat_bubble_outline_rounded,
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
                              icon: Icons.chat_rounded,
                              tooltip: 'Open WhatsApp chat',
                              onPressed: onWhatsApp,
                              backgroundColor: isDark
                                  ? const Color(0xFF17382F)
                                  : const Color(0xFFE9F6F1),
                              foregroundColor: _green,
                            ),
                            const SizedBox(width: 6),
                            _QuickActionButton(
                              icon: Icons.call_rounded,
                              tooltip: 'Call student',
                              onPressed: onCall,
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
  });

  final String status;
  final bool isSyncing;
  final bool isConnected;
  final String? lastSyncTime;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final color = isSyncing
        ? theme.colorScheme.primary
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
                  ? isConnected
                        ? const Color(0xFF17382F)
                        : const Color(0xFF263440)
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
                    isConnected
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
                if (lastSyncTime != null && isConnected) ...[
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

  final IconData icon;
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
      icon: Icon(icon, size: 19),
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
      nextCallDateTime: _nextCallDateTime?.toIso8601String() ?? '',
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
    final preferredDate = _nextCallDateTime ?? now;
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
        initialTime: _nextCallDateTime == null
            ? TimeOfDay.fromDateTime(now)
            : TimeOfDay.fromDateTime(_nextCallDateTime!),
        helpText: 'Select next call time',
      );
      if (!mounted || selectedTime == null) return;

      setState(() {
        _nextCallDateTime = DateTime(
          selectedDate.year,
          selectedDate.month,
          selectedDate.day,
          selectedTime.hour,
          selectedTime.minute,
        );
      });
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

  Future<void> _showCommentHistory() async {
    final attempts = List<CallAttempt>.of(widget.student.attempts)
      ..sort((left, right) {
        final leftDate = DateTime.tryParse(left.dateTime);
        final rightDate = DateTime.tryParse(right.dateTime);
        if (leftDate == null || rightDate == null) {
          return left.dateTime.compareTo(right.dateTime);
        }
        return leftDate.compareTo(rightDate);
      });
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Call attempt history'),
        content: SizedBox(
          width: 420,
          child: attempts.isEmpty && widget.student.commentHistory.isEmpty
              ? const Text('No call attempts have been saved.')
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: attempts.isEmpty
                      ? ListView.separated(
                          shrinkWrap: true,
                          itemCount: widget.student.commentHistory.length,
                          separatorBuilder: (_, _) => const Divider(height: 20),
                          itemBuilder: (context, index) =>
                              Text(widget.student.commentHistory[index]),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: attempts.length,
                          separatorBuilder: (_, _) => const Divider(height: 20),
                          itemBuilder: (context, index) {
                            final attempt = attempts[index];
                            final dateTime = DateTime.tryParse(
                              attempt.dateTime,
                            );
                            final timestamp = dateTime == null
                                ? attempt.dateTime
                                : _formatReminder(dateTime);
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        attempt.status,
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      timestamp,
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                                if (attempt.comment.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(attempt.comment),
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
                    if (value != null) setState(() => _callStatus = value);
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
                    onPressed: () {
                      if (!_formKey.currentState!.validate()) return;
                      Navigator.of(context).pop(_updatedStudent());
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

class _SettingsHubSheet extends StatelessWidget {
  const _SettingsHubSheet({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.isSheetConnected,
    required this.hasActiveFilters,
  });

  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeModeChanged;
  final bool isSheetConnected;
  final bool hasActiveFilters;

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
                key: ValueKey(themeMode),
                initialValue: themeMode,
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
                  if (mode != null) unawaited(onThemeModeChanged(mode));
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
                        isLabelVisible: hasActiveFilters,
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
                    isSheetConnected
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
