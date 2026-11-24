part of '../main.dart';

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

