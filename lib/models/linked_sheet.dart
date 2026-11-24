part of '../main.dart';

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

