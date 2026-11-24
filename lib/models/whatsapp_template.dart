part of '../main.dart';

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

