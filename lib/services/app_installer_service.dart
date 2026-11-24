part of '../main.dart';

class AppInstallerService {
  static const _channel = MethodChannel('com.example.call_dial/installer');

  static Future<String> getApkDownloadPath() async {
    if (Platform.isAndroid) {
      try {
        final path = await _channel.invokeMethod<String>('getApkDownloadPath');
        if (path != null && path.isNotEmpty) return path;
      } catch (e) {
        debugPrint('Error getting apk download path: $e');
      }
    }
    final tempDir = Directory.systemTemp;
    return '${tempDir.path}/LeadPilot-update.apk';
  }

  static Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) return true;
    try {
      final allowed =
          await _channel.invokeMethod<bool>('canRequestPackageInstalls');
      return allowed ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openInstallPermissionSettings');
    } catch (_) {}
  }

  static Future<bool> installApk(String filePath) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel
          .invokeMethod<bool>('installApk', {'filePath': filePath});
      return result ?? true;
    } catch (e) {
      debugPrint('Install APK error: $e');
      rethrow;
    }
  }
}

Stream<({int receivedBytes, int totalBytes, double progress})>
    downloadApkWithProgress({
  required String url,
  required String destinationPath,
  http.Client? client,
}) async* {
  final httpClient = client ?? http.Client();
  final request = http.Request('GET', Uri.parse(url));
  request.headers['User-Agent'] = 'LeadPilot-App';
  final response = await httpClient.send(request);

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception('Failed to download APK (HTTP ${response.statusCode})');
  }

  final totalBytes = response.contentLength ?? 0;
  var receivedBytes = 0;
  final file = File(destinationPath);
  if (file.existsSync()) {
    try {
      file.deleteSync();
    } catch (_) {}
  }
  file.createSync(recursive: true);
  final raf = file.openSync(mode: FileMode.write);

  try {
    await for (final chunk in response.stream) {
      raf.writeFromSync(chunk);
      receivedBytes += chunk.length;
      final progress = totalBytes > 0 ? (receivedBytes / totalBytes) : 0.0;
      yield (
        receivedBytes: receivedBytes,
        totalBytes: totalBytes,
        progress: progress,
      );
    }
  } finally {
    try {
      raf.closeSync();
    } catch (_) {}
    if (client == null) {
      httpClient.close();
    }
  }
}

