import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:lead_pilot/main.dart';

class FakeReminderScheduler implements ReminderScheduler {
  final scheduled = <({Student student, DateTime dateTime})>[];
  final cancelled = <Student>[];
  bool exactAlarmAllowed = true;
  bool exactAlarmPermissionResult = true;
  int exactAlarmPermissionRequests = 0;

  @override
  Future<bool> canScheduleExactAlarms() async => exactAlarmAllowed;

  @override
  Future<bool> requestExactAlarmsPermission() async {
    exactAlarmPermissionRequests++;
    exactAlarmAllowed = exactAlarmPermissionResult;
    return exactAlarmPermissionResult;
  }

  @override
  Future<void> scheduleStudentReminder(
    Student student,
    DateTime dateTime,
  ) async {
    scheduled.add((student: student, dateTime: dateTime));
  }

  @override
  Future<void> cancelStudentReminder(Student student) async {
    cancelled.add(student);
  }

  @override
  Future<bool> isStudentReminderScheduled(
    Student student, [
    DateTime? dateTime,
  ]) async {
    final phone = normalizeContactPhone(student.phone);
    return scheduled.any((item) {
      final itemPhone = normalizeContactPhone(item.student.phone);
      if (itemPhone != phone) return false;
      if (dateTime != null) {
        return item.dateTime.isAtSameMomentAs(dateTime);
      }
      return true;
    });
  }
}

class FakeDeviceContactsService implements DeviceContactsService {
  SaveContactsResult result = const SaveContactsResult();
  List<Student> receivedStudents = const [];

  @override
  Future<SaveContactsResult> saveMissingStudents(List<Student> students) async {
    receivedStudents = List.of(students);
    return result;
  }
}

Widget testApp({
  http.Client? httpClient,
  ReminderScheduler? reminderScheduler,
  MemoryAppSettingsStore? settingsStore,
  DeviceContactsService? deviceContactsService,
  bool showSplash = false,
}) {
  return StudentCallApp(
    httpClient: httpClient,
    reminderScheduler: reminderScheduler ?? FakeReminderScheduler(),
    settingsStore: settingsStore ?? MemoryAppSettingsStore(),
    deviceContactsService: deviceContactsService,
    showSplash: showSplash,
  );
}

String _dateStamp(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

Future<void> enterPin(WidgetTester tester, String pin) async {
  for (final digit in pin.split('')) {
    final key = find.text(digit).last;
    await tester.ensureVisible(key);
    await tester.tap(key);
    await tester.pump();
  }
}

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More options'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
}

Future<void> openSheetSettings(WidgetTester tester) async {
  await openSettings(tester);
  await tester.ensureVisible(find.text('Google Sheets Sync'));
  await tester.tap(find.text('Google Sheets Sync'));
  await tester.pumpAndSettle();
}

class MockVoiceToTextService implements VoiceToTextService {
  MockVoiceToTextService({
    this.initialAvailable = true,
    this.mockWords = 'student ekka katha kala degree fees ahuwa',
  });

  bool initialAvailable;
  String mockWords;
  bool _listening = false;
  int listenCallCount = 0;
  int stopCallCount = 0;

  @override
  bool get isAvailable => initialAvailable;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize() async => initialAvailable;

  @override
  Future<void> listen({
    required void Function(String recognizedWords) onResult,
    void Function(String status)? onStatus,
    void Function(String error)? onError,
    String? localeId,
  }) async {
    listenCallCount++;
    if (!initialAvailable) {
      onError?.call('Microphone permission denied');
      return;
    }
    _listening = true;
    onStatus?.call('listening');
    onResult(mockWords);
  }

  @override
  Future<void> stop() async {
    stopCallCount++;
    _listening = false;
  }

  @override
  Future<void> cancel() async {
    _listening = false;
  }
}

void main() {
  test('builds a WhatsApp chat link for an unsaved Sri Lankan number', () {
    expect(
      whatsAppChatUri('070 106 1244').toString(),
      'https://wa.me/94701061244',
    );
    expect(
      whatsAppChatUri('070 106 1244', text: 'Hello Kasun!').toString(),
      'https://wa.me/94701061244?text=Hello+Kasun%21',
    );
    expect(
      whatsAppChatUri('+1 (555) 010-1234').toString(),
      'https://wa.me/15550101234',
    );
    expect(
      normalizeContactPhone('+94 70 106 1244'),
      normalizeContactPhone('0701061244'),
    );
  });

  test(
    'builds SMS composer links with normalized phone numbers and optional body',
    () {
      expect(smsComposerUri('070 106 1244').toString(), 'sms:+94701061244');
      expect(
        smsComposerUri('+1 (555) 010-1234').toString(),
        'sms:+15550101234',
      );
      expect(
        smsComposerUri('070 106 1244', body: 'Hello student').toString(),
        'sms:+94701061244?body=Hello+student',
      );
    },
  );

  test('allocates stable, distinct reminder notification IDs per phone', () {
    final firstId = allocateReminderNotificationId('0701061244', const {});
    final secondId = allocateReminderNotificationId('+94 70 106 1245', {
      firstId,
    });

    expect(firstId, greaterThan(0));
    expect(secondId, greaterThan(0));
    expect(secondId, isNot(firstId));
    expect(allocateReminderNotificationId('94701061244', const {}), firstId);
    expect(
      allocateReminderNotificationId('0701061244', {firstId}),
      isNot(firstId),
    );
  });

  test('reminder actions offer calling and a five-minute snooze', () {
    expect(studentReminderActions.map((action) => (action.id, action.title)), [
      ('call_student', 'Call'),
      ('snooze_reminder', 'Snooze 5 min'),
    ]);
    expect(
      snoozedReminderDateTime(DateTime(2026, 11, 13, 9, 0)),
      DateTime(2026, 11, 13, 9, 5),
    );
  });

  test('rejects reminder times on today that are not in the future', () {
    final now = DateTime(2026, 11, 13, 8);
    final today = DateTime(2026, 11, 13);
    final pastTime = combineReminderDateAndTime(
      today,
      const TimeOfDay(hour: 7, minute: 59),
    );
    expect(isReminderDateTimeInFuture(pastTime, now: now), isFalse);
    expect(
      isReminderDateTimeInFuture(
        combineReminderDateAndTime(today, const TimeOfDay(hour: 8, minute: 1)),
        now: now,
      ),
      isTrue,
    );
    expect(
      isReminderDateTimeInFuture(
        combineReminderDateAndTime(
          DateTime(2026, 11, 14),
          const TimeOfDay(hour: 7, minute: 59),
        ),
        now: now,
      ),
      isTrue,
    );
  });

  test('recognizes closed lead statuses and legacy spellings', () {
    expect(isFinalLeadStatus(' Not Interested '), isTrue);
    expect(isFinalLeadStatus('Not Potential'), isTrue);
    expect(isFinalLeadStatus('Not Protencial'), isTrue);
    expect(isFinalLeadStatus('Not Pretencial'), isTrue);
    expect(isInactiveStatus('Inactive'), isTrue);
    expect(isFinalLeadStatus('Inactive'), isTrue);
    expect(isFinalLeadStatus('Interested'), isFalse);
  });

  test('marks connection activity green, orange, and red by elapsed days', () {
    final today = DateTime(2026, 11, 12, 12);
    Student withAttempt(String status, int daysAgo) => Student(
      name: 'Lead',
      phone: '0700000000',
      attempts: [
        CallAttempt(
          dateTime: today.subtract(Duration(days: daysAgo)).toIso8601String(),
          status: status,
          comment: '',
        ),
      ],
    );

    expect(
      studentActivityStatus(withAttempt('Interested', 2), now: today).level,
      StudentActivityLevel.active,
    );
    expect(
      studentActivityStatus(withAttempt('No Answer', 3), now: today).level,
      StudentActivityLevel.cooling,
    );
    expect(
      studentActivityStatus(withAttempt('Not Responding', 5), now: today).level,
      StudentActivityLevel.inactive,
    );
    expect(
      studentActivityStatus(withAttempt('Call Cut', 3), now: today).level,
      StudentActivityLevel.cooling,
    );
    expect(
      studentActivityStatus(withAttempt('Line Busy', 5), now: today).level,
      StudentActivityLevel.inactive,
    );
    expect(
      studentActivityStatus(
        const Student(name: 'New lead', phone: '0700000001'),
        now: today,
      ).level,
      StudentActivityLevel.unknown,
    );
  });

  test('a successful connection resets the not-connected streak', () {
    final today = DateTime(2026, 11, 12, 12);
    final student = Student(
      name: 'Lead',
      phone: '0700000000',
      attempts: [
        for (final (status, daysAgo) in [
          ('No Answer', 8),
          ('Not Responding', 7),
          ('Interested', 1),
          ('Call Cut', 0),
        ])
          CallAttempt(
            dateTime: today.subtract(Duration(days: daysAgo)).toIso8601String(),
            status: status,
            comment: '',
          ),
      ],
    );

    expect(
      studentActivityStatus(student, now: today).level,
      StudentActivityLevel.active,
    );
    expect(studentActivityStatus(student, now: today).daysSinceConnection, 1);
  });

  test('uses the last successful connection for the activity age', () {
    final today = DateTime(2026, 11, 12, 12);
    final student = Student(
      name: 'Lead',
      phone: '0700000000',
      attempts: [
        CallAttempt(
          dateTime: today.subtract(const Duration(days: 8)).toIso8601String(),
          status: 'Answered',
          comment: '',
        ),
        CallAttempt(
          dateTime: today.subtract(const Duration(days: 1)).toIso8601String(),
          status: 'No Answer',
          comment: '',
        ),
      ],
    );

    expect(
      studentActivityStatus(student, now: today).level,
      StudentActivityLevel.inactive,
    );
  });

  test('detects an unanswered call written only in comment history', () {
    final today = DateTime(2026, 11, 12, 12);
    final threeDaysAgo = today.subtract(const Duration(days: 3));
    final student = Student(
      name: 'Lead',
      phone: '0700000000',
      commentHistory: [
        '${threeDaysAgo.year}-${threeDaysAgo.month.toString().padLeft(2, '0')}-'
            '${threeDaysAgo.day.toString().padLeft(2, '0')} 12:00 PM — No answer',
      ],
    );

    expect(
      studentActivityStatus(student, now: today).level,
      StudentActivityLevel.cooling,
    );
  });

  test('detects an unanswered call in the current comment text', () {
    final today = DateTime(2026, 11, 12, 12);
    final student = Student(
      name: 'Lead',
      phone: '0700000000',
      addedDate: today.subtract(const Duration(days: 5)).toIso8601String(),
      callStatus: 'Pending',
      comment: 'No answer, will try again',
    );

    expect(
      studentActivityStatus(student, now: today).level,
      StudentActivityLevel.inactive,
    );
  });

  testWidgets('uses the activity color for the student card border', (
    tester,
  ) async {
    final threeDaysAgo = DateTime.now().subtract(const Duration(days: 3));
    const fullName = 'Alexandria Perera Wijesinghe';
    final student = Student(
      name: fullName,
      phone: '0700000000',
      attempts: [
        CallAttempt(
          dateTime: threeDaysAgo.toIso8601String(),
          status: 'No Answer',
          comment: '',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentCard(
            student: student,
            onTap: () {},
            onLongPress: () {},
            onCall: () {},
            onWhatsApp: () {},
            onSms: () {},
            onNote: () {},
            onSaveContact: () {},
          ),
        ),
      ),
    );

    final card = tester.widget<Card>(find.byType(Card).first);
    final shape = card.shape! as RoundedRectangleBorder;
    expect(shape.side.width, 1.0);
    expect(find.text('0700000000'), findsOneWidget);
    final name = tester.widget<Text>(find.text(fullName));
    expect(name.maxLines, 2);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(find.text('3d'), findsNothing);
  });

  testWidgets('displays avatar corner badge for 3x and 5x unanswered streaks', (
    tester,
  ) async {
    final now = DateTime.now();
    final student = Student(
      name: 'Badge Student',
      phone: '0700000000',
      attempts: [
        for (int i = 3; i >= 1; i--)
          CallAttempt(
            dateTime: now.subtract(Duration(hours: i)).toIso8601String(),
            status: 'No Answer',
            comment: '',
          ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentCard(
            student: student,
            onTap: () {},
            onLongPress: () {},
            onCall: () {},
            onWhatsApp: () {},
            onSms: () {},
            onNote: () {},
            onSaveContact: () {},
          ),
        ),
      ),
    );

    final badge = tester.widget<Badge>(find.byType(Badge).first);
    expect(badge.isLabelVisible, isTrue);
    expect(badge.backgroundColor, const Color(0xFFE58A18));
    expect(find.text('3'), findsOneWidget);
  });

  test('includes every same-time reminder in the grouped notification', () {
    final body = buildReminderGroupBody([
      (name: 'Mia Patel', phone: '070 111 2222'),
      (name: 'Noah Lee', phone: '071 333 4444'),
      (name: 'Ava Kim', phone: '072 555 6666'),
    ]);

    expect(
      body,
      'Mia Patel (070 111 2222)\nNoah Lee (071 333 4444)\n'
      'Ava Kim (072 555 6666)',
    );
  });

  test('exports student rows as properly escaped CSV', () {
    final csv = studentsToCsv([
      const Student(
        name: 'Mia Patel, Jr.',
        phone: '555-0104',
        source: 'WhatsApp',
        location: 'Colombo',
        comment: 'Interested in "A/L"',
        commentHistory: ['First note', 'Second note'],
      ),
    ]);

    expect(csv, contains('"Mia Patel, Jr."'));
    expect(csv, contains('"Interested in ""A/L"""'));
    expect(csv, contains('"First note\nSecond note"'));
    expect(csv.split('\r\n'), hasLength(3));
  });

  test('accepts the Google Apps Script ContentService POST redirect', () async {
    http.Request? sentRequest;
    final service = GoogleSheetService(
      client: MockClient((request) async {
        sentRequest = request;
        return http.Response(
          '',
          302,
          headers: {
            'location':
                'https://script.googleusercontent.com/macros/echo?key=test',
          },
        );
      }),
    );

    await service.updateStudentInSheet(
      'https://script.google.com/macros/s/test/exec',
      const Student(
        name: 'Mia Patel',
        phone: '555-0199',
        location: 'Colombo',
        examType: 'A/L',
      ),
      previousPhone: '555-0104',
    );

    expect(sentRequest, isNotNull);
    final payload = jsonDecode(sentRequest!.body) as Map<String, dynamic>;
    expect(payload['action'], 'update');
    expect(payload['name'], 'Mia Patel');
    expect(payload['contact'], '555-0199');
    expect(payload['previousContact'], '555-0104');
    expect(payload['location'], 'Colombo');
    service.close();
  });

  test('does not treat unrelated POST redirects as successful sync', () async {
    final service = GoogleSheetService(
      client: MockClient(
        (_) async => http.Response(
          '',
          302,
          headers: {'location': 'https://example.com/result'},
        ),
      ),
    );

    await expectLater(
      service.updateStudentInSheet(
        'https://script.google.com/macros/s/test/exec',
        const Student(name: 'Mia Patel', phone: '555-0104'),
      ),
      throwsA(isA<SheetApiException>()),
    );
    service.close();
  });

  testWidgets('sets up a PIN and opens the student directory', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    expect(find.text('Create Your 4-Digit PIN'), findsOneWidget);
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    expect(find.text('Confirm Your PIN'), findsOneWidget);

    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    expect(find.text('LeadPilot'), findsOneWidget);
    expect(find.text('No students yet'), findsOneWidget);
  });

  testWidgets('keeps the created PIN after restarting the app', (tester) async {
    final settingsStore = MemoryAppSettingsStore();
    await tester.pumpWidget(testApp(settingsStore: settingsStore));
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    expect(settingsStore.pin, '2580');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(testApp(settingsStore: settingsStore));
    await tester.pumpAndSettle();
    expect(find.text('Welcome Back - Enter PIN'), findsOneWidget);
    expect(find.text('Create Your 4-Digit PIN'), findsNothing);

    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    expect(find.text('LeadPilot'), findsOneWidget);
  });

  testWidgets('locks and validates the saved PIN before reopening', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    await enterPin(tester, '1234');
    await tester.pumpAndSettle();
    await enterPin(tester, '1234');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lock app'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome Back - Enter PIN'), findsOneWidget);

    await enterPin(tester, '9999');
    await tester.pumpAndSettle();
    expect(
      find.text('That PIN isn’t correct. Please try again.'),
      findsOneWidget,
    );

    await enterPin(tester, '1234');
    await tester.pumpAndSettle();
    expect(find.text('LeadPilot'), findsOneWidget);
  });

  testWidgets('parses multiple lines and adds them locally', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add student'));
    await tester.pumpAndSettle();
    expect(find.text('Add New Student'), findsOneWidget);

    await tester.enterText(
      find.byType(TextFormField).first,
      'Mia Patel - 555-0104\nNoah Lee - 070-111-2222',
    );
    await tester.ensureVisible(find.text('Save Student(s)'));
    await tester.tap(find.text('Save Student(s)'));
    await tester.pumpAndSettle();

    expect(find.text('Mia Patel'), findsOneWidget);
    expect(find.text('Noah Lee'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Mia Patel')).dy,
      lessThan(tester.getTopLeft(find.text('Noah Lee')).dy),
    );
  });

  testWidgets('fetches sheet contacts and posts newly added students', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode([]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"success":true}', 200);
    });

    await tester.pumpWidget(testApp(httpClient: client));
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await openSheetSettings(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('sheet-name-input')),
      'Test Leads',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sheet-url-input')),
      'https://script.google.com/macros/s/test/exec',
    );
    await tester.ensureVisible(find.text('Save & Sync'));
    await tester.tap(find.text('Save & Sync'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.cloud_done_rounded), findsOneWidget);
    expect(requests.single.method, 'GET');

    await tester.tap(find.text('Add student'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'Mia Patel - 555-0104\nNoah Lee - 070-111-2222',
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WhatsApp').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save Student(s)'));
    await tester.tap(find.text('Save Student(s)'));
    await tester.pumpAndSettle();

    final posts = requests
        .where((request) => request.method == 'POST')
        .toList();
    expect(posts, hasLength(2));
    final firstPayload = jsonDecode(posts.first.body) as Map<String, dynamic>;
    expect(firstPayload['name'], 'Mia Patel');
    expect(firstPayload['contact'], '555-0104');
    expect(firstPayload['source'], 'WhatsApp');
    expect(
      firstPayload['addedDate'],
      matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')),
    );
    expect(jsonDecode(posts.last.body)['name'], 'Noah Lee');
    expect(find.text('Mia Patel'), findsOneWidget);
    expect(find.text('Noah Lee'), findsOneWidget);
    expect(
      find.text('Student(s) saved and synced to Google Sheet!'),
      findsOneWidget,
    );
  });

  testWidgets('keeps new contact locally when the sheet rejects a write', (
    tester,
  ) async {
    final client = MockClient((request) async {
      if (request.method == 'GET') return http.Response('[]', 200);
      return http.Response('write failed', 500);
    });

    await tester.pumpWidget(testApp(httpClient: client));
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    await openSheetSettings(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sheet-name-input')),
      'Test Leads',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sheet-url-input')),
      'https://script.google.com/macros/s/test/exec',
    );
    await tester.ensureVisible(find.text('Save & Sync'));
    await tester.tap(find.text('Save & Sync'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add student'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'Mia Patel - 555-0104',
    );
    await tester.ensureVisible(find.text('Save Student(s)'));
    await tester.tap(find.text('Save Student(s)'));
    await tester.pumpAndSettle();

    expect(find.text('Mia Patel'), findsOneWidget);
    expect(find.textContaining('could not be synced'), findsOneWidget);
  });

  testWidgets('edits student details and syncs the update action', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final reminderScheduler = FakeReminderScheduler()
      ..exactAlarmAllowed = false;
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') return http.Response('[]', 200);
      return http.Response('{"success":true}', 200);
    });

    await tester.pumpWidget(
      testApp(httpClient: client, reminderScheduler: reminderScheduler),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await openSheetSettings(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sheet-name-input')),
      'Test Leads',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sheet-url-input')),
      'https://script.google.com/macros/s/test/exec',
    );
    await tester.ensureVisible(find.text('Save & Sync'));
    await tester.tap(find.text('Save & Sync'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add student'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'Mia Patel - 555-0104',
    );
    await tester.ensureVisible(find.text('Save Student(s)'));
    await tester.tap(find.text('Save Student(s)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mia Patel'));
    await tester.pumpAndSettle();
    expect(find.text('Edit details'), findsOneWidget);

    await tester.tap(find.text('Edit details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Edit Details'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('edit-name-input')),
      'Mia Fernando',
    );
    await tester.enterText(
      find.byKey(const ValueKey('edit-phone-input')),
      '555-0199',
    );
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(2), '2025');
    await tester.enterText(fields.at(3), 'Colombo');
    await tester.enterText(fields.at(4), 'A');
    await tester.enterText(fields.at(5), 'B');
    await tester.ensureVisible(find.text('Same as contact number'));
    await tester.tap(find.text('Same as contact number'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byType(DropdownButtonFormField<String>).first,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('A/L').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Edit details saved directly and closed the sheet; reopen Mia Fernando to log a call
    await tester.tap(find.text('Mia Fernando'));
    await tester.pumpAndSettle();

    final remarkField = find.widgetWithText(
      TextFormField,
      'Call remark (optional)',
    );
    await tester.enterText(remarkField, 'Interested in A/L classes');

    final statusDropdown = find.byType(DropdownButtonFormField<String>).first;
    await tester.ensureVisible(statusDropdown);
    await tester.tap(statusDropdown);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Future'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Future'), findsOneWidget);
    await tester.tap(find.text('Future'));
    await tester.pumpAndSettle();

    final reminderButton = find.text('Pick date & time');
    await tester.ensureVisible(reminderButton);
    await tester.tap(reminderButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Allow exact call reminders'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(reminderScheduler.exactAlarmPermissionRequests, 1);
    expect(reminderScheduler.scheduled, hasLength(1));

    final updateRequests = requests
        .where(
          (request) =>
              request.method == 'POST' &&
              (jsonDecode(request.body) as Map<String, dynamic>)['action'] ==
                  'update',
        )
        .toList();
    expect(updateRequests.length, 2);
    final detailsPayload =
        jsonDecode(updateRequests.first.body) as Map<String, dynamic>;
    expect(detailsPayload['action'], 'update');
    expect(detailsPayload['name'], 'Mia Fernando');
    expect(detailsPayload['contact'], '555-0199');
    expect(detailsPayload['previousContact'], '555-0104');

    final payload =
        jsonDecode(updateRequests.last.body) as Map<String, dynamic>;
    expect(payload['action'], 'update');
    expect(payload['name'], 'Mia Fernando');
    expect(payload['contact'], '555-0199');
    expect(payload['previousContact'], '555-0199');
    expect(payload['examType'], 'A/L');
    expect(payload['examYear'], '2025');
    expect(payload['location'], 'Colombo');
    expect(payload['olEnglish'], 'A');
    expect(payload['olMaths'], 'B');
    expect(payload['whatsappNumber'], '555-0199');
    expect(payload['whatsappSameAsContact'], isTrue);
    expect(payload['callStatus'], 'Future');
    expect(payload['comment'], 'Interested in A/L classes');
    expect(payload['commentHistory'], hasLength(1));
    expect(payload['attempts'], hasLength(1));
    final attempt = payload['attempts'][0] as Map<String, dynamic>;
    expect(attempt['status'], 'Future');
    expect(attempt['comment'], 'Interested in A/L classes');
    expect(
      attempt['dateTime'],
      matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')),
    );
    expect(
      payload['commentHistory'][0],
      matches(
        RegExp(
          r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2} (AM|PM) — Interested in A/L classes$',
        ),
      ),
    );
    expect(
      payload['nextCallDateTime'],
      matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00')),
    );
    expect(reminderScheduler.scheduled, hasLength(1));
    expect(reminderScheduler.scheduled.single.student.name, 'Mia Fernando');
    expect(reminderScheduler.scheduled.single.student.phone, '555-0199');
    expect(
      reminderScheduler.scheduled.single.dateTime,
      DateTime.parse(payload['nextCallDateTime'] as String),
    );
    expect(find.text('Future'), findsWidgets);
    expect(find.textContaining('Call · '), findsOneWidget);

    await tester.tap(find.text('Mia Fernando'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('View history'));
    await tester.tap(find.text('View history'));
    await tester.pumpAndSettle();
    expect(find.text('Call attempt history'), findsOneWidget);
    expect(find.text('Future'), findsWidgets);
    expect(find.textContaining('Interested in A/L classes'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Clear'));
    await tester.tap(find.text('Clear'));
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(reminderScheduler.cancelled, hasLength(1));
    expect(reminderScheduler.cancelled.single.phone, '555-0199');
  });

  testWidgets('saves student details with no next-call date', (tester) async {
    final requests = <http.Request>[];
    final reminderScheduler = FakeReminderScheduler();
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') return http.Response('[]', 200);
      return http.Response('{"success":true}', 200);
    });

    await tester.pumpWidget(
      testApp(httpClient: client, reminderScheduler: reminderScheduler),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await openSheetSettings(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sheet-name-input')),
      'Test Leads',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sheet-url-input')),
      'https://script.google.com/macros/s/test/exec',
    );
    await tester.ensureVisible(find.text('Save & Sync'));
    await tester.tap(find.text('Save & Sync'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add student'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'Mia Patel - 555-0104',
    );
    await tester.ensureVisible(find.text('Save Student(s)'));
    await tester.tap(find.text('Save Student(s)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mia Patel'));
    await tester.pumpAndSettle();
    expect(find.text('Pick date & time'), findsOneWidget);

    await tester.ensureVisible(find.text('Pick date & time'));
    await tester.tap(find.text('Pick date & time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Pick date & time'), findsOneWidget);

    await tester.tap(find.text('Pick date & time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Pick date & time'), findsOneWidget);

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final update = requests.lastWhere((request) => request.method == 'POST');
    final payload = jsonDecode(update.body) as Map<String, dynamic>;
    expect(payload['action'], 'update');
    expect(payload['nextCallDateTime'], '');
    expect(reminderScheduler.scheduled, isEmpty);
    expect(reminderScheduler.cancelled, isEmpty);
  });

  testWidgets('filters leads by category, status, and call comments', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final today = DateTime.now();
    final students = [
      {
        'name': 'New Lead',
        'contact': '555-0101',
        'addedDate': today.toIso8601String(),
        'callStatus': 'Pending',
        'attempts': [],
      },
      {
        'name': 'Follow-up Lead',
        'contact': '555-0102',
        'addedDate': today.subtract(const Duration(days: 20)).toIso8601String(),
        'nextCallDateTime': DateTime(
          today.year,
          today.month,
          today.day,
          16,
        ).toIso8601String(),
        'callStatus': 'No Answer',
        'comment': 'Call after class',
        'commentHistory': ['Call after class'],
        'attempts': [],
      },
      {
        'name': 'Old Lead',
        'contact': '555-0103',
        'addedDate': today.subtract(const Duration(days: 30)).toIso8601String(),
        'callStatus': 'Very Interested',
        'comment': 'Interested in A/L',
        'attempts': [
          {
            'dateTime': today
                .subtract(const Duration(days: 2))
                .toIso8601String(),
            'status': 'Very Interested',
            'comment': 'Interested in A/L',
          },
        ],
      },
    ];
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'success': true, 'students': students}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(testApp(httpClient: client));
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await openSheetSettings(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sheet-name-input')),
      'Test Leads',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sheet-url-input')),
      'https://script.google.com/macros/s/test/exec',
    );
    await tester.ensureVisible(find.text('Save & Sync'));
    await tester.tap(find.text('Save & Sync'));
    await tester.pumpAndSettle();

    expect(find.text('New Lead'), findsOneWidget);
    expect(find.text('Follow-up Lead'), findsOneWidget);
    expect(find.text('Old Lead'), findsOneWidget);

    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();
    expect(find.text('New Lead'), findsOneWidget);
    expect(find.text('Follow-up Lead'), findsNothing);
    expect(find.text('Old Lead'), findsNothing);

    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(find.text('Follow-up Lead'), findsOneWidget);
    expect(find.text('New Lead'), findsNothing);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('New Lead')).dy,
      lessThan(tester.getTopLeft(find.text('Follow-up Lead')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Follow-up Lead')).dy,
      lessThan(tester.getTopLeft(find.text('Old Lead')).dy),
    );

    await tester.enterText(find.byType(TextField).first, 'Very Interested');
    await tester.pumpAndSettle();
    expect(find.text('Old Lead'), findsOneWidget);
    expect(find.text('Follow-up Lead'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'after class');
    await tester.pumpAndSettle();
    expect(find.text('Follow-up Lead'), findsOneWidget);
    expect(find.text('Old Lead'), findsNothing);
  });

  testWidgets('hides closed leads and shows separate report categories', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settingsStore = MemoryAppSettingsStore()
      ..pin = '2580'
      ..sheetConfig = 'https://script.google.com/macros/s/test/exec';
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'students': [
            {
              'name': 'Active Lead',
              'contact': '555-0611',
              'callStatus': 'Interested',
              'attempts': [],
            },
            {
              'name': 'Not Interested Lead',
              'contact': '555-0612',
              'callStatus': 'Not Interested',
              'attempts': [],
            },
            {
              'name': 'Not Potential Lead',
              'contact': '555-0613',
              'callStatus': 'Not Potential',
              'attempts': [],
            },
          ],
        }),
        200,
      ),
    );

    await tester.pumpWidget(
      testApp(httpClient: client, settingsStore: settingsStore),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    expect(find.text('Active Lead'), findsOneWidget);
    expect(find.text('Not Interested Lead'), findsNothing);
    expect(find.text('Not Potential Lead'), findsNothing);

    await openSettings(tester);
    await tester.tap(find.text('Data'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Lead reports'));
    await tester.tap(find.text('Lead reports'));
    await tester.pumpAndSettle();

    expect(find.text('Not Interested'), findsOneWidget);
    expect(find.text('Not Potential'), findsOneWidget);
    expect(find.text('1 student(s) · Export CSV'), findsNWidgets(2));
    expect(find.text('Not Interested Lead'), findsNothing);
    expect(find.text('Not Potential Lead'), findsNothing);
  });

  testWidgets('New Leads shows pending only, regardless of lead age', (
    tester,
  ) async {
    final oldDate = DateTime.now().subtract(const Duration(days: 40));
    final recentlyAdded = DateTime.now();
    final students = [
      {
        'name': 'Old Pending',
        'contact': '555-0201',
        'addedDate': oldDate.toIso8601String(),
        'callStatus': 'Pending',
        'attempts': [],
      },
      {
        'name': 'Recent Answered',
        'contact': '555-0202',
        'addedDate': recentlyAdded.toIso8601String(),
        'callStatus': 'Answered',
        'attempts': [
          {
            'dateTime': recentlyAdded.toIso8601String(),
            'status': 'Answered',
            'comment': '',
          },
        ],
      },
    ];
    final settingsStore = MemoryAppSettingsStore()
      ..pin = '2580'
      ..sheetConfig = 'https://script.google.com/macros/s/test/exec';
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'students': students}), 200),
    );

    await tester.pumpWidget(
      testApp(httpClient: client, settingsStore: settingsStore),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    expect(find.text('Old Pending'), findsOneWidget);
    expect(find.text('Recent Answered'), findsOneWidget);
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();
    expect(find.text('Old Pending'), findsOneWidget);
    expect(find.text('Recent Answered'), findsNothing);
  });

  testWidgets(
    'Today Follow-up shows missed calls first and ignores completed ones',
    (tester) async {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final tomorrow = now.add(const Duration(days: 1));
      final todayCallTime = DateTime(now.year, now.month, now.day, 12, 0);
      final students = [
        {
          'name': 'Today Call',
          'contact': '555-0401',
          'addedDate': now.toIso8601String(),
          'nextCallDateTime': todayCallTime.toIso8601String(),
          'callStatus': 'Interested',
          'attempts': [],
        },
        {
          'name': 'Missed Yesterday Call',
          'contact': '555-0402',
          'addedDate': now.toIso8601String(),
          'nextCallDateTime': yesterday.toIso8601String(),
          'callStatus': 'No Answer',
          'attempts': [],
        },
        {
          'name': 'Already Followed Up',
          'contact': '555-0403',
          'addedDate': now.toIso8601String(),
          'nextCallDateTime': yesterday.toIso8601String(),
          'callStatus': 'Answered',
          'attempts': [
            {
              'dateTime': now.toIso8601String(),
              'status': 'Answered',
              'comment': 'Spoke today',
            },
          ],
        },
        {
          'name': 'Future Call',
          'contact': '555-0404',
          'addedDate': now.toIso8601String(),
          'nextCallDateTime': tomorrow.toIso8601String(),
          'callStatus': 'Interested',
          'attempts': [],
        },
      ];
      final settingsStore = MemoryAppSettingsStore()
        ..pin = '2580'
        ..sheetConfig = 'https://script.google.com/macros/s/test/exec';
      final client = MockClient(
        (_) async => http.Response(jsonEncode({'students': students}), 200),
      );
      await tester.pumpWidget(
        testApp(httpClient: client, settingsStore: settingsStore),
      );
      await tester.pumpAndSettle();
      await enterPin(tester, '2580');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();

      expect(find.text('Missed Yesterday Call'), findsOneWidget);
      expect(find.text('Today Call'), findsOneWidget);
      expect(find.text('Already Followed Up'), findsNothing);
      expect(find.text('Future Call'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Missed Yesterday Call')).dy,
        lessThan(tester.getTopLeft(find.text('Today Call')).dy),
      );
    },
  );

  testWidgets('filters by chosen added-date range and call status', (
    tester,
  ) async {
    final today = DateTime.now();
    final monthStart = DateTime(today.year, today.month);
    final priorMonth = DateTime(today.year, today.month - 1, 15);
    final students = [
      {
        'name': 'Prior Month No Answer',
        'contact': '555-0301',
        'addedDate': '${_dateStamp(priorMonth)} 09:00',
        'callStatus': 'No Answer',
        'attempts': [],
      },
      {
        'name': 'Today No Answer',
        'contact': '555-0302',
        'addedDate': '${_dateStamp(today)} 09:00',
        'callStatus': 'No Answer',
        'attempts': [],
      },
      {
        'name': 'This Month No Answer',
        'contact': '555-0303',
        'addedDate': '${_dateStamp(monthStart)} 10:00',
        'callStatus': 'No Answer',
        'attempts': [],
      },
      {
        'name': 'Today Interested',
        'contact': '555-0304',
        'addedDate': '${_dateStamp(today)} 10:00',
        'callStatus': 'Interested',
        'attempts': [],
      },
    ];
    final settingsStore = MemoryAppSettingsStore()
      ..pin = '2580'
      ..sheetConfig = 'https://script.google.com/macros/s/test/exec';
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'students': students}), 200),
    );
    await tester.pumpWidget(
      testApp(httpClient: client, settingsStore: settingsStore),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await openSettings(tester);
    await tester.tap(find.text('Data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filter by date and call status'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('No Answer').last);
    await tester.pumpAndSettle();
    expect(find.text('Yesterday'), findsNothing);
    await tester.tap(find.text('This month'));
    await tester.tap(find.text('Apply filters'));
    await tester.pumpAndSettle();

    expect(find.text('Today No Answer'), findsOneWidget);
    expect(find.text('This Month No Answer'), findsOneWidget);
    expect(find.text('Prior Month No Answer'), findsNothing);
    expect(find.text('Today Interested'), findsNothing);
  });

  testWidgets('Save contacts acts only on currently displayed students', (
    tester,
  ) async {
    final contactsService = FakeDeviceContactsService()
      ..result = const SaveContactsResult(saved: 1, alreadySaved: 1);
    final settingsStore = MemoryAppSettingsStore()
      ..pin = '2580'
      ..sheetConfig = 'https://script.google.com/macros/s/test/exec';
    final students = [
      {
        'name': 'Pending Student',
        'contact': '070-100-0001',
        'addedDate': DateTime.now().toIso8601String(),
        'callStatus': 'Pending',
        'attempts': [],
      },
      {
        'name': 'Interested Student',
        'contact': '070-100-0002',
        'addedDate': DateTime.now().toIso8601String(),
        'callStatus': 'Interested',
        'attempts': [],
      },
    ];
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'students': students}), 200),
    );
    await tester.pumpWidget(
      testApp(
        httpClient: client,
        settingsStore: settingsStore,
        deviceContactsService: contactsService,
      ),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();
    await openSettings(tester);
    await tester.tap(find.text('Data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save contacts'));
    await tester.pumpAndSettle();

    expect(contactsService.receivedStudents.map((student) => student.name), [
      'Pending Student',
    ]);
    expect(find.textContaining('1 contact(s) saved'), findsOneWidget);
    expect(find.textContaining('1 already saved'), findsOneWidget);
  });

  testWidgets(
    'save quick action saves a contact; long press keeps edit and selection',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final contactsService = FakeDeviceContactsService()
        ..result = const SaveContactsResult(alreadySaved: 1);
      final settingsStore = MemoryAppSettingsStore()
        ..pin = '2580'
        ..sheetConfig = 'https://script.google.com/macros/s/test/exec';
      final students = [
        {
          'name': 'Pending Student',
          'contact': '070-100-0001',
          'addedDate': DateTime.now().toIso8601String(),
          'callStatus': 'Pending',
          'attempts': [],
        },
        {
          'name': 'Interested Student',
          'contact': '070-100-0002',
          'addedDate': DateTime.now().toIso8601String(),
          'callStatus': 'Interested',
          'attempts': [],
        },
      ];
      final client = MockClient(
        (_) async => http.Response(jsonEncode({'students': students}), 200),
      );
      await tester.pumpWidget(
        testApp(
          httpClient: client,
          settingsStore: settingsStore,
          deviceContactsService: contactsService,
        ),
      );
      await tester.pumpAndSettle();
      await enterPin(tester, '2580');
      await tester.pumpAndSettle();

      expect(find.byTooltip('Call student'), findsNWidgets(2));
      final pendingStudentCard = find.ancestor(
        of: find.text('Pending Student'),
        matching: find.byType(Card),
      );
      final moreActionsButton = find.descendant(
        of: pendingStudentCard,
        matching: find.byTooltip('More actions'),
      );
      expect(moreActionsButton, findsOneWidget);
      await tester.ensureVisible(moreActionsButton);
      await tester.tap(moreActionsButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save contact'));
      await tester.pumpAndSettle();

      expect(contactsService.receivedStudents, hasLength(1));
      expect(contactsService.receivedStudents.single.name, 'Pending Student');
      expect(find.textContaining('already saved'), findsOneWidget);

      await tester.longPress(find.text('Pending Student'));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Save contact'), findsNothing);
      expect(find.text('Select multiple'), findsOneWidget);

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
    },
  );

  testWidgets('bulk selection saves only selected contacts', (tester) async {
    final contactsService = FakeDeviceContactsService()
      ..result = const SaveContactsResult(saved: 1, alreadySaved: 1);
    final settingsStore = MemoryAppSettingsStore()
      ..pin = '2580'
      ..sheetConfig = 'https://script.google.com/macros/s/test/exec';
    final addedDate = DateTime.now().toIso8601String();
    final students = [
      {
        'name': 'First Student',
        'contact': '070-100-0011',
        'addedDate': addedDate,
        'callStatus': 'Pending',
        'attempts': [],
      },
      {
        'name': 'Second Student',
        'contact': '070-100-0012',
        'addedDate': addedDate,
        'callStatus': 'Pending',
        'attempts': [],
      },
      {
        'name': 'Unselected Student',
        'contact': '070-100-0013',
        'addedDate': addedDate,
        'callStatus': 'Pending',
        'attempts': [],
      },
    ];
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'students': students}), 200),
    );
    await tester.pumpWidget(
      testApp(
        httpClient: client,
        settingsStore: settingsStore,
        deviceContactsService: contactsService,
      ),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await tester.longPress(find.text('First Student'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select multiple'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Second Student'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Second Student'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byTooltip('Export selected contacts'), findsOneWidget);

    await tester.tap(find.byTooltip('Save selected contacts'));
    await tester.pumpAndSettle();
    expect(contactsService.receivedStudents.map((student) => student.name), [
      'First Student',
      'Second Student',
    ]);
    expect(find.textContaining('1 contact(s) saved'), findsOneWidget);
    expect(find.textContaining('1 already saved'), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel selection'));
    await tester.pumpAndSettle();
    expect(find.text('LeadPilot'), findsOneWidget);
  });

  testWidgets('persists light, dark, and system theme setting', (tester) async {
    final settingsStore = MemoryAppSettingsStore()..pin = '2580';
    await tester.pumpWidget(testApp(settingsStore: settingsStore));
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await openSettings(tester);
    await tester.ensureVisible(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<ThemeMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark').last);
    await tester.pumpAndSettle();
    expect(settingsStore.themeMode, ThemeMode.dark);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    final searchField = tester.widget<TextField>(
      find.byType(TextField, skipOffstage: false).first,
    );
    final hintColor = searchField.decoration!.hintStyle!.color!;
    expect(hintColor.computeLuminance(), greaterThan(0.3));
    expect(
      tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .darkTheme!
          .inputDecorationTheme
          .fillColor!
          .computeLuminance(),
      lessThan(0.1),
    );

    await tester.tap(find.byType(DropdownButtonFormField<ThemeMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System default').last);
    await tester.pumpAndSettle();
    expect(settingsStore.themeMode, ThemeMode.system);
  });

  testWidgets('Comments opens the full chronological call history', (
    tester,
  ) async {
    final settingsStore = MemoryAppSettingsStore()
      ..pin = '2580'
      ..sheetConfig = 'https://script.google.com/macros/s/test/exec';
    final history = [
      {
        'name': 'Mia Patel',
        'contact': '555-0104',
        'addedDate': '2025-01-01 09:00',
        'callStatus': 'Interested',
        'comment': 'Asked for details',
        'commentHistory': [
          '2025-01-02 09:00 AM — First attempt',
          '2025-01-03 10:00 AM — Asked for details',
        ],
        'attempts': [
          {
            'dateTime': '2025-01-02T09:00:00',
            'status': 'No Answer',
            'comment': 'First attempt',
          },
          {
            'dateTime': '2025-01-03T10:00:00',
            'status': 'Interested',
            'comment': 'Asked for details',
          },
          {
            'dateTime': '2025-01-04T11:00:00',
            'status': 'Not Responding',
            'comment': '',
          },
        ],
      },
    ];
    final client = MockClient(
      (_) async => http.Response.bytes(
        utf8.encode(jsonEncode({'students': history})),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    await tester.pumpWidget(
      testApp(httpClient: client, settingsStore: settingsStore),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    expect(find.text('Call history · Mia Patel'), findsOneWidget);
    final historyDialog = find.byType(AlertDialog);
    expect(find.text('No Answer'), findsOneWidget);
    expect(
      find.descendant(of: historyDialog, matching: find.text('Interested')),
      findsOneWidget,
    );
    expect(find.text('Not Responding'), findsOneWidget);
    expect(find.text('First attempt'), findsOneWidget);
    expect(find.text('Asked for details'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('First attempt')).dy,
      lessThan(tester.getTopLeft(find.text('Asked for details')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Asked for details')).dy,
      lessThan(tester.getTopLeft(find.text('Not Responding')).dy),
    );
  });

  testWidgets('offers previously linked sheet URLs for quick selection', (
    tester,
  ) async {
    final settingsStore = MemoryAppSettingsStore();
    const olderUrl = 'https://script.google.com/macros/s/older/exec';
    const newerUrl = 'https://script.google.com/macros/s/newer/exec';
    await settingsStore.savePin('2580');
    await settingsStore.saveSheetConfig(olderUrl, name: 'Older Leads');
    await settingsStore.saveSheetConfig(newerUrl, name: 'Current Leads');
    final client = MockClient((_) async => http.Response('[]', 200));

    await tester.pumpWidget(
      testApp(httpClient: client, settingsStore: settingsStore),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    await openSheetSettings(tester);
    await tester.pumpAndSettle();
    expect(find.text('Previously linked sheets'), findsOneWidget);

    final savedSheetsDropdown = find.byType(
      DropdownButtonFormField<LinkedSheet>,
    );
    await tester.tap(savedSheetsDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Older Leads').last);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('sheet-url-input')))
          .controller
          ?.text,
      olderUrl,
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('sheet-name-input')))
          .controller
          ?.text,
      'Older Leads',
    );
    expect(settingsStore.linkedSheets, const [
      LinkedSheet(name: 'Current Leads', url: newerUrl),
      LinkedSheet(name: 'Older Leads', url: olderUrl),
    ]);
  });

  testWidgets('switching linked sheets reloads only the selected sheet data', (
    tester,
  ) async {
    const firstUrl = 'https://script.google.com/macros/s/first/exec';
    const secondUrl = 'https://script.google.com/macros/s/second/exec';
    final settingsStore = MemoryAppSettingsStore()
      ..pin = '2580'
      ..sheetConfig = firstUrl
      ..sheetName = 'First sheet'
      ..linkedSheets.addAll(const [
        LinkedSheet(name: 'First sheet', url: firstUrl),
        LinkedSheet(name: 'Second sheet', url: secondUrl),
      ]);
    var getCount = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        getCount++;
        final studentName = getCount == 1
            ? 'First sheet student'
            : 'Second sheet student';
        final phone = getCount == 1 ? '555-1001' : '555-2001';
        return http.Response(
          jsonEncode({
            'students': [
              {
                'name': studentName,
                'contact': phone,
                'addedDate': DateTime.now().toIso8601String(),
                'callStatus': 'Pending',
                'attempts': [],
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{"success":true}', 200);
    });

    await tester.pumpWidget(
      testApp(httpClient: client, settingsStore: settingsStore),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();
    expect(find.text('First sheet student'), findsOneWidget);

    await openSettings(tester);
    await tester.ensureVisible(find.text('Google Sheets Sync'));
    await tester.tap(find.text('Google Sheets Sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<LinkedSheet>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second sheet').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save & Sync'));
    await tester.tap(find.text('Save & Sync'));
    await tester.pumpAndSettle();

    expect(find.text('Second sheet student'), findsOneWidget);
    expect(find.text('First sheet student'), findsNothing);
    expect(getCount, 2);
    expect(settingsStore.sheetConfig, secondUrl);
    expect(settingsStore.sheetName, 'Second sheet');
  });

  testWidgets(
    'auto-schedules unscheduled today follow-up reminders when syncing',
    (tester) async {
      final now = DateTime.now();
      final endOfToday = DateTime(now.year, now.month, now.day + 1);
      final remainingMs = endOfToday.difference(now).inMilliseconds;
      final stepMs = (remainingMs / 4).clamp(1000, 3600000).toInt();
      final todayFutureCall = now.add(Duration(milliseconds: stepMs));
      final alreadyScheduledCall = now.add(Duration(milliseconds: stepMs * 2));

      final reminderScheduler = FakeReminderScheduler();
      final alreadyScheduledStudent = Student(
        name: 'Already Scheduled',
        phone: '555-0801',
        nextCallDateTime: alreadyScheduledCall.toIso8601String(),
      );
      await reminderScheduler.scheduleStudentReminder(
        alreadyScheduledStudent,
        alreadyScheduledCall,
      );

      final students = [
        {
          'name': 'Already Scheduled',
          'contact': '555-0801',
          'addedDate': now.toIso8601String(),
          'nextCallDateTime': alreadyScheduledCall.toIso8601String(),
          'callStatus': 'Interested',
          'attempts': [],
        },
        {
          'name': 'Needs Scheduling',
          'contact': '555-0802',
          'addedDate': now.toIso8601String(),
          'nextCallDateTime': todayFutureCall.toIso8601String(),
          'callStatus': 'Pending',
          'attempts': [],
        },
        {
          'name': 'Past Call',
          'contact': '555-0803',
          'addedDate': now.toIso8601String(),
          'nextCallDateTime': now
              .subtract(const Duration(hours: 1))
              .toIso8601String(),
          'callStatus': 'Pending',
          'attempts': [],
        },
      ];

      final settingsStore = MemoryAppSettingsStore()
        ..pin = '2580'
        ..sheetConfig = 'https://script.google.com/macros/s/test/exec';
      final client = MockClient(
        (_) async => http.Response(jsonEncode({'students': students}), 200),
      );

      await tester.pumpWidget(
        testApp(
          httpClient: client,
          settingsStore: settingsStore,
          reminderScheduler: reminderScheduler,
        ),
      );
      await tester.pumpAndSettle();
      await enterPin(tester, '2580');
      await tester.pumpAndSettle();

      expect(reminderScheduler.scheduled, hasLength(2));
      expect(
        reminderScheduler.scheduled.map((item) => item.student.name),
        containsAll(['Already Scheduled', 'Needs Scheduling']),
      );
    },
  );

  testWidgets(
    'queues offline updates when network fails and auto-syncs when online',
    (tester) async {
      final initialStudent = {
        'name': 'Kamal Perera',
        'contact': '555-0901',
        'addedDate': DateTime.now().toIso8601String(),
        'callStatus': 'Pending',
        'comment': 'Initial comment',
        'attempts': [],
      };

      var shouldFailPost = true;
      final postedRequests = <http.Request>[];

      final client = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'students': [initialStudent],
            }),
            200,
          );
        }
        if (request.method == 'POST') {
          if (shouldFailPost) {
            throw http.ClientException('No internet connection');
          }
          postedRequests.add(request);
          return http.Response('{"success":true}', 200);
        }
        return http.Response('Not found', 404);
      });

      final settingsStore = MemoryAppSettingsStore()
        ..pin = '2580'
        ..sheetConfig = 'https://script.google.com/macros/s/test/exec';

      await tester.pumpWidget(
        testApp(httpClient: client, settingsStore: settingsStore),
      );
      await tester.pumpAndSettle();
      await enterPin(tester, '2580');
      await tester.pumpAndSettle();

      expect(find.text('Kamal Perera'), findsOneWidget);

      await tester.tap(find.text('Kamal Perera'));
      await tester.pumpAndSettle();

      final commentField = find.byType(TextFormField).first;
      await tester.enterText(commentField, 'Offline call notes');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(settingsStore.offlineQueue, hasLength(1));
      expect(
        settingsStore.offlineQueue.first.student.comment,
        'Offline call notes',
      );
      expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sync-appbar-button')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );

      shouldFailPost = false;
      await tester.tap(find.byKey(const ValueKey('sync-appbar-button')));
      await tester.pumpAndSettle();

      expect(settingsStore.offlineQueue, isEmpty);
      expect(postedRequests, hasLength(1));
      final payload =
          jsonDecode(postedRequests.first.body) as Map<String, dynamic>;
      expect(payload['comment'], 'Offline call notes');
    },
  );

  testWidgets(
    'manages WhatsApp templates in Settings and verifies persistence',
    (tester) async {
      final initialStudent = {
        'name': 'Kamal Perera',
        'contact': '0701061244',
        'addedDate': DateTime.now().toIso8601String(),
        'callStatus': 'Pending',
        'comment': '',
        'attempts': [],
      };
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'students': [initialStudent],
            }),
            200,
          );
        }
        return http.Response('{"success":true}', 200);
      });

      final settingsStore = MemoryAppSettingsStore()
        ..pin = '2580'
        ..sheetConfig = 'https://script.google.com/macros/s/test/exec';

      await tester.pumpWidget(
        testApp(httpClient: client, settingsStore: settingsStore),
      );
      await tester.pumpAndSettle();
      await enterPin(tester, '2580');
      await tester.pumpAndSettle();

      await openSettings(tester);
      await tester.tap(find.text('Messages'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('WhatsApp & SMS templates'));
      await tester.pumpAndSettle();

      expect(find.text('WhatsApp & SMS Templates'), findsOneWidget);
      expect(find.text('General Follow-up'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Add Template'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Template Name'),
        'Special Offer',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Message'),
        'Hello {name}, 20% discount!',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('Special Offer'), findsOneWidget);
      final savedTemplates = await settingsStore.readWhatsAppTemplates();
      expect(
        savedTemplates.any(
          (t) =>
              t.name == 'Special Offer' &&
              t.message == 'Hello {name}, 20% discount!',
        ),
        isTrue,
      );
    },
  );

  testWidgets('tapping WhatsApp action offers Custom and Template choices', (
    tester,
  ) async {
    final initialStudent = {
      'name': 'Kamal Perera',
      'contact': '0701061244',
      'addedDate': DateTime.now().toIso8601String(),
      'callStatus': 'Pending',
      'comment': '',
      'attempts': [],
    };
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'students': [initialStudent],
          }),
          200,
        );
      }
      return http.Response('{"success":true}', 200);
    });

    final settingsStore = MemoryAppSettingsStore()
      ..pin = '2580'
      ..sheetConfig = 'https://script.google.com/macros/s/test/exec';

    await tester.pumpWidget(
      testApp(httpClient: client, settingsStore: settingsStore),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, '2580');
    await tester.pumpAndSettle();

    final moreActionsBtn = find.byTooltip('More actions').first;
    await tester.tap(moreActionsBtn);
    await tester.pumpAndSettle();
    await tester.tap(find.text('WhatsApp'));
    await tester.pumpAndSettle();

    expect(find.text('Send WhatsApp Message'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('Template'), findsOneWidget);

    await tester.tap(find.text('Template'));
    await tester.pumpAndSettle();

    expect(find.text('Select Template'), findsOneWidget);
    expect(find.text('General Follow-up'), findsOneWidget);
    expect(
      find.textContaining(
        'Hello Kamal Perera, following up on our recent conversation.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('General Follow-up'));
    await tester.pumpAndSettle();

    expect(find.text('Select Template'), findsNothing);
  });

  test(
    'calculates consecutive unanswered streak correctly and resets on answer',
    () {
      final now = DateTime.now();
      final student3 = Student(
        name: 'Lead 3x',
        phone: '0711111111',
        attempts: [
          CallAttempt(
            dateTime: now.subtract(const Duration(hours: 5)).toIso8601String(),
            status: 'Answered',
            comment: 'Talked',
          ),
          CallAttempt(
            dateTime: now.subtract(const Duration(hours: 3)).toIso8601String(),
            status: 'No Answer',
            comment: '',
          ),
          CallAttempt(
            dateTime: now.subtract(const Duration(hours: 2)).toIso8601String(),
            status: 'Call Cut',
            comment: '',
          ),
          CallAttempt(
            dateTime: now.subtract(const Duration(hours: 1)).toIso8601String(),
            status: 'Not Responding',
            comment: '',
          ),
        ],
      );

      final status3 = studentActivityStatus(student3);
      expect(status3.unansweredStreak, 3);
      expect(status3.level, StudentActivityLevel.cooling);

      final student5 = student3.copyWith(
        attempts: [
          ...student3.attempts,
          CallAttempt(
            dateTime: now
                .subtract(const Duration(minutes: 30))
                .toIso8601String(),
            status: 'Line Busy',
            comment: '',
          ),
          CallAttempt(
            dateTime: now
                .subtract(const Duration(minutes: 10))
                .toIso8601String(),
            status: 'No Answer',
            comment: '',
          ),
        ],
      );

      final status5 = studentActivityStatus(student5);
      expect(status5.unansweredStreak, 5);
      expect(status5.level, StudentActivityLevel.inactive);
    },
  );

  testWidgets(
    'prompts to move lead to Inactive on 6th consecutive unanswered attempt',
    (tester) async {
      final now = DateTime.now();
      final fiveAttemptStudent = {
        'name': 'Kamal Perera',
        'contact': '0701061244',
        'addedDate': now.toIso8601String(),
        'callStatus': 'No Answer',
        'comment': '',
        'attempts': [
          for (int i = 5; i >= 1; i--)
            {
              'dateTime': now.subtract(Duration(hours: i)).toIso8601String(),
              'status': 'No Answer',
              'comment': '',
            },
        ],
      };

      final client = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'students': [fiveAttemptStudent],
            }),
            200,
          );
        }
        return http.Response('{"success":true}', 200);
      });

      final settingsStore = MemoryAppSettingsStore()
        ..pin = '2580'
        ..sheetConfig = 'https://script.google.com/macros/s/test/exec';

      await tester.pumpWidget(
        testApp(httpClient: client, settingsStore: settingsStore),
      );
      await tester.pumpAndSettle();
      await enterPin(tester, '2580');
      await tester.pumpAndSettle();

      expect(find.text('Kamal Perera'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);

      await tester.tap(find.text('Kamal Perera'));
      await tester.pumpAndSettle();

      expect(find.text('Save'), findsOneWidget);
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Move to Inactive?'), findsOneWidget);
      expect(
        find.textContaining(
          'Kamal Perera has not answered 6 consecutive times.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Move to Inactive'));
      await tester.pumpAndSettle();

      expect(find.text('Kamal Perera'), findsNothing);

      // Verify that syncing with Google Sheet does NOT bring the inactive student back to the active list
      await tester.tap(find.byKey(const ValueKey('sync-appbar-button')));
      await tester.pumpAndSettle();

      expect(find.text('Kamal Perera'), findsNothing);
    },
  );

  test('CallerIdService syncs student leads with normalized attributes to native channel', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CallerIdService.channel, (call) async {
          calls.add(call);
          if (call.method == 'isCallerIdEnabled') return true;
          if (call.method == 'canDrawOverlays') return true;
          if (call.method == 'hasPhonePermissions') return true;
          return true;
        });

    final now = DateTime.now();
    final student = Student(
      name: 'Nimal Silva',
      phone: '071 234 5678',
      whatsappNumber: '077 888 9999',
      callStatus: 'No Answer',
      location: 'Gampaha',
      examType: '2026 A/L',
      comment: 'Follow up requested tomorrow afternoon',
      attempts: [
        CallAttempt(
          dateTime: now.subtract(const Duration(days: 3)).toIso8601String(),
          status: 'No Answer',
          comment: 'Line ringing',
        ),
        CallAttempt(
          dateTime: now.subtract(const Duration(days: 2)).toIso8601String(),
          status: 'Not Responding',
          comment: 'Ringing no answer',
        ),
        CallAttempt(
          dateTime: now.subtract(const Duration(days: 1)).toIso8601String(),
          status: 'Call Cut',
          comment: 'Line busy',
        ),
      ],
    );

    await CallerIdService.syncStudents([student]);

    expect(calls, hasLength(1));
    expect(calls.first.method, 'syncCallerIdData');
    final args = calls.first.arguments as Map<dynamic, dynamic>;
    final studentsList = args['students'] as List<dynamic>;
    expect(studentsList, hasLength(1));

    final synced = (studentsList.first as Map).cast<String, dynamic>();
    expect(synced['name'], 'Nimal Silva');
    expect(synced['phone'], '071 234 5678');
    expect(synced['whatsappNumber'], '077 888 9999');
    expect(synced['status'], 'No Answer');
    expect(synced['location'], 'Gampaha');
    expect(synced['examType'], '2026 A/L');
    expect(synced['lastComment'], 'Follow up requested tomorrow afternoon');
    expect(synced['streak'], 3);

    expect(await CallerIdService.isEnabled(), isTrue);
    await CallerIdService.setEnabled(false);
    expect(calls.any((c) => c.method == 'setCallerIdEnabled'), isTrue);

    await CallerIdService.testCallerIdPopup();
    expect(calls.any((c) => c.method == 'testCallerIdPopup'), isTrue);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CallerIdService.channel, null);
  });

  testWidgets(
    'Settings displays Incoming Caller ID toggle, test popup, and v1.11.1',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CallerIdService.channel, (call) async {
            if (call.method == 'isCallerIdEnabled') return true;
            if (call.method == 'canDrawOverlays') return true;
            if (call.method == 'hasPhonePermissions') return true;
            if (call.method == 'getCachedStudentCount') return 5;
            return true;
          });

      final settingsStore = MemoryAppSettingsStore()..pin = '2580';
      await tester.pumpWidget(testApp(settingsStore: settingsStore));
      await tester.pumpAndSettle();
      await enterPin(tester, '2580');
      await tester.pumpAndSettle();

      await openSettings(tester);
      await tester.tap(find.text('Caller ID'));
      await tester.pumpAndSettle();

      expect(find.text('Incoming Caller ID Popup'), findsOneWidget);

      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();

      final testPopupFinder = find.text('Preview / Test Popup');

      await tester.tap(testPopupFinder);
      await tester.pumpAndSettle();
      expect(find.text('Sample Caller ID popup displayed!'), findsOneWidget);

      final bannerFinder = find.text('Test Lock Screen & Heads-Up Banner');
      await tester.ensureVisible(bannerFinder);
      await tester.pumpAndSettle();
      expect(bannerFinder, findsOneWidget);
      await tester.tap(bannerFinder);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Sample Heads-Up / Lock Screen banner displayed! Check your notifications.',
        ),
        findsOneWidget,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CallerIdService.channel, null);
    },
  );

  testWidgets(
    'PinScreen auto-biometric dismissal does not decrement attempts or show error',
    (tester) async {
      var biometricCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PinScreen(
              isFirstTime: false,
              storedPin: '2580',
              biometricEnabled: true,
              onBiometricAuth: () async {
                biometricCalled = true;
                return false; // User dismissed or canceled
              },
              onPinCreated: (_) async {},
              onAuthenticated: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(biometricCalled, isTrue);
      expect(find.textContaining('tries left'), findsNothing);
      expect(find.textContaining('not recognised'), findsNothing);
      expect(find.text('Welcome Back'), findsOneWidget);
      expect(find.text('Use fingerprint or enter your PIN.'), findsOneWidget);
    },
  );

  test('GeminiService generates follow-up message using student context and mock client', () async {
    final mockClient = MockClient((request) async {
      expect(request.url.queryParameters['key'], 'test_api_key_123');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final promptText = body['contents'][0]['parts'][0]['text'] as String;
      expect(promptText.contains('Kamal Perera'), isTrue);
      expect(promptText.contains('2026 A/L'), isTrue);
      expect(promptText.contains('Asked about fee'), isTrue);

      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'text':
                        'Hello Kamal, following up on your class fee inquiry!',
                  },
                ],
              },
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = GeminiService(client: mockClient);
    const student = Student(
      name: 'Kamal Perera',
      phone: '0771234567',
      examType: '2026 A/L',
      callStatus: 'Interested',
      comment: 'Asked about fee',
    );

    final msg = await service.generateFollowUp(
      apiKey: 'test_api_key_123',
      student: student,
      language: 'English',
      tone: 'Class Details & Fees',
    );

    expect(msg, 'Hello Kamal, following up on your class fee inquiry!');
  });

  testWidgets(
    'WhatsApp choice sheet displays Generate with AI option and Gemini badge',
    (tester) async {
      const student = Student(name: 'Kamal Perera', phone: '0771234567');

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: WhatsAppChoiceSheet(student: student)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Custom'), findsOneWidget);
      expect(find.text('Template'), findsOneWidget);
      expect(find.text('Generate with AI'), findsOneWidget);
      expect(find.text('Gemini'), findsOneWidget);
    },
  );

  testWidgets(
    'SMS choice sheet displays Custom, Template, and Generate with AI',
    (tester) async {
      const student = Student(name: 'Nimal Bandara', phone: '0712345678');

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SmsChoiceSheet(student: student)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Send SMS Message'), findsOneWidget);
      expect(find.text('SMS to Nimal Bandara'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
      expect(find.text('Open SMS app with a blank message'), findsOneWidget);
      expect(find.text('Template'), findsOneWidget);
      expect(find.text('Generate with AI'), findsOneWidget);
      expect(find.text('Gemini'), findsOneWidget);
    },
  );

  testWidgets(
    'StudentCard displays history button with Icons.history_rounded',
    (tester) async {
      const student = Student(name: 'Test Student', phone: '0712345678');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudentCard(
              student: student,
              onTap: () {},
              onLongPress: () {},
              onCall: () {},
              onWhatsApp: () {},
              onSms: () {},
              onNote: () {},
              onSaveContact: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('History'), findsOneWidget);
      expect(find.byIcon(Icons.history_rounded), findsWidgets);
    },
  );

  test('GeminiService.sanitizeApiKey correctly cleans messy input keys', () {
    expect(
      GeminiService.sanitizeApiKey(
        '  "AIzaSyD1234567890abcdefghijklmnopqrst"  ',
      ),
      'AIzaSyD1234567890abcdefghijklmnopqrst',
    );
    expect(
      GeminiService.sanitizeApiKey("'AIzaSyD1234567890abcdefghijklmnopqrst'"),
      'AIzaSyD1234567890abcdefghijklmnopqrst',
    );
    expect(
      GeminiService.sanitizeApiKey('key=AIzaSyD1234567890abcdefghijklmnopqrst'),
      'AIzaSyD1234567890abcdefghijklmnopqrst',
    );
    expect(
      GeminiService.sanitizeApiKey(
        'https://generativelanguage.googleapis.com?key=AIzaSyD1234567890abcdefghijklmnopqrst',
      ),
      'AIzaSyD1234567890abcdefghijklmnopqrst',
    );
    expect(
      GeminiService.sanitizeApiKey(
        '  `AIzaSyD1234567890abcdefghijklmnopqrst` \n',
      ),
      'AIzaSyD1234567890abcdefghijklmnopqrst',
    );
    expect(
      GeminiService.looksLikeGoogleApiKey(
        'AIzaSyD1234567890abcdefghijklmnopqrst',
      ),
      isTrue,
    );
    expect(
      GeminiService.looksLikeGoogleApiKey('leadpilot-project-id'),
      isFalse,
    );
  });

  test('GeminiService.testConnection handles successful connection and error parsing', () async {
    final successClient = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'pong'},
                ],
              },
            },
          ],
        }),
        200,
      );
    });

    final successService = GeminiService(client: successClient);
    final res = await successService.testConnection(
      'AIzaSyD1234567890abcdefghijklmnopqrst',
    );
    expect(res.isSuccess, isTrue);
    expect(res.message.contains('Connection successful'), isTrue);
    expect(res.modelName, 'gemini-1.5-flash');

    final invalidKeyClient = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'error': {
            'code': 400,
            'message': 'API key not valid. Please pass a valid API key.',
            'status': 'INVALID_ARGUMENT',
          },
        }),
        400,
      );
    });

    final invalidService = GeminiService(client: invalidKeyClient);
    final errRes = await invalidService.testConnection('bad_key_123');
    expect(errRes.isSuccess, isFalse);
    expect(errRes.message.contains('Google rejected this API key'), isTrue);

    final projectDisabledClient = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'error': {
            'code': 404,
            'message': 'models/gemini-1.5-flash is not found for API version v1beta, or is not supported for generateContent. Call ModelService.ListModels to see the list of available models and their supported methods.',
            'status': 'NOT_FOUND',
          },
        }),
        404,
      );
    });

    final projectDisabledService = GeminiService(client: projectDisabledClient);
    final disabledRes = await projectDisabledService.testConnection(
      'AQ.Ab8RN6L_nOJHLak9Aea9qBX5fMjc',
    );
    expect(disabledRes.isSuccess, isFalse);
    expect(disabledRes.statusCode, 404);
    expect(
      disabledRes.message.contains('Generative Language API is disabled'),
      isTrue,
    );
    expect(
      disabledRes.message.contains('Create API key in new project'),
      isTrue,
    );

    // Test modality mismatch fallback (e.g. gemini-2.5-flash-preview-tts returns 400 modalities, gemini-1.5-flash returns 200)
    final modalityFallbackClient = MockClient((request) async {
      if (request.url.path.contains('gemini-2.5-flash-preview-tts')) {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 400,
              'message': 'The requested combination of response modalities (TEXT) is not supported by the model. models/gemini-2.5-flash-preview-tts accepts AUDIO',
              'status': 'INVALID_ARGUMENT',
            },
          }),
          400,
        );
      }
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'pong'},
                ],
              },
            },
          ],
        }),
        200,
      );
    });

    final fallbackService = GeminiService(client: modalityFallbackClient);
    final fallbackRes = await fallbackService.testConnection(
      'AIzaSyD1234567890abcdefghijklmnopqrst',
      targetModel: 'gemini-2.5-flash-preview-tts',
    );
    expect(fallbackRes.isSuccess, isTrue);
    expect(fallbackRes.modelName, 'gemini-1.5-flash');
  });

  testWidgets(
    'ManageGeminiAiSheet tests key and displays connection feedback',
    (tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'},
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final store = MemoryAppSettingsStore()
        ..geminiApiKey = 'AIzaSyD1234567890abcdefghijklmnopqrst';
      final service = GeminiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManageGeminiAiSheet(
              settingsStore: store,
              geminiService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Gemini AI Assistant'), findsOneWidget);
      final testFinder = find.text('Test Key');
      expect(testFinder, findsOneWidget);

      await tester.ensureVisible(testFinder);
      await tester.tap(testFinder);
      await tester.pumpAndSettle();

      expect(find.textContaining('Connection successful'), findsOneWidget);
    },
  );

  testWidgets(
    'ManageGeminiAiSheet dynamically fetches models and allows selecting preferred model',
    (tester) async {
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('/models') && request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'models': [
                {
                  'name': 'models/gemini-1.5-flash',
                  'displayName': 'Gemini 1.5 Flash',
                  'supportedGenerationMethods': ['generateContent'],
                },
                {
                  'name': 'models/gemini-2.0-flash',
                  'displayName': 'Gemini 2.0 Flash',
                  'supportedGenerationMethods': ['generateContent'],
                },
                {
                  'name': 'models/gemini-1.5-pro',
                  'displayName': 'Gemini 1.5 Pro',
                  'supportedGenerationMethods': ['generateContent'],
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'Ping response'},
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final store = MemoryAppSettingsStore()
        ..geminiApiKey = 'AIzaSyD1234567890abcdefghijklmnopqrst';
      final service = GeminiService(client: mockClient);

      // Verify fetchAvailableModels directly
      final fetched = await service.fetchAvailableModels(
        'AIzaSyD1234567890abcdefghijklmnopqrst',
      );
      expect(fetched.length, 3);
      expect(fetched.first.id, 'gemini-1.5-flash');
      expect(fetched[1].id, 'gemini-2.0-flash');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManageGeminiAiSheet(
              settingsStore: store,
              geminiService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Test Key
      final testKeyFinder = find.text('Test Key');
      await tester.ensureVisible(testKeyFinder);
      await tester.tap(testKeyFinder);
      await tester.pumpAndSettle();

      expect(find.textContaining('Connection successful'), findsOneWidget);
      expect(find.text('Selected Gemini Model'), findsOneWidget);

      // Tap Save Key
      final saveFinder = find.text('Save Key');
      await tester.ensureVisible(saveFinder);
      await tester.tap(saveFinder);
      await tester.pumpAndSettle();

      expect(await store.readGeminiModel(), 'gemini-1.5-flash');
    },
  );

  testWidgets(
    'GeminiAiMessageSheet allows saving generated message as a reusable template',
    (tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text':
                          'Hello Nimal, your tuition class starts next Monday!',
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final store = MemoryAppSettingsStore()
        ..geminiApiKey = 'AIzaSyD1234567890abcdefghijklmnopqrst';
      final service = GeminiService(client: mockClient);

      const student = Student(
        name: 'Nimal Silva',
        phone: '0771234567',
        callStatus: 'Interested',
        examType: '2026 A/L',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GeminiAiMessageSheet(
              student: student,
              initialApiKey: 'AIzaSyD1234567890abcdefghijklmnopqrst',
              settingsStore: store,
              geminiService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Save Template'), findsOneWidget);
      expect(find.text('Send on WhatsApp'), findsOneWidget);
      expect(find.text('Regenerate'), findsOneWidget);
      expect(find.text('Generate Message'), findsOneWidget);
      expect(find.text('What should this message be about?'), findsOneWidget);

      await tester.ensureVisible(find.text('Save Template'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Template'));
      await tester.pumpAndSettle();

      expect(find.text('Save as Template'), findsOneWidget);
      expect(
        find.text('Hello {name}, your tuition class starts next Monday!'),
        findsOneWidget,
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final templates = await store.readWhatsAppTemplates();
      expect(
        templates.any(
          (t) =>
              t.message ==
              'Hello {name}, your tuition class starts next Monday!',
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'AppSplashScreen displays LeadPilot emblem, animates, and allows instant tap to skip',
    (tester) async {
      var finished = false;

      await tester.pumpWidget(
        MaterialApp(
          home: AppSplashScreen(
            duration: const Duration(milliseconds: 300),
            onFinished: () => finished = true,
          ),
        ),
      );

      // Initial frame
      await tester.pump();
      expect(find.text('LeadPilot'), findsOneWidget);
      expect(find.text('STUDENT LEADS • SMART DIALER'), findsOneWidget);
      expect(find.byType(LeadPilotAppIcon), findsOneWidget);

      // Tap to skip immediately
      await tester.tap(find.byType(AppSplashScreen));
      await tester.pump();
      expect(finished, isTrue);
    },
  );

  test('MemoryAppSettingsStore stores and reads default and custom companyDescription', () async {
    final store = MemoryAppSettingsStore();
    expect(await store.readCompanyDescription(), contains('LNBTI'));

    await store.saveCompanyDescription('Custom Institute of Technology');
    expect(
      await store.readCompanyDescription(),
      'Custom Institute of Technology',
    );

    // Blank description should reset to default
    await store.saveCompanyDescription('   ');
    expect(await store.readCompanyDescription(), contains('LNBTI'));
  });

  test('GeminiService includes LNBTI company context and friendly conversational tone rules in prompt', () async {
    String? sentPrompt;
    final mockClient = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final contents = body['contents'] as List;
      final parts = contents.first['parts'] as List;
      sentPrompt = parts.first['text'] as String;
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Hello Kasun from LNBTI!'},
                ],
              },
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = GeminiService(client: mockClient);
    const student = Student(
      name: 'Kasun Bandara',
      phone: '0711122334',
      callStatus: 'Interested',
      comment: 'Wants IT degree info',
    );

    final msg = await service.generateFollowUp(
      apiKey: 'test_key',
      student: student,
      language: 'English',
    );

    expect(msg, 'Hello Kasun from LNBTI!');
    expect(sentPrompt, contains('LNBTI'));
    expect(sentPrompt, contains('STRICTLY FORBIDDEN PHRASES'));
    expect(sentPrompt, contains('NO overly casual buddy slang'));
    expect(sentPrompt, contains('DO NOT OVER-DETAIL'));
  });

  testWidgets(
    'ManageGeminiAiSheet displays and updates Description about your company',
    (tester) async {
      final store = MemoryAppSettingsStore();
      final service = GeminiService();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManageGeminiAiSheet(
              settingsStore: store,
              geminiService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Description about your company'), findsOneWidget);
      expect(find.text(store.companyDescription), findsOneWidget);

      // Enter a new company description
      final descField = find.widgetWithText(
        TextField,
        store.companyDescription,
      );
      await tester.ensureVisible(descField);
      await tester.enterText(descField, 'LNBTI Higher Education Campus');
      await tester.pumpAndSettle();

      final saveFinder = find.text('Save Key');
      await tester.ensureVisible(saveFinder);
      await tester.tap(saveFinder);
      await tester.pumpAndSettle();

      expect(
        await store.readCompanyDescription(),
        'LNBTI Higher Education Campus',
      );
    },
  );

  testWidgets(
    'GeminiAiMessageSheet displays representation badge on behalf of LNBTI',
    (tester) async {
      final store = MemoryAppSettingsStore();
      final service = GeminiService();

      const student = Student(
        name: 'Saman Kumara',
        phone: '0779988776',
        callStatus: 'Interested',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GeminiAiMessageSheet(
              student: student,
              initialApiKey: 'test_key',
              settingsStore: store,
              geminiService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('On behalf of: LNBTI'), findsOneWidget);
    },
  );

  test('tryParseDate parses ISO, AM/PM, and slash date formats correctly', () {
    expect(tryParseDate('2026-11-17T14:30:00'), DateTime(2026, 11, 17, 14, 30));
    expect(tryParseDate('2026-11-17 02:30 PM'), DateTime(2026, 11, 17, 14, 30));
    expect(tryParseDate('2026-11-17 9:15 AM'), DateTime(2026, 11, 17, 9, 15));
    expect(tryParseDate('17/11/2026 14:30:00'), DateTime(2026, 11, 17, 14, 30));
    expect(tryParseDate('17/11/2026 02:30 PM'), DateTime(2026, 11, 17, 14, 30));
    expect(tryParseDate('17/11/2026'), DateTime(2026, 11, 17));
    expect(tryParseDate(''), isNull);
    expect(tryParseDate(null), isNull);
  });

  testWidgets(
    'Lead with overdue reminder from yesterday displays overdue notice and quick chips in EditStudentSheet',
    (tester) async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final student = Student(
        name: 'Nalaka Silva',
        phone: '0773344556',
        callStatus: 'Call Back',
        nextCallDateTime: yesterday.toIso8601String(),
      );

      Student? updatedResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  updatedResult = await showModalBottomSheet<Student>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => EditStudentSheet(student: student),
                  );
                },
                child: const Text('Open Edit'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Edit'));
      await tester.pumpAndSettle();

      // Verify overdue indication
      expect(find.textContaining('Overdue:'), findsOneWidget);
      expect(find.text('+1 hr'), findsOneWidget);
      expect(find.text('+3 hrs'), findsOneWidget);
      expect(find.text('Tomorrow 10 AM'), findsOneWidget);

      // Tap +1 hr quick shortcut
      await tester.ensureVisible(find.text('+1 hr'));
      await tester.tap(find.text('+1 hr'));
      await tester.pumpAndSettle();

      // Overdue warning should be replaced by the new scheduled future time
      expect(find.textContaining('Overdue:'), findsNothing);

      // Save
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(updatedResult, isNotNull);
      final parsedNextCall = tryParseDate(updatedResult!.nextCallDateTime);
      expect(parsedNextCall, isNotNull);
      expect(parsedNextCall!.isAfter(DateTime.now()), isTrue);
    },
  );

  testWidgets(
    'Saving lead with overdue reminder without setting new future reminder clears nextCallDateTime',
    (tester) async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final student = Student(
        name: 'Sunil Shantha',
        phone: '0715566778',
        callStatus: 'No Answer',
        nextCallDateTime: yesterday.toIso8601String(),
      );

      Student? updatedResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  updatedResult = await showModalBottomSheet<Student>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => EditStudentSheet(student: student),
                  );
                },
                child: const Text('Open Edit'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Edit'));
      await tester.pumpAndSettle();

      // Overdue warning is present
      expect(find.textContaining('Overdue:'), findsOneWidget);

      // Save directly without picking a new reminder
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(updatedResult, isNotNull);
      // nextCallDateTime must be empty string so past reminder is not preserved
      expect(updatedResult!.nextCallDateTime, isEmpty);
    },
  );

  testWidgets(
    'EditStudentSheet opens EditDetailsScreen via Edit details button and returns updated student to Log call screen',
    (tester) async {
      const student = Student(
        name: 'Kasun Bandara',
        phone: '0771122334',
        callStatus: 'Pending',
      );

      Student? updatedResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  updatedResult = await showModalBottomSheet<Student>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => EditStudentSheet(student: student),
                  );
                },
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('Kasun Bandara'), findsOneWidget);
      expect(find.byTooltip('Call Kasun Bandara'), findsOneWidget);

      await tester.tap(find.text('Edit details'));
      await tester.pumpAndSettle();

      expect(find.text('Edit Details · Kasun Bandara'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('edit-name-input')),
        'Kasun B. Fernando',
      );
      await tester.enterText(
        find.byKey(const ValueKey('edit-phone-input')),
        '0779988776',
      );
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Back on Log call screen with updated name
      expect(find.text('Kasun B. Fernando'), findsOneWidget);

      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(updatedResult, isNotNull);
      expect(updatedResult!.name, 'Kasun B. Fernando');
      expect(updatedResult!.phone, '0779988776');
    },
  );

  test('GeminiService.polishRemark rewrites broken or rough remarks into clear CRM English', () async {
    String? capturedPrompt;
    final mockClient = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final contents = body['contents'] as List;
      final parts = contents.first['parts'] as List;
      capturedPrompt = parts.first['text'] as String;

      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'text': 'Student did not answer; requested a follow-up call tomorrow at 4:00 PM.',
                  },
                ],
              },
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = GeminiService(client: mockClient);
    final polished = await service.polishRemark(
      apiKey: 'test_key',
      rawRemark: 'ans kale na he told to call tomorrow 4pm',
    );

    expect(
      polished,
      'Student did not answer; requested a follow-up call tomorrow at 4:00 PM.',
    );
    expect(
      capturedPrompt,
      contains('ans kale na he told to call tomorrow 4pm'),
    );
    expect(capturedPrompt, contains('Rewrite and polish this raw remark'));
  });

  testWidgets(
    'EditStudentSheet allows polishing raw remarks with AI and supports Undo',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final store = MemoryAppSettingsStore();
      await store.saveGeminiApiKey('test_key');

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text': 'Interested in Software Engineering; requested evening callback.',
                    },
                  ],
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = GeminiService(client: mockClient);
      const student = Student(name: 'Nimal Perera', phone: '0712233445');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EditStudentSheet(
                student: student,
                settingsStore: store,
                geminiService: service,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final polishBtn = find.byKey(const Key('polish_remark_button'));
      await tester.ensureVisible(polishBtn);

      // 1. Tapping when empty shows a notice
      await tester.tap(polishBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Please type your raw or draft remark first.'),
        findsOneWidget,
      );

      // 2. Enter rough remark
      final remarkField = find.widgetWithText(
        TextFormField,
        'Call remark (optional)',
      );
      await tester.enterText(
        remarkField,
        'student kata kala se degree kamathi kiwwa hawasa call ganna',
      );
      await tester.pump();

      // 3. Tap Polish English (AI)
      await tester.ensureVisible(polishBtn);
      await tester.tap(polishBtn);
      await tester.pump(); // starts loading
      await tester.pump(); // completes Future
      await tester.pump(); // setState with polished text & calls showSnackBar
      await tester.pump(); // starts SnackBar entry animation
      await tester.pump(
        const Duration(milliseconds: 350),
      ); // finishes slide-in animation

      // Field should now have polished English
      expect(
        find.text(
          'Interested in Software Engineering; requested evening callback.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('✨ Remark polished into clear English!'),
        findsOneWidget,
      );

      // 4. Tap Undo on SnackBar
      final undoFinder = find.byType(SnackBarAction);
      expect(undoFinder, findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      tester.widget<SnackBarAction>(undoFinder).onPressed.call();
      await tester.pump();

      // Reverted back to raw text
      expect(
        find.text(
          'student kata kala se degree kamathi kiwwa hawasa call ganna',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'EditStudentSheet supports voice-to-text dictation and seamless AI polish',
    (tester) async {
      final mockVoice = MockVoiceToTextService(
        mockWords: 'katha kala degree fees ahuwa',
      );
      final store = MemoryAppSettingsStore();
      await store.saveGeminiApiKey('test_key');

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text':
                          'Contacted student regarding degree fee structure.',
                    },
                  ],
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final gemini = GeminiService(client: mockClient);
      const student = Student(name: 'Sunil Silva', phone: '0771234567');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EditStudentSheet(
                student: student,
                settingsStore: store,
                geminiService: gemini,
                voiceToTextService: mockVoice,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final voiceBtn = find.byKey(const Key('voice_to_text_button'));
      final langToggle = find.byKey(const Key('voice_language_toggle'));
      expect(voiceBtn, findsOneWidget);
      expect(langToggle, findsOneWidget);
      expect(find.text('සිංහල'), findsOneWidget);
      expect(find.text('🎙️ Speak'), findsOneWidget);

      // Toggle language from Sinhala to English and back
      await tester.ensureVisible(langToggle);
      await tester.tap(langToggle);
      await tester.pump();
      expect(find.text('English'), findsOneWidget);

      await tester.tap(langToggle);
      await tester.pump();
      expect(find.text('සිංහල'), findsOneWidget);

      // 1. Tap Speak button
      await tester.ensureVisible(voiceBtn);
      await tester.tap(voiceBtn);
      await tester.pump();

      expect(mockVoice.listenCallCount, 1);
      expect(find.text('katha kala degree fees ahuwa'), findsOneWidget);

      // 2. Tap Polish button to polish the dictated speech
      final polishBtn = find.byKey(const Key('polish_remark_button'));
      await tester.ensureVisible(polishBtn);
      await tester.tap(polishBtn);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.text('Contacted student regarding degree fee structure.'),
        findsOneWidget,
      );
      expect(
        find.text('✨ Remark polished into clear English!'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'StudentHistoryDialog supports voice-to-text when editing last comment',
    (tester) async {
      final mockVoice = MockVoiceToTextService(
        mockWords: 'father will visit campus next week',
      );
      final store = MemoryAppSettingsStore();

      Student student = const Student(
        name: 'Kamal Gunawardena',
        phone: '0719876543',
        commentHistory: ['2026-11-18 10:00: Initial call made'],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => StudentHistoryDialog(
                    student: student,
                    title: 'History',
                    settingsStore: store,
                    voiceToTextService: mockVoice,
                    onStudentUpdated: (updated) async {
                      student = updated;
                    },
                  ),
                ),
                child: const Text('Open History'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open History'));
      await tester.pumpAndSettle();

      final editBtn = find.text('Edit last remark');
      expect(editBtn, findsOneWidget);
      await tester.tap(editBtn);
      await tester.pumpAndSettle();

      expect(find.text('Edit Last Remark'), findsOneWidget);

      final speakBtn = find.text('🎙️ Speak');
      expect(speakBtn, findsOneWidget);
      await tester.tap(speakBtn);
      await tester.pump();

      expect(mockVoice.listenCallCount, 1);
      expect(
        find.text(
          '2026-11-18 10:00: Initial call made father will visit campus next week',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        student.commentHistory.last,
        contains('father will visit campus next week'),
      );
    },
  );

  test(
    'AppUpdateService.compareVersions compares semantic versions accurately',
    () {
      expect(AppUpdateService.compareVersions('1.16.2', '1.17.0'), 1);
      expect(AppUpdateService.compareVersions('1.17.0', '1.16.2'), -1);
      expect(AppUpdateService.compareVersions('1.17.0', '1.17.0'), 0);
      expect(AppUpdateService.compareVersions('v1.17.0+33', 'v1.17.1'), 1);
      expect(AppUpdateService.compareVersions('1.17.0', '2.0.0'), 1);
      expect(AppUpdateService.compareVersions('1.17.0', '1.16.99'), -1);
    },
  );

  test('AppUpdateService.checkForUpdates parses GitHub release and assets correctly', () async {
    final mockClient = MockClient((request) async {
      expect(request.url.path, '/repos/jiatachira/LeadPilot/releases/latest');
      return http.Response(
        jsonEncode({
          'tag_name': 'v1.18.0',
          'name': 'LeadPilot v1.18.0 - Direct Updates',
          'body': '### What\'s New\n* Added in-app updater\n* Bug fixes',
          'html_url':
              'https://github.com/jiatachira/LeadPilot/releases/tag/v1.18.0',
          'published_at': '2026-11-20T08:00:00Z',
          'assets': [
            {
              'name': 'app-release.apk',
              'browser_download_url': 'https://github.com/jiatachira/LeadPilot/releases/download/v1.18.0/app-release.apk',
              'size': 63892011,
            },
          ],
        }),
        200,
      );
    });

    final service = AppUpdateService(client: mockClient);
    final info = await service.checkForUpdates(currentVersion: '1.17.0');

    expect(info.hasUpdate, isTrue);
    expect(info.latestVersion, '1.18.0');
    expect(
      info.downloadUrl,
      'https://github.com/jiatachira/LeadPilot/releases/download/v1.18.0/app-release.apk',
    );
    expect(info.releaseTitle, 'LeadPilot v1.18.0 - Direct Updates');
    expect(info.releaseNotes, contains('Added in-app updater'));
    expect(info.apkSize, 63892011);
  });

  test(
    'AppUpdateService.checkForUpdates handles 404 no releases gracefully',
    () async {
      final mockClient = MockClient((request) async {
        return http.Response('{"message":"Not Found"}', 404);
      });

      final service = AppUpdateService(client: mockClient);
      final info = await service.checkForUpdates(currentVersion: '1.17.0');

      expect(info.hasUpdate, isFalse);
      expect(info.currentVersion, '1.17.0');
    },
  );

  testWidgets(
    'showAppUpdateDialog renders details, downloads with progress, and triggers installer',
    (tester) async {
      String installedPath = '';
      const updateInfo = AppUpdateInfo(
        currentVersion: '1.17.0',
        latestVersion: '1.18.0',
        hasUpdate: true,
        releaseTitle: 'LeadPilot v1.18.0',
        releaseNotes: 'Performance improvements and bug fixes.',
        downloadUrl: 'https://example.com/app-release.apk',
        releaseUrl:
            'https://github.com/jiatachira/LeadPilot/releases/tag/v1.18.0',
        apkSize: 2048,
      );

      final mockHttpClient = MockClient((request) async {
        return http.Response.bytes(
          List<int>.filled(2048, 42),
          200,
          headers: {'content-length': '2048'},
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showAppUpdateDialog(
                    context,
                    updateInfo,
                    httpClient: mockHttpClient,
                    onInstallApk: (path) async {
                      installedPath = path;
                    },
                  ),
                  child: const Text('Show Dialog'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show Dialog'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('app_update_dialog')), findsOneWidget);
      expect(find.text('New Update Available'), findsOneWidget);
      expect(find.text('v1.17.0'), findsOneWidget);
      expect(find.text('v1.18.0'), findsOneWidget);
      expect(find.text("What's New:"), findsOneWidget);
      expect(
        find.text('Performance improvements and bug fixes.'),
        findsOneWidget,
      );

      final updateNowBtn = find.byKey(const Key('update_now_button'));
      expect(updateNowBtn, findsOneWidget);
      await tester.tap(updateNowBtn);
      await tester.pump();
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      expect(installedPath.endsWith('LeadPilot-update.apk'), isTrue);
      expect(find.text('Update Ready!'), findsOneWidget);
      expect(find.byKey(const Key('install_now_button')), findsOneWidget);
    },
  );

  testWidgets(
    'Settings displays App Updates card and allows manual check and toggle',
    (tester) async {
      final store = MemoryAppSettingsStore();
      final updateService = AppUpdateService(
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'tag_name': 'v1.18.2',
              'name': 'LeadPilot v1.18.2',
              'body': 'Current release',
              'html_url': 'https://github.com/jiatachira/LeadPilot/releases/tag/v1.18.2',
              'assets': [],
            }),
            200,
          );
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => SettingsHubSheet(
                    themeMode: ThemeMode.system,
                    onThemeModeChanged: (_) async {},
                    isSheetConnected: true,
                    hasActiveFilters: false,
                    biometricEnabled: false,
                    onBiometricChanged: (_) async {},
                    settingsStore: store,
                    updateService: updateService,
                  ),
                ),
                child: const Text('Open Settings'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Updates & About'), 100);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Updates & About'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Updates & About'));
      await tester.pumpAndSettle();

      final checkBtn = find.byKey(const Key('check_updates_button'));
      await tester.ensureVisible(checkBtn);
      await tester.pumpAndSettle();

      expect(find.text('Updates & About'), findsOneWidget);
      expect(find.text('Check for Updates'), findsOneWidget);
      expect(find.text('Auto-check on Startup'), findsOneWidget);

      // Tap Check for Updates
      await tester.tap(checkBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('LeadPilot is up to date (v1.29.1).'), findsOneWidget);

      // Toggle Auto-check
      final switchFinder = find.byKey(const Key('auto_check_updates_switch'));
      await tester.tap(switchFinder);
      await tester.pump();
      expect(await store.readAutoCheckUpdates(), isFalse);
    },
  );

  test('formatStudentHistoryForPrompt includes all chronological call attempts, dates, and statuses', () {
    const studentWithHistory = Student(
      name: 'Nimal Silva',
      phone: '0779988776',
      callStatus: 'Follow-up',
      comment: 'Wants evening callback',
      attempts: [
        CallAttempt(
          dateTime: '2026-11-10 10:30 AM',
          status: 'No Answer',
          comment: 'Ringing, no response',
        ),
        CallAttempt(
          dateTime: '2026-11-12 02:15 PM',
          status: 'Connected',
          comment: 'Spoke with mother; student is doing 2026 A/L Maths',
        ),
      ],
      commentHistory: ['2026-11-08 — Web form lead received'],
    );

    final historyText = formatStudentHistoryForPrompt(studentWithHistory);

    expect(historyText, contains('2026-11-08'));
    expect(historyText, contains('Web form lead received'));
    expect(historyText, contains('2026-11-10 10:30 AM'));
    expect(historyText, contains('No Answer'));
    expect(historyText, contains('Ringing, no response'));
    expect(historyText, contains('2026-11-12 02:15 PM'));
    expect(historyText, contains('Connected'));
    expect(historyText, contains('Spoke with mother'));
  });

  test('GeminiService sends complete chronological call history with dates and statuses in prompt', () async {
    String capturedPrompt = '';
    final mockClient = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      capturedPrompt = body['contents'][0]['parts'][0]['text'] as String;
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Hi Nimal! Following up from LNBTI.'},
                ],
              },
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = GeminiService(client: mockClient);
    const student = Student(
      name: 'Nimal Silva',
      phone: '0779988776',
      callStatus: 'Interested',
      attempts: [
        CallAttempt(
          dateTime: '2026-11-14 09:00 AM',
          status: 'No Answer',
          comment: 'Line busy',
        ),
        CallAttempt(
          dateTime: '2026-11-16 03:30 PM',
          status: 'Interested',
          comment:
              'Asked for Software Engineering degree fees and Japanese classes',
        ),
      ],
    );

    await service.generateFollowUp(
      apiKey: 'test_key',
      student: student,
      language: 'English',
    );

    expect(
      capturedPrompt,
      contains('Complete Call & Interaction History (Chronological):'),
    );
    expect(capturedPrompt, contains('2026-11-14 09:00 AM'));
    expect(capturedPrompt, contains('Line busy'));
    expect(capturedPrompt, contains('2026-11-16 03:30 PM'));
    expect(
      capturedPrompt,
      contains('Software Engineering degree fees and Japanese classes'),
    );
    expect(capturedPrompt, contains('USE OF COMPLETE CALL HISTORY'));
  });

  testWidgets(
    'GeminiAiMessageSheet displays past interactions count analyzed by AI',
    (tester) async {
      final store = MemoryAppSettingsStore();
      const student = Student(
        name: 'Saman Kumara',
        phone: '0712345678',
        callStatus: 'Interested',
        attempts: [
          CallAttempt(
            dateTime: '2026-11-15 10:00 AM',
            status: 'No Answer',
            comment: 'No reply',
          ),
          CallAttempt(
            dateTime: '2026-11-18 11:30 AM',
            status: 'Interested',
            comment: 'Requested brochure',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GeminiAiMessageSheet(
              student: student,
              initialApiKey: 'test_api_key',
              settingsStore: store,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('2 past interaction(s) analyzed by AI'), findsOneWidget);
      expect(find.textContaining('Requested brochure'), findsOneWidget);
    },
  );

  test(
    'WhatsAppTemplate supports document attachments and JSON serialization',
    () {
      const templateWithDoc = WhatsAppTemplate(
        id: 'doc_1',
        name: 'Brochure Template',
        message: 'Hello {name}, find attached the syllabus.',
        documentPath: '/storage/syllabus.pdf',
        documentName: 'syllabus.pdf',
      );

      expect(templateWithDoc.hasDocument, isTrue);
      expect(templateWithDoc.documentPath, '/storage/syllabus.pdf');
      expect(templateWithDoc.documentName, 'syllabus.pdf');

      final json = templateWithDoc.toJson();
      expect(json['documentPath'], '/storage/syllabus.pdf');
      expect(json['documentName'], 'syllabus.pdf');

      final fromJson = WhatsAppTemplate.fromJson(json);
      expect(fromJson.hasDocument, isTrue);
      expect(fromJson.name, 'Brochure Template');
      expect(fromJson.documentPath, '/storage/syllabus.pdf');
      expect(fromJson.documentName, 'syllabus.pdf');

      final cleared = templateWithDoc.copyWith(clearDocument: true);
      expect(cleared.hasDocument, isFalse);
      expect(cleared.documentPath, isNull);
      expect(cleared.documentName, isNull);
    },
  );

  test('WhatsAppSendPayload handles text and multiple documents correctly', () {
    const payload = WhatsAppSendPayload(
      message: 'Hello Student',
      documentPaths: ['/path/to/doc1.pdf', '/path/to/doc2.pdf'],
    );
    expect(payload.hasDocuments, isTrue);
    expect(payload.documentPaths.length, 2);

    const textOnly = WhatsAppSendPayload(message: 'Just text');
    expect(textOnly.hasDocuments, isFalse);
    expect(textOnly.documentPaths, isEmpty);
  });

  testWidgets(
    'WhatsApp Template picker allows multi-selecting and combining templates with documents',
    (tester) async {
      final student = Student(name: 'Nimal Perera', phone: '0771234567');

      final templates = [
        const WhatsAppTemplate(
          id: 't1',
          name: 'Greeting',
          message: 'Hello {name}, welcome to our institute!',
        ),
        const WhatsAppTemplate(
          id: 't2',
          name: 'Curriculum PDF',
          message: 'Here is the course syllabus.',
          documentPath: '/mock/syllabus.pdf',
          documentName: 'syllabus.pdf',
        ),
      ];

      WhatsAppSendPayload? dispatchedResult;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  dispatchedResult =
                      await showModalBottomSheet<WhatsAppSendPayload>(
                        context: ctx,
                        isScrollControlled: true,
                        builder: (_) => WhatsAppTemplatePickerSheet(
                          student: student,
                          templates: templates,
                          onManageTemplates: () {},
                        ),
                      );
                },
                child: const Text('Open Picker'),
              ),
            ),
          ),
        ),
      );

      // Open sheet
      await tester.tap(find.text('Open Picker'));
      await tester.pumpAndSettle();

      expect(find.text('Select Template'), findsOneWidget);
      expect(find.text('Greeting'), findsOneWidget);
      expect(find.text('Curriculum PDF'), findsOneWidget);
      expect(find.text('syllabus.pdf'), findsOneWidget);

      // Switch to Multi-Select
      await tester.tap(find.text('Multi-Select'));
      await tester.pumpAndSettle();

      expect(find.text('Done'), findsOneWidget);

      // Select both templates
      await tester.tap(find.text('Greeting'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Curriculum PDF'));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);
      expect(find.text('Send 2 Templates (1 with docs)'), findsOneWidget);

      // Tap Send
      await tester.tap(find.text('Send 2 Templates (1 with docs)'));
      await tester.pumpAndSettle();

      expect(dispatchedResult, isNotNull);
      expect(
        dispatchedResult!.message,
        'Hello Nimal Perera, welcome to our institute!\n\nHere is the course syllabus.',
      );
      expect(dispatchedResult!.documentPaths, ['/mock/syllabus.pdf']);
    },
  );

  test('WhatsAppTemplate allows document only without message text', () {
    const docOnlyTemplate = WhatsAppTemplate(
      id: 'doc_only_1',
      name: 'Fee Structure PDF',
      message: '',
      documentPath: '/mock/fees.pdf',
      documentName: 'fees.pdf',
    );

    expect(docOnlyTemplate.hasDocument, isTrue);
    expect(docOnlyTemplate.message, isEmpty);

    final json = docOnlyTemplate.toJson();
    final restored = WhatsAppTemplate.fromJson(json);
    expect(restored.hasDocument, isTrue);
    expect(restored.message, isEmpty);
    expect(restored.documentName, 'fees.pdf');
  });

  testWidgets(
    'WhatsApp Template picker sends template with document only when message is empty',
    (tester) async {
      final student = Student(name: 'Kasun Dias', phone: '0711111111');

      final templates = [
        const WhatsAppTemplate(
          id: 'doc_only',
          name: 'Prospectus PDF',
          message: '',
          documentPath: '/mock/prospectus.pdf',
          documentName: 'prospectus.pdf',
        ),
      ];

      WhatsAppSendPayload? dispatchedResult;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  dispatchedResult =
                      await showModalBottomSheet<WhatsAppSendPayload>(
                        context: ctx,
                        isScrollControlled: true,
                        builder: (_) => WhatsAppTemplatePickerSheet(
                          student: student,
                          templates: templates,
                          onManageTemplates: () {},
                        ),
                      );
                },
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('Prospectus PDF'), findsOneWidget);
      expect(find.text('prospectus.pdf'), findsOneWidget);

      // Tap single template
      await tester.tap(find.text('Prospectus PDF'));
      await tester.pumpAndSettle();

      expect(dispatchedResult, isNotNull);
      expect(dispatchedResult!.message, isEmpty);
      expect(dispatchedResult!.documentPaths, ['/mock/prospectus.pdf']);
      expect(dispatchedResult!.hasDocuments, isTrue);
    },
  );

  testWidgets(
    'BulkDispatchSheet processes students in queue with personalized text and skip support',
    (tester) async {
      final students = [
        Student(name: 'Amal Silva', phone: '0712345678'),
        Student(name: 'Bimal Fernando', phone: '0723456789'),
      ];

      const payload = WhatsAppSendPayload(
        message: 'Hello {name}, your course starts soon!',
        documentPaths: ['/mock/brochure.pdf'],
      );

      final dispatched = <({String studentName, String text})>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BulkDispatchSheet(
              students: students,
              payload: payload,
              isSms: false,
              onDispatch: (student, text) async {
                dispatched.add((studentName: student.name, text: text));
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bulk WhatsApp Queue'), findsOneWidget);
      expect(find.text('2 students in queue'), findsOneWidget);
      expect(find.text('Amal Silva'), findsWidgets);
      expect(
        find.text('Hello Amal Silva, your course starts soon!'),
        findsOneWidget,
      );
      expect(find.text('1 document(s) attached'), findsOneWidget);

      // Send first student
      await tester.tap(find.text('Send to Amal'));
      await tester.pumpAndSettle();

      expect(dispatched.length, 1);
      expect(dispatched[0].studentName, 'Amal Silva');
      expect(dispatched[0].text, 'Hello Amal Silva, your course starts soon!');

      // Now on Bimal
      expect(find.text('Bimal Fernando'), findsWidgets);
      expect(
        find.text('Hello Bimal Fernando, your course starts soon!'),
        findsOneWidget,
      );

      // Skip second student
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      // All done
      expect(find.text('All Messages Dispatched!'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    },
  );

  test('formatCallDuration correctly formats various time intervals', () {
    expect(formatCallDuration(225), '3 mins 45 secs');
    expect(formatCallDuration(60), '1 min');
    expect(formatCallDuration(65), '1 min 05 secs');
    expect(formatCallDuration(120), '2 mins');
    expect(formatCallDuration(121), '2 mins 01 sec');
    expect(formatCallDuration(45), '45 secs');
    expect(formatCallDuration(1), '1 sec');
    expect(formatCallDuration(0), '0s');
    expect(formatCallDuration(-5), '0s');
  });

  testWidgets(
    'Settings displays Direct In-App Calling toggle and updates store',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CallerIdService.channel, (call) async {
        if (call.method == 'isCallerIdEnabled') return true;
        if (call.method == 'canDrawOverlays') return true;
        if (call.method == 'hasPhonePermissions') return true;
        if (call.method == 'getCachedStudentCount') return 5;
        if (call.method == 'isIgnoringBatteryOptimizations') return true;
        return true;
      });

      final settingsStore = MemoryAppSettingsStore()..pin = '2580';
      await tester.pumpWidget(testApp(settingsStore: settingsStore));
      await tester.pumpAndSettle();
      await enterPin(tester, '2580');
      await tester.pumpAndSettle();

      await openSettings(tester);
      await tester.tap(find.text('Calling'));
      await tester.pumpAndSettle();

      final directCallingFinder = find.text('Direct In-App Calling');
      await tester.ensureVisible(directCallingFinder);
      await tester.pumpAndSettle();

      expect(directCallingFinder, findsOneWidget);
      expect(
        find.text(
          'Call directly without opening dialpad • Keep LeadPilot in front',
        ),
        findsOneWidget,
      );

      // Verify toggle action
      await tester.tap(directCallingFinder);
      await tester.pumpAndSettle();
      expect(await settingsStore.readDirectCalling(), isFalse);

      await tester.tap(directCallingFinder);
      await tester.pumpAndSettle();
      expect(await settingsStore.readDirectCalling(), isTrue);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CallerIdService.channel, null);
    },
  );

  testWidgets(
    'WhatsAppTemplatePickerSheet with isBulk: true preserves {name} placeholder for bulk dispatch',
    (tester) async {
      final student = Student(name: 'First Student', phone: '0711111111');
      final templates = [
        const WhatsAppTemplate(
          id: 'test_t1',
          name: 'Welcome Template',
          message: 'Hello {name}, welcome to class!',
        ),
      ];

      WhatsAppSendPayload? payload;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  payload = await showModalBottomSheet<WhatsAppSendPayload>(
                    context: ctx,
                    builder: (_) => WhatsAppTemplatePickerSheet(
                      student: student,
                      templates: templates,
                      onManageTemplates: () {},
                      isBulk: true,
                    ),
                  );
                },
                child: const Text('Open Picker'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Picker'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Welcome Template'));
      await tester.pumpAndSettle();

      expect(payload, isNotNull);
      // Confirms {name} was preserved and NOT burnt with 'First Student'
      expect(payload!.message, 'Hello {name}, welcome to class!');
    },
  );

  test('formatCallTimer formats elapsed seconds into mm:ss monospace clock', () {
    expect(formatCallTimer(0), '00:00');
    expect(formatCallTimer(9), '00:09');
    expect(formatCallTimer(45), '00:45');
    expect(formatCallTimer(60), '01:00');
    expect(formatCallTimer(125), '02:05');
    expect(formatCallTimer(3600), '60:00');
    expect(formatCallTimer(-5), '00:00');
  });

  test('MemoryAppSettingsStore stores and reads directCalling, preferredSimSlot, and preferredCallingApp', () async {
    final store = MemoryAppSettingsStore();
    expect(await store.readDirectCalling(), isTrue);
    expect(await store.readPreferredSimSlot(), -1);
    expect(await store.readPreferredCallingApp(), '');

    await store.saveDirectCalling(false);
    expect(await store.readDirectCalling(), isFalse);

    await store.savePreferredSimSlot(1);
    expect(await store.readPreferredSimSlot(), 1);

    await store.savePreferredCallingApp('com.google.android.dialer');
    expect(await store.readPreferredCallingApp(), 'com.google.android.dialer');
  });

  testWidgets('Settings displays Direct In-App Calling toggle', (tester) async {
    final store = MemoryAppSettingsStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsHubSheet(
            themeMode: ThemeMode.system,
            onThemeModeChanged: (_) async {},
            isSheetConnected: true,
            hasActiveFilters: false,
            biometricEnabled: false,
            onBiometricChanged: (_) async {},
            settingsStore: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Calling'));
    await tester.pumpAndSettle();

    expect(find.text('Direct In-App Calling'), findsOneWidget);
    expect(find.text('Floating Call Head (1-Tap End Call)'), findsNothing);
  });

  testWidgets(
    'StudentCard triggers onCall via Call button and onWhatsApp via action menu',
    (tester) async {
      bool callTriggered = false;
      bool whatsAppTriggered = false;
      const student = Student(name: 'Saman Silva', phone: '0771234567');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudentCard(
              student: student,
              onTap: () {},
              onLongPress: () {},
              onCall: () => callTriggered = true,
              onWhatsApp: () => whatsAppTriggered = true,
              onSms: () {},
              onNote: () {},
              onSaveContact: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Call student'));
      await tester.pumpAndSettle();
      expect(callTriggered, isTrue);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('WhatsApp'));
      await tester.pumpAndSettle();
      expect(whatsAppTriggered, isTrue);
      expect(find.text('Saman Silva'), findsOneWidget);
    },
  );

  test(
    'Student pre-computes searchIndex and caches parsed dates for fast search and sort',
    () {
      const student = Student(
        name: 'Nimal Jayawardena',
        phone: '0714567890',
        location: 'Kandy',
        callStatus: 'Interested',
        addedDate: '2026-11-20',
        nextCallDateTime: '2026-11-25 10:00 AM',
        comment: 'Very keen on IT degree',
      );

      expect(student.searchIndex, contains('nimal jayawardena'));
      expect(student.searchIndex, contains('0714567890'));
      expect(student.searchIndex, contains('kandy'));
      expect(student.searchIndex, contains('interested'));
      expect(student.searchIndex, contains('very keen on it degree'));

      expect(student.parsedAddedDate, isNotNull);
      expect(student.parsedAddedDate!.year, 2026);
      expect(student.parsedNextCallDate, isNotNull);
      expect(student.parsedNextCallDate!.year, 2026);
    },
  );

  test(
    'Clean Architecture: exports all modular components and version is 1.29.1',
    () {
      expect(kAppVersion, '1.29.1');
      final store = MemoryAppSettingsStore();
      expect(store, isNotNull);
      const student = Student(name: 'Enterprise Lead', phone: '0771234567');
      expect(student.name, 'Enterprise Lead');
    },
  );

  testWidgets(
    'Segmented button displays dynamic counts for All, New, and Today',
    (tester) async {
      final today = DateTime.now();
      final todayStr =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')} 14:00';
      final settingsStore = MemoryAppSettingsStore()
        ..pin = '2580'
        ..sheetConfig = 'https://script.google.com/macros/s/test/exec';
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'students': [
              {
                'name': 'Lead 1',
                'contact': '0711111111',
                'callStatus': 'Pending',
              },
              {
                'name': 'Lead 2',
                'contact': '0722222222',
                'callStatus': 'Follow-up',
                'nextCallDateTime': todayStr,
              },
              {
                'name': 'Lead 3',
                'contact': '0733333333',
                'callStatus': 'Interested',
              },
            ],
          }),
          200,
        ),
      );

      await tester.pumpWidget(
        testApp(httpClient: client, settingsStore: settingsStore),
      );
      await tester.pumpAndSettle();
      await enterPin(tester, '2580');
      await tester.pumpAndSettle();

      final segmentedButton =
          find.byWidgetPredicate((w) => w is SegmentedButton);
      expect(segmentedButton, findsOneWidget);
      expect(
        find.descendant(of: segmentedButton, matching: find.text('All')),
        findsWidgets,
      );
      expect(
        find.descendant(of: segmentedButton, matching: find.text('3')),
        findsWidgets,
      );
      expect(
        find.descendant(of: segmentedButton, matching: find.text('New')),
        findsWidgets,
      );
      expect(
        find.descendant(of: segmentedButton, matching: find.text('Today')),
        findsWidgets,
      );
      expect(
        find.descendant(of: segmentedButton, matching: find.text('1')),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'StudentCard has direct 1-tap History and Call buttons on card, and EditStudentSheet has WhatsApp next to Call',
    (tester) async {
      bool callTapped = false;
      bool waTappedOnCard = false;
      bool historyTapped = false;

      const student = Student(name: 'Quick Lead With A Full Long Name', phone: '0719876543');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudentCard(
              student: student,
              onTap: () {},
              onLongPress: () {},
              onCall: () => callTapped = true,
              onWhatsApp: () => waTappedOnCard = true,
              onSms: () {},
              onNote: () => historyTapped = true,
              onSaveContact: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Call student'), findsOneWidget);
      expect(find.byTooltip('Call history'), findsOneWidget);
      expect(find.byTooltip('WhatsApp chat'), findsNothing);

      await tester.tap(find.byTooltip('Call student'));
      expect(callTapped, isTrue);

      await tester.tap(find.byTooltip('Call history'));
      expect(historyTapped, isTrue);
      expect(waTappedOnCard, isFalse);

      // Now verify EditStudentSheet header has WhatsApp button next to Call button
      Student? waStudent;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditStudentSheet(
              student: student,
              onWhatsApp: (s) => waStudent = s,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('WhatsApp ${student.name}'), findsOneWidget);
      expect(find.byTooltip('Call ${student.name}'), findsOneWidget);
      await tester.tap(find.byTooltip('WhatsApp ${student.name}'));
      expect(waStudent?.name, student.name);
    },
  );

  testWidgets(
    'EditStudentSheet displays student details summary card on log call screen',
    (tester) async {
      const student = Student(
        name: 'Kasun Perera',
        phone: '0771234567',
        location: 'Kandy',
        examType: 'A/L',
        examYear: '2025',
        olEnglish: 'A',
        olMaths: 'B',
        whatsappNumber: '0779998888',
        source: 'Facebook Ad',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EditStudentSheet(
              student: student,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Student Details'), findsOneWidget);
      expect(find.text('A/L 2025'), findsOneWidget);
      expect(find.text('Kandy'), findsOneWidget);
      expect(find.text('O/L Eng: A'), findsOneWidget);
      expect(find.text('O/L Maths: B'), findsOneWidget);
      expect(find.text('0779998888'), findsOneWidget);
      expect(find.text('Source: Facebook Ad'), findsOneWidget);
    },
  );

  testWidgets(
    'ManageGeminiAiSheet switches to Groq provider and allows configuring Groq API key',
    (tester) async {
      final store = MemoryAppSettingsStore();
      final mockClient = MockClient((request) async {
        if (request.url.host.contains('groq.com')) {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'OK'}
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });
      final service = GeminiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManageGeminiAiSheet(
              settingsStore: store,
              geminiService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Groq Cloud (Free) tab
      await tester.tap(find.text('Groq Cloud (Free)'));
      await tester.pumpAndSettle();

      expect(find.text('Ultra-Fast Groq Cloud (Free)'), findsOneWidget);
      expect(find.text('Selected Groq Model'), findsOneWidget);

      // Enter key
      await tester.enterText(
        find.widgetWithText(TextField, 'Groq API Key'),
        'gsk_test1234567890abcdef',
      );
      await tester.pumpAndSettle();

      // Test connection
      final testFinder = find.text('Test Key');
      await tester.ensureVisible(testFinder);
      await tester.tap(testFinder);
      await tester.pumpAndSettle();

      final matches = find.byType(SelectableText);
      expect(matches, findsOneWidget);
      expect(find.textContaining('Connected to Groq Cloud'), findsOneWidget);

      // Save Key
      final saveFinder = find.text('Save Key');
      await tester.ensureVisible(saveFinder);
      await tester.tap(saveFinder);
      await tester.pumpAndSettle();

      expect(await store.readAiProvider(), 'groq');
      expect(await store.readGroqApiKey(), 'gsk_test1234567890abcdef');
    },
  );

  testWidgets(
    'EditStudentSheet saves details directly via onDetailsSaved without adding a call attempt',
    (tester) async {
      const student = Student(
        name: 'Nimal Perera',
        phone: '0771234567',
        location: 'Colombo',
        callStatus: 'Interested',
      );

      Student? savedStudent;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<Student>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => EditStudentSheet(
                      student: student,
                      onDetailsSaved: (prev, updated) async {
                        savedStudent = updated;
                      },
                    ),
                  );
                },
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit details'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('edit-name-input')),
        'Nimal S. Perera',
      );
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Sheet should pop directly and onDetailsSaved should be invoked
      expect(savedStudent, isNotNull);
      expect(savedStudent!.name, 'Nimal S. Perera');
      expect(savedStudent!.attempts, isEmpty);
      expect(savedStudent!.commentHistory, isEmpty);
      expect(find.text('Edit Details · Nimal Perera'), findsNothing);
    },
  );
}
