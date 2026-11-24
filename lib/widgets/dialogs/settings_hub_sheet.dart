part of '../../main.dart';

class SettingsHubSheet extends StatefulWidget {
  const SettingsHubSheet({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.isSheetConnected,
    required this.hasActiveFilters,
    required this.biometricEnabled,
    required this.onBiometricChanged,
    this.students = const [],
    this.settingsStore,
    this.updateService,
    super.key,
  });

  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeModeChanged;
  final bool isSheetConnected;
  final bool hasActiveFilters;
  final bool biometricEnabled;
  final Future<void> Function(bool) onBiometricChanged;
  final List<Student> students;
  final AppSettingsStore? settingsStore;
  final AppUpdateService? updateService;

  @override
  State<SettingsHubSheet> createState() => _SettingsHubSheetState();
}

class _SettingsHubSheetState extends State<SettingsHubSheet> {
  bool _callerIdEnabled = true;
  bool _hasOverlayPermission = false;
  bool _hasPhonePermissions = false;
  bool _isIgnoringBattery = true;
  bool _directCalling = true;
  int _preferredSimSlot = -1;
  String _preferredCallingApp = '';
  bool _floatingCallHead = true;
  List<Map<String, dynamic>> _detectedSimSlots = [];
  List<Map<String, dynamic>> _detectedCallingApps = [];
  int _cachedCount = 0;
  String _geminiApiKey = '';
  bool _autoCheckUpdates = true;
  bool _isCheckingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadCallerIdState();
    _loadGeminiState();
    _loadUpdateState();
  }

  Future<void> _loadUpdateState() async {
    final enabled = await widget.settingsStore?.readAutoCheckUpdates() ?? true;
    if (mounted) {
      setState(() => _autoCheckUpdates = enabled);
    }
  }

  Future<void> _checkForUpdatesManually() async {
    setState(() => _isCheckingUpdate = true);
    try {
      final info = await (widget.updateService ?? AppUpdateService())
          .checkForUpdates(currentVersion: kAppVersion);
      if (!mounted) return;
      if (info.hasUpdate) {
        await showAppUpdateDialog(context, info);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('LeadPilot is up to date (v$kAppVersion).'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not check for updates: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isCheckingUpdate = false);
      }
    }
  }

  Future<void> _loadGeminiState() async {
    final key = await widget.settingsStore?.readGeminiApiKey() ?? '';
    if (mounted) {
      setState(() => _geminiApiKey = key);
    }
  }

  Future<void> _loadCallerIdState() async {
    final enabled = await CallerIdService.isEnabled();
    final hasOverlay = await CallerIdService.canDrawOverlays();
    final hasPhone = await CallerIdService.hasPhonePermissions();
    final isIgnoringBattery =
        await CallerIdService.isIgnoringBatteryOptimizations();
    final directCalling =
        await widget.settingsStore?.readDirectCalling() ?? true;
    final preferredSimSlot =
        await widget.settingsStore?.readPreferredSimSlot() ?? -1;
    final preferredCallingApp =
        await widget.settingsStore?.readPreferredCallingApp() ?? '';
    final floatingCallHead =
        await widget.settingsStore?.readFloatingCallHead() ?? true;
    final sims = await CallerIdService.getSimSlots();
    final callingApps = await CallerIdService.getCallingApps();
    var count = await CallerIdService.getCachedCount();
    if (count == 0 && widget.students.isNotEmpty) {
      await CallerIdService.syncStudents(widget.students);
      count = await CallerIdService.getCachedCount();
    }
    if (mounted) {
      setState(() {
        _callerIdEnabled = enabled;
        _hasOverlayPermission = hasOverlay;
        _hasPhonePermissions = hasPhone;
        _isIgnoringBattery = isIgnoringBattery;
        _directCalling = directCalling;
        _preferredSimSlot = preferredSimSlot;
        _preferredCallingApp = preferredCallingApp;
        _floatingCallHead = floatingCallHead;
        _detectedSimSlots = sims;
        _detectedCallingApps = callingApps;
        _cachedCount = count > 0 ? count : widget.students.length;
      });
    }
  }

  Future<void> _showDefaultSimDialog() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Default Calling SIM'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(-1),
            child: Row(
              children: [
                Icon(
                  _preferredSimSlot == -1
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: _green,
                  size: 20,
                ),
                const SizedBox(width: 12),
                const Text('Always Ask / System Default'),
              ],
            ),
          ),
          ..._detectedSimSlots.map((slot) {
            final idx = (slot['slotIndex'] as num?)?.toInt() ?? 0;
            final carrier = slot['carrierName']?.toString() ?? '';
            final display =
                slot['displayName']?.toString() ?? 'SIM ${idx + 1}';
            final isSelected = _preferredSimSlot == idx;
            return SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(idx),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: _green,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(carrier.isNotEmpty ? '$display ($carrier)' : display),
                ],
              ),
            );
          }),
        ],
      ),
    );

    if (selected != null) {
      setState(() => _preferredSimSlot = selected);
      await widget.settingsStore?.savePreferredSimSlot(selected);
    }
  }

  String _getSimSlotSubtitle() {
    if (_preferredSimSlot == -1) return 'Always Ask / System Default';
    final match = _detectedSimSlots.firstWhere(
      (s) => s['slotIndex'] == _preferredSimSlot,
      orElse: () => {},
    );
    if (match.isEmpty) return 'SIM ${_preferredSimSlot + 1}';
    final carrier = match['carrierName']?.toString() ?? '';
    final display =
        match['displayName']?.toString() ?? 'SIM ${_preferredSimSlot + 1}';
    return carrier.isNotEmpty ? '$display ($carrier)' : display;
  }

  Future<void> _showCallingAppDialog() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Default Calling App'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(''),
            child: Row(
              children: [
                Icon(
                  _preferredCallingApp.isEmpty
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: _green,
                  size: 20,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Always Ask / System Chooser'),
                ),
              ],
            ),
          ),
          ..._detectedCallingApps.map((app) {
            final pkg = app['packageName']?.toString() ?? '';
            final name = app['appName']?.toString() ?? pkg;
            final is3cx = name.toLowerCase().contains('3cx') ||
                pkg.toLowerCase().contains('tcx');
            final isSelected = _preferredCallingApp == pkg;
            return SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(pkg),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: _green,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          is3cx ? name : '$name (SIM Call)',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          pkg,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );

    if (selected != null) {
      setState(() => _preferredCallingApp = selected);
      await widget.settingsStore?.savePreferredCallingApp(selected);
    }
  }

  String _getCallingAppSubtitle() {
    if (_preferredCallingApp.isEmpty) return 'Always Ask / System Chooser';
    final match = _detectedCallingApps.firstWhere(
      (a) => a['packageName'] == _preferredCallingApp,
      orElse: () => {},
    );
    if (match.isEmpty) return _preferredCallingApp;
    final name = match['appName']?.toString() ?? _preferredCallingApp;
    final is3cx = name.toLowerCase().contains('3cx') ||
        _preferredCallingApp.toLowerCase().contains('tcx');
    return is3cx ? name : '$name (SIM Call)';
  }

  Future<void> _requestPermissions() async {
    final hasOverlay = await CallerIdService.canDrawOverlays();
    if (!mounted) return;
    if (!hasOverlay) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.layers_outlined, color: Color(0xFF62D6B0)),
              SizedBox(width: 8),
              Text('Display Over Apps'),
            ],
          ),
          content: const Text(
            'To show the Caller ID popup when a student calls, LeadPilot needs the "Display over other apps" permission.\n\nPlease enable it on the next screen.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('Grant Permission'),
            ),
          ],
        ),
      );
      if (proceed == true) {
        await CallerIdService.requestOverlayPermission();
      }
    }

    final hasPhone = await CallerIdService.hasPhonePermissions();
    if (!hasPhone) {
      await CallerIdService.requestPhonePermissions();
    }

    if (widget.students.isNotEmpty) {
      await CallerIdService.syncStudents(widget.students);
    }

    await _loadCallerIdState();
  }

  Future<void> _handleCallerIdToggle(bool enable) async {
    if (enable) {
      await CallerIdService.setEnabled(true);
      await _requestPermissions();
    } else {
      await CallerIdService.setEnabled(false);
      if (mounted) setState(() => _callerIdEnabled = false);
    }
  }

  Future<void> _testCallerIdPopup() async {
    final hasOverlay = await CallerIdService.canDrawOverlays();
    final hasPhone = await CallerIdService.hasPhonePermissions();
    if (!mounted) return;
    if (!hasOverlay || !hasPhone) {
      await _requestPermissions();
      return;
    }
    await CallerIdService.testCallerIdPopup();
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Sample Caller ID popup displayed!'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<void> _testNotificationBanner() async {
    final hasPhone = await CallerIdService.hasPhonePermissions();
    if (!mounted) return;
    if (!hasPhone) {
      await _requestPermissions();
      return;
    }
    await CallerIdService.testNotificationBanner();
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Sample Heads-Up / Lock Screen banner displayed! Check your notifications.',
        ),
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  height: 4,
                  width: 40,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF526170)
                        : const Color(0xFFDDE3E9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Settings',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Appearance',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<ThemeMode>(
                key: ValueKey(widget.themeMode),
                initialValue: widget.themeMode,
                decoration: const InputDecoration(
                  labelText: 'Theme',
                  prefixIcon: Icon(Icons.palette_outlined),
                ),
                items: const [
                  DropdownMenuItem(
                    value: ThemeMode.system,
                    child: Text('System default'),
                  ),
                  DropdownMenuItem(
                    value: ThemeMode.light,
                    child: Text('Light'),
                  ),
                  DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                ],
                onChanged: (mode) {
                  if (mode != null) unawaited(widget.onThemeModeChanged(mode));
                },
              ),
              const SizedBox(height: 20),
              Text(
                'Student data',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    ListTile(
                      leading: Badge(
                        isLabelVisible: widget.hasActiveFilters,
                        child: const Icon(Icons.tune_rounded),
                      ),
                      title: const Text('Filter by date and call status'),
                      subtitle: const Text(
                        'Choose a date range and status such as No Answer',
                      ),
                      onTap: () =>
                          Navigator.pop(context, _SettingsAction.filters),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(Icons.assessment_outlined),
                      title: const Text('Lead reports'),
                      subtitle: const Text(
                        'Export Not Interested and Not Potential separately',
                      ),
                      onTap: () =>
                          Navigator.pop(context, _SettingsAction.reports),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(Icons.file_download_outlined),
                      title: const Text('Download CSV report'),
                      subtitle: const Text(
                        'Export the students matching your current filters',
                      ),
                      onTap: () =>
                          Navigator.pop(context, _SettingsAction.export),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(Icons.contact_phone_outlined),
                      title: const Text('Save contacts'),
                      subtitle: const Text(
                        'Save displayed contacts and skip numbers already saved',
                      ),
                      onTap: () =>
                          Navigator.pop(context, _SettingsAction.saveContacts),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(Icons.chat_outlined),
                      title: const Text('WhatsApp & SMS templates'),
                      subtitle: const Text(
                        'Manage pre-written message templates',
                      ),
                      onTap: () => Navigator.pop(
                        context,
                        _SettingsAction.whatsAppTemplates,
                      ),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.auto_awesome_rounded,
                        color: Color(0xFF8B5CF6),
                      ),
                      title: const Text('Gemini AI Assistant'),
                      subtitle: Text(
                        _geminiApiKey.trim().isEmpty
                            ? 'Connect free API key for smart follow-ups'
                            : 'Connected • Ready for AI messaging',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pop(
                        context,
                        _SettingsAction.geminiAi,
                      ),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.business_rounded,
                        color: Color(0xFF8B5CF6),
                      ),
                      title: const Text('Description about your company'),
                      subtitle: const Text(
                        'Configure institute details (LNBTI) for AI messaging',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pop(
                        context,
                        _SettingsAction.companyDescription,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Sync and storage',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: ListTile(
                  leading: const Icon(Icons.cloud_sync_outlined),
                  title: const Text('Google Sheets Sync'),
                  subtitle: Text(
                    widget.isSheetConnected
                        ? 'Sheet URL and linked sheets'
                        : 'Link a Google Apps Script Web App',
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onTap: () =>
                      Navigator.pop(context, _SettingsAction.sheetSync),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Security',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: SwitchListTile(
                  secondary: const Icon(Icons.fingerprint_rounded),
                  title: const Text('Fingerprint Login'),
                  subtitle: const Text(
                    'Use fingerprint to log in instead of PIN',
                  ),
                  value: widget.biometricEnabled,
                  onChanged: (val) => unawaited(widget.onBiometricChanged(val)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Calling & SIM',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.phone_forwarded_rounded),
                      title: const Text('Direct In-App Calling'),
                      subtitle: const Text(
                        'Call directly without opening dialpad • Keep LeadPilot in front',
                      ),
                      value: _directCalling,
                      onChanged: (val) async {
                        setState(() => _directCalling = val);
                        await widget.settingsStore?.saveDirectCalling(val);
                      },
                    ),
                    if (_detectedSimSlots.isNotEmpty) ...[
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      ListTile(
                        leading: const Icon(Icons.sim_card_outlined),
                        title: const Text('Default Calling SIM'),
                        subtitle: Text(_getSimSlotSubtitle()),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _showDefaultSimDialog,
                      ),
                    ],
                    if (_detectedCallingApps.length > 1) ...[
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      ListTile(
                        leading: const Icon(Icons.phone_android_rounded),
                        title: const Text('Default Calling App (Phone / 3CX)'),
                        subtitle: Text(_getCallingAppSubtitle()),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _showCallingAppDialog,
                      ),
                    ],
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.chat_bubble_outline_rounded),
                      title: const Text('Floating Call Head (1-Tap End Call)'),
                      subtitle: const Text(
                        'Show floating card with student name & 1-tap End Call button',
                      ),
                      value: _floatingCallHead,
                      onChanged: (val) async {
                        setState(() => _floatingCallHead = val);
                        await widget.settingsStore?.saveFloatingCallHead(val);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Caller ID',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.phone_in_talk_rounded),
                      title: const Text('Incoming Caller ID Popup'),
                      subtitle: Text(
                        _callerIdEnabled
                            ? (_hasOverlayPermission && _hasPhonePermissions
                                ? 'Active • $_cachedCount lead(s) cached offline'
                                : 'Permission required for call detection')
                            : 'Disabled',
                      ),
                      value: _callerIdEnabled,
                      onChanged: _handleCallerIdToggle,
                    ),
                    if (_callerIdEnabled && (!_hasOverlayPermission || !_hasPhonePermissions)) ...[
                      Divider(height: 1, indent: 56, color: theme.colorScheme.outlineVariant),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFAA48), size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  'Setup Action Required',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: const Color(0xFFFFAA48),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              !_hasPhonePermissions
                                  ? 'Allow Phone & Call Log permission so LeadPilot can detect caller numbers.'
                                  : 'Allow "Display over other apps" so the popup can show on incoming calls.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            FilledButton.tonalIcon(
                              icon: const Icon(Icons.lock_open_rounded, size: 16),
                              label: const Text('Grant Permissions'),
                              onPressed: _requestPermissions,
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_callerIdEnabled) ...[
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      ListTile(
                        leading: const Icon(Icons.preview_rounded),
                        title: const Text('Preview / Test Popup'),
                        subtitle: const Text(
                          'Display a sample floating card over the screen',
                        ),
                        onTap: _testCallerIdPopup,
                      ),
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      ListTile(
                        leading: const Icon(Icons.notification_important_rounded),
                        title: const Text('Test Lock Screen & Heads-Up Banner'),
                        subtitle: const Text(
                          'Display a sample calling alert banner',
                        ),
                        onTap: _testNotificationBanner,
                      ),
                      if (!_isIgnoringBattery) ...[
                        Divider(
                          height: 1,
                          indent: 56,
                          color: theme.colorScheme.outlineVariant,
                        ),
                        ListTile(
                          leading: const Icon(
                            Icons.battery_alert_rounded,
                            color: Color(0xFFFFAA48),
                          ),
                          title: const Text('Allow Background Running'),
                          subtitle: const Text(
                            'Exempt from Battery Optimization so detection runs when phone is asleep',
                          ),
                          trailing: FilledButton.tonal(
                            onPressed: () async {
                              await CallerIdService
                                  .requestIgnoreBatteryOptimizations();
                              await Future<void>.delayed(
                                const Duration(seconds: 1),
                              );
                              await _loadCallerIdState();
                            },
                            child: const Text('Allow'),
                          ),
                        ),
                      ],
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      ListTile(
                        leading: const Icon(Icons.app_settings_alt_rounded),
                        title: const Text('Xiaomi / Samsung Background Fix'),
                        subtitle: const Text(
                          'Open App Settings to allow Autostart & Pop-ups in background',
                        ),
                        trailing: Icon(
                          Icons.open_in_new_rounded,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        onTap: () async {
                          await CallerIdService.openAppDetailsSettings();
                        },
                      ),
                      Divider(
                        height: 1,
                        indent: 56,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      ListTile(
                        leading: const Icon(Icons.sync_rounded),
                        title: const Text('Re-sync Leads to Phone'),
                        subtitle: Text(
                          '$_cachedCount student lead(s) stored in phone',
                        ),
                        trailing: TextButton(
                          onPressed: () async {
                            if (widget.students.isNotEmpty) {
                              await CallerIdService.syncStudents(
                                widget.students,
                              );
                              await _loadCallerIdState();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${widget.students.length} leads synced for Caller ID!',
                                    ),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text('Sync'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'App Updates',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.system_update_rounded),
                      title: const Text('Check for Updates'),
                      subtitle: Text(
                        _isCheckingUpdate
                            ? 'Checking GitHub for updates...'
                            : 'Current version: v$kAppVersion',
                      ),
                      trailing: _isCheckingUpdate
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : FilledButton.tonal(
                              key: const Key('check_updates_button'),
                              onPressed: _checkForUpdatesManually,
                              child: const Text('Check'),
                            ),
                      onTap: _isCheckingUpdate ? null : _checkForUpdatesManually,
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    SwitchListTile(
                      key: const Key('auto_check_updates_switch'),
                      secondary: const Icon(Icons.autorenew_rounded),
                      title: const Text('Auto-check on Startup'),
                      subtitle: const Text(
                        'Automatically check for new releases when app opens',
                      ),
                      value: _autoCheckUpdates,
                      onChanged: (val) async {
                        setState(() => _autoCheckUpdates = val);
                        await widget.settingsStore?.saveAutoCheckUpdates(val);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'LeadPilot v$kAppVersion',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

