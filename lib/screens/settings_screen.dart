part of '../main.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.isSheetConnected,
    required this.hasActiveFilters,
    required this.biometricEnabled,
    required this.onBiometricChanged,
    this.sheetUrl = '',
    this.sheetName = '',
    this.savedSheets = const [],
    this.onSaveSheetConfig,
    this.students = const [],
    this.filteredStudents = const [],
    this.settingsStore,
    this.updateService,
    this.onOpenLeadFilters,
    this.onExportCsv,
    this.onOpenLeadReports,
    this.onSaveVisibleContacts,
    this.initialSubPage,
    super.key,
  });

  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeModeChanged;
  final bool isSheetConnected;
  final bool hasActiveFilters;
  final bool biometricEnabled;
  final Future<void> Function(bool) onBiometricChanged;
  final String sheetUrl;
  final String sheetName;
  final List<LinkedSheet> savedSheets;
  final Future<void> Function(LinkedSheet)? onSaveSheetConfig;
  final List<Student> students;
  final List<Student> filteredStudents;
  final AppSettingsStore? settingsStore;
  final AppUpdateService? updateService;
  final Future<void> Function()? onOpenLeadFilters;
  final Future<void> Function()? onExportCsv;
  final Future<void> Function()? onOpenLeadReports;
  final Future<void> Function()? onSaveVisibleContacts;
  final String? initialSubPage;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _callerIdEnabled = true;
  bool _hasOverlayPermission = false;
  bool _hasPhonePermissions = false;
  bool _isIgnoringBattery = true;
  bool _directCalling = true;
  int _preferredSimSlot = -1;
  String _preferredCallingApp = '';
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
    if (widget.initialSubPage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openInitialSubPage(widget.initialSubPage!);
      });
    }
  }

  void _openInitialSubPage(String pageKey) {
    if (!mounted) return;
    switch (pageKey.toLowerCase()) {
      case 'sheets':
      case 'googlesheets':
      case 'sync':
        _openGoogleSheetsSync();
        break;
      case 'messages':
        _openMessages();
        break;
      case 'calling':
        _openCalling();
        break;
      case 'callerid':
        _openCallerId();
        break;
      case 'data':
        _openData();
        break;
      case 'security':
        _openSecurity();
        break;
      case 'appearance':
        _openAppearance();
        break;
      case 'updates':
      case 'about':
        _openUpdatesAbout();
        break;
    }
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

  Future<void> _openCompanyDescriptionDialog() async {
    final current = await widget.settingsStore?.readCompanyDescription() ?? '';
    if (!mounted) return;
    final controller = TextEditingController(text: current);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.business_rounded, color: Color(0xFF8B5CF6)),
            SizedBox(width: 8),
            Text('Company Description'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI uses this description to represent your institute (LNBTI) in generated follow-up messages politely without overwhelming details.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: 'Description about your company',
                  hintText: 'Enter institute details...',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.restart_alt_rounded),
                    tooltip: 'Reset to default',
                    onPressed: () {
                      controller.text = _defaultCompanyDescription;
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (updated != null) {
      await widget.settingsStore?.saveCompanyDescription(updated);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Company description saved for AI messaging.'),
        ),
      );
    }
  }

  void _pushPage(Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  // --- Sub-page Navigators ---

  Future<void> _openGoogleSheetsSync() async {
    final result = await Navigator.of(context).push<LinkedSheet>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Google Sheets Sync')),
          body: _SheetSettingsSheet(
            initialUrl: widget.sheetUrl,
            initialName: widget.sheetName,
            savedSheets: widget.savedSheets,
            isConnected: widget.isSheetConnected,
          ),
        ),
      ),
    );
    if (result != null) {
      if (widget.onSaveSheetConfig != null) {
        await widget.onSaveSheetConfig!(result);
      }
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  void _openMessages() {
    _pushPage(_MessagesSettingsSubPage(
      geminiApiKey: _geminiApiKey,
      settingsStore: widget.settingsStore,
      onOpenCompanyDescription: _openCompanyDescriptionDialog,
      onRefreshGemini: _loadGeminiState,
    ));
  }

  void _openCalling() {
    _pushPage(_CallingSettingsSubPage(
      directCalling: _directCalling,
      detectedSimSlots: _detectedSimSlots,
      detectedCallingApps: _detectedCallingApps,
      simSlotSubtitle: _getSimSlotSubtitle(),
      callingAppSubtitle: _getCallingAppSubtitle(),
      onDirectCallingChanged: (val) async {
        setState(() => _directCalling = val);
        await widget.settingsStore?.saveDirectCalling(val);
      },
      onSelectSim: _showDefaultSimDialog,
      onSelectCallingApp: _showCallingAppDialog,
    ));
  }

  void _openCallerId() {
    _pushPage(_CallerIdSettingsSubPage(
      callerIdEnabled: _callerIdEnabled,
      hasOverlayPermission: _hasOverlayPermission,
      hasPhonePermissions: _hasPhonePermissions,
      isIgnoringBattery: _isIgnoringBattery,
      cachedCount: _cachedCount,
      studentsCount: widget.students.length,
      onToggleCallerId: _handleCallerIdToggle,
      onRequestPermissions: _requestPermissions,
      onTestPopup: _testCallerIdPopup,
      onTestBanner: _testNotificationBanner,
      onAllowBattery: () async {
        await CallerIdService.requestIgnoreBatteryOptimizations();
        await Future<void>.delayed(const Duration(seconds: 1));
        await _loadCallerIdState();
      },
      onXiaomiFix: () async {
        await CallerIdService.openAppDetailsSettings();
      },
      onResyncLeads: () async {
        if (widget.students.isNotEmpty) {
          await CallerIdService.syncStudents(widget.students);
          await _loadCallerIdState();
          if (mounted) {
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
    ));
  }

  void _openData() {
    _pushPage(_DataSettingsSubPage(
      hasActiveFilters: widget.hasActiveFilters,
      onExportCsv: () async {
        Navigator.pop(context);
        Navigator.pop(context);
        await widget.onExportCsv?.call();
      },
      onOpenReports: () async {
        Navigator.pop(context);
        Navigator.pop(context);
        await widget.onOpenLeadReports?.call();
      },
      onSaveContacts: () async {
        Navigator.pop(context);
        Navigator.pop(context);
        await widget.onSaveVisibleContacts?.call();
      },
      onOpenFilters: () async {
        Navigator.pop(context);
        Navigator.pop(context);
        await widget.onOpenLeadFilters?.call();
      },
    ));
  }

  void _openSecurity() {
    _pushPage(_SecuritySettingsSubPage(
      biometricEnabled: widget.biometricEnabled,
      onBiometricChanged: widget.onBiometricChanged,
    ));
  }

  void _openAppearance() {
    _pushPage(_AppearanceSettingsSubPage(
      themeMode: widget.themeMode,
      onThemeModeChanged: widget.onThemeModeChanged,
    ));
  }

  void _openUpdatesAbout() {
    _pushPage(_UpdatesAboutSettingsSubPage(
      isCheckingUpdate: _isCheckingUpdate,
      autoCheckUpdates: _autoCheckUpdates,
      onCheckForUpdates: _checkForUpdatesManually,
      onAutoCheckChanged: (val) async {
        setState(() => _autoCheckUpdates = val);
        await widget.settingsStore?.saveAutoCheckUpdates(val);
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // 1. Google Sheets sync
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: theme.colorScheme.surfaceContainerLow,
            child: ListTile(
              leading: const Icon(Icons.cloud_sync_outlined),
              title: const Text('Google Sheets Sync'),
              subtitle: Text(
                widget.isSheetConnected
                    ? 'Connected • Sheet URL and linked sheets'
                    : 'Link a Google Apps Script Web App',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _openGoogleSheetsSync,
            ),
          ),

          // 2. Messages
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: theme.colorScheme.surfaceContainerLow,
            child: ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: const Text('Messages'),
              subtitle: const Text(
                'WhatsApp/SMS templates, Gemini AI, company description',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _openMessages,
            ),
          ),

          // 3. Calling
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: theme.colorScheme.surfaceContainerLow,
            child: ListTile(
              leading: const Icon(Icons.phone_forwarded_rounded),
              title: const Text('Calling'),
              subtitle: const Text(
                'Direct calling, default SIM, default calling app',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _openCalling,
            ),
          ),

          // 4. Caller ID
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: theme.colorScheme.surfaceContainerLow,
            child: ListTile(
              leading: const Icon(Icons.phone_in_talk_rounded),
              title: const Text('Caller ID'),
              subtitle: const Text('Enable popup and permissions'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _openCallerId,
            ),
          ),

          // 5. Data
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: theme.colorScheme.surfaceContainerLow,
            child: ListTile(
              leading: const Icon(Icons.storage_rounded),
              title: const Text('Data'),
              subtitle: const Text(
                'Export CSV, lead reports, save contacts, filters',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _openData,
            ),
          ),

          // 6. Security
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: theme.colorScheme.surfaceContainerLow,
            child: ListTile(
              leading: const Icon(Icons.security_rounded),
              title: const Text('Security'),
              subtitle: const Text('Fingerprint login'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _openSecurity,
            ),
          ),

          // 7. Appearance
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: theme.colorScheme.surfaceContainerLow,
            child: ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('Appearance'),
              subtitle: const Text('Theme'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _openAppearance,
            ),
          ),

          // 8. Updates & About
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: theme.colorScheme.surfaceContainerLow,
            child: ListTile(
              leading: const Icon(Icons.system_update_rounded),
              title: const Text('Updates & About'),
              subtitle: const Text('Check for updates, auto-check, version'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _openUpdatesAbout,
            ),
          ),

          const SizedBox(height: 20),
          Center(
            child: Text(
              'LeadPilot v$kAppVersion',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Google Sheets Sync Small Page
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// 2. Messages Small Page
// ─────────────────────────────────────────────────────────────────────────────

class _MessagesSettingsSubPage extends StatelessWidget {
  const _MessagesSettingsSubPage({
    required this.geminiApiKey,
    required this.settingsStore,
    required this.onOpenCompanyDescription,
    required this.onRefreshGemini,
  });

  final String geminiApiKey;
  final AppSettingsStore? settingsStore;
  final VoidCallback onOpenCompanyDescription;
  final VoidCallback onRefreshGemini;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Card(
            color: theme.colorScheme.surfaceContainerLow,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.chat_outlined),
                  title: const Text('WhatsApp & SMS templates'),
                  subtitle: const Text('Manage pre-written message templates'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    await showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => _ManageWhatsAppTemplatesSheet(
                        settingsStore: settingsStore ?? MemoryAppSettingsStore(),
                      ),
                    );
                  },
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
                    geminiApiKey.trim().isEmpty
                        ? 'Connect free API key for smart follow-ups'
                        : 'Connected • Ready for AI messaging',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    await showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => ManageGeminiAiSheet(
                        settingsStore: settingsStore ?? MemoryAppSettingsStore(),
                      ),
                    );
                    onRefreshGemini();
                  },
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
                  onTap: onOpenCompanyDescription,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Calling Small Page
// ─────────────────────────────────────────────────────────────────────────────

class _CallingSettingsSubPage extends StatefulWidget {
  const _CallingSettingsSubPage({
    required this.directCalling,
    required this.detectedSimSlots,
    required this.detectedCallingApps,
    required this.simSlotSubtitle,
    required this.callingAppSubtitle,
    required this.onDirectCallingChanged,
    required this.onSelectSim,
    required this.onSelectCallingApp,
  });

  final bool directCalling;
  final List<Map<String, dynamic>> detectedSimSlots;
  final List<Map<String, dynamic>> detectedCallingApps;
  final String simSlotSubtitle;
  final String callingAppSubtitle;
  final ValueChanged<bool> onDirectCallingChanged;
  final VoidCallback onSelectSim;
  final VoidCallback onSelectCallingApp;

  @override
  State<_CallingSettingsSubPage> createState() =>
      _CallingSettingsSubPageState();
}

class _CallingSettingsSubPageState extends State<_CallingSettingsSubPage> {
  late bool _directCalling = widget.directCalling;
  bool? _isDefaultDialer;
  bool _autoRecord = false;

  @override
  void initState() {
    super.initState();
    _refreshDefaultDialerStatus();
    _loadAutoRecordStatus();
  }

  Future<void> _loadAutoRecordStatus() async {
    try {
      final val = await CallerIdService.isAutoRecordEnabled();
      if (mounted) setState(() => _autoRecord = val);
    } catch (_) {}
  }

  Future<void> _refreshDefaultDialerStatus() async {
    try {
      final val = await CallerIdService.isDefaultDialer();
      if (mounted) setState(() => _isDefaultDialer = val);
    } catch (_) {
      if (mounted) setState(() => _isDefaultDialer = false);
    }
  }

  Future<void> _requestDefaultDialer() async {
    await CallerIdService.requestDefaultDialer();
    await _refreshDefaultDialerStatus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calling'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
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
                  onChanged: (val) {
                    setState(() => _directCalling = val);
                    widget.onDirectCallingChanged(val);
                  },
                ),
                if (widget.detectedSimSlots.isNotEmpty) ...[
                  Divider(
                    height: 1,
                    indent: 56,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  ListTile(
                    leading: const Icon(Icons.sim_card_outlined),
                    title: const Text('Default Calling SIM'),
                    subtitle: Text(widget.simSlotSubtitle),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: widget.onSelectSim,
                  ),
                ],
                if (widget.detectedCallingApps.length > 1) ...[
                  Divider(
                    height: 1,
                    indent: 56,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  ListTile(
                    leading: const Icon(Icons.phone_android_rounded),
                    title: const Text('Default Calling App (Phone / 3CX)'),
                    subtitle: Text(widget.callingAppSubtitle),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: widget.onSelectCallingApp,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          // ── Default Phone App card ──────────────────────────────────────
          Card(
            color: theme.colorScheme.surfaceContainerLow,
            child: ListTile(
              leading: Icon(
                Icons.dialer_sip_rounded,
                color: (_isDefaultDialer ?? false)
                    ? theme.colorScheme.primary
                    : null,
              ),
              title: const Text('Default Phone App'),
              subtitle: _isDefaultDialer == null
                  ? const Text('Checking…')
                  : _isDefaultDialer!
                      ? const Text(
                          'LeadPilot is your default dialer — full in-call UI for all calls',
                        )
                      : const Text(
                          'Set LeadPilot as default dialer to show CRM info during all calls',
                        ),
              trailing: _isDefaultDialer == null
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _isDefaultDialer!
                      ? Icon(
                          Icons.check_circle_rounded,
                          color: theme.colorScheme.primary,
                        )
                      : FilledButton.tonal(
                          onPressed: _requestDefaultDialer,
                          child: const Text('Set Default'),
                        ),
              onTap: _isDefaultDialer == true ? null : _requestDefaultDialer,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            color: theme.colorScheme.surfaceContainerLow,
            child: SwitchListTile(
              secondary: Icon(
                Icons.fiber_manual_record_rounded,
                color: _autoRecord ? Colors.red : null,
              ),
              title: const Text('Auto-Record Calls'),
              subtitle: const Text(
                'Automatically record calls locally when set as Default Phone App',
              ),
              value: _autoRecord,
              onChanged: (val) async {
                setState(() => _autoRecord = val);
                await CallerIdService.setAutoRecordEnabled(val);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Caller ID Small Page
// ─────────────────────────────────────────────────────────────────────────────

class _CallerIdSettingsSubPage extends StatelessWidget {
  const _CallerIdSettingsSubPage({
    required this.callerIdEnabled,
    required this.hasOverlayPermission,
    required this.hasPhonePermissions,
    required this.isIgnoringBattery,
    required this.cachedCount,
    required this.studentsCount,
    required this.onToggleCallerId,
    required this.onRequestPermissions,
    required this.onTestPopup,
    required this.onTestBanner,
    required this.onAllowBattery,
    required this.onXiaomiFix,
    required this.onResyncLeads,
  });

  final bool callerIdEnabled;
  final bool hasOverlayPermission;
  final bool hasPhonePermissions;
  final bool isIgnoringBattery;
  final int cachedCount;
  final int studentsCount;
  final ValueChanged<bool> onToggleCallerId;
  final VoidCallback onRequestPermissions;
  final VoidCallback onTestPopup;
  final VoidCallback onTestBanner;
  final VoidCallback onAllowBattery;
  final VoidCallback onXiaomiFix;
  final VoidCallback onResyncLeads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Caller ID'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Card(
            color: theme.colorScheme.surfaceContainerLow,
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.phone_in_talk_rounded),
                  title: const Text('Incoming Caller ID Popup'),
                  subtitle: Text(
                    callerIdEnabled
                        ? (hasOverlayPermission && hasPhonePermissions
                            ? 'Active • $cachedCount lead(s) cached offline'
                            : 'Permission required for call detection')
                        : 'Disabled',
                  ),
                  value: callerIdEnabled,
                  onChanged: onToggleCallerId,
                ),
                if (callerIdEnabled &&
                    (!hasOverlayPermission || !hasPhonePermissions)) ...[
                  Divider(
                    height: 1,
                    indent: 56,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: Color(0xFFFFAA48),
                              size: 18,
                            ),
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
                          !hasPhonePermissions
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
                          onPressed: onRequestPermissions,
                        ),
                      ],
                    ),
                  ),
                ],
                if (callerIdEnabled) ...[
                  Divider(
                    height: 1,
                    indent: 56,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  ListTile(
                    leading: const Icon(Icons.sync_rounded),
                    title: const Text('Re-sync Leads to Phone'),
                    subtitle: Text('$cachedCount student lead(s) stored in phone'),
                    trailing: TextButton(
                      onPressed: onResyncLeads,
                      child: const Text('Sync'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Collapsed Advanced section
          Card(
            color: theme.colorScheme.surfaceContainerLow,
            child: ExpansionTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text(
                'Advanced',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Preview, alert banner & manufacturer background fix',
              ),
              initiallyExpanded: false,
              children: [
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
                  onTap: onTestPopup,
                ),
                Divider(
                  height: 1,
                  indent: 56,
                  color: theme.colorScheme.outlineVariant,
                ),
                ListTile(
                  leading: const Icon(Icons.notification_important_rounded),
                  title: const Text('Test Lock Screen & Heads-Up Banner'),
                  subtitle: const Text('Display a sample calling alert banner'),
                  onTap: onTestBanner,
                ),
                if (!isIgnoringBattery) ...[
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
                      onPressed: onAllowBattery,
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
                  onTap: onXiaomiFix,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Data Small Page
// ─────────────────────────────────────────────────────────────────────────────

class _DataSettingsSubPage extends StatelessWidget {
  const _DataSettingsSubPage({
    required this.hasActiveFilters,
    required this.onExportCsv,
    required this.onOpenReports,
    required this.onSaveContacts,
    required this.onOpenFilters,
  });

  final bool hasActiveFilters;
  final VoidCallback onExportCsv;
  final VoidCallback onOpenReports;
  final VoidCallback onSaveContacts;
  final VoidCallback onOpenFilters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Data'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Card(
            color: theme.colorScheme.surfaceContainerLow,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('Download CSV report'),
                  subtitle: const Text(
                    'Export the students matching your current filters',
                  ),
                  onTap: onExportCsv,
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
                  onTap: onOpenReports,
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
                  onTap: onSaveContacts,
                ),
                Divider(
                  height: 1,
                  indent: 56,
                  color: theme.colorScheme.outlineVariant,
                ),
                ListTile(
                  leading: Badge(
                    isLabelVisible: hasActiveFilters,
                    child: const Icon(Icons.tune_rounded),
                  ),
                  title: const Text('Filter by date and call status'),
                  subtitle: const Text(
                    'Choose a date range and status such as No Answer',
                  ),
                  onTap: onOpenFilters,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Security Small Page
// ─────────────────────────────────────────────────────────────────────────────

class _SecuritySettingsSubPage extends StatefulWidget {
  const _SecuritySettingsSubPage({
    required this.biometricEnabled,
    required this.onBiometricChanged,
  });

  final bool biometricEnabled;
  final Future<void> Function(bool) onBiometricChanged;

  @override
  State<_SecuritySettingsSubPage> createState() =>
      _SecuritySettingsSubPageState();
}

class _SecuritySettingsSubPageState extends State<_SecuritySettingsSubPage> {
  late bool _biometricEnabled = widget.biometricEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Security'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Card(
            color: theme.colorScheme.surfaceContainerLow,
            child: SwitchListTile(
              secondary: const Icon(Icons.fingerprint_rounded),
              title: const Text('Fingerprint Login'),
              subtitle: const Text('Use fingerprint to log in instead of PIN'),
              value: _biometricEnabled,
              onChanged: (val) {
                setState(() => _biometricEnabled = val);
                unawaited(widget.onBiometricChanged(val));
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Appearance Small Page
// ─────────────────────────────────────────────────────────────────────────────

class _AppearanceSettingsSubPage extends StatelessWidget {
  const _AppearanceSettingsSubPage({
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeModeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appearance'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        children: [
          Card(
            color: theme.colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<ThemeMode>(
                key: ValueKey(themeMode),
                initialValue: themeMode,
                decoration: const InputDecoration(
                  labelText: 'Theme',
                  prefixIcon: Icon(Icons.palette_outlined),
                  border: OutlineInputBorder(),
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
                  DropdownMenuItem(
                    value: ThemeMode.dark,
                    child: Text('Dark'),
                  ),
                ],
                onChanged: (mode) {
                  if (mode != null) unawaited(onThemeModeChanged(mode));
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. Updates & About Small Page
// ─────────────────────────────────────────────────────────────────────────────

class _UpdatesAboutSettingsSubPage extends StatefulWidget {
  const _UpdatesAboutSettingsSubPage({
    required this.isCheckingUpdate,
    required this.autoCheckUpdates,
    required this.onCheckForUpdates,
    required this.onAutoCheckChanged,
  });

  final bool isCheckingUpdate;
  final bool autoCheckUpdates;
  final VoidCallback onCheckForUpdates;
  final ValueChanged<bool> onAutoCheckChanged;

  @override
  State<_UpdatesAboutSettingsSubPage> createState() =>
      _UpdatesAboutSettingsSubPageState();
}

class _UpdatesAboutSettingsSubPageState
    extends State<_UpdatesAboutSettingsSubPage> {
  late bool _autoCheckUpdates = widget.autoCheckUpdates;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Updates & About'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Card(
            color: theme.colorScheme.surfaceContainerLow,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.system_update_rounded),
                  title: const Text('Check for Updates'),
                  subtitle: Text(
                    widget.isCheckingUpdate
                        ? 'Checking GitHub for updates...'
                        : 'Current version: v$kAppVersion',
                  ),
                  trailing: widget.isCheckingUpdate
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          key: const Key('check_updates_button'),
                          onPressed: widget.onCheckForUpdates,
                          child: const Text('Check'),
                        ),
                  onTap:
                      widget.isCheckingUpdate ? null : widget.onCheckForUpdates,
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
                  onChanged: (val) {
                    setState(() => _autoCheckUpdates = val);
                    widget.onAutoCheckChanged(val);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Column(
              children: [
                Text(
                  'LeadPilot v$kAppVersion',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Student lead management & call CRM',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
