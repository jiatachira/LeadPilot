part of '../../main.dart';

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.updateInfo,
    this.onLaunchUrl,
    this.onInstallApk,
    this.httpClient,
  });

  final AppUpdateInfo updateInfo;
  final Future<void> Function(String url)? onLaunchUrl;
  final Future<void> Function(String filePath)? onInstallApk;
  final http.Client? httpClient;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _isDownloading = false;
  bool _isDownloaded = false;
  double _progress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String? _downloadError;
  String _savedApkPath = '';
  StreamSubscription<dynamic>? _downloadSub;
  bool _needsInstallPermission = false;

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  Future<void> _startDownload() async {
    final downloadUrl = widget.updateInfo.downloadUrl;
    if (!downloadUrl.toLowerCase().endsWith('.apk')) {
      await _openUrl(downloadUrl);
      if (mounted) Navigator.pop(context);
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadError = null;
      _progress = 0.0;
      _receivedBytes = 0;
      _totalBytes = widget.updateInfo.apkSize;
    });

    try {
      final destPath = await AppInstallerService.getApkDownloadPath();
      _savedApkPath = destPath;

      final stream = downloadApkWithProgress(
        url: downloadUrl,
        destinationPath: destPath,
        client: widget.httpClient,
      );

      _downloadSub = stream.listen(
        (data) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = data.receivedBytes;
            _totalBytes = data.totalBytes > 0
                ? data.totalBytes
                : widget.updateInfo.apkSize;
            _progress = data.progress.clamp(0.0, 1.0);
          });
        },
        onError: (err) {
          if (!mounted) return;
          setState(() {
            _isDownloading = false;
            _downloadError = err.toString();
          });
        },
        onDone: () async {
          if (!mounted) return;
          setState(() {
            _isDownloading = false;
            _isDownloaded = true;
            _progress = 1.0;
          });
          await _triggerInstall();
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadError = e.toString();
      });
    }
  }

  Future<void> _triggerInstall() async {
    if (_savedApkPath.isEmpty) return;

    if (widget.onInstallApk != null) {
      await widget.onInstallApk!(_savedApkPath);
      return;
    }

    try {
      final canInstall = await AppInstallerService.canRequestPackageInstalls();
      if (!canInstall) {
        if (mounted) setState(() => _needsInstallPermission = true);
        await AppInstallerService.openInstallPermissionSettings();
        return;
      }
      await AppInstallerService.installApk(_savedApkPath);
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('PERMISSION_REQUIRED')) {
        if (mounted) setState(() => _needsInstallPermission = true);
      } else {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('Installation prompt failed: $e')),
          );
        }
      }
    }
  }

  Future<void> _openUrl(String url) async {
    if (widget.onLaunchUrl != null) {
      await widget.onLaunchUrl!(url);
      return;
    }
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 1. Download in progress view
    if (_isDownloading) {
      return AlertDialog(
        key: const Key('app_update_dialog'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                value: _progress.clamp(0.01, 1.0),
                color: const Color(0xFF00966D),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Downloading Update...',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Downloading LeadPilot v${widget.updateInfo.latestVersion}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: _progress.clamp(0.0, 1.0),
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
              backgroundColor:
                  isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
              color: const Color(0xFF00966D),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(_progress * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF00966D),
                  ),
                ),
                Text(
                  _totalBytes > 0
                      ? '${(_receivedBytes / (1024 * 1024)).toStringAsFixed(1)} / ${(_totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
                      : '${(_receivedBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _downloadSub?.cancel();
              setState(() => _isDownloading = false);
            },
            child: const Text('Cancel Download'),
          ),
        ],
      );
    }

    // 2. Download complete / ready to install view
    if (_isDownloaded) {
      return AlertDialog(
        key: const Key('app_update_dialog'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF00966D).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF00966D),
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Update Ready!',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'LeadPilot v${widget.updateInfo.latestVersion} has finished downloading. Launching package installer to apply update...',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            if (_needsInstallPermission) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3CD),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFFD56B)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.security_rounded,
                      color: Color(0xFF996500),
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Android permission required: Please allow "Install unknown apps" for LeadPilot, then tap Install Now.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF664400),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (_needsInstallPermission)
            TextButton.icon(
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: const Text('Allow in Settings'),
              onPressed: () =>
                  AppInstallerService.openInstallPermissionSettings(),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Dismiss'),
          ),
          FilledButton.icon(
            key: const Key('install_now_button'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00966D),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.system_update_rounded, size: 18),
            label: const Text('Install Now'),
            onPressed: _triggerInstall,
          ),
        ],
      );
    }

    // 3. Initial dialog view with release notes & download size
    return AlertDialog(
      key: const Key('app_update_dialog'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF62D6B0).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.system_update_rounded,
              color: Color(0xFF00966D),
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'New Update Available',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF334155)
                        : const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'v${widget.updateInfo.currentVersion}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward_rounded, size: 16),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00966D),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'v${widget.updateInfo.latestVersion}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            if (widget.updateInfo.apkSize > 0) ...[
              const SizedBox(height: 10),
              Text(
                'Download size: ${(widget.updateInfo.apkSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (_downloadError != null) ...[
              const SizedBox(height: 10),
              Text(
                'Download failed: $_downloadError',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            if (widget.updateInfo.releaseNotes.trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                "What's New:",
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.maxFinite,
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                  ),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    widget.updateInfo.releaseNotes.trim(),
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('update_later_button'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Later'),
        ),
        if (widget.updateInfo.releaseUrl.isNotEmpty &&
            widget.updateInfo.releaseUrl != widget.updateInfo.downloadUrl)
          TextButton(
            key: const Key('update_github_button'),
            onPressed: () => _openUrl(widget.updateInfo.releaseUrl),
            child: const Text('View on GitHub'),
          ),
        FilledButton.icon(
          key: const Key('update_now_button'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF00966D),
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Update Now'),
          onPressed: _startDownload,
        ),
      ],
    );
  }
}

Future<void> showAppUpdateDialog(
  BuildContext context,
  AppUpdateInfo updateInfo, {
  Future<void> Function(String url)? onLaunchUrl,
  Future<void> Function(String filePath)? onInstallApk,
  http.Client? httpClient,
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AppUpdateDialog(
        updateInfo: updateInfo,
        onLaunchUrl: onLaunchUrl,
        onInstallApk: onInstallApk,
        httpClient: httpClient,
      ),
    );

