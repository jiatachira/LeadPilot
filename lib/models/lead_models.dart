part of '../main.dart';

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


enum _StudentCardAction { edit, selectMultiple }

enum _LeadReportAction { notInterested, notPotential, inactive }

