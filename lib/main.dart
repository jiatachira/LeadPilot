import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;
import 'package:url_launcher/url_launcher.dart';


// Modular Architecture Parts
part 'core/constants.dart';
part 'models/student_activity.dart';
part 'models/scheduled_reminder.dart';
part 'models/linked_sheet.dart';
part 'models/whatsapp_template.dart';
part 'models/save_contacts_result.dart';
part 'services/contacts_service.dart';
part 'services/storage_service.dart';
part 'services/caller_id_service.dart';
part 'services/reminder_service.dart';
part 'widgets/leadpilot_app_icon.dart';
part 'screens/splash_screen.dart';
part 'screens/pin_screen.dart';
part 'models/call_attempt.dart';
part 'models/student.dart';
part 'models/lead_models.dart';
part 'services/gemini_service.dart';
part 'services/google_sheet_service.dart';
part 'models/app_update_info.dart';
part 'services/voice_to_text_service.dart';
part 'services/app_update_service.dart';
part 'services/app_installer_service.dart';
part 'widgets/dialogs/app_update_dialog.dart';
part 'screens/home_screen.dart';
part 'widgets/dialogs/student_history_dialog.dart';
part 'widgets/dialogs/lead_filter_sheet.dart';
part 'widgets/student_card.dart';
part 'widgets/voice_ai_remark_controls.dart';
part 'screens/edit_details_screen.dart';
part 'screens/settings_screen.dart';
part 'widgets/dialogs/edit_student_sheet.dart';
part 'widgets/dialogs/add_student_sheet.dart';
part 'widgets/dialogs/lead_reports_sheet.dart';
part 'widgets/dialogs/settings_hub_sheet.dart';
part 'widgets/dialogs/sheet_settings_sheet.dart';
part 'widgets/dialogs/message_choice_sheets.dart';
part 'widgets/dialogs/whatsapp_template_picker_sheet.dart';
part 'widgets/dialogs/bulk_dispatch_sheet.dart';
part 'widgets/dialogs/manage_gemini_ai_sheet.dart';
part 'widgets/dialogs/gemini_ai_message_sheet.dart';
part 'widgets/dialogs/dialpad_sheet.dart';

// Entry Point & Root Application Widget
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  timezone.setLocalLocation(timezone.UTC);
  await LocalReminderService.initialize();
  runApp(const StudentCallApp());
}

void _handleReminderNotificationResponse(NotificationResponse response) {
  final student = _studentFromReminderPayload(response.payload);
  if (student == null) return;

  if (response.actionId == 'call_student') {
    unawaited(_callStudentFromReminder(student));
  } else if (response.actionId == 'snooze_reminder') {
    unawaited(_snoozeReminder(student));
  } else {
    _queueReminderPopup(student);
  }
}

void _queueReminderPopup(Student student) {
  _pendingReminderPopups.add(student);
  _showNextReminderPopup();
}

void _showNextReminderPopup() {
  final context = _appNavigatorKey.currentContext;
  if (_isShowingReminderPopup ||
      _pendingReminderPopups.isEmpty ||
      context == null) {
    return;
  }

  final student = _pendingReminderPopups.removeAt(0);
  _isShowingReminderPopup = true;

  // 🔔 Start ringing when the popup appears.
  unawaited(_playReminderRingtone());

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.alarm_rounded, color: _green, size: 36),
        title: const Text('Upcoming Call Reminder'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              student.name,
              textAlign: TextAlign.center,
              style: Theme.of(dialogContext).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(student.phone),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              unawaited(_stopReminderRingtone()); // 🔕 Stop ring on snooze
              Navigator.of(dialogContext).pop();
              await _snoozeReminder(student);
            },
            icon: const Icon(Icons.snooze_rounded),
            label: const Text('Snooze 5 min'),
          ),
          FilledButton.icon(
            onPressed: () async {
              unawaited(_stopReminderRingtone()); // 🔕 Stop ring on call
              Navigator.of(dialogContext).pop();
              await _callStudentFromReminder(student);
            },
            icon: const Icon(Icons.call_rounded),
            label: const Text('Call'),
          ),
        ],
      ),
    ).then((_) {
      // 🔕 Also stop ring if dialog dismissed by any other means.
      unawaited(_stopReminderRingtone());
      _isShowingReminderPopup = false;
      _showNextReminderPopup();
    }),
  );
}

@pragma('vm:entry-point')
void _handleBackgroundReminderNotificationResponse(
  NotificationResponse response,
) async {
  if (response.actionId != 'snooze_reminder') return;
  WidgetsFlutterBinding.ensureInitialized();
  final student = _studentFromReminderPayload(response.payload);
  if (student != null) await _snoozeReminder(student);
}

Student? _studentFromReminderPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) return null;
    final name = decoded['name']?.toString().trim() ?? '';
    final phone = decoded['phone']?.toString().trim() ?? '';
    if (name.isEmpty || phone.isEmpty) return null;
    return Student(name: name, phone: phone);
  } on FormatException catch (error) {
    debugPrint('Invalid student reminder payload: $error');
    return null;
  }
}

Future<void> _callStudentFromReminder(Student student) async {
  try {
    final launched = await launchUrl(Uri.parse('tel:${student.phone}'));
    if (!launched) {
      debugPrint('Could not open the phone dialer for ${student.name}.');
    }
  } on Exception catch (error) {
    debugPrint('Could not start the reminder call: $error');
  }
}

Future<void> _snoozeReminder(Student student) async {
  try {
    await LocalReminderService().scheduleStudentReminder(
      student,
      snoozedReminderDateTime(DateTime.now()),
    );
  } on Exception catch (error) {
    debugPrint('Could not snooze the reminder for ${student.name}: $error');
  }
}

class StudentCallApp extends StatefulWidget {
  const StudentCallApp({
    this.httpClient,
    this.reminderScheduler,
    this.settingsStore,
    this.deviceContactsService,
    this.updateService,
    this.showSplash = true,
    super.key,
  });

  final http.Client? httpClient;
  final ReminderScheduler? reminderScheduler;
  final AppSettingsStore? settingsStore;
  final DeviceContactsService? deviceContactsService;
  final AppUpdateService? updateService;
  final bool showSplash;

  @override
  State<StudentCallApp> createState() => _StudentCallAppState();
}

class _StudentCallAppState extends State<StudentCallApp> {
  late bool _showSplash = widget.showSplash;
  String? _pin;
  String _sheetConfig = '';
  String _sheetName = '';
  List<LinkedSheet> _linkedSheets = const [];
  ThemeMode _themeMode = ThemeMode.system;
  bool _isFirstTime = true;
  bool _isAuthenticated = false;
  bool _isLoadingSettings = true;
  bool _biometricEnabled = false;
  Object? _settingsLoadError;
  late final AppSettingsStore _settingsStore =
      widget.settingsStore ?? SecureAppSettingsStore();
  late final GoogleSheetService _sheetService = GoogleSheetService(
    client: widget.httpClient,
  );
  late final ReminderScheduler _reminderScheduler =
      widget.reminderScheduler ?? LocalReminderService();
  final _localAuth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
  }

  @override
  void dispose() {
    _sheetService.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lightColorScheme = ColorScheme.fromSeed(
      seedColor: _navy,
      primary: _navy,
      secondary: _green,
      surface: Colors.white,
    );
    final darkColorScheme = ColorScheme.fromSeed(
      seedColor: _green,
      brightness: Brightness.dark,
      primary: const Color(0xFFB7C9E0),
      secondary: const Color(0xFF62D6B0),
      surface: const Color(0xFF1B2733),
    );

    return MaterialApp(
      title: 'LeadPilot',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: lightColorScheme,
        scaffoldBackgroundColor: _canvas,
        appBarTheme: const AppBarTheme(
          backgroundColor: _canvas,
          foregroundColor: _navy,
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 17,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE5EAF0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE5EAF0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: _green, width: 1.5),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: darkColorScheme,
        scaffoldBackgroundColor: const Color(0xFF101820),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF101820),
          foregroundColor: Color(0xFFE6EDF5),
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1B2733),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 17,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF344453)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF344453)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF62D6B0), width: 1.5),
          ),
        ),
      ),
      home: _showSplash
          ? AppSplashScreen(
              onFinished: () {
                if (mounted) setState(() => _showSplash = false);
              },
            )
          : _isLoadingSettings
          ? const _AppStartupScreen()
          : _settingsLoadError != null
          ? _SettingsLoadErrorScreen(
              message: _settingsLoadError.toString(),
              onRetry: _loadSavedSettings,
            )
          : _isAuthenticated
          ? HomeScreen(
              sheetConfig: _sheetConfig,
              sheetName: _sheetName,
              linkedSheets: _linkedSheets,
              sheetService: _sheetService,
              reminderScheduler: _reminderScheduler,
              deviceContactsService:
                  widget.deviceContactsService ??
                  const NativeDeviceContactsService(),
              themeMode: _themeMode,
              onLogout: _lockApp,
              onSaveSheetConfig: _saveSheetConfig,
              onThemeModeChanged: _saveThemeMode,
              biometricEnabled: _biometricEnabled,
              onBiometricChanged: _saveBiometricEnabled,
              settingsStore: _settingsStore,
              updateService: widget.updateService,
            )
          : PinScreen(
              key: ValueKey(_isFirstTime),
              isFirstTime: _isFirstTime,
              storedPin: _pin,
              biometricEnabled: _biometricEnabled && !_isFirstTime,
              onBiometricAuth: _tryBiometricLogin,
              onPinCreated: _savePin,
              onAuthenticated: _unlockApp,
            ),
    );
  }

  Future<void> _loadSavedSettings() async {
    setState(() {
      _isLoadingSettings = true;
      _settingsLoadError = null;
    });
    try {
      final values = await Future.wait<Object?>([
        _settingsStore.readPin(),
        _settingsStore.readSheetConfig(),
        _settingsStore.readSheetName(),
        _settingsStore.readLinkedSheets(),
        _settingsStore.readThemeMode(),
        _settingsStore.readBiometricEnabled(),
      ]);
      if (!mounted) return;
      final savedPin = values[0] as String?;
      final savedSheetConfig = values[1] as String;
      final linkedSheets = values[3] as List<LinkedSheet>;
      final savedSheetName = values[2] as String;
      final biometricEnabled = values[5] as bool;
      setState(() {
        _pin = savedPin;
        _isFirstTime = savedPin == null;
        _sheetConfig = savedSheetConfig;
        _sheetName = savedSheetName.isNotEmpty
            ? savedSheetName
            : linkedSheets
                      .where((sheet) => sheet.url == savedSheetConfig)
                      .firstOrNull
                      ?.name ??
                  '';
        _linkedSheets = linkedSheets;
        _themeMode = values[4] as ThemeMode;
        _biometricEnabled = biometricEnabled;
        _isLoadingSettings = false;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _settingsLoadError = error;
        _isLoadingSettings = false;
      });
    }
  }

  bool _isBiometricRunning = false;

  Future<bool> _tryBiometricLogin() async {
    if (_isBiometricRunning) return false;
    _isBiometricRunning = true;
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      if (!canCheck && !isDeviceSupported) {
        debugPrint('Device does not support biometric check');
        return false;
      }
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Scan your fingerprint to log in to LeadPilot',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      if (authenticated && mounted) {
        _unlockApp();
        return true;
      }
      return false;
    } on PlatformException catch (error) {
      debugPrint('Biometric authentication failed: $error');
      return false;
    } catch (error) {
      debugPrint('Unexpected biometric error: $error');
      return false;
    } finally {
      _isBiometricRunning = false;
    }
  }

  Future<void> _savePin(String pin) async {
    await _settingsStore.savePin(pin);
    if (!mounted) return;
    setState(() {
      _pin = pin;
      _isFirstTime = false;
      _isAuthenticated = true;
    });
  }

  void _unlockApp() {
    setState(() => _isAuthenticated = true);
  }

  void _lockApp() {
    setState(() => _isAuthenticated = false);
  }

  Future<void> _saveBiometricEnabled(bool enabled) async {
    await _settingsStore.saveBiometricEnabled(enabled);
    if (!mounted) return;
    setState(() => _biometricEnabled = enabled);
  }

  Future<void> _saveSheetConfig(LinkedSheet config) async {
    await _settingsStore.saveSheetConfig(config.url, name: config.name);
    final linkedSheets = await _settingsStore.readLinkedSheets();
    if (!mounted) return;
    setState(() {
      _sheetConfig = config.url;
      _sheetName = config.name;
      _linkedSheets = linkedSheets;
    });
  }

  Future<void> _saveThemeMode(ThemeMode mode) async {
    await _settingsStore.saveThemeMode(mode);
    if (!mounted) return;
    setState(() => _themeMode = mode);
  }
}

