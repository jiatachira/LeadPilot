part of '../../main.dart';

class EditStudentSheet extends StatefulWidget {
  const EditStudentSheet({
    super.key,
    required this.student,
    this.settingsStore,
    this.geminiService,
    this.voiceToTextService,
    this.onWhatsApp,
  });

  final Student student;
  final AppSettingsStore? settingsStore;
  final GeminiService? geminiService;
  final VoiceToTextService? voiceToTextService;
  final ValueChanged<Student>? onWhatsApp;

  @override
  State<EditStudentSheet> createState() => _EditStudentSheetState();
}

typedef _EditStudentSheet = EditStudentSheet;
typedef LogCallSheet = EditStudentSheet;

class _EditStudentSheetState extends State<EditStudentSheet> {
  final _logCallFormKey = GlobalKey<FormState>();
  final _detailsFormKey = GlobalKey<FormState>();

  late final AppSettingsStore _settingsStore =
      widget.settingsStore ?? SecureAppSettingsStore();
  late final GeminiService _geminiService =
      widget.geminiService ?? GeminiService();
  late final VoiceToTextService _voiceService =
      widget.voiceToTextService ?? DefaultVoiceToTextService();

  bool _isEditingDetails = false;
  late Student _activeStudent = widget.student;

  // Log call fields
  late final _commentController = TextEditingController(text: '');

  static const _callStatuses = [
    'Very Interested',
    'Interested',
    'Minimal Interested',
    'Not Interested',
    'Not Potential',
    'Inactive',
    'Answered',
    'No Answer',
    'Not Responding',
    'Wrong number',
    'Call Cut',
    'Line Busy',
    'Call Back',
    'Future',
  ];

  late String? _callStatus = _callStatuses.contains(widget.student.callStatus)
      ? widget.student.callStatus
      : null;
  late DateTime? _nextCallDateTime = tryParseDate(
    widget.student.nextCallDateTime,
  );
  bool _isPickingNextCallDateTime = false;

  // Edit details fields
  late final _nameController = TextEditingController(text: widget.student.name);
  late final _phoneController = TextEditingController(
    text: widget.student.phone,
  );
  late final _examYearController = TextEditingController(
    text: widget.student.examYear,
  );
  late final _locationController = TextEditingController(
    text: widget.student.location,
  );
  late final _englishController = TextEditingController(
    text: widget.student.olEnglish,
  );
  late final _mathsController = TextEditingController(
    text: widget.student.olMaths,
  );
  late final _whatsappController = TextEditingController(
    text: widget.student.whatsappNumber,
  );

  static const _examTypes = ['O/L', 'A/L'];
  late String? _examType = _examTypes.contains(widget.student.examType)
      ? widget.student.examType
      : null;
  late bool _sameAsContact = widget.student.whatsappSameAsContact ||
      widget.student.whatsappNumber == widget.student.phone;

  @override
  void initState() {
    super.initState();
    if (_sameAsContact) _whatsappController.text = widget.student.phone;
  }

  @override
  void dispose() {
    _commentController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _examYearController.dispose();
    _locationController.dispose();
    _englishController.dispose();
    _mathsController.dispose();
    _whatsappController.dispose();
    super.dispose();
  }

  Student _updatedStudent() {
    final newComment = _commentController.text.trim();
    final history = List<String>.of(_activeStudent.commentHistory);
    final attempts = List<CallAttempt>.of(_activeStudent.attempts);
    final attemptedAt = DateTime.now();
    final callStatus = _callStatus ?? _activeStudent.callStatus;
    if (newComment.isNotEmpty) {
      history.add('${_formatReminder(DateTime.now())} — $newComment');
    }
    attempts.add(
      CallAttempt(
        dateTime: attemptedAt.toIso8601String(),
        status: callStatus,
        comment: newComment,
      ),
    );

    final hasValidFutureReminder = _nextCallDateTime != null &&
        _nextCallDateTime!.isAfter(DateTime.now());
    final nextCallStr =
        (isFinalLeadStatus(callStatus) || !hasValidFutureReminder)
            ? ''
            : _nextCallDateTime!.toIso8601String();

    return _activeStudent.copyWith(
      callStatus: callStatus,
      nextCallDateTime: nextCallStr,
      comment: newComment.isEmpty ? null : newComment,
      commentHistory: history,
      attempts: attempts,
    );
  }

  void _saveDetails() {
    if (!_detailsFormKey.currentState!.validate()) return;
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    setState(() {
      _activeStudent = _activeStudent.copyWith(
        name: name,
        phone: phone,
        examType: _examType ?? '',
        examYear: _examYearController.text.trim(),
        location: _locationController.text.trim(),
        olEnglish: _englishController.text.trim().toUpperCase(),
        olMaths: _mathsController.text.trim().toUpperCase(),
        whatsappNumber: _sameAsContact ? phone : _whatsappController.text.trim(),
        whatsappSameAsContact: _sameAsContact,
      );
      _isEditingDetails = false;
    });
  }

  void _setQuickReminder(Duration offset, [int? targetHour]) {
    final now = DateTime.now();
    DateTime target;
    if (targetHour != null) {
      final tomorrow = now.add(const Duration(days: 1));
      target = DateTime(
        tomorrow.year,
        tomorrow.month,
        tomorrow.day,
        targetHour,
        0,
      );
    } else {
      target = now.add(offset);
      final remainder = target.minute % 5;
      final roundedMinute = remainder == 0 ? target.minute : target.minute + (5 - remainder);
      if (roundedMinute >= 60) {
        target = DateTime(
          target.year,
          target.month,
          target.day,
          target.hour + 1,
          roundedMinute - 60,
        );
      } else {
        target = DateTime(
          target.year,
          target.month,
          target.day,
          target.hour,
          roundedMinute,
        );
      }
    }
    setState(() => _nextCallDateTime = target);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Next call scheduled: ${_formatReminder(target)}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _pickNextCallDateTime() async {
    if (_isPickingNextCallDateTime) return;
    setState(() => _isPickingNextCallDateTime = true);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final existingReminder = _nextCallDateTime;
    final isExistingFuture =
        existingReminder != null && existingReminder.isAfter(now);

    final initialPickerDate = isExistingFuture
        ? DateTime(
            existingReminder.year,
            existingReminder.month,
            existingReminder.day,
          )
        : today;

    TimeOfDay initialPickerTime;
    if (isExistingFuture) {
      initialPickerTime = TimeOfDay.fromDateTime(existingReminder);
    } else if (existingReminder != null &&
        combineReminderDateAndTime(
          today,
          TimeOfDay.fromDateTime(existingReminder),
        ).isAfter(now.add(const Duration(minutes: 5)))) {
      initialPickerTime = TimeOfDay.fromDateTime(existingReminder);
    } else {
      final safeDefault = _defaultFutureReminder(now);
      initialPickerTime = TimeOfDay.fromDateTime(safeDefault);
    }

    try {
      final selectedDate = await showDatePicker(
        context: context,
        initialDate: initialPickerDate.isBefore(today) ? today : initialPickerDate,
        firstDate: today,
        lastDate: DateTime(now.year + 10),
        helpText: 'Select next call date',
      );
      if (!mounted || selectedDate == null) return;

      final selectedTime = await showTimePicker(
        context: context,
        initialTime: initialPickerTime,
        helpText: 'Select next call time',
      );
      if (!mounted || selectedTime == null) return;

      var selectedDateTime = combineReminderDateAndTime(
        selectedDate,
        selectedTime,
      );

      final currentNow = DateTime.now();
      final isSelectedDateToday = selectedDate.year == currentNow.year &&
          selectedDate.month == currentNow.month &&
          selectedDate.day == currentNow.day;

      if (isSelectedDateToday) {
        if (selectedDateTime.isBefore(currentNow) &&
            selectedDateTime.isAfter(
              currentNow.subtract(const Duration(minutes: 2)),
            )) {
          selectedDateTime = currentNow.add(const Duration(minutes: 2));
        } else if (selectedDateTime.isBefore(currentNow)) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text(
                'That time has already passed today. Choose a later time.',
              ),
            ),
          );
          return;
        }
      }

      setState(() => _nextCallDateTime = selectedDateTime);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('Could not open the call reminder picker: $error'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPickingNextCallDateTime = false);
      }
    }
  }

  Future<void> _showCommentHistory() => _showStudentHistory(
    context,
    _activeStudent,
    title: 'Call attempt history',
    settingsStore: _settingsStore,
    geminiService: _geminiService,
    voiceToTextService: _voiceService,
    onStudentUpdated: (updated) async {
      setState(() {
        _activeStudent = updated;
      });
    },
  );

  Future<void> _onSave() async {
    if (!_logCallFormKey.currentState!.validate()) return;
    final updated = _updatedStudent();
    final currentStreak = studentActivityStatus(_activeStudent).unansweredStreak;
    final isNewAttemptUnanswered = _isUnansweredCall(
      updated.callStatus,
      updated.comment,
    );

    if (currentStreak >= 5 && isNewAttemptUnanswered) {
      final nextStreak = currentStreak + 1;
      final moveToInactive = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('Move to Inactive?'),
          content: Text(
            '${_activeStudent.name} has not answered $nextStreak consecutive times. Move to \'Inactive\'?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('Keep Active'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('Move to Inactive'),
            ),
          ],
        ),
      );

      if (moveToInactive == true) {
        final enteredComment = _commentController.text.trim();
        final updatedAttempts = List<CallAttempt>.of(updated.attempts);
        final inactiveComment = enteredComment.isNotEmpty
            ? enteredComment
            : 'Marked as Inactive after $nextStreak unanswered calls';
        if (updatedAttempts.isNotEmpty) {
          final last = updatedAttempts.last;
          updatedAttempts[updatedAttempts.length - 1] = CallAttempt(
            dateTime: last.dateTime,
            status: 'Inactive',
            comment: inactiveComment,
          );
        } else {
          updatedAttempts.add(
            CallAttempt(
              dateTime: DateTime.now().toIso8601String(),
              status: 'Inactive',
              comment: inactiveComment,
            ),
          );
        }

        final updatedHistory = List<String>.of(updated.commentHistory);
        final historyEntry =
            '${_formatReminder(DateTime.now())} — Inactive ($inactiveComment)';
        if (enteredComment.isNotEmpty && updatedHistory.isNotEmpty) {
          updatedHistory[updatedHistory.length - 1] = historyEntry;
        } else if (!updatedHistory.contains(historyEntry)) {
          updatedHistory.add(historyEntry);
        }

        final inactiveStudent = updated.copyWith(
          callStatus: 'Inactive',
          nextCallDateTime: '',
          comment: inactiveComment,
          commentHistory: updatedHistory,
          attempts: updatedAttempts,
        );
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
        Navigator.of(context).pop(inactiveStudent);
        return;
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
          child: _isEditingDetails
              ? _buildEditDetailsView(context)
              : _buildLogCallView(context),
        ),
      ),
    );
  }

  Widget _buildLogCallView(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Form(
      key: _logCallFormKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              height: 4,
              width: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFDDE3E9),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Header: student name, phone and Call button
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: isDark
                    ? const Color(0xFF17382F)
                    : const Color(0xFFEAF3F1),
                child: Text(
                  _activeStudent.initials,
                  style: const TextStyle(
                    color: _green,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _activeStudent.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _activeStudent.phone,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filled(
                tooltip: 'WhatsApp ${_activeStudent.name}',
                onPressed: () {
                  if (widget.onWhatsApp != null) {
                    widget.onWhatsApp!(_activeStudent);
                  } else {
                    final target =
                        _activeStudent.whatsappNumber.trim().isEmpty
                        ? _activeStudent.phone
                        : _activeStudent.whatsappNumber;
                    launchUrl(
                      whatsAppChatUri(target),
                      mode: LaunchMode.externalApplication,
                    );
                  }
                },
                icon: const FaIcon(FontAwesomeIcons.whatsapp, size: 20),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Call ${_activeStudent.name}',
                onPressed: () =>
                    launchUrl(Uri.parse('tel:${_activeStudent.phone}')),
                icon: const Icon(Icons.call_rounded, size: 20),
                style: IconButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Actions row: Edit details & View history
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              OutlinedButton.icon(
                onPressed: () => setState(() => _isEditingDetails = true),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Edit details'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _showCommentHistory,
                icon: const Icon(Icons.history_rounded, size: 16),
                label: const Text('View history'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Student details summary card
          _buildStudentDetailsCard(context),
          const Divider(height: 20),
          // Call status dropdown
          DropdownButtonFormField<String>(
            initialValue: _callStatus,
            decoration: const InputDecoration(
              labelText: 'Call status',
              prefixIcon: Icon(Icons.call_outlined),
            ),
            hint: const Text('Select call status'),
            items: _callStatuses
                .map(
                  (status) => DropdownMenuItem(
                    value: status,
                    child: Text(status),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _callStatus = value;
                if (isFinalLeadStatus(value)) {
                  _nextCallDateTime = null;
                }
              });
            },
          ),
          const SizedBox(height: 16),
          // Next call header & reminder state
          Row(
            children: [
              Icon(
                _nextCallDateTime != null &&
                        _nextCallDateTime!.isBefore(DateTime.now())
                    ? Icons.warning_amber_rounded
                    : Icons.event_available_outlined,
                size: 18,
                color: _nextCallDateTime != null &&
                        _nextCallDateTime!.isBefore(DateTime.now())
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _nextCallDateTime == null
                      ? 'Next call: Not scheduled'
                      : (_nextCallDateTime!.isBefore(DateTime.now())
                          ? 'Next call · Overdue: ${_formatReminder(_nextCallDateTime!)}'
                          : 'Next call · ${_formatReminder(_nextCallDateTime!)}'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: _nextCallDateTime != null &&
                            _nextCallDateTime!.isBefore(DateTime.now())
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),
              if (_nextCallDateTime != null)
                TextButton(
                  onPressed: () => setState(() => _nextCallDateTime = null),
                  child: const Text('Clear'),
                ),
            ],
          ),
          if (_nextCallDateTime != null &&
              _nextCallDateTime!.isBefore(DateTime.now()))
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(
                '⚠️ This reminder was for the past. Tap above to reschedule, or save to clear.',
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const SizedBox(height: 6),
          // Quick chips + Pick date & time
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ActionChip(
                  avatar: const Icon(Icons.add_alarm_rounded, size: 15),
                  label: const Text('+1 hr'),
                  onPressed: () => _setQuickReminder(const Duration(hours: 1)),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.add_alarm_rounded, size: 15),
                  label: const Text('+3 hrs'),
                  onPressed: () => _setQuickReminder(const Duration(hours: 3)),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.wb_sunny_outlined, size: 15),
                  label: const Text('Tomorrow 10 AM'),
                  onPressed: () =>
                      _setQuickReminder(const Duration(days: 1), 10),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.brightness_5_rounded, size: 15),
                  label: const Text('Tomorrow 2 PM'),
                  onPressed: () =>
                      _setQuickReminder(const Duration(days: 1), 14),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.calendar_month_outlined, size: 15),
                  label: const Text('Pick date & time'),
                  onPressed: _pickNextCallDateTime,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Remark field
          TextFormField(
            controller: _commentController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Call remark (optional)',
              alignLabelWithHint: true,
              prefixIcon: Padding(
                padding: EdgeInsets.only(bottom: 24),
                child: Icon(Icons.notes_outlined),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Voice input & AI polish shared toolbar
          VoiceAiRemarkControls(
            controller: _commentController,
            settingsStore: _settingsStore,
            geminiService: _geminiService,
            voiceToTextService: _voiceService,
          ),
          const SizedBox(height: 24),
          // Save button
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _onSave,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Save'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudentDetailsCard(BuildContext context) {
    final theme = Theme.of(context);
    final details = <Widget>[];

    final examStr = [
      _activeStudent.examType,
      _activeStudent.examYear,
    ].where((s) => s.trim().isNotEmpty).join(' ');

    if (examStr.isNotEmpty) {
      details.add(_buildDetailChip(
        Icons.school_outlined,
        examStr,
        theme,
      ));
    }
    if (_activeStudent.location.trim().isNotEmpty) {
      details.add(_buildDetailChip(
        Icons.location_on_outlined,
        _activeStudent.location.trim(),
        theme,
      ));
    }
    if (_activeStudent.olEnglish.trim().isNotEmpty) {
      details.add(_buildDetailChip(
        Icons.translate_rounded,
        'O/L Eng: ${_activeStudent.olEnglish.trim()}',
        theme,
      ));
    }
    if (_activeStudent.olMaths.trim().isNotEmpty) {
      details.add(_buildDetailChip(
        Icons.calculate_outlined,
        'O/L Maths: ${_activeStudent.olMaths.trim()}',
        theme,
      ));
    }
    if (_activeStudent.whatsappNumber.trim().isNotEmpty) {
      details.add(_buildDetailChip(
        FontAwesomeIcons.whatsapp,
        _activeStudent.whatsappNumber.trim(),
        theme,
        isFa: true,
      ));
    }
    if (_activeStudent.source.trim().isNotEmpty) {
      details.add(_buildDetailChip(
        Icons.campaign_outlined,
        'Source: ${_activeStudent.source.trim()}',
        theme,
      ));
    }
    if (_activeStudent.addedDate.trim().isNotEmpty) {
      details.add(_buildDetailChip(
        Icons.calendar_today_outlined,
        'Added: ${_activeStudent.addedDate.trim()}',
        theme,
      ));
    }

    if (details.isEmpty) {
      return Container(
        margin: const EdgeInsets.only(top: 8, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 15,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No extra details added yet (Location, Exam, WhatsApp, etc.)',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.assignment_ind_outlined,
                size: 15,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Student Details',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: details,
          ),
        ],
      ),
    );
  }

  Widget _buildDetailChip(
    dynamic iconData,
    String label,
    ThemeData theme, {
    bool isFa = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isFa)
            const FaIcon(
              FontAwesomeIcons.whatsapp,
              size: 11,
              color: Color(0xFF25D366),
            )
          else
            Icon(
              iconData as IconData,
              size: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditDetailsView(BuildContext context) {
    final theme = Theme.of(context);

    return Form(
      key: _detailsFormKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              height: 4,
              width: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFDDE3E9),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton(
                onPressed: () => setState(() => _isEditingDetails = false),
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Back to log call',
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Edit Details · ${_activeStudent.name}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const ValueKey('edit-name-input'),
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Student name',
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Enter a student name'
                : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('edit-phone-input'),
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Contact number',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
            validator: (value) =>
                value == null || normalizeContactPhone(value).isEmpty
                    ? 'Enter a valid contact number'
                    : null,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _examType,
            decoration: const InputDecoration(
              labelText: 'Exam type',
              prefixIcon: Icon(Icons.school_outlined),
            ),
            hint: const Text('Select exam type'),
            items: _examTypes
                .map(
                  (type) => DropdownMenuItem(value: type, child: Text(type)),
                )
                .toList(),
            onChanged: (value) => setState(() => _examType = value),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _examYearController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Exam Year',
              hintText: 'e.g. 2026',
              prefixIcon: Icon(Icons.calendar_today_outlined),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) return null;
              if (!RegExp(r'^\d{4}$').hasMatch(value.trim())) {
                return 'Enter a 4-digit exam year';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _locationController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Location / City',
              prefixIcon: Icon(Icons.location_city_outlined),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _englishController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'O/L English',
                    hintText: 'A / B / C / S',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _mathsController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'O/L Maths',
                    hintText: 'A / B / C / S',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _whatsappController,
            keyboardType: TextInputType.phone,
            enabled: !_sameAsContact,
            decoration: const InputDecoration(
              labelText: 'WhatsApp number',
              prefixIcon: Icon(Icons.chat_outlined),
            ),
          ),
          Material(
            color: Colors.transparent,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _sameAsContact,
              activeColor: _green,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'Same as contact number',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onChanged: (value) {
                final checked = value ?? false;
                setState(() {
                  _sameAsContact = checked;
                  if (checked) {
                    _whatsappController.text = _phoneController.text.trim();
                  } else if (_whatsappController.text ==
                      _phoneController.text.trim()) {
                    _whatsappController.clear();
                  }
                });
              },
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _saveDetails,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Save'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
