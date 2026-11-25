part of '../main.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.sheetConfig,
    required this.sheetName,
    required this.linkedSheets,
    required this.sheetService,
    required this.reminderScheduler,
    required this.deviceContactsService,
    required this.themeMode,
    required this.onLogout,
    required this.onSaveSheetConfig,
    required this.onThemeModeChanged,
    required this.biometricEnabled,
    required this.onBiometricChanged,
    this.settingsStore,
    this.updateService,
    super.key,
  });

  final String sheetConfig;
  final String sheetName;
  final List<LinkedSheet> linkedSheets;
  final GoogleSheetService sheetService;
  final ReminderScheduler reminderScheduler;
  final DeviceContactsService deviceContactsService;
  final ThemeMode themeMode;
  final VoidCallback onLogout;
  final Future<void> Function(LinkedSheet) onSaveSheetConfig;
  final Future<void> Function(ThemeMode) onThemeModeChanged;
  final bool biometricEnabled;
  final Future<void> Function(bool) onBiometricChanged;
  final AppSettingsStore? settingsStore;
  final AppUpdateService? updateService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  final List<Student> _students = [];
  final Set<String> _selectedStudentKeys = {};
  late final AppSettingsStore _settingsStore =
      widget.settingsStore ?? SecureAppSettingsStore();
  late final AppUpdateService _updateService =
      widget.updateService ?? AppUpdateService();

  List<QueuedSheetAction> _offlineQueue = [];
  Timer? _offlineQueueRetryTimer;
  bool _isFlushingQueue = false;

  String _query = '';
  _LeadFilter _leadFilter = _LeadFilter.all;
  String _syncStatus = 'Not connected';
  bool _isSyncing = false;
  bool _hasSynced = false;
  int _syncGeneration = 0;
  String? _lastSyncTime;
  String? _statusFilter;
  DateTime? _dateFrom;
  DateTime? _dateTo;
  bool _isSelectionMode = false;

  Student? _pendingCallStudent;
  DateTime? _callStartedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInitialOfflineData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkAndLogCallDuration());
    }
  }

  Future<void> _loadInitialOfflineData() async {
    try {
      final cached = await _settingsStore.readCachedStudents();
      final queue = await _settingsStore.readOfflineQueue();
      if (!mounted) return;
      setState(() {
        _offlineQueue = queue;
        if (cached.isNotEmpty) {
          final merged = <String, Student>{
            for (final s in cached) _studentKey(s): s,
          };
          for (final q in queue) {
            merged[_studentKey(q.student)] = q.student;
          }
          _students
            ..clear()
            ..addAll(merged.values);
        }
        if (queue.isNotEmpty) {
          _syncStatus = '${queue.length} offline change(s) queued';
        }
      });
      if (queue.isNotEmpty) {
        _startOfflineQueueTimer();
      }
      if (_students.isNotEmpty) {
        unawaited(CallerIdService.syncStudents(_students));
      }
    } catch (_) {}

    if (widget.sheetConfig.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncWithGoogleSheet();
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkAutoUpdatesOnStartup();
    });
  }

  Future<void> _checkAutoUpdatesOnStartup() async {
    try {
      final enabled = await _settingsStore.readAutoCheckUpdates();
      if (!enabled) return;
      final info =
          await _updateService.checkForUpdates(currentVersion: kAppVersion);
      if (info.hasUpdate && mounted) {
        await showAppUpdateDialog(context, info);
      }
    } catch (_) {
      // Silent catch on app startup if offline or failed
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _offlineQueueRetryTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _startOfflineQueueTimer() {
    _offlineQueueRetryTimer?.cancel();
    _offlineQueueRetryTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) {
        if (mounted && _offlineQueue.isNotEmpty && !_isSyncing) {
          _flushOfflineQueue();
        }
      },
    );
  }

  void _stopOfflineQueueTimer() {
    _offlineQueueRetryTimer?.cancel();
    _offlineQueueRetryTimer = null;
  }

  Future<void> _enqueueOfflineAction(QueuedSheetAction action) async {
    final phoneKey = normalizeContactPhone(action.student.phone);
    final previousPhoneKey = action.previousPhone != null
        ? normalizeContactPhone(action.previousPhone!)
        : null;

    final existingIndex = _offlineQueue.indexWhere((item) {
      final itemPhone = normalizeContactPhone(item.student.phone);
      return itemPhone == phoneKey ||
          (previousPhoneKey != null && itemPhone == previousPhoneKey);
    });

    if (existingIndex >= 0) {
      final existing = _offlineQueue[existingIndex];
      final preservedAction = existing.action == 'add' ? 'add' : action.action;
      _offlineQueue[existingIndex] = QueuedSheetAction(
        id: existing.id,
        action: preservedAction,
        student: action.student,
        previousPhone: existing.previousPhone ?? action.previousPhone,
        queuedAt: DateTime.now(),
      );
    } else {
      _offlineQueue.add(action);
    }

    await _settingsStore.saveOfflineQueue(_offlineQueue);
    await _settingsStore.saveCachedStudents(_students);
    _startOfflineQueueTimer();

    if (mounted) {
      setState(() {
        _syncStatus = '${_offlineQueue.length} offline change(s) queued';
      });
    }
  }

  Future<int> _flushOfflineQueue() async {
    if (_isFlushingQueue ||
        _offlineQueue.isEmpty ||
        widget.sheetConfig.isEmpty) {
      return 0;
    }
    _isFlushingQueue = true;
    var syncedCount = 0;
    final remainingQueue = List<QueuedSheetAction>.of(_offlineQueue);

    for (final item in _offlineQueue) {
      try {
        if (item.action == 'add') {
          await widget.sheetService.addStudentToSheet(
            widget.sheetConfig,
            item.student,
          );
        } else {
          await widget.sheetService.updateStudentInSheet(
            widget.sheetConfig,
            item.student,
            previousPhone: item.previousPhone,
          );
        }
        remainingQueue.remove(item);
        syncedCount++;
      } catch (_) {
        // Network still unavailable or rejected; break out so we retry later
        break;
      }
    }

    _offlineQueue = remainingQueue;
    await _settingsStore.saveOfflineQueue(_offlineQueue);
    _isFlushingQueue = false;

    if (syncedCount > 0 && mounted) {
      setState(() {
        if (_offlineQueue.isEmpty) {
          _stopOfflineQueueTimer();
          _syncStatus =
              'All offline changes synced! · ${_formattedSyncTime()}';
        } else {
          _syncStatus = '${_offlineQueue.length} offline change(s) queued';
        }
      });
      await _settingsStore.saveCachedStudents(_students);
    }
    return syncedCount;
  }

  List<Student> get _filteredStudents {
    final query = _query.trim().toLowerCase();
    final statusFilter = _statusFilter?.trim().toLowerCase();
    final filtered = <Student>[];

    for (var i = 0; i < _students.length; i++) {
      final student = _students[i];
      if (isFinalLeadStatus(student.callStatus) &&
          (statusFilter == null ||
              statusFilter != student.callStatus.trim().toLowerCase())) {
        continue;
      }
      if (!_matchesLeadFilter(student)) continue;
      if (query.isNotEmpty && !_matchesSearch(student, query)) continue;
      filtered.add(student);
    }

    if (filtered.length > 1) {
      final indexMap = {
        for (var i = 0; i < filtered.length; i++) filtered[i]: i,
      };
      filtered.sort(
        _leadFilter == _LeadFilter.todayFollowUp
            ? (a, b) => _compareStudentsByFollowUpDate(a, b, indexMap)
            : (a, b) => _compareStudentsByNewestDate(a, b, indexMap),
      );
    }
    return filtered;
  }

  List<Student> get _selectedStudents => _students
      .where(
        (student) =>
            !isFinalLeadStatus(student.callStatus) &&
            _selectedStudentKeys.contains(_selectionKey(student)),
      )
      .toList();

  String _selectionKey(Student student) {
    final phone = normalizeContactPhone(student.phone);
    return phone.isEmpty ? student.name.trim().toLowerCase() : phone;
  }

  void _startSelection(Student student) {
    setState(() {
      _isSelectionMode = true;
      _selectedStudentKeys.add(_selectionKey(student));
    });
  }

  void _toggleStudentSelection(Student student) {
    final key = _selectionKey(student);
    setState(() {
      if (_selectedStudentKeys.contains(key)) {
        _selectedStudentKeys.remove(key);
        if (_selectedStudentKeys.isEmpty) _isSelectionMode = false;
      } else {
        _isSelectionMode = true;
        _selectedStudentKeys.add(key);
      }
    });
  }

  void _clearStudentSelection() {
    setState(() {
      _isSelectionMode = false;
      _selectedStudentKeys.clear();
    });
  }

  void _toggleSelectAll(List<Student> displayedStudents) {
    setState(() {
      final allKeys = displayedStudents.map(_selectionKey).toSet();
      final allSelected = allKeys.isNotEmpty &&
          allKeys.every(_selectedStudentKeys.contains);
      if (allSelected) {
        _selectedStudentKeys.removeAll(allKeys);
        if (_selectedStudentKeys.isEmpty) _isSelectionMode = false;
      } else {
        _isSelectionMode = true;
        _selectedStudentKeys.addAll(allKeys);
      }
    });
  }

  int _compareStudentsByFollowUpDate(
    Student left,
    Student right, [
    Map<Student, int>? indexMap,
  ]) {
    final leftDate = left.parsedNextCallDate;
    final rightDate = right.parsedNextCallDate;
    if (leftDate == null || rightDate == null) {
      if (leftDate == null && rightDate != null) return 1;
      if (rightDate == null && leftDate != null) return -1;
      final leftIdx = indexMap?[left] ?? _students.indexOf(left);
      final rightIdx = indexMap?[right] ?? _students.indexOf(right);
      return leftIdx.compareTo(rightIdx);
    }
    final dateComparison = leftDate.compareTo(rightDate);
    if (dateComparison != 0) return dateComparison;
    final leftIdx = indexMap?[left] ?? _students.indexOf(left);
    final rightIdx = indexMap?[right] ?? _students.indexOf(right);
    return leftIdx.compareTo(rightIdx);
  }

  int _compareStudentsByNewestDate(
    Student left,
    Student right, [
    Map<Student, int>? indexMap,
  ]) {
    final leftDate = left.parsedAddedDate;
    final rightDate = right.parsedAddedDate;
    if (leftDate == null || rightDate == null) {
      if (leftDate == null && rightDate != null) return 1;
      if (rightDate == null && leftDate != null) return -1;
      final leftIdx = indexMap?[left] ?? _students.indexOf(left);
      final rightIdx = indexMap?[right] ?? _students.indexOf(right);
      return leftIdx.compareTo(rightIdx);
    }
    final dateComparison = rightDate.compareTo(leftDate);
    if (dateComparison != 0) return dateComparison;
    final leftIdx = indexMap?[left] ?? _students.indexOf(left);
    final rightIdx = indexMap?[right] ?? _students.indexOf(right);
    return leftIdx.compareTo(rightIdx);
  }

  bool _matchesCategory(Student student, _LeadFilter filter) {
    final normalizedStatus = student.callStatus.trim().toLowerCase();
    if (_statusFilter != null &&
        normalizedStatus != _statusFilter!.toLowerCase()) {
      return false;
    }

    final from = _dateFrom;
    final to = _dateTo;
    if (from != null || to != null) {
      final addedDate = student.parsedAddedDate;
      if (addedDate == null) return false;
      final day = DateTime(addedDate.year, addedDate.month, addedDate.day);
      if (from != null && day.isBefore(_dateOnly(from))) return false;
      if (to != null && day.isAfter(_dateOnly(to))) return false;
    }

    switch (filter) {
      case _LeadFilter.all:
        return true;
      case _LeadFilter.newLeads:
        return student.callStatus.trim().toLowerCase() == 'pending';
      case _LeadFilter.todayFollowUp:
        final nextCall = student.parsedNextCallDate;
        final today = DateTime.now();
        if (nextCall == null ||
            !nextCall.isBefore(
              DateTime(today.year, today.month, today.day + 1),
            )) {
          return false;
        }
        return !student.attempts.any((attempt) {
          final attemptedAt = tryParseDate(attempt.dateTime);
          return attemptedAt != null && !attemptedAt.isBefore(nextCall);
        });
    }
  }

  bool _matchesLeadFilter(Student student) =>
      _matchesCategory(student, _leadFilter);

  int _countForCategory(_LeadFilter filter) {
    final statusFilter = _statusFilter?.trim().toLowerCase();
    final query = _query.trim().toLowerCase();
    var count = 0;
    for (var i = 0; i < _students.length; i++) {
      final student = _students[i];
      if (isFinalLeadStatus(student.callStatus) &&
          (statusFilter == null ||
              statusFilter != student.callStatus.trim().toLowerCase())) {
        continue;
      }
      if (!_matchesCategory(student, filter)) continue;
      if (query.isNotEmpty && !_matchesSearch(student, query)) continue;
      count++;
    }
    return count;
  }

  bool _matchesSearch(Student student, String query) {
    return student.searchIndex.contains(query);
  }

  Future<void> _addStudent() async {
    final entries = await showModalBottomSheet<List<Student>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddStudentSheet(),
    );
    if (entries == null || entries.isEmpty || !mounted) return;

    setState(() => _students.insertAll(0, entries));
    if (widget.sheetConfig.isEmpty) {
      _showMessage(
        '${entries.length} student(s) saved locally. Configure the Google Sheet URL to sync.',
      );
      return;
    }

    setState(() {
      _isSyncing = true;
      _syncStatus = 'Sending students…';
    });

    final failures = <String>[];
    for (final student in entries) {
      try {
        await widget.sheetService.addStudentToSheet(
          widget.sheetConfig,
          student,
        );
      } on SheetApiException catch (error) {
        failures.add('${student.name}: ${error.message}');
        await _enqueueOfflineAction(
          QueuedSheetAction(
            id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
            action: 'add',
            student: student,
            queuedAt: DateTime.now(),
          ),
        );
      } on http.ClientException catch (error) {
        failures.add('${student.name}: network error (${error.message})');
        await _enqueueOfflineAction(
          QueuedSheetAction(
            id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
            action: 'add',
            student: student,
            queuedAt: DateTime.now(),
          ),
        );
      } on TimeoutException {
        failures.add('${student.name}: request timed out');
        await _enqueueOfflineAction(
          QueuedSheetAction(
            id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
            action: 'add',
            student: student,
            queuedAt: DateTime.now(),
          ),
        );
      } on FormatException catch (error) {
        failures.add('${student.name}: ${error.message}');
        await _enqueueOfflineAction(
          QueuedSheetAction(
            id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
            action: 'add',
            student: student,
            queuedAt: DateTime.now(),
          ),
        );
      } on Exception catch (error) {
        failures.add('${student.name}: $error');
        await _enqueueOfflineAction(
          QueuedSheetAction(
            id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
            action: 'add',
            student: student,
            queuedAt: DateTime.now(),
          ),
        );
      }
    }
    await _settingsStore.saveCachedStudents(_students);

    if (!mounted) return;
    if (failures.isEmpty) {
      setState(() {
        _isSyncing = false;
        _hasSynced = true;
        _lastSyncTime = _formattedSyncTime();
        _syncStatus = 'Synced · $_lastSyncTime';
      });
      _showMessage('Student(s) saved and synced to Google Sheet!');
    } else {
      setState(() {
        _isSyncing = false;
        _hasSynced = false;
        _syncStatus = 'Sync failed';
      });
      _showMessage(
        '${failures.length} of ${entries.length} student(s) could not be synced. '
        'They remain in the local list. ${failures.join(' • ')}',
      );
    }
  }

  Future<void> _editStudent(Student student) async {
    final scheduledNextCalls = _students
        .where((s) => s.phone != student.phone)
        .map((s) => tryParseDate(s.nextCallDateTime))
        .whereType<DateTime>()
        .toList();
    final updatedStudent = await showModalBottomSheet<Student>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditStudentSheet(
        student: student,
        settingsStore: _settingsStore,
        onWhatsApp: _openWhatsAppChat,
        onDetailsSaved: _persistStudentUpdate,
        scheduledNextCalls: scheduledNextCalls,
      ),
    );
    if (updatedStudent == null || !mounted) return;
    await _persistStudentUpdate(student, updatedStudent);
  }

  Future<void> _persistStudentUpdate(
    Student student,
    Student updatedStudent,
  ) async {
    final index = _students.indexOf(student);
    if (index < 0) return;
    setState(() {
      _students[index] = updatedStudent;
    });

    await _updateStudentReminder(student, updatedStudent);
    if (!mounted) return;

    if (widget.sheetConfig.isEmpty) {
      _showMessage('Student details updated on this device.');
      await _settingsStore.saveCachedStudents(_students);
      return;
    }

    setState(() {
      _isSyncing = true;
      _syncStatus = 'Updating student…';
    });
    try {
      await widget.sheetService.updateStudentInSheet(
        widget.sheetConfig,
        updatedStudent,
        previousPhone: student.phone,
      );
      if (!mounted) return;
      _offlineQueue.removeWhere((item) =>
          normalizeContactPhone(item.student.phone) ==
          normalizeContactPhone(student.phone));
      await _settingsStore.saveOfflineQueue(_offlineQueue);
      await _settingsStore.saveCachedStudents(_students);

      setState(() {
        _isSyncing = false;
        _hasSynced = true;
        _lastSyncTime = _formattedSyncTime();
        if (_offlineQueue.isEmpty) {
          _syncStatus = 'Synced · $_lastSyncTime';
        } else {
          _syncStatus = '${_offlineQueue.length} offline change(s) queued';
        }
      });
      _showMessage('Student details updated and synced to Google Sheets.');
    } catch (error) {
      if (!mounted) return;
      await _enqueueOfflineAction(
        QueuedSheetAction(
          id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
          action: 'update',
          student: updatedStudent,
          previousPhone: student.phone,
          queuedAt: DateTime.now(),
        ),
      );
      setState(() {
        _isSyncing = false;
        _hasSynced = false;
        _syncStatus = 'Sync failed';
      });
      _showMessage(
        'Details updated locally, but could not be synced. $error',
      );
    } finally {
      if (mounted && _isSyncing) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  Future<void> _updateStudentReminder(
    Student previousStudent,
    Student updatedStudent,
  ) async {
    try {
      final previousCall = tryParseDate(previousStudent.nextCallDateTime);
      final nextCall = tryParseDate(updatedStudent.nextCallDateTime);
      if (nextCall == null || !nextCall.isAfter(DateTime.now())) {
        if (previousCall != null) {
          await widget.reminderScheduler.cancelStudentReminder(previousStudent);
        }
      } else {
        if (!await _ensureExactAlarmPermission()) return;
        final contactChanged =
            normalizeContactPhone(previousStudent.phone) !=
            normalizeContactPhone(updatedStudent.phone);
        if (previousCall != null &&
            (previousCall != nextCall || contactChanged)) {
          await widget.reminderScheduler.cancelStudentReminder(previousStudent);
        }
        try {
          await widget.reminderScheduler.scheduleStudentReminder(
            updatedStudent,
            nextCall,
          );
        } on PlatformException catch (error) {
          if (error.code != 'exact_alarms_not_permitted' ||
              !await _ensureExactAlarmPermission(forceRequest: true)) {
            rethrow;
          }
          await widget.reminderScheduler.scheduleStudentReminder(
            updatedStudent,
            nextCall,
          );
        }
      }
    } on StateError catch (error) {
      if (mounted) {
        _showMessage(
          'Student saved, but reminder was not set. ${error.message}',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        _showMessage(
          error.code == 'exact_alarms_not_permitted'
              ? 'Exact alarm access is still off. Allow it in Android Settings, then save the reminder again.'
              : 'Student saved, but Android could not set the reminder (${error.code}).',
        );
      }
    } on Exception catch (error) {
      if (mounted) {
        _showMessage('Student saved, but reminder was not set. $error');
      }
    }
  }

  Future<bool> _ensureExactAlarmPermission({bool forceRequest = false}) async {
    if (!forceRequest &&
        await widget.reminderScheduler.canScheduleExactAlarms()) {
      return true;
    }
    if (!mounted) return false;

    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.alarm_rounded, color: _green),
        title: const Text('Allow exact call reminders'),
        content: const Text(
          'Android requires the “Alarms & reminders” permission to notify you '
          'at the exact time selected. Tap below, then allow this app in the '
          'Android Settings screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (openSettings != true || !mounted) return false;

    final granted = await widget.reminderScheduler
        .requestExactAlarmsPermission();
    if (!granted && mounted) {
      _showMessage(
        'Exact alarm access was not enabled. Allow it in Android Settings and try again.',
      );
    }
    return granted;
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          themeMode: widget.themeMode,
          onThemeModeChanged: _changeThemeMode,
          isSheetConnected: widget.sheetConfig.isNotEmpty,
          sheetUrl: widget.sheetConfig,
          sheetName: widget.sheetName,
          savedSheets: widget.linkedSheets,
          onSaveSheetConfig: (savedConfig) async {
            await widget.onSaveSheetConfig(savedConfig);
            if (mounted) {
              await _syncWithGoogleSheet(url: savedConfig.url);
            }
          },
          hasActiveFilters: _hasActiveFilters,
          biometricEnabled: widget.biometricEnabled,
          onBiometricChanged: widget.onBiometricChanged,
          students: _students,
          filteredStudents: _filteredStudents,
          settingsStore: _settingsStore,
          updateService: _updateService,
          onOpenLeadFilters: _openLeadFilters,
          onExportCsv: () => _exportStudentsToCsv(_filteredStudents),
          onOpenLeadReports: _openLeadReports,
          onSaveVisibleContacts: _saveVisibleContacts,
        ),
      ),
    );
  }

  Future<void> _openWhatsAppTemplatesSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ManageWhatsAppTemplatesSheet(
        settingsStore: _settingsStore,
      ),
    );
  }

  Future<void> _openLeadFilters() async {
    final filters = await showModalBottomSheet<_LeadFilterSelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LeadFilterSheet(
        initialStatus: _statusFilter,
        initialDateFrom: _dateFrom,
        initialDateTo: _dateTo,
      ),
    );
    if (filters == null || !mounted) return;
    setState(() {
      _statusFilter = filters.callStatus;
      _dateFrom = filters.dateFrom;
      _dateTo = filters.dateTo;
    });
  }

  Future<void> _openLeadReports() async {
    final action = await showModalBottomSheet<_LeadReportAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LeadReportsSheet(
        notInterestedCount: _students
            .where((student) => isNotInterestedStatus(student.callStatus))
            .length,
        notPotentialCount: _students
            .where((student) => isNotPotentialStatus(student.callStatus))
            .length,
        inactiveCount: _students
            .where((student) => isInactiveStatus(student.callStatus))
            .length,
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case _LeadReportAction.notInterested:
        await _exportStudentsToCsv(
          _students
              .where((student) => isNotInterestedStatus(student.callStatus))
              .toList(),
          fileName: 'not_interested_students.csv',
          title: 'Not Interested report',
          emptyMessage: 'There are no students in this report to export.',
        );
      case _LeadReportAction.notPotential:
        await _exportStudentsToCsv(
          _students
              .where((student) => isNotPotentialStatus(student.callStatus))
              .toList(),
          fileName: 'not_potential_students.csv',
          title: 'Not Potential report',
          emptyMessage: 'There are no students in this report to export.',
        );
      case _LeadReportAction.inactive:
        await _exportStudentsToCsv(
          _students
              .where((student) => isInactiveStatus(student.callStatus))
              .toList(),
          fileName: 'inactive_students.csv',
          title: 'Inactive report',
          emptyMessage: 'There are no students in this report to export.',
        );
    }
  }

  bool get _hasActiveFilters =>
      _statusFilter != null || _dateFrom != null || _dateTo != null;

  Future<void> _changeThemeMode(ThemeMode mode) async {
    try {
      await widget.onThemeModeChanged(mode);
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not save theme setting: $error');
    }
  }

  Future<void> _syncWithGoogleSheet({String? url}) async {
    final endpoint = (url ?? widget.sheetConfig).trim();
    if (endpoint.isEmpty) {
      if (mounted) {
        setState(() {
          _syncStatus = 'Not connected';
          _hasSynced = false;
          _lastSyncTime = null;
        });
      }
      return;
    }

    final syncGeneration = ++_syncGeneration;
    setState(() {
      _isSyncing = true;
      _syncStatus = 'Syncing…';
    });
    try {
      await _flushOfflineQueue();

      final sheetStudents = await widget.sheetService.fetchStudentsFromSheet(
        endpoint,
      );
      if (!mounted || syncGeneration != _syncGeneration) return;
      final currentStudentsByKey = {
        for (final s in _students) _studentKey(s): s,
      };
      final merged = <String, Student>{};
      for (final student in sheetStudents) {
        final key = _studentKey(student);
        final current = currentStudentsByKey[key];
        if (current != null && isFinalLeadStatus(current.callStatus)) {
          // If the sheet did not mark it final, preserve the locally marked final status (Inactive, Not Interested, Not Potential)
          if (!isFinalLeadStatus(student.callStatus)) {
            merged[key] = student.copyWith(
              callStatus: current.callStatus,
              nextCallDateTime: '',
              comment: current.comment.isNotEmpty
                  ? current.comment
                  : student.comment,
              commentHistory:
                  current.commentHistory.length >= student.commentHistory.length
                      ? current.commentHistory
                      : student.commentHistory,
              attempts: current.attempts.length >= student.attempts.length
                  ? current.attempts
                  : student.attempts,
            );
            continue;
          }
        }

        // Safety rule: if fetched student has >= 6 consecutive unanswered calls, automatically treat as Inactive
        if (!isFinalLeadStatus(student.callStatus) &&
            studentActivityStatus(student).unansweredStreak >= 6) {
          merged[key] = student.copyWith(
            callStatus: 'Inactive',
            nextCallDateTime: '',
          );
          continue;
        }

        merged[key] = student;
      }
      for (final queued in _offlineQueue) {
        merged[_studentKey(queued.student)] = queued.student;
      }
      setState(() {
        _isSelectionMode = false;
        _selectedStudentKeys.clear();
        _students
          ..clear()
          ..addAll(merged.values);
        _isSyncing = false;
        _hasSynced = true;
        _lastSyncTime = _formattedSyncTime();
        if (_offlineQueue.isEmpty) {
          _syncStatus = 'Synced · $_lastSyncTime';
        } else {
          _syncStatus =
              'Synced · $_lastSyncTime (${_offlineQueue.length} offline queued)';
        }
      });
      await _settingsStore.saveCachedStudents(_students);
      unawaited(_autoScheduleTodayFollowUps(merged.values));
    } on SheetApiException catch (error) {
      if (syncGeneration == _syncGeneration) _showSyncFailure(error.message);
    } on http.ClientException catch (error) {
      if (syncGeneration == _syncGeneration) {
        _showSyncFailure('Network error: ${error.message}');
      }
    } on TimeoutException {
      if (syncGeneration == _syncGeneration) {
        _showSyncFailure('The Google Sheet request timed out.');
      }
    } on FormatException catch (error) {
      if (syncGeneration == _syncGeneration) {
        _showSyncFailure('Invalid student data: ${error.message}');
      }
    } on Exception catch (error) {
      if (syncGeneration == _syncGeneration) {
        _showSyncFailure('Could not sync with the Google Sheet: $error');
      }
    }
  }

  Future<void> _autoScheduleTodayFollowUps(Iterable<Student> students) async {
    try {
      final now = DateTime.now();
      final endOfToday = DateTime(now.year, now.month, now.day + 1);

      final canSchedule =
          await widget.reminderScheduler.canScheduleExactAlarms();
      if (!canSchedule) return;

      for (final student in students) {
        if (isFinalLeadStatus(student.callStatus)) continue;
        final nextCall = tryParseDate(student.nextCallDateTime);
        if (nextCall == null) continue;

        if (!nextCall.isBefore(endOfToday) || !nextCall.isAfter(now)) {
          continue;
        }

        final alreadyAttempted = student.attempts.any((attempt) {
          final attemptedAt = tryParseDate(attempt.dateTime);
          return attemptedAt != null && !attemptedAt.isBefore(nextCall);
        });
        if (alreadyAttempted) continue;

        final isScheduled = await widget.reminderScheduler
            .isStudentReminderScheduled(student, nextCall);
        if (!isScheduled) {
          try {
            await widget.reminderScheduler.scheduleStudentReminder(
              student,
              nextCall,
            );
          } on Exception catch (error) {
            debugPrint(
              'Could not auto-schedule reminder for ${student.name}: $error',
            );
          }
        }
      }
    } on Exception catch (error) {
      debugPrint('Error while auto-scheduling today reminders: $error');
    }
  }

  String _studentKey(Student student) {
    final digits = student.phone.replaceAll(RegExp(r'\D'), '');
    return digits.isEmpty ? student.name.trim().toLowerCase() : digits;
  }

  String _formattedSyncTime() {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  void _showSyncFailure(String message) {
    if (!mounted) return;
    setState(() {
      _isSyncing = false;
      _hasSynced = false;
      if (_offlineQueue.isNotEmpty) {
        _syncStatus = 'Sync failed (${_offlineQueue.length} offline queued)';
      } else {
        _syncStatus = 'Sync failed';
      }
    });
    _showMessage(message);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _exportStudentsToCsv(
    List<Student> students, {
    String fileName = 'student_leads.csv',
    String title = 'Export student leads',
    String emptyMessage = 'No students match the current filters to export.',
  }) async {
    if (students.isEmpty) {
      _showMessage(emptyMessage);
      return;
    }

    final csv = studentsToCsv(students);
    final bytes = Uint8List.fromList(utf8.encode('\uFEFF$csv'));
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: 'text/csv', name: fileName)],
          fileNameOverrides: [fileName],
          title: title,
          subject: title,
          text: '${students.length} student record(s)',
          downloadFallbackEnabled: true,
        ),
      );
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not export CSV: $error');
    }
  }

  Widget _leadCountBadge(int count, {required bool isSelected}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: isSelected
            ? (isDark
                ? theme.colorScheme.primary.withValues(alpha: 0.25)
                : theme.colorScheme.primary.withValues(alpha: 0.15))
            : (isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final students = _filteredStudents;
    final selectedStudents = _selectedStudents;
    final allCount = _countForCategory(_LeadFilter.all);
    final newCount = _countForCategory(_LeadFilter.newLeads);
    final todayCount = _countForCategory(_LeadFilter.todayFollowUp);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: _isSelectionMode
            ? IconButton(
                tooltip: 'Cancel selection',
                onPressed: _clearStudentSelection,
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        title: _isSelectionMode
            ? Text('${selectedStudents.length} selected')
            : const Text(
                'LeadPilot',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
        actions: _isSelectionMode
            ? [
                IconButton(
                  tooltip: students.isNotEmpty &&
                          students.every((s) => _selectedStudentKeys
                              .contains(_selectionKey(s)))
                      ? 'Deselect all'
                      : 'Select all',
                  onPressed: () => _toggleSelectAll(students),
                  icon: Icon(
                    students.isNotEmpty &&
                            students.every((s) => _selectedStudentKeys
                                .contains(_selectionKey(s)))
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                  ),
                ),
                IconButton(
                  tooltip: 'Export selected contacts',
                  onPressed: selectedStudents.isEmpty
                      ? null
                      : () => _exportStudentsToCsv(selectedStudents),
                  icon: const Icon(Icons.file_download_outlined),
                ),
                IconButton(
                  tooltip: 'Save selected contacts',
                  onPressed: selectedStudents.isEmpty
                      ? null
                      : _saveSelectedContacts,
                  icon: const Icon(Icons.contact_phone_outlined),
                ),
                const SizedBox(width: 8),
              ]
            : [
                IconButton(
                  key: const ValueKey('sync-appbar-button'),
                  tooltip: _lastSyncTime != null
                      ? 'Last synced: $_lastSyncTime'
                      : (_syncStatus.isNotEmpty ? _syncStatus : 'Sync now'),
                  onPressed: _isSyncing ? null : () => _syncWithGoogleSheet(),
                  icon: _isSyncing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : _offlineQueue.isNotEmpty
                      ? Badge(
                          label: Text('${_offlineQueue.length}'),
                          child: const Icon(Icons.cloud_upload_outlined),
                        )
                      : Icon(
                          _hasSynced
                              ? Icons.cloud_done_rounded
                              : Icons.cloud_outlined,
                          color: _hasSynced ? _green : null,
                        ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded),
                  tooltip: 'More options',
                  onSelected: (value) {
                    switch (value) {
                      case 'select_multiple':
                        setState(() => _isSelectionMode = true);
                        break;
                      case 'settings':
                        _openSettings();
                        break;
                      case 'lock_app':
                        widget.onLogout();
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'select_multiple',
                      child: Row(
                        children: [
                          Icon(Icons.checklist_rounded),
                          SizedBox(width: 12),
                          Text('Select multiple'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'settings',
                      child: Row(
                        children: [
                          Icon(Icons.settings_outlined),
                          SizedBox(width: 12),
                          Text('Settings'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'lock_app',
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline_rounded),
                          SizedBox(width: 12),
                          Text('Lock app'),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
              ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              onChanged: (value) =>
                                  setState(() => _query = value),
                              decoration: InputDecoration(
                                hintText:
                                    'Search name, status, phone or comments',
                                hintStyle: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  fontSize: 14,
                                ),
                                prefixIcon: const Icon(Icons.search_rounded),
                                suffixIcon: _query.isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: 'Clear search',
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(() => _query = '');
                                        },
                                        icon: const Icon(Icons.close_rounded),
                                      ),
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Filter leads',
                            onPressed: _openLeadFilters,
                            icon: Badge(
                              isLabelVisible: _hasActiveFilters,
                              smallSize: 8,
                              child: const Icon(Icons.tune_rounded),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<_LeadFilter>(
                          segments: [
                            ButtonSegment(
                              value: _LeadFilter.all,
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('All'),
                                  const SizedBox(width: 6),
                                  _leadCountBadge(
                                    allCount,
                                    isSelected: _leadFilter == _LeadFilter.all,
                                  ),
                                ],
                              ),
                            ),
                            ButtonSegment(
                              value: _LeadFilter.newLeads,
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('New'),
                                  const SizedBox(width: 6),
                                  _leadCountBadge(
                                    newCount,
                                    isSelected:
                                        _leadFilter == _LeadFilter.newLeads,
                                  ),
                                ],
                              ),
                            ),
                            ButtonSegment(
                              value: _LeadFilter.todayFollowUp,
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('Today'),
                                  const SizedBox(width: 6),
                                  _leadCountBadge(
                                    todayCount,
                                    isSelected:
                                        _leadFilter == _LeadFilter.todayFollowUp,
                                  ),
                                ],
                              ),
                            ),
                          ],
                          selected: {_leadFilter},
                          onSelectionChanged: (newSelection) {
                            setState(() {
                              _leadFilter = newSelection.first;
                            });
                          },
                          showSelectedIcon: false,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: students.isEmpty
                      ? _EmptySearchState(
                          isSearching: _query.isNotEmpty ||
                              _leadFilter != _LeadFilter.all ||
                              _hasActiveFilters,
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                          itemCount: students.length,
                          itemBuilder: (context, index) => StudentCard(
                            student: students[index],
                            isSelectionMode: _isSelectionMode,
                            isSelected: _selectedStudentKeys.contains(
                              _selectionKey(students[index]),
                            ),
                            onTap: () => _isSelectionMode
                                ? _toggleStudentSelection(students[index])
                                : _editStudent(students[index]),
                            onLongPress: () => _isSelectionMode
                                ? _toggleStudentSelection(students[index])
                                : _showStudentActions(students[index]),
                            onCall: () => _callStudent(students[index]),
                            onWhatsApp: () =>
                                _openWhatsAppChat(students[index]),
                            onSms: () => _sendStudentSms(students[index]),
                            onNote: () => _showStudentNote(students[index]),
                            onSaveContact: () =>
                                _saveStudentContact(students[index]),
                          ),
                        ),
                ),
              ],
            ),
      ],
    ),
  ),
      bottomNavigationBar: _isSelectionMode
          ? Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('bulk_whatsapp_button'),
                        onPressed: selectedStudents.isEmpty
                            ? null
                            : () => _startBulkWhatsApp(selectedStudents),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF25D366),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const FaIcon(FontAwesomeIcons.whatsapp, size: 18),
                        label: Text(
                          'Bulk WhatsApp (${selectedStudents.length})',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        key: const Key('bulk_sms_button'),
                        onPressed: selectedStudents.isEmpty
                            ? null
                            : () => _startBulkSms(selectedStudents),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.sms_outlined, size: 18),
                        label: Text(
                          'Bulk SMS (${selectedStudents.length})',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      floatingActionButton: _isSelectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _addStudent,
              backgroundColor: _green,
              foregroundColor: Colors.white,
              elevation: 4,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text(
                'Add student',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
    );
  }

  Future<int?> _showSimChoiceSheet(
    Student student,
    List<Map<String, dynamic>> slots,
  ) async {
    bool remember = false;
    return showModalBottomSheet<int>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final theme = Theme.of(context);
            return SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Icon(Icons.sim_card_outlined,
                            color: _green, size: 24),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Choose SIM for Call',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Calling ${student.name} (${student.phone})',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ...slots.map((slot) {
                      final idx = (slot['slotIndex'] as num?)?.toInt() ?? 0;
                      final carrier = slot['carrierName']?.toString() ?? '';
                      final display =
                          slot['displayName']?.toString() ?? 'SIM ${idx + 1}';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                                color: theme.colorScheme.outlineVariant),
                          ),
                          leading: CircleAvatar(
                            backgroundColor: _green.withValues(alpha: 0.15),
                            foregroundColor: _green,
                            child: Text('${idx + 1}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                          ),
                          title: Text(
                            display,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: carrier.isNotEmpty ? Text(carrier) : null,
                          trailing: const Icon(Icons.call_outlined,
                              color: _green),
                          onTap: () async {
                            if (remember) {
                              await _settingsStore.savePreferredSimSlot(idx);
                            }
                            if (ctx.mounted) Navigator.of(ctx).pop(idx);
                          },
                        ),
                      );
                    }),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: remember,
                      title: const Text('Always use this SIM for calls'),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (val) {
                        setSheetState(() => remember = val ?? false);
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<String?> _showCallingAppChoiceSheet(
    Student student,
    List<Map<String, dynamic>> apps,
  ) async {
    bool remember = true;
    return showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final theme = Theme.of(context);
            return SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Icon(Icons.phone_forwarded_rounded,
                            color: _green, size: 24),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Select Calling App',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Choose which app makes calls without asking each time',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ...apps.map((app) {
                      final pkg = app['packageName']?.toString() ?? '';
                      final name = app['appName']?.toString() ?? pkg;
                      final is3cx = name.toLowerCase().contains('3cx') ||
                          pkg.toLowerCase().contains('tcx');
                      final isSystem = !is3cx;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                                color: theme.colorScheme.outlineVariant),
                          ),
                          leading: CircleAvatar(
                            backgroundColor: is3cx
                                ? const Color(0xFF0079C1)
                                    .withValues(alpha: 0.15)
                                : _green.withValues(alpha: 0.15),
                            foregroundColor:
                                is3cx ? const Color(0xFF0079C1) : _green,
                            child: Icon(
                              is3cx
                                  ? Icons.phone_in_talk
                                  : Icons.call_outlined,
                            ),
                          ),
                          title: Text(
                            isSystem ? '$name (SIM Call)' : name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(pkg),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () async {
                            if (remember) {
                              await _settingsStore
                                  .savePreferredCallingApp(pkg);
                            }
                            if (ctx.mounted) Navigator.of(ctx).pop(pkg);
                          },
                        ),
                      );
                    }),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: remember,
                      title: const Text('Always use this app for calls'),
                      subtitle:
                          const Text('You can change this anytime in Settings'),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (val) {
                        setSheetState(() => remember = val ?? false);
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _callStudent(Student student) async {
    try {
      final directCalling = await _settingsStore.readDirectCalling();
      if (directCalling) {
        var hasPermission = await CallerIdService.hasCallPhonePermission();
        if (!hasPermission) {
          hasPermission = await CallerIdService.requestCallPhonePermission();
        }

        if (hasPermission) {
          int preferredSlot = await _settingsStore.readPreferredSimSlot();
          if (preferredSlot == -1) {
            final simSlots = await CallerIdService.getSimSlots();
            if (simSlots.length > 1 && mounted) {
              final chosen = await _showSimChoiceSheet(student, simSlots);
              if (chosen == null) return;
              preferredSlot = chosen;
            }
          }

          String preferredApp =
              await _settingsStore.readPreferredCallingApp();
          if (preferredApp.isEmpty) {
            final callingApps = await CallerIdService.getCallingApps();
            if (callingApps.length > 1 && mounted) {
              final chosenApp =
                  await _showCallingAppChoiceSheet(student, callingApps);
              if (chosenApp == null) return;
              preferredApp = chosenApp;
            }
          }

          _pendingCallStudent = student;
          _callStartedAt = DateTime.now();

          final success = await CallerIdService.directCall(
            phone: student.phone,
            simSlot: preferredSlot,
            name: student.name,
            callingAppPackage: preferredApp,
          );

          if (!success && mounted) {
            final launched = await launchUrl(Uri.parse('tel:${student.phone}'));
            if (!launched && mounted) {
              _showMessage('Could not initiate call for ${student.name}.');
            }
          }
          return;
        }
      }

      _pendingCallStudent = student;
      _callStartedAt = DateTime.now();
      final launched = await launchUrl(Uri.parse('tel:${student.phone}'));
      if (!launched && mounted) {
        _showMessage('Could not open the phone dialer for ${student.name}.');
      }
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not start the call: $error');
    }
  }

  Future<void> _checkAndLogCallDuration() async {
    if (_pendingCallStudent != null && _callStartedAt != null) {
      _pendingCallStudent = null;
      _callStartedAt = null;
    }
  }



  Future<void> _startBulkWhatsApp(List<Student> students) async {
    if (students.isEmpty) return;

    final templates = await _settingsStore.readWhatsAppTemplates();
    if (!mounted) return;

    final payload = await showModalBottomSheet<WhatsAppSendPayload>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WhatsAppTemplatePickerSheet(
        student: students.first,
        templates: templates,
        isSms: false,
        isBulk: true,
        onManageTemplates: () async {
          Navigator.pop(context);
          await _openWhatsAppTemplatesSettings();
        },
      ),
    );

    if (payload == null || !mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => BulkDispatchSheet(
        students: students,
        payload: payload,
        isSms: false,
        onDispatch: (student, text) => _dispatchWhatsAppMessage(
          student: student,
          text: text,
          documentPaths: payload.documentPaths,
        ),
      ),
    );
  }

  Future<void> _startBulkSms(List<Student> students) async {
    if (students.isEmpty) return;

    final templates = await _settingsStore.readWhatsAppTemplates();
    if (!mounted) return;

    final payload = await showModalBottomSheet<WhatsAppSendPayload>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WhatsAppTemplatePickerSheet(
        student: students.first,
        templates: templates,
        isSms: true,
        isBulk: true,
        onManageTemplates: () async {
          Navigator.pop(context);
          await _openWhatsAppTemplatesSettings();
        },
      ),
    );

    if (payload == null || !mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => BulkDispatchSheet(
        students: students,
        payload: payload,
        isSms: true,
        onDispatch: (student, text) => _launchSms(
          student.phone,
          text: text,
        ),
      ),
    );
  }

  Future<void> _openWhatsAppChat(Student student) async {
    final number = student.whatsappNumber.trim().isEmpty
        ? student.phone
        : student.whatsappNumber;
    final digits = normalizeContactPhone(number);
    if (digits.isEmpty) {
      _showMessage(
        'No valid WhatsApp number is available for ${student.name}.',
      );
      return;
    }

    final choice = await showModalBottomSheet<_MessageChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WhatsAppChoiceSheet(student: student),
    );

    if (choice == null || !mounted) return;

    if (choice == _MessageChoice.custom) {
      await _launchWhatsApp(number);
    } else if (choice == _MessageChoice.template) {
      final templates = await _settingsStore.readWhatsAppTemplates();
      if (!mounted) return;
      final selectedPayload =
          await showModalBottomSheet<WhatsAppSendPayload>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => WhatsAppTemplatePickerSheet(
          student: student,
          templates: templates,
          isSms: false,
          onManageTemplates: () async {
            Navigator.pop(context);
            await _openWhatsAppTemplatesSettings();
          },
        ),
      );
      if (selectedPayload != null && mounted) {
        await _dispatchWhatsAppMessage(
          student: student,
          text: selectedPayload.message,
          documentPaths: selectedPayload.documentPaths,
        );
      }
    } else if (choice == _MessageChoice.ai) {
      final apiKey = await _settingsStore.readGeminiApiKey();
      if (!mounted) return;
      final selectedMessage = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => GeminiAiMessageSheet(
          student: student,
          initialApiKey: apiKey,
          settingsStore: _settingsStore,
          isSms: false,
        ),
      );
      if (selectedMessage != null &&
          selectedMessage.trim().isNotEmpty &&
          mounted) {
        await _launchWhatsApp(number, text: selectedMessage.trim());
      }
    }
  }

  Future<void> _dispatchWhatsAppMessage({
    required Student student,
    required String text,
    List<String> documentPaths = const [],
  }) async {
    final number = student.whatsappNumber.trim().isEmpty
        ? student.phone
        : student.whatsappNumber;
    final validDocuments = documentPaths
        .where((path) => path.trim().isNotEmpty && File(path).existsSync())
        .toList();

    if (validDocuments.isNotEmpty) {
      try {
        final xFiles = validDocuments.map((path) => XFile(path)).toList();
        await SharePlus.instance.share(
          ShareParams(
            files: xFiles,
            text: text.trim().isNotEmpty ? text.trim() : null,
            subject: 'Document for ${student.name}',
          ),
        );
      } on Exception catch (error) {
        if (mounted) {
          _showMessage('Could not share documents: $error');
        }
      }
    } else {
      await _launchWhatsApp(
        number,
        text: text.trim().isNotEmpty ? text.trim() : null,
      );
    }
  }

  Future<void> _launchWhatsApp(String number, {String? text}) async {
    try {
      final launched = await launchUrl(
        whatsAppChatUri(number, text: text),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        _showMessage('Could not open WhatsApp.');
      }
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not open WhatsApp: $error');
    }
  }

  Future<void> _sendStudentSms(Student student) async {
    final number = student.phone;
    final digits = normalizeContactPhone(number);
    if (digits.isEmpty) {
      _showMessage('No valid phone number is available for ${student.name}.');
      return;
    }

    final choice = await showModalBottomSheet<_MessageChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SmsChoiceSheet(student: student),
    );

    if (choice == null || !mounted) return;

    if (choice == _MessageChoice.custom) {
      await _launchSms(number);
    } else if (choice == _MessageChoice.template) {
      final templates = await _settingsStore.readWhatsAppTemplates();
      if (!mounted) return;
      final selectedPayload =
          await showModalBottomSheet<WhatsAppSendPayload>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => WhatsAppTemplatePickerSheet(
          student: student,
          templates: templates,
          isSms: true,
          onManageTemplates: () async {
            Navigator.pop(context);
            await _openWhatsAppTemplatesSettings();
          },
        ),
      );
      if (selectedPayload != null && mounted) {
        await _launchSms(number, text: selectedPayload.message);
      }
    } else if (choice == _MessageChoice.ai) {
      final apiKey = await _settingsStore.readGeminiApiKey();
      if (!mounted) return;
      final selectedMessage = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => GeminiAiMessageSheet(
          student: student,
          initialApiKey: apiKey,
          settingsStore: _settingsStore,
          isSms: true,
        ),
      );
      if (selectedMessage != null &&
          selectedMessage.trim().isNotEmpty &&
          mounted) {
        await _launchSms(number, text: selectedMessage.trim());
      }
    }
  }

  Future<void> _launchSms(String number, {String? text}) async {
    try {
      final launched = await launchUrl(
        smsComposerUri(number, body: text),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        _showMessage('Could not open the SMS composer for number $number.');
      }
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not open SMS: $error');
    }
  }

  Future<void> _saveVisibleContacts() async {
    final students = _filteredStudents;
    if (students.isEmpty) {
      _showMessage('There are no displayed contacts to save.');
      return;
    }
    await _saveContacts(students);
  }

  Future<void> _saveSelectedContacts() async {
    final students = _selectedStudents;
    if (students.isEmpty) {
      _showMessage('Select at least one contact first.');
      return;
    }
    await _saveContacts(students);
  }

  Future<void> _saveContacts(List<Student> students) async {
    try {
      final result = await widget.deviceContactsService.saveMissingStudents(
        students,
      );
      await _showContactSaveResult(result);
    } on Exception catch (error) {
      if (mounted) _showMessage('Could not save contacts: $error');
    }
  }

  Future<void> _showStudentActions(Student student) async {
    final action = await showModalBottomSheet<_StudentCardAction>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () =>
                    Navigator.pop(sheetContext, _StudentCardAction.edit),
              ),
              ListTile(
                leading: const Icon(Icons.checklist_rounded),
                title: const Text('Select multiple'),
                subtitle: const Text('Select contacts to save or export'),
                onTap: () => Navigator.pop(
                  sheetContext,
                  _StudentCardAction.selectMultiple,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _StudentCardAction.edit:
        await _editStudent(student);
        break;
      case _StudentCardAction.selectMultiple:
        _startSelection(student);
        break;
    }
  }

  Future<void> _saveStudentContact(Student student) async {
    await _saveContacts([student]);
  }

  Future<void> _showContactSaveResult(SaveContactsResult result) async {
    if (!mounted) return;
    if (result.permissionDenied) {
      final openSettings = result.permissionPermanentlyDenied
          ? await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('Contacts permission required'),
                content: const Text(
                  'Allow Contacts access in your device settings to check '
                  'saved numbers and add missing contacts.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Open settings'),
                  ),
                ],
              ),
            )
          : false;
      if (openSettings == true) {
        await FlutterContacts.permissions.openSettings();
      } else if (!result.permissionPermanentlyDenied && mounted) {
        _showMessage('Contacts permission was not granted.');
      }
      return;
    }

    final summary = <String>[
      if (result.saved > 0) '${result.saved} contact(s) saved',
      if (result.alreadySaved > 0)
        '${result.alreadySaved} already saved or duplicate',
      if (result.failedNames.isNotEmpty)
        '${result.failedNames.length} failed: ${result.failedNames.join(', ')}',
    ];
    _showMessage(
      summary.isEmpty ? 'No contacts needed saving.' : summary.join(' · '),
    );
  }

  void _showStudentNote(Student student) {
    _showStudentHistory(
      context,
      student,
      title: 'Call history · ${student.name}',
      settingsStore: _settingsStore,
      geminiService: GeminiService(),
      onStudentUpdated: (updatedStudent) async {
        final index = _students.indexWhere(
          (s) =>
              normalizeContactPhone(s.phone) ==
              normalizeContactPhone(student.phone),
        );
        if (index >= 0) {
          setState(() {
            _students[index] = updatedStudent;
          });
          await _settingsStore.saveCachedStudents(_students);
        }
        if (widget.sheetConfig.isNotEmpty) {
          try {
            await widget.sheetService.updateStudentInSheet(
              widget.sheetConfig,
              updatedStudent,
              previousPhone: student.phone,
            );
          } catch (_) {
            await _enqueueOfflineAction(
              QueuedSheetAction(
                id: '${student.phone}_${DateTime.now().millisecondsSinceEpoch}',
                action: 'update',
                student: updatedStudent,
                previousPhone: student.phone,
                queuedAt: DateTime.now(),
              ),
            );
          }
        }
      },
    );
  }
}

Future<void> _showStudentHistory(
  BuildContext context,
  Student student, {
  required String title,
  Future<void> Function(Student updatedStudent)? onStudentUpdated,
  AppSettingsStore? settingsStore,
  GeminiService? geminiService,
  VoiceToTextService? voiceToTextService,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => StudentHistoryDialog(
      student: student,
      title: title,
      onStudentUpdated: onStudentUpdated,
      settingsStore: settingsStore,
      geminiService: geminiService,
      voiceToTextService: voiceToTextService,
    ),
  );
}

