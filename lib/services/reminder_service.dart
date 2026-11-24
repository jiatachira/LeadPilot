part of '../main.dart';

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

