part of '../../main.dart';

class EditStudentSheet extends StatefulWidget {
  const EditStudentSheet({
    super.key,
    required this.student,
    this.settingsStore,
    this.geminiService,
    this.voiceToTextService,
  });

  final Student student;
  final AppSettingsStore? settingsStore;
  final GeminiService? geminiService;
  final VoiceToTextService? voiceToTextService;

  @override
  State<EditStudentSheet> createState() => _EditStudentSheetState();
}

typedef _EditStudentSheet = EditStudentSheet;

class _EditStudentSheetState extends State<EditStudentSheet> {
  final _formKey = GlobalKey<FormState>();
  late final AppSettingsStore _settingsStore =
      widget.settingsStore ?? SecureAppSettingsStore();
  late final GeminiService _geminiService =
      widget.geminiService ?? GeminiService();
  late final VoiceToTextService _voiceService =
      widget.voiceToTextService ?? DefaultVoiceToTextService();
  bool _isPolishing = false;
  bool _isListeningVoice = false;
  String _voiceLanguage = 'si';
  String _preVoiceText = '';
  late Student _activeStudent = widget.student;

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
  late final _commentController = TextEditingController(text: '');

  static const _examTypes = ['O/L', 'A/L'];
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

  late String? _examType = _examTypes.contains(widget.student.examType)
      ? widget.student.examType
      : null;
  late String? _callStatus = _callStatuses.contains(widget.student.callStatus)
      ? widget.student.callStatus
      : null;
  late bool _sameAsContact =
      widget.student.whatsappSameAsContact ||
      widget.student.whatsappNumber == widget.student.phone;
  late DateTime? _nextCallDateTime = tryParseDate(
    widget.student.nextCallDateTime,
  );
  bool _isPickingNextCallDateTime = false;

  @override
  void initState() {
    super.initState();
    if (_sameAsContact) _whatsappController.text = widget.student.phone;
  }

  @override
  void dispose() {
    if (_isListeningVoice) {
      _voiceService.stop();
    }
    _nameController.dispose();
    _phoneController.dispose();
    _examYearController.dispose();
    _locationController.dispose();
    _englishController.dispose();
    _mathsController.dispose();
    _whatsappController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  Student _updatedStudent() {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
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
      name: name,
      phone: phone,
      examType: _examType ?? '',
      examYear: _examYearController.text.trim(),
      location: _locationController.text.trim(),
      olEnglish: _englishController.text.trim().toUpperCase(),
      olMaths: _mathsController.text.trim().toUpperCase(),
      whatsappNumber: _sameAsContact ? phone : _whatsappController.text.trim(),
      whatsappSameAsContact: _sameAsContact,
      callStatus: callStatus,
      nextCallDateTime: nextCallStr,
      comment: newComment.isEmpty ? null : newComment,
      commentHistory: history,
      attempts: attempts,
    );
  }

  void _setQuickReminder(Duration offset, [int? targetHour]) {
    final now = DateTime.now();
    DateTime target;
    if (targetHour != null) {
      final tomorrow = now.add(const Duration(days: 1));
      target = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, targetHour, 0);
    } else {
      target = now.add(offset);
      final remainder = target.minute % 5;
      final roundedMinute = remainder == 0 ? target.minute : target.minute + (5 - remainder);
      if (roundedMinute >= 60) {
        target = DateTime(target.year, target.month, target.day, target.hour + 1, roundedMinute - 60);
      } else {
        target = DateTime(target.year, target.month, target.day, target.hour, roundedMinute);
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
    final isExistingFuture = existingReminder != null && existingReminder.isAfter(now);

    final initialPickerDate = isExistingFuture
        ? DateTime(existingReminder.year, existingReminder.month, existingReminder.day)
        : today;

    TimeOfDay initialPickerTime;
    if (isExistingFuture) {
      initialPickerTime = TimeOfDay.fromDateTime(existingReminder);
    } else if (existingReminder != null &&
        combineReminderDateAndTime(today, TimeOfDay.fromDateTime(existingReminder))
            .isAfter(now.add(const Duration(minutes: 5)))) {
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
            selectedDateTime.isAfter(currentNow.subtract(const Duration(minutes: 2)))) {
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

  Future<void> _toggleVoice() async {
    if (_isListeningVoice) {
      await _voiceService.stop();
      if (mounted) setState(() => _isListeningVoice = false);
      return;
    }

    _preVoiceText = _commentController.text;
    setState(() => _isListeningVoice = true);

    final localeId = _voiceLanguage == 'si' ? 'si_LK' : 'en_US';

    await _voiceService.listen(
      localeId: localeId,
      onResult: (words) {
        if (!mounted || words.trim().isEmpty) return;
        setState(() {
          final prefix = _preVoiceText.trim();
          if (prefix.isEmpty) {
            _commentController.text = words.trim();
          } else {
            _commentController.text = '$prefix ${words.trim()}';
          }
          _commentController.selection = TextSelection.fromPosition(
            TextPosition(offset: _commentController.text.length),
          );
        });
      },
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'notListening' || status == 'done') {
          setState(() => _isListeningVoice = false);
        }
      },
      onError: (err) {
        if (!mounted) return;
        setState(() => _isListeningVoice = false);
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.removeCurrentSnackBar();
        messenger?.showSnackBar(
          SnackBar(
            content: Text('Voice input: $err'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      },
    );
  }

  Future<void> _polishRemarkWithAi() async {
    final rawRemark = _commentController.text.trim();
    if (rawRemark.isEmpty) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.removeCurrentSnackBar();
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Please type your raw or draft remark first.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final apiKey = await _settingsStore.readGeminiApiKey();
    if (apiKey.trim().isEmpty) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.removeCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: const Text(
            'Gemini API key not configured. Please add your free key in Settings.',
          ),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () {
              showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => ManageGeminiAiSheet(
                  settingsStore: _settingsStore,
                  geminiService: _geminiService,
                ),
              );
            },
          ),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

    setState(() => _isPolishing = true);
    final originalText = _commentController.text;

    try {
      final model = await _settingsStore.readGeminiModel();
      final polished = await _geminiService.polishRemark(
        apiKey: apiKey,
        rawRemark: rawRemark,
        model: model,
      );

      if (!mounted) return;
      if (polished.isNotEmpty) {
        setState(() {
          _commentController.text = polished;
          _commentController.selection = TextSelection.fromPosition(
            TextPosition(offset: polished.length),
          );
        });

        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.removeCurrentSnackBar();
        messenger?.showSnackBar(
          SnackBar(
            content: const Text('✨ Remark polished into clear English!'),
            behavior: SnackBarBehavior.floating,
            dismissDirection: DismissDirection.horizontal,
            duration: const Duration(seconds: 2),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () {
                messenger.hideCurrentSnackBar();
                setState(() {
                  _commentController.text = originalText;
                  _commentController.selection = TextSelection.fromPosition(
                    TextPosition(offset: originalText.length),
                  );
                });
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.removeCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Could not polish remark: $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isPolishing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
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
                const SizedBox(height: 20),
                Text(
                  'Update ${widget.student.name}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Update these details on the existing student record.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),
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
                        (type) =>
                            DropdownMenuItem(value: type, child: Text(type)),
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
                          _whatsappController.text = widget.student.phone;
                        } else if (_whatsappController.text ==
                            widget.student.phone) {
                          _whatsappController.clear();
                        }
                      });
                    },
                  ),
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isPickingNextCallDateTime
                      ? null
                      : _pickNextCallDateTime,
                  icon: Icon(
                    _isPickingNextCallDateTime
                        ? Icons.hourglass_top_rounded
                        : (_nextCallDateTime != null && _nextCallDateTime!.isBefore(DateTime.now())
                            ? Icons.warning_amber_rounded
                            : Icons.event_available_outlined),
                    color: _nextCallDateTime != null && _nextCallDateTime!.isBefore(DateTime.now())
                        ? const Color(0xFFD32F2F)
                        : null,
                  ),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _isPickingNextCallDateTime
                          ? 'Selecting date & time…'
                          : _nextCallDateTime == null
                          ? 'Next call date & time (optional)'
                          : (_nextCallDateTime!.isBefore(DateTime.now())
                              ? 'Next call · Overdue: ${_formatReminder(_nextCallDateTime!)} (Tap to reschedule)'
                              : 'Next call · ${_formatReminder(_nextCallDateTime!)}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    minimumSize: const Size.fromHeight(54),
                    side: BorderSide(
                      color: _nextCallDateTime != null && _nextCallDateTime!.isBefore(DateTime.now())
                          ? const Color(0xFFD32F2F)
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
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
                        onPressed: () => _setQuickReminder(const Duration(days: 1), 10),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(Icons.brightness_5_rounded, size: 15),
                        label: const Text('Tomorrow 2 PM'),
                        onPressed: () => _setQuickReminder(const Duration(days: 1), 14),
                      ),
                    ],
                  ),
                ),
                if (_nextCallDateTime == null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 6),
                    child: Text(
                      'Optional — leave blank to save without a call reminder.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (_nextCallDateTime != null && _nextCallDateTime!.isBefore(DateTime.now()))
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 4),
                    child: Text(
                      '⚠️ This reminder was for the past. Tap above to reschedule, or save to clear.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (_nextCallDateTime != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setState(() => _nextCallDateTime = null),
                      child: const Text('Clear reminder'),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'New call remark',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _showCommentHistory,
                      icon: const Icon(Icons.history_rounded, size: 18),
                      label: const Text('View History'),
                    ),
                  ],
                ),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: _isListeningVoice
                          ? Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Colors.redAccent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Listening in ${_voiceLanguage == 'si' ? 'Sinhala' : 'English'}...',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: Colors.redAccent,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              'Draft in Sinhala, Singlish, or English',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                        .withValues(alpha: 0.7),
                                    fontSize: 11,
                                  ),
                            ),
                    ),
                    const SizedBox(width: 4),
                    // Language switcher chip (සිංහල / English)
                    InkWell(
                      key: const Key('voice_language_toggle'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        setState(() {
                          _voiceLanguage = _voiceLanguage == 'si' ? 'en' : 'si';
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          border: Border.all(
                            color: Theme.of(context)
                                .colorScheme
                                .outlineVariant
                                .withValues(alpha: 0.6),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.language_rounded,
                              size: 13,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _voiceLanguage == 'si' ? 'සිංහල' : 'English',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      key: const Key('voice_to_text_button'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        foregroundColor: _isListeningVoice
                            ? Colors.redAccent
                            : const Color(0xFF00966D),
                        side: BorderSide(
                          color: _isListeningVoice
                              ? Colors.redAccent
                              : const Color(0xFF00966D).withValues(alpha: 0.6),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onPressed: _toggleVoice,
                      icon: Icon(
                        _isListeningVoice
                            ? Icons.stop_circle_rounded
                            : Icons.mic_rounded,
                        size: 14,
                      ),
                      label: Text(
                        _isListeningVoice ? 'Stop' : '🎙️ Speak',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      key: const Key('polish_remark_button'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        foregroundColor: const Color(0xFF8B5CF6),
                        side: BorderSide(
                          color: const Color(0xFF8B5CF6).withValues(alpha: 0.6),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onPressed: _isPolishing ? null : _polishRemarkWithAi,
                      icon: _isPolishing
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome_rounded, size: 14),
                      label: Text(
                        _isPolishing ? 'Polishing...' : '✨ Polish',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      if (!_formKey.currentState!.validate()) return;
                      final updated = _updatedStudent();
                      final currentStreak =
                          studentActivityStatus(widget.student).unansweredStreak;
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
                              '${widget.student.name} has not answered $nextStreak consecutive times. Move to \'Inactive\'?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogCtx, false),
                                child: const Text('Keep Active'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor:
                                      Theme.of(context).colorScheme.error,
                                ),
                                onPressed: () => Navigator.pop(dialogCtx, true),
                                child: const Text('Move to Inactive'),
                              ),
                            ],
                          ),
                        );

                        if (moveToInactive == true) {
                          final enteredComment =
                              _commentController.text.trim();
                          final updatedAttempts =
                              List<CallAttempt>.of(updated.attempts);
                          final inactiveComment = enteredComment.isNotEmpty
                              ? enteredComment
                              : 'Marked as Inactive after $nextStreak unanswered calls';
                          if (updatedAttempts.isNotEmpty) {
                            final last = updatedAttempts.last;
                            updatedAttempts[updatedAttempts.length - 1] =
                                CallAttempt(
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

                          final updatedHistory =
                              List<String>.of(updated.commentHistory);
                          final historyEntry =
                              '${_formatReminder(DateTime.now())} — Inactive ($inactiveComment)';
                          if (enteredComment.isNotEmpty &&
                              updatedHistory.isNotEmpty) {
                            updatedHistory[updatedHistory.length - 1] =
                                historyEntry;
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
                          if (context.mounted) {
                            ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
                            Navigator.of(context).pop(inactiveStudent);
                          }
                          return;
                        }
                      }

                      if (context.mounted) {
                        ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
                        Navigator.of(context).pop(updated);
                      }
                    },
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Update Details'),
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
          ),
        ),
      ),
    );
  }
}

