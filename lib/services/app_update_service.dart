part of '../main.dart';

class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    this.owner = 'jiatachira',
    this.repo = 'LeadPilot',
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String owner;
  final String repo;

  Future<AppUpdateInfo> checkForUpdates({
    String currentVersion = kAppVersion,
  }) async {
    final url = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/releases/latest',
    );
    final response = await _client.get(
      url,
      headers: {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'LeadPilot-App',
      },
    );

    if (response.statusCode == 404) {
      return AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: currentVersion,
        hasUpdate: false,
        releaseNotes: 'No releases found on GitHub.',
      );
    }

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to check for updates (HTTP ${response.statusCode})',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final tagName = (data['tag_name'] as String? ?? '').trim();
    final cleanLatest =
        tagName.replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
    final hasUpdate = compareVersions(currentVersion, cleanLatest) > 0;

    final assets = (data['assets'] as List<dynamic>?) ?? [];
    String apkDownloadUrl = '';
    int apkSize = 0;
    for (final asset in assets) {
      if (asset is Map<String, dynamic>) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.endsWith('.apk')) {
          apkDownloadUrl = asset['browser_download_url'] as String? ?? '';
          apkSize = (asset['size'] as num?)?.toInt() ?? 0;
          break;
        }
      }
    }

    final htmlUrl =
        data['html_url'] as String? ?? 'https://github.com/$owner/$repo/releases';
    if (apkDownloadUrl.isEmpty) {
      apkDownloadUrl = htmlUrl;
    }

    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: cleanLatest.isNotEmpty ? cleanLatest : tagName,
      hasUpdate: hasUpdate,
      releaseTitle: data['name'] as String? ?? tagName,
      releaseNotes: data['body'] as String? ?? '',
      downloadUrl: apkDownloadUrl,
      releaseUrl: htmlUrl,
      publishedAt: DateTime.tryParse(data['published_at'] as String? ?? ''),
      apkSize: apkSize,
    );
  }

  static int compareVersions(String current, String latest) {
    String clean(String v) =>
        v.trim().toLowerCase().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
    final cParts = clean(current)
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final lParts = clean(latest)
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();

    final maxLen = math.max(cParts.length, lParts.length);
    for (var i = 0; i < maxLen; i++) {
      final c = i < cParts.length ? cParts[i] : 0;
      final l = i < lParts.length ? lParts[i] : 0;
      if (l > c) return 1;
      if (l < c) return -1;
    }
    return 0;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

