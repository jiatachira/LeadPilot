part of '../main.dart';

class SheetApiException implements Exception {
  const SheetApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GoogleSheetService {
  GoogleSheetService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  static const _timeout = Duration(seconds: 20);

  Future<List<Student>> fetchStudentsFromSheet(String webAppUrl) async {
    final response = await _client
        .get(
          _endpoint(webAppUrl),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SheetApiException(
        'Sheet request failed with HTTP ${response.statusCode}.',
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const SheetApiException(
        'The web app returned invalid JSON. Return a JSON list of students.',
      );
    }

    final dynamic rows;
    if (decoded is List<dynamic>) {
      rows = decoded;
    } else if (decoded is Map<String, dynamic>) {
      rows = decoded['students'] ?? decoded['data'];
    } else {
      rows = null;
    }

    if (rows is! List<dynamic>) {
      throw const SheetApiException(
        'Expected a JSON list or an object containing a "students" list.',
      );
    }

    return rows.map((row) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('Student rows must be JSON objects.');
      }
      return Student.fromJson(row);
    }).toList();
  }

  Future<void> addStudentToSheet(String webAppUrl, Student student) =>
      _sendStudent(webAppUrl, student, action: 'add');

  Future<void> updateStudentInSheet(
    String webAppUrl,
    Student student, {
    String? previousPhone,
  }) => _sendStudent(
    webAppUrl,
    student,
    action: 'update',
    previousContact: previousPhone ?? student.phone,
  );

  Future<void> _sendStudent(
    String webAppUrl,
    Student student, {
    required String action,
    String? previousContact,
  }) async {
    final response = await _client
        .post(
          _endpoint(webAppUrl),
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'text/plain; charset=utf-8',
          },
          body: jsonEncode({
            'action': action,
            'name': student.name,
            'contact': student.phone,
            if (action == 'update')
              'previousContact': previousContact ?? student.phone,
            'source': student.source,
            'addedDate': student.addedDate,
            'location': student.location,
            'examType': student.examType,
            'examYear': student.examYear,
            'olEnglish': student.olEnglish,
            'olMaths': student.olMaths,
            'whatsappNumber': student.whatsappNumber,
            'whatsappSameAsContact': student.whatsappSameAsContact,
            'callStatus': student.callStatus,
            'nextCallDateTime': student.nextCallDateTime,
            'comment': student.comment,
            'commentHistory': student.commentHistory,
            'attempts': student.attempts
                .map((attempt) => attempt.toJson())
                .toList(),
            if (student.attempts.isNotEmpty)
              'latestAttempt': student.attempts.last.toJson(),
          }),
        )
        .timeout(_timeout);
    final redirectLocation = Uri.tryParse(response.headers['location'] ?? '');
    final redirectHost = redirectLocation?.host.toLowerCase() ?? '';
    final isAppsScriptContentRedirect =
        (response.statusCode == 302 ||
            response.statusCode == 303 ||
            response.statusCode == 307) &&
        (redirectHost == 'script.googleusercontent.com' ||
            redirectHost.endsWith('.googleusercontent.com') ||
            redirectHost.endsWith('google.com'));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Apps Script executes doPost before redirecting ContentService output.
      if (isAppsScriptContentRedirect) return;
      throw SheetApiException(
        'Could not ${action == 'add' ? 'add' : 'update'} the student in the sheet '
        '(HTTP ${response.statusCode}).',
      );
    }

    final body = response.body.trim();
    if (body.startsWith('{')) {
      final dynamic result;
      try {
        result = jsonDecode(body);
      } on FormatException {
        throw const SheetApiException(
          'The web app returned invalid JSON after saving the student.',
        );
      }
      if (result is Map<String, dynamic> && result['success'] == false) {
        throw SheetApiException(
          result['error']?.toString() ??
              'The sheet rejected the student ${action == 'add' ? 'addition' : 'update'}.',
        );
      }
    }
  }

  Uri _endpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !uri.path.endsWith('/exec')) {
      throw const SheetApiException(
        'Enter a valid HTTPS Google Apps Script Web App URL ending in /exec.',
      );
    }
    return uri;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

