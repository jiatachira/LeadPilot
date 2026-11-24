part of '../main.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    this.releaseTitle = '',
    this.releaseNotes = '',
    this.downloadUrl = '',
    this.releaseUrl = '',
    this.publishedAt,
    this.apkSize = 0,
  });

  final String currentVersion;
  final String latestVersion;
  final bool hasUpdate;
  final String releaseTitle;
  final String releaseNotes;
  final String downloadUrl;
  final String releaseUrl;
  final DateTime? publishedAt;
  final int apkSize;
}

abstract class VoiceToTextService {
  bool get isAvailable;
  bool get isListening;
  Future<bool> initialize();
  Future<void> listen({
    required void Function(String recognizedWords) onResult,
    void Function(String status)? onStatus,
    void Function(String error)? onError,
    String? localeId,
  });
  Future<void> stop();
  Future<void> cancel();
}

