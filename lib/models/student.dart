part of '../main.dart';

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

  static final _searchIndexExpando = Expando<String>();
  static final _addedDateExpando = Expando<DateTime>();
  static final _nextCallDateExpando = Expando<DateTime>();

  String get searchIndex {
    final cached = _searchIndexExpando[this];
    if (cached != null) return cached;
    final sb = StringBuffer();
    sb.write(name.toLowerCase());
    sb.write(' ');
    sb.write(phone.toLowerCase());
    sb.write(' ');
    sb.write(location.toLowerCase());
    sb.write(' ');
    sb.write(callStatus.toLowerCase());
    sb.write(' ');
    sb.write(comment.toLowerCase());
    for (final c in commentHistory) {
      sb.write(' ');
      sb.write(c.toLowerCase());
    }
    for (final a in attempts) {
      sb.write(' ');
      sb.write(a.status.toLowerCase());
      sb.write(' ');
      sb.write(a.comment.toLowerCase());
    }
    final result = sb.toString();
    _searchIndexExpando[this] = result;
    return result;
  }

  DateTime? get parsedAddedDate {
    final cached = _addedDateExpando[this];
    if (cached != null) return cached;
    final parsed = tryParseDate(addedDate);
    if (parsed != null) _addedDateExpando[this] = parsed;
    return parsed;
  }

  DateTime? get parsedNextCallDate {
    final cached = _nextCallDateExpando[this];
    if (cached != null) return cached;
    final parsed = tryParseDate(nextCallDateTime);
    if (parsed != null) _nextCallDateExpando[this] = parsed;
    return parsed;
  }
}

