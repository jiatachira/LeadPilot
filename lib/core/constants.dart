part of '../main.dart';

const _navy = Color(0xFF142B4A);
const _green = Color(0xFF159A76);
const _canvas = Color(0xFFF4F7FA);
const _muted = Color(0xFF748194);
const String kAppVersion = '1.28.0';
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

