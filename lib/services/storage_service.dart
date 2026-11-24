part of '../main.dart';

class SecureAppSettingsStore implements AppSettingsStore {
  SecureAppSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _pinKey = 'student_call_pin';
  static const _sheetConfigKey = 'student_call_sheet_config';
  static const _sheetNameKey = 'student_call_sheet_name';
  static const _linkedSheetsKey = 'student_call_linked_sheets';
  static const _themeModeKey = 'student_call_theme_mode';
  static const _biometricEnabledKey = 'student_call_biometric_enabled';
  static const _offlineQueueKey = 'student_call_offline_queue';
  static const _cachedStudentsKey = 'student_call_cached_students';
  static const _whatsAppTemplatesKey = 'student_call_whatsapp_templates';
  static const _geminiApiKeyKey = 'student_call_gemini_api_key';
  static const _geminiModelKey = 'student_call_gemini_model';
  static const _aiProviderKey = 'student_call_ai_provider';
  static const _groqApiKeyKey = 'student_call_groq_api_key';
  static const _groqModelKey = 'student_call_groq_model';
  static const _companyDescriptionKey = 'student_call_company_description';
  static const _autoCheckUpdatesKey = 'student_call_auto_check_updates';
  static const _autoLogCallDurationKey = 'student_call_auto_log_call_duration';
  static const _directCallingKey = 'student_call_direct_calling';
  static const _preferredSimSlotKey = 'student_call_preferred_sim_slot';
  static const _preferredCallingAppKey = 'student_call_preferred_calling_app';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> readPin() => _storage.read(key: _pinKey);

  @override
  Future<void> savePin(String pin) => _storage.write(key: _pinKey, value: pin);

  @override
  Future<String> readSheetConfig() async =>
      await _storage.read(key: _sheetConfigKey) ?? '';

  @override
  Future<String> readSheetName() async =>
      await _storage.read(key: _sheetNameKey) ?? '';

  @override
  Future<List<LinkedSheet>> readLinkedSheets() async {
    final saved = await _storage.read(key: _linkedSheetsKey);
    if (saved == null || saved.isEmpty) return const [];
    final decoded = jsonDecode(saved);
    if (decoded is! List) {
      throw const FormatException('Saved linked sheets data is invalid.');
    }
    return decoded
        .asMap()
        .entries
        .map((entry) => LinkedSheet.fromJson(entry.value, index: entry.key))
        .toList();
  }

  @override
  Future<ThemeMode> readThemeMode() async =>
      _themeModeFromName(await _storage.read(key: _themeModeKey));

  @override
  Future<void> saveThemeMode(ThemeMode mode) =>
      _storage.write(key: _themeModeKey, value: mode.name);

  @override
  Future<bool> readBiometricEnabled() async {
    final val = await _storage.read(key: _biometricEnabledKey);
    return val == 'true';
  }

  @override
  Future<void> saveBiometricEnabled(bool enabled) =>
      _storage.write(key: _biometricEnabledKey, value: enabled.toString());

  @override
  Future<List<QueuedSheetAction>> readOfflineQueue() async {
    final saved = await _storage.read(key: _offlineQueueKey);
    if (saved == null || saved.isEmpty) return const [];
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((item) => QueuedSheetAction.fromJson(item))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> saveOfflineQueue(List<QueuedSheetAction> queue) =>
      _storage.write(
        key: _offlineQueueKey,
        value: jsonEncode(queue.map((item) => item.toJson()).toList()),
      );

  Future<File?> _getLocalCacheFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return File('${dir.path}/leadpilot_leads_db.json');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Student>> readCachedStudents() async {
    try {
      final file = await _getLocalCacheFile();
      if (file != null && await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is List) {
            return decoded
                .whereType<Map<String, dynamic>>()
                .map((item) => Student.fromJson(item))
                .toList();
          }
        }
      }
    } catch (_) {}

    final saved = await _storage.read(key: _cachedStudentsKey);
    if (saved == null || saved.isEmpty) return const [];
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) return const [];
      final students = decoded
          .whereType<Map<String, dynamic>>()
          .map((item) => Student.fromJson(item))
          .toList();
      unawaited(saveCachedStudents(students));
      return students;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> saveCachedStudents(List<Student> students) async {
    bool fileSaved = false;
    try {
      final file = await _getLocalCacheFile();
      if (file != null) {
        final tempFile = File('${file.path}.tmp');
        final payload = jsonEncode(students.map((s) => s.toJson()).toList());
        await tempFile.writeAsString(payload, flush: true);
        if (await file.exists()) {
          await file.delete();
        }
        await tempFile.rename(file.path);
        fileSaved = true;
      }
    } catch (_) {}

    if (!fileSaved) {
      try {
        await _storage.write(
          key: _cachedStudentsKey,
          value: jsonEncode(students.map((s) => s.toJson()).toList()),
        );
      } catch (_) {}
    }
    unawaited(CallerIdService.syncStudents(students));
  }

  @override
  Future<List<WhatsAppTemplate>> readWhatsAppTemplates() async {
    final saved = await _storage.read(key: _whatsAppTemplatesKey);
    if (saved == null) {
      return WhatsAppTemplate.defaultTemplates;
    }
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) return WhatsAppTemplate.defaultTemplates;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((item) => WhatsAppTemplate.fromJson(item))
          .toList();
    } catch (_) {
      return WhatsAppTemplate.defaultTemplates;
    }
  }

  @override
  Future<void> saveWhatsAppTemplates(List<WhatsAppTemplate> templates) =>
      _storage.write(
        key: _whatsAppTemplatesKey,
        value: jsonEncode(templates.map((t) => t.toJson()).toList()),
      );

  @override
  Future<String> readGeminiApiKey() async =>
      await _storage.read(key: _geminiApiKeyKey) ?? '';

  @override
  Future<void> saveGeminiApiKey(String key) =>
      _storage.write(key: _geminiApiKeyKey, value: key.trim());

  @override
  Future<String> readGeminiModel() async =>
      await _storage.read(key: _geminiModelKey) ?? 'gemini-1.5-flash';

  @override
  Future<void> saveGeminiModel(String model) =>
      _storage.write(key: _geminiModelKey, value: model.trim());

  @override
  Future<String> readCompanyDescription() async {
    final value = await _storage.read(key: _companyDescriptionKey);
    if (value == null || value.trim().isEmpty) {
      return _defaultCompanyDescription;
    }
    return value.trim();
  }

  @override
  Future<void> saveCompanyDescription(String description) =>
      _storage.write(
        key: _companyDescriptionKey,
        value: description.trim().isEmpty
            ? _defaultCompanyDescription
            : description.trim(),
      );

  @override
  Future<String> readAiProvider() async =>
      await _storage.read(key: _aiProviderKey) ?? 'gemini';

  @override
  Future<void> saveAiProvider(String provider) =>
      _storage.write(key: _aiProviderKey, value: provider.trim());

  @override
  Future<String> readGroqApiKey() async =>
      await _storage.read(key: _groqApiKeyKey) ?? '';

  @override
  Future<void> saveGroqApiKey(String key) =>
      _storage.write(key: _groqApiKeyKey, value: key.trim());

  @override
  Future<String> readGroqModel() async =>
      await _storage.read(key: _groqModelKey) ?? 'llama-3.3-70b-versatile';

  @override
  Future<void> saveGroqModel(String model) =>
      _storage.write(key: _groqModelKey, value: model.trim());

  @override
  Future<bool> readAutoCheckUpdates() async {
    final value = await _storage.read(key: _autoCheckUpdatesKey);
    return value != 'false';
  }

  @override
  Future<void> saveAutoCheckUpdates(bool enabled) =>
      _storage.write(key: _autoCheckUpdatesKey, value: enabled.toString());

  @override
  Future<bool> readAutoLogCallDuration() async {
    final value = await _storage.read(key: _autoLogCallDurationKey);
    return value != 'false';
  }

  @override
  Future<void> saveAutoLogCallDuration(bool enabled) =>
      _storage.write(key: _autoLogCallDurationKey, value: enabled.toString());

  @override
  Future<bool> readDirectCalling() async {
    final value = await _storage.read(key: _directCallingKey);
    return value != 'false';
  }

  @override
  Future<void> saveDirectCalling(bool enabled) =>
      _storage.write(key: _directCallingKey, value: enabled.toString());

  @override
  Future<int> readPreferredSimSlot() async {
    final value = await _storage.read(key: _preferredSimSlotKey);
    return int.tryParse(value ?? '') ?? -1;
  }

  @override
  Future<void> savePreferredSimSlot(int slot) =>
      _storage.write(key: _preferredSimSlotKey, value: slot.toString());

  @override
  Future<String> readPreferredCallingApp() async {
    final value = await _storage.read(key: _preferredCallingAppKey);
    return value ?? '';
  }

  @override
  Future<void> savePreferredCallingApp(String packageName) =>
      _storage.write(key: _preferredCallingAppKey, value: packageName);

  @override
  Future<void> saveSheetConfig(String url, {String name = ''}) async {
    final normalizedUrl = url.trim();
    final linkedSheets = await readLinkedSheets();
    final normalizedName = name.trim().isEmpty
        ? _defaultSheetName(normalizedUrl)
        : name.trim();
    final duplicateName = linkedSheets.any(
      (sheet) =>
          sheet.url != normalizedUrl &&
          sheet.name.toLowerCase() == normalizedName.toLowerCase(),
    );
    if (duplicateName) {
      throw StateError(
        'A linked sheet already uses the name "$normalizedName".',
      );
    }
    final updatedSheets = <LinkedSheet>[
      LinkedSheet(name: normalizedName, url: normalizedUrl),
      ...linkedSheets.where((sheet) => sheet.url != normalizedUrl),
    ];
    await _storage.write(key: _sheetConfigKey, value: normalizedUrl);
    await _storage.write(key: _sheetNameKey, value: normalizedName);
    await _storage.write(
      key: _linkedSheetsKey,
      value: jsonEncode(updatedSheets.map((sheet) => sheet.toJson()).toList()),
    );
  }
}

class MemoryAppSettingsStore implements AppSettingsStore {
  String? pin;
  String sheetConfig = '';
  String sheetName = '';
  ThemeMode themeMode = ThemeMode.system;
  bool biometricEnabled = false;
  String geminiApiKey = '';
  final List<LinkedSheet> linkedSheets = [];

  @override
  Future<String?> readPin() async => pin;

  @override
  Future<void> savePin(String value) async {
    pin = value;
  }

  @override
  Future<String> readSheetConfig() async => sheetConfig;

  @override
  Future<String> readSheetName() async => sheetName;

  @override
  Future<List<LinkedSheet>> readLinkedSheets() async =>
      List<LinkedSheet>.of(linkedSheets);

  @override
  Future<void> saveSheetConfig(String url, {String name = ''}) async {
    sheetConfig = url.trim();
    sheetName = name.trim().isEmpty
        ? _defaultSheetName(sheetConfig)
        : name.trim();
    linkedSheets.removeWhere((sheet) => sheet.url == sheetConfig);
    linkedSheets.insert(0, LinkedSheet(name: sheetName, url: sheetConfig));
  }

  @override
  Future<ThemeMode> readThemeMode() async => themeMode;

  @override
  Future<void> saveThemeMode(ThemeMode mode) async {
    themeMode = mode;
  }

  @override
  Future<bool> readBiometricEnabled() async => biometricEnabled;

  @override
  Future<void> saveBiometricEnabled(bool enabled) async {
    biometricEnabled = enabled;
  }

  final List<QueuedSheetAction> offlineQueue = [];
  final List<Student> cachedStudents = [];
  List<WhatsAppTemplate>? whatsAppTemplates;

  @override
  Future<List<QueuedSheetAction>> readOfflineQueue() async =>
      List.of(offlineQueue);

  @override
  Future<void> saveOfflineQueue(List<QueuedSheetAction> queue) async {
    offlineQueue
      ..clear()
      ..addAll(queue);
  }

  @override
  Future<List<Student>> readCachedStudents() async => List.of(cachedStudents);

  @override
  Future<void> saveCachedStudents(List<Student> students) async {
    cachedStudents
      ..clear()
      ..addAll(students);
    unawaited(CallerIdService.syncStudents(students));
  }

  @override
  Future<List<WhatsAppTemplate>> readWhatsAppTemplates() async =>
      List.of(whatsAppTemplates ?? WhatsAppTemplate.defaultTemplates);

  @override
  Future<void> saveWhatsAppTemplates(List<WhatsAppTemplate> templates) async {
    whatsAppTemplates = List.of(templates);
  }

  @override
  Future<String> readGeminiApiKey() async => geminiApiKey;

  @override
  Future<void> saveGeminiApiKey(String key) async {
    geminiApiKey = key.trim();
  }

  String geminiModel = 'gemini-1.5-flash';
  String companyDescription = _defaultCompanyDescription;

  @override
  Future<String> readGeminiModel() async => geminiModel;

  @override
  Future<void> saveGeminiModel(String model) async {
    geminiModel = model.trim();
  }

  @override
  Future<String> readCompanyDescription() async => companyDescription;

  @override
  Future<void> saveCompanyDescription(String description) async {
    companyDescription = description.trim().isEmpty
        ? _defaultCompanyDescription
        : description.trim();
  }

  String aiProvider = 'gemini';
  String groqApiKey = '';
  String groqModel = 'llama-3.3-70b-versatile';

  @override
  Future<String> readAiProvider() async => aiProvider;

  @override
  Future<void> saveAiProvider(String provider) async {
    aiProvider = provider.trim();
  }

  @override
  Future<String> readGroqApiKey() async => groqApiKey;

  @override
  Future<void> saveGroqApiKey(String key) async {
    groqApiKey = key.trim();
  }

  @override
  Future<String> readGroqModel() async => groqModel;

  @override
  Future<void> saveGroqModel(String model) async {
    groqModel = model.trim();
  }

  bool autoCheckUpdates = true;
  bool autoLogCallDuration = true;
  bool directCalling = true;
  int preferredSimSlot = -1;

  @override
  Future<bool> readAutoCheckUpdates() async => autoCheckUpdates;

  @override
  Future<void> saveAutoCheckUpdates(bool enabled) async {
    autoCheckUpdates = enabled;
  }

  @override
  Future<bool> readAutoLogCallDuration() async => autoLogCallDuration;

  @override
  Future<void> saveAutoLogCallDuration(bool enabled) async {
    autoLogCallDuration = enabled;
  }

  @override
  Future<bool> readDirectCalling() async => directCalling;

  @override
  Future<void> saveDirectCalling(bool enabled) async {
    directCalling = enabled;
  }

  @override
  Future<int> readPreferredSimSlot() async => preferredSimSlot;

  @override
  Future<void> savePreferredSimSlot(int slot) async {
    preferredSimSlot = slot;
  }

  String preferredCallingApp = '';

  @override
  Future<String> readPreferredCallingApp() async => preferredCallingApp;

  @override
  Future<void> savePreferredCallingApp(String packageName) async {
    preferredCallingApp = packageName;
  }
}

ThemeMode _themeModeFromName(String? value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

String formatCallDuration(int seconds) {
  if (seconds <= 0) return '0s';
  final mins = seconds ~/ 60;
  final secs = seconds % 60;
  if (mins > 0 && secs > 0) {
    return '$mins min${mins > 1 ? 's' : ''} ${secs.toString().padLeft(2, '0')} sec${secs > 1 ? 's' : ''}';
  } else if (mins > 0) {
    return '$mins min${mins > 1 ? 's' : ''}';
  } else {
    return '$secs sec${secs > 1 ? 's' : ''}';
  }
}

String formatCallTimer(int seconds) {
  if (seconds < 0) return '00:00';
  final mins = seconds ~/ 60;
  final secs = seconds % 60;
  return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
}

