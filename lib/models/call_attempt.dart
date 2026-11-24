part of '../main.dart';

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

