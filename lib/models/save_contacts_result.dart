part of '../main.dart';

class SaveContactsResult {
  const SaveContactsResult({
    this.saved = 0,
    this.alreadySaved = 0,
    this.failedNames = const [],
    this.permissionDenied = false,
    this.permissionPermanentlyDenied = false,
  });

  final int saved;
  final int alreadySaved;
  final List<String> failedNames;
  final bool permissionDenied;
  final bool permissionPermanentlyDenied;
}

abstract interface class DeviceContactsService {
  Future<SaveContactsResult> saveMissingStudents(List<Student> students);
}

