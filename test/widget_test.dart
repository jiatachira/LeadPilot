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
}) {
  return StudentCallApp(
    httpClient: httpClient,
    reminderScheduler: reminderScheduler ?? FakeReminderScheduler(),
    settingsStore: settingsStore ?? MemoryAppSettingsStore(),
    deviceContactsService: deviceContactsService,
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

Future<void> openSheetSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Google Sheets Sync'));
  await tester.tap(find.text('Google Sheets Sync'));
  await tester.pumpAndSettle();
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

  test('builds SMS composer links with normalized phone numbers', () {
    expect(smsComposerUri('070 106 1244').toString(), 'sms:+94701061244');
    expect(smsComposerUri('+1 (555) 010-1234').toString(), 'sms:+15550101234');
  });

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
    expect(shape.side.color, const Color(0xFFF0F2F5));
    expect(shape.side.width, 1.0);
    expect(find.text('0700000000'), findsOneWidget);
    final name = tester.widget<Text>(find.text(fullName));
    expect(name.maxLines, isNull);
    expect(name.overflow, isNull);
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

    expect(find.text('Your students'), findsOneWidget);
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
    expect(find.text('Your students'), findsOneWidget);
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

    await tester.tap(find.byTooltip('Lock app'));
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
    expect(find.text('Your students'), findsOneWidget);
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
    expect(find.text('Facebook'), findsNWidgets(2));
    expect(find.text('2 contacts • Keep in touch'), findsOneWidget);
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

    expect(find.textContaining('Synced'), findsOneWidget);
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
    expect(find.text('Sync failed'), findsOneWidget);
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
    expect(find.text('Update Mia Patel'), findsOneWidget);

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
    await tester.enterText(fields.at(7), 'Interested in A/L classes');
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

    final statusDropdown = find.byType(DropdownButtonFormField<String>).last;
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

    final reminderButton = find.text('Next call date & time (optional)');
    await tester.ensureVisible(reminderButton);
    await tester.tap(reminderButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Update Details'));
    await tester.tap(find.text('Update Details'));
    await tester.pumpAndSettle();
    expect(find.text('Allow exact call reminders'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(reminderScheduler.exactAlarmPermissionRequests, 1);
    expect(reminderScheduler.scheduled, hasLength(1));

    final update = requests.lastWhere((request) => request.method == 'POST');
    final payload = jsonDecode(update.body) as Map<String, dynamic>;
    expect(payload['action'], 'update');
    expect(payload['name'], 'Mia Fernando');
    expect(payload['contact'], '555-0199');
    expect(payload['previousContact'], '555-0104');
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
    expect(find.text('A/L'), findsOneWidget);
    expect(find.text('Future'), findsWidgets);
    expect(find.textContaining('Call · '), findsOneWidget);

    await tester.tap(find.text('Mia Fernando'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('View History'));
    await tester.tap(find.text('View History'));
    await tester.pumpAndSettle();
    expect(find.text('Call attempt history'), findsOneWidget);
    expect(find.text('Future'), findsWidgets);
    expect(find.textContaining('Interested in A/L classes'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Clear reminder'));
    await tester.tap(find.text('Clear reminder'));
    await tester.ensureVisible(find.text('Update Details'));
    await tester.tap(find.text('Update Details'));
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
    expect(find.text('Next call date & time (optional)'), findsOneWidget);

    await tester.ensureVisible(find.text('Next call date & time (optional)'));
    await tester.tap(find.text('Next call date & time (optional)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Next call date & time (optional)'), findsOneWidget);

    await tester.tap(find.text('Next call date & time (optional)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Next call date & time (optional)'), findsOneWidget);

    await tester.ensureVisible(find.text('Update Details'));
    await tester.tap(find.text('Update Details'));
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

    await tester.tap(find.text('New Leads'));
    await tester.pumpAndSettle();
    expect(find.text('New Lead'), findsOneWidget);
    expect(find.text('Follow-up Lead'), findsNothing);
    expect(find.text('Old Lead'), findsNothing);

    await tester.tap(find.text('Today Follow-up'));
    await tester.pumpAndSettle();
    expect(find.text('Follow-up Lead'), findsOneWidget);
    expect(find.text('New Lead'), findsNothing);

    await tester.tap(find.text('All Leads'));
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

    await tester.tap(find.byTooltip('Settings'));
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
    await tester.tap(find.text('New Leads'));
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
      final students = [
        {
          'name': 'Today Call',
          'contact': '555-0401',
          'addedDate': now.toIso8601String(),
          'nextCallDateTime': now
              .add(const Duration(hours: 1))
              .toIso8601String(),
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

      await tester.tap(find.text('Today Follow-up'));
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

    await tester.tap(find.byTooltip('Settings'));
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

    await tester.tap(find.text('New Leads'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
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

      expect(find.byTooltip('Comments'), findsNWidgets(2));
      expect(find.byTooltip('Open WhatsApp chat'), findsNWidgets(2));
      expect(find.byTooltip('Send SMS'), findsNWidgets(2));
      expect(find.byTooltip('Call student'), findsNWidgets(2));
      final pendingStudentCard = find.ancestor(
        of: find.text('Pending Student'),
        matching: find.byType(Card),
      );
      final saveContactButton = find.descendant(
        of: pendingStudentCard,
        matching: find.byTooltip('Save contact'),
      );
      expect(saveContactButton, findsOneWidget);
      await tester.ensureVisible(saveContactButton);
      await tester.tap(saveContactButton);
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
      expect(find.text('Update Details'), findsOneWidget);
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

    await tester.tap(find.byTooltip('Settings'));
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
    final searchField = tester.widget<TextField>(find.byType(TextField).first);
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

    await tester.tap(find.byTooltip('Comments'));
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

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
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
      final todayFutureCall = now.add(const Duration(hours: 2));
      final alreadyScheduledCall = now.add(const Duration(hours: 3));

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
          'nextCallDateTime':
              now.subtract(const Duration(hours: 1)).toIso8601String(),
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

      final commentField = find.byType(TextFormField).at(7);
      await tester.enterText(commentField, 'Offline call notes');
      await tester.ensureVisible(find.text('Update Details'));
      await tester.tap(find.text('Update Details'));
      await tester.pumpAndSettle();

      expect(settingsStore.offlineQueue, hasLength(1));
      expect(
        settingsStore.offlineQueue.first.student.comment,
        'Offline call notes',
      );
      expect(find.textContaining('queued'), findsWidgets);

      shouldFailPost = false;
      await tester.tap(find.text('Sync now'));
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

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('WhatsApp templates'));
      await tester.pumpAndSettle();

      expect(find.text('WhatsApp Templates'), findsOneWidget);
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

  testWidgets(
    'tapping WhatsApp action offers Custom and Template choices',
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

      final firstWhatsAppBtn = find.byTooltip('Open WhatsApp chat').first;
      await tester.tap(firstWhatsAppBtn);
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
    },
  );

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
            dateTime: now.subtract(const Duration(minutes: 30)).toIso8601String(),
            status: 'Line Busy',
            comment: '',
          ),
          CallAttempt(
            dateTime: now.subtract(const Duration(minutes: 10)).toIso8601String(),
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
      expect(find.text('🚨 5x No Answer'), findsOneWidget);

      await tester.tap(find.text('Kamal Perera'));
      await tester.pumpAndSettle();

      expect(find.text('Update Details'), findsOneWidget);
      await tester.ensureVisible(find.text('Update Details'));
      await tester.tap(find.text('Update Details'));
      await tester.pumpAndSettle();

      expect(find.text('Move to Inactive?'), findsOneWidget);
      expect(
        find.textContaining('Kamal Perera has not answered 6 consecutive times.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Move to Inactive'));
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

  testWidgets('Settings displays Incoming Caller ID toggle, test popup, and v1.11.1', (tester) async {
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

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    final testPopupFinder = find.text('Preview / Test Popup');
    await tester.ensureVisible(testPopupFinder);
    await tester.pumpAndSettle();

    expect(find.text('Caller ID'), findsOneWidget);
    expect(find.text('Incoming Caller ID Popup'), findsOneWidget);
    expect(testPopupFinder, findsOneWidget);
    expect(find.text('LeadPilot v1.12.4'), findsOneWidget);

    await tester.tap(testPopupFinder);
    await tester.pumpAndSettle();
    expect(find.text('Sample Caller ID popup displayed!'), findsOneWidget);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CallerIdService.channel, null);
  });

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
  });

  test(
      'GeminiService generates follow-up message using student context and mock client',
      () async {
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
                        'Hello Kamal, following up on your class fee inquiry!'
                  }
                ]
              }
            }
          ]
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
    const student = Student(
      name: 'Kamal Perera',
      phone: '0771234567',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WhatsAppChoiceSheet(student: student),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('Template'), findsOneWidget);
    expect(find.text('Generate with AI'), findsOneWidget);
    expect(find.text('Gemini'), findsOneWidget);
  });

  test('GeminiService.sanitizeApiKey correctly cleans messy input keys', () {
    expect(
      GeminiService.sanitizeApiKey('  "AIzaSyD1234567890abcdefghijklmnopqrst"  '),
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
      GeminiService.sanitizeApiKey('https://generativelanguage.googleapis.com?key=AIzaSyD1234567890abcdefghijklmnopqrst'),
      'AIzaSyD1234567890abcdefghijklmnopqrst',
    );
    expect(
      GeminiService.sanitizeApiKey('  `AIzaSyD1234567890abcdefghijklmnopqrst` \n'),
      'AIzaSyD1234567890abcdefghijklmnopqrst',
    );
    expect(
      GeminiService.looksLikeGoogleApiKey('AIzaSyD1234567890abcdefghijklmnopqrst'),
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
                  {'text': 'pong'}
                ]
              }
            }
          ]
        }),
        200,
      );
    });

    final successService = GeminiService(client: successClient);
    final res = await successService.testConnection('AIzaSyD1234567890abcdefghijklmnopqrst');
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
          }
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
            'message':
                'models/gemini-1.5-flash is not found for API version v1beta, or is not supported for generateContent. Call ModelService.ListModels to see the list of available models and their supported methods.',
            'status': 'NOT_FOUND',
          }
        }),
        404,
      );
    });

    final projectDisabledService =
        GeminiService(client: projectDisabledClient);
    final disabledRes = await projectDisabledService
        .testConnection('AQ.Ab8RN6L_nOJHLak9Aea9qBX5fMjc');
    expect(disabledRes.isSuccess, isFalse);
    expect(disabledRes.statusCode, 404);
    expect(disabledRes.message.contains('Generative Language API is disabled'), isTrue);
    expect(disabledRes.message.contains('Create API key in new project'), isTrue);
  });

  testWidgets('ManageGeminiAiSheet tests key and displays connection feedback', (tester) async {
    final mockClient = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'ok'}
                ]
              }
            }
          ]
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
    expect(find.text('Test Key'), findsOneWidget);

    await tester.tap(find.text('Test Key'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Connection successful'), findsOneWidget);
  });

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
                        'Hello Nimal, your tuition class starts next Monday!'
                  }
                ]
              }
            }
          ]
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
      templates.any((t) =>
          t.message == 'Hello {name}, your tuition class starts next Monday!'),
      isTrue,
    );
  });
}
