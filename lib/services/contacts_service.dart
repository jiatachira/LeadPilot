part of '../main.dart';

class NativeDeviceContactsService implements DeviceContactsService {
  const NativeDeviceContactsService();

  @override
  Future<SaveContactsResult> saveMissingStudents(List<Student> students) async {
    final permission = await FlutterContacts.permissions.request(
      PermissionType.readWrite,
    );
    if (permission != PermissionStatus.granted &&
        permission != PermissionStatus.limited) {
      return SaveContactsResult(
        permissionDenied: true,
        permissionPermanentlyDenied:
            permission == PermissionStatus.permanentlyDenied ||
            permission == PermissionStatus.restricted,
      );
    }

    final existingContacts = await FlutterContacts.getAll(
      properties: const {ContactProperty.phone},
    );
    final savedNumbers = <String>{
      for (final contact in existingContacts)
        for (final phone in contact.phones)
          if (normalizeContactPhone(phone.number).isNotEmpty)
            normalizeContactPhone(phone.number),
    };

    var saved = 0;
    var alreadySaved = 0;
    final failedNames = <String>[];
    for (final student in students) {
      final number = normalizeContactPhone(student.phone);
      if (number.isEmpty || !savedNumbers.add(number)) {
        alreadySaved++;
        continue;
      }

      final nameParts = student.name.trim().split(RegExp(r'\s+'));
      final contact = Contact(
        name: Name(
          first: nameParts.first,
          last: nameParts.length > 1 ? nameParts.skip(1).join(' ') : null,
        ),
        phones: [Phone(number: student.phone)],
      );
      try {
        await FlutterContacts.create(contact);
        saved++;
      } on Exception {
        failedNames.add(student.name);
      }
    }
    return SaveContactsResult(
      saved: saved,
      alreadySaved: alreadySaved,
      failedNames: failedNames,
    );
  }
}

const String _defaultCompanyDescription =
    'LNBTI (Lanka Nippon BizTech Institute) - Japanese-based Higher Education Institute in Sri Lanka offering IT & Computing degrees with Japanese language and pathway to careers in Japan.';

abstract interface class AppSettingsStore {
  Future<String?> readPin();

  Future<void> savePin(String pin);

  Future<String> readSheetConfig();

  Future<String> readSheetName();

  Future<List<LinkedSheet>> readLinkedSheets();

  Future<void> saveSheetConfig(String url, {String name = ''});

  Future<ThemeMode> readThemeMode();

  Future<void> saveThemeMode(ThemeMode mode);

  Future<bool> readBiometricEnabled();

  Future<void> saveBiometricEnabled(bool enabled);

  Future<List<QueuedSheetAction>> readOfflineQueue();

  Future<void> saveOfflineQueue(List<QueuedSheetAction> queue);

  Future<List<Student>> readCachedStudents();

  Future<void> saveCachedStudents(List<Student> students);

  Future<List<WhatsAppTemplate>> readWhatsAppTemplates();

  Future<void> saveWhatsAppTemplates(List<WhatsAppTemplate> templates);

  Future<String> readGeminiApiKey();

  Future<void> saveGeminiApiKey(String key);

  Future<String> readGeminiModel();

  Future<void> saveGeminiModel(String model);

  Future<String> readCompanyDescription();

  Future<void> saveCompanyDescription(String description);

  Future<bool> readAutoCheckUpdates();

  Future<void> saveAutoCheckUpdates(bool enabled);

  Future<bool> readAutoLogCallDuration();

  Future<void> saveAutoLogCallDuration(bool enabled);

  Future<bool> readDirectCalling();

  Future<void> saveDirectCalling(bool enabled);

  Future<int> readPreferredSimSlot();

  Future<void> savePreferredSimSlot(int slot);

  Future<bool> readFloatingCallHead();

  Future<void> saveFloatingCallHead(bool enabled);

  Future<String> readPreferredCallingApp();

  Future<void> savePreferredCallingApp(String packageName);
}

