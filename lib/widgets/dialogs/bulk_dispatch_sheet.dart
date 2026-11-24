part of '../../main.dart';

class BulkDispatchSheet extends StatefulWidget {
  const BulkDispatchSheet({
    super.key,
    required this.students,
    required this.payload,
    required this.isSms,
    required this.onDispatch,
  });

  final List<Student> students;
  final WhatsAppSendPayload payload;
  final bool isSms;
  final Future<void> Function(Student student, String text) onDispatch;

  @override
  State<BulkDispatchSheet> createState() => _BulkDispatchSheetState();
}

class _BulkDispatchSheetState extends State<BulkDispatchSheet> {
  int _currentIndex = 0;
  final Map<int, _BulkItemStatus> _statuses = {};
  final Map<int, String> _customEdits = {};
  late final TextEditingController _messageController;
  bool _isDone = false;
  bool _isDispatching = false;

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController();
    _syncControllerForCurrentStudent();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  void _syncControllerForCurrentStudent() {
    if (_currentIndex < widget.students.length) {
      final student = widget.students[_currentIndex];
      _messageController.text =
          _customEdits[_currentIndex] ?? _formatForStudent(student);
    }
  }

  int get _sentCount =>
      _statuses.values.where((s) => s == _BulkItemStatus.sent).length;

  int get _skippedCount =>
      _statuses.values.where((s) => s == _BulkItemStatus.skipped).length;

  int get _remainingCount =>
      widget.students.length - (_sentCount + _skippedCount);

  double get _progress => widget.students.isEmpty
      ? 1.0
      : (_sentCount + _skippedCount) / widget.students.length;

  String _formatForStudent(Student student) {
    final sName = student.name.trim();
    final nameToUse = sName.isNotEmpty ? sName : 'there';
    var text = widget.payload.message;
    text = text.replaceAll(
      RegExp(r'\{\s*name\s*\}', caseSensitive: false),
      nameToUse,
    );
    text = text.replaceAll(
      RegExp(r'\{\s*student\s*\}', caseSensitive: false),
      nameToUse,
    );
    text = text.replaceAll(
      RegExp(r'\{\s*student_name\s*\}', caseSensitive: false),
      nameToUse,
    );
    return text;
  }

  void _advanceToNext() {
    int next = -1;
    for (int i = 0; i < widget.students.length; i++) {
      if (!_statuses.containsKey(i)) {
        next = i;
        break;
      }
    }
    if (next != -1) {
      _currentIndex = next;
      _syncControllerForCurrentStudent();
    } else {
      _isDone = true;
    }
  }

  Future<void> _sendCurrent() async {
    if (_isDispatching || _currentIndex >= widget.students.length) return;
    setState(() => _isDispatching = true);

    final student = widget.students[_currentIndex];
    final personalizedText = _messageController.text.trim();

    try {
      await widget.onDispatch(student, personalizedText);
    } finally {
      if (mounted) {
        setState(() {
          _isDispatching = false;
          _statuses[_currentIndex] = _BulkItemStatus.sent;
          _advanceToNext();
        });
      }
    }
  }

  void _skipCurrent() {
    if (_currentIndex >= widget.students.length) return;
    setState(() {
      _statuses[_currentIndex] = _BulkItemStatus.skipped;
      _advanceToNext();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            const SizedBox(height: 14),
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: widget.isSms
                      ? const Color(0xFF2E6FA3).withValues(alpha: 0.15)
                      : const Color(0xFF25D366).withValues(alpha: 0.15),
                  child: widget.isSms
                      ? const Icon(
                          Icons.sms_rounded,
                          size: 18,
                          color: Color(0xFF2E6FA3),
                        )
                      : const FaIcon(
                          FontAwesomeIcons.whatsapp,
                          size: 18,
                          color: Color(0xFF25D366),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.isSms ? 'Bulk SMS Queue' : 'Bulk WhatsApp Queue',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${widget.students.length} students in queue',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Close queue',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(
                  widget.isSms
                      ? const Color(0xFF2E6FA3)
                      : const Color(0xFF25D366),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Sent: $_sentCount • Skipped: $_skippedCount',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  '$_remainingCount remaining',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (_isDone) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      size: 64,
                      color: Color(0xFF25D366),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'All Messages Dispatched!',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Successfully processed ${widget.students.length} student(s) with personalized messages.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 12,
                        ),
                      ),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            ] else ...[
              _buildCurrentStudentCard(context, theme),
              const SizedBox(height: 12),
              Text(
                'Queue Overview (${widget.students.length})',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.students.length,
                  separatorBuilder: (ctx, i) => const SizedBox(height: 6),
                  itemBuilder: (ctx, i) {
                    final student = widget.students[i];
                    final status = _statuses[i] ?? _BulkItemStatus.pending;
                    final isCurrent = i == _currentIndex;

                    Widget statusIcon;
                    String statusLabel;
                    Color statusColor;

                    if (status == _BulkItemStatus.sent) {
                      statusIcon = const Icon(
                        Icons.check_circle,
                        size: 16,
                        color: Color(0xFF25D366),
                      );
                      statusLabel = 'Sent';
                      statusColor = const Color(0xFF25D366);
                    } else if (status == _BulkItemStatus.skipped) {
                      statusIcon = const Icon(
                        Icons.skip_next,
                        size: 16,
                        color: Colors.orange,
                      );
                      statusLabel = 'Skipped';
                      statusColor = Colors.orange;
                    } else if (isCurrent) {
                      statusIcon = Icon(
                        Icons.play_circle_fill,
                        size: 16,
                        color: theme.colorScheme.primary,
                      );
                      statusLabel = 'Current';
                      statusColor = theme.colorScheme.primary;
                    } else {
                      statusIcon = Icon(
                        Icons.radio_button_unchecked,
                        size: 16,
                        color: theme.colorScheme.outline,
                      );
                      statusLabel = 'Pending';
                      statusColor = theme.colorScheme.outline;
                    }

                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        setState(() {
                          _currentIndex = i;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? theme.colorScheme.primaryContainer
                                  .withValues(alpha: 0.3)
                              : theme.colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(10),
                          border: isCurrent
                              ? Border.all(
                                  color: theme.colorScheme.primary,
                                  width: 1.2,
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            statusIcon,
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                student.name,
                                style: TextStyle(
                                  fontWeight: isCurrent
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              statusLabel,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: statusColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentStudentCard(BuildContext context, ThemeData theme) {
    final currentStudent = widget.students[_currentIndex];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_currentIndex + 1} of ${widget.students.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              Icon(
                Icons.phone_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                currentStudent.phone,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            currentStudent.name,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (widget.payload.hasDocuments && !widget.isSms) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.attach_file,
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '${widget.payload.documentPaths.length} document(s) attached',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _messageController,
            maxLines: 4,
            onChanged: (val) {
              _customEdits[_currentIndex] = val;
            },
            decoration: InputDecoration(
              isDense: true,
              hintText: '(Document attachment only)',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: theme.colorScheme.primary,
                  width: 1.5,
                ),
              ),
              contentPadding: const EdgeInsets.all(10),
            ),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isDispatching ? null : _sendCurrent,
                  style: FilledButton.styleFrom(
                    backgroundColor: widget.isSms
                        ? const Color(0xFF2E6FA3)
                        : const Color(0xFF25D366),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: widget.isSms
                      ? const Icon(Icons.send_rounded, size: 18)
                      : const FaIcon(FontAwesomeIcons.whatsapp, size: 18),
                  label: Text(
                    'Send to ${currentStudent.name.split(" ").first}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _skipCurrent,
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Skip'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TemplateEditorDialog extends StatefulWidget {
  const _TemplateEditorDialog({
    this.template,
    this.initialName,
    this.initialMessage,
  });

  final WhatsAppTemplate? template;
  final String? initialName;
  final String? initialMessage;

  @override
  State<_TemplateEditorDialog> createState() => _TemplateEditorDialogState();
}

class _TemplateEditorDialogState extends State<_TemplateEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _messageController;
  String? _documentPath;
  String? _documentName;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.template?.name ?? widget.initialName ?? '',
    );
    _messageController = TextEditingController(
      text: widget.template?.message ?? widget.initialMessage ?? '',
    );
    _documentPath = widget.template?.documentPath;
    _documentName = widget.template?.documentName;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _pickDocument() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: [
          'pdf',
          'doc',
          'docx',
          'xls',
          'xlsx',
          'ppt',
          'pptx',
          'txt',
          'png',
          'jpg',
          'jpeg',
        ],
      );
      if (file != null && file.path != null && file.path!.trim().isNotEmpty) {
        setState(() {
          _documentPath = file.path;
          _documentName = file.name;
        });
        _formKey.currentState?.validate();
      }
    } catch (e) {
      debugPrint('Error picking file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not attach file: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(
        widget.template != null
            ? 'Edit Template'
            : (widget.initialMessage != null
                ? 'Save as Template'
                : 'Add Template'),
      ),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Template Name',
                  hintText: 'e.g. Class Follow-up',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.sentences,
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter a template name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _messageController,
                decoration: InputDecoration(
                  labelText: 'Message',
                  hintText: 'e.g. Hello {name}, your class starts tomorrow.',
                  helperText: _documentPath != null
                      ? 'Optional when document is attached'
                      : 'Tip: Use {name} for student name',
                  border: const OutlineInputBorder(),
                ),
                maxLines: 4,
                minLines: 2,
                textCapitalization: TextCapitalization.sentences,
                validator: (val) {
                  final hasDoc = _documentPath != null &&
                      _documentPath!.trim().isNotEmpty;
                  if ((val == null || val.trim().isEmpty) && !hasDoc) {
                    return 'Please enter message content or attach a document';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              // Document attachment section for WhatsApp templates
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.attach_file,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Attach Document (WhatsApp)',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Attach a PDF or file to send along with this template on WhatsApp.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_documentPath != null && _documentName != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.description,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _documentName!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Remove document',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () {
                                setState(() {
                                  _documentPath = null;
                                  _documentName = null;
                                });
                                _formKey.currentState?.validate();
                              },
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      OutlinedButton.icon(
                        onPressed: _pickDocument,
                        icon: const Icon(Icons.upload_file, size: 18),
                        label: const Text('Attach Document (PDF, Doc)'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState?.validate() ?? false) {
              final result = WhatsAppTemplate(
                id: widget.template?.id ??
                    DateTime.now().millisecondsSinceEpoch.toString(),
                name: _nameController.text.trim(),
                message: _messageController.text.trim(),
                documentPath: _documentPath,
                documentName: _documentName,
              );
              Navigator.pop(context, result);
            }
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ManageWhatsAppTemplatesSheet extends StatefulWidget {
  const _ManageWhatsAppTemplatesSheet({required this.settingsStore});

  final AppSettingsStore settingsStore;

  @override
  State<_ManageWhatsAppTemplatesSheet> createState() =>
      _ManageWhatsAppTemplatesSheetState();
}

class _ManageWhatsAppTemplatesSheetState
    extends State<_ManageWhatsAppTemplatesSheet> {
  List<WhatsAppTemplate> _templates = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    final list = await widget.settingsStore.readWhatsAppTemplates();
    if (mounted) {
      setState(() {
        _templates = List.of(list);
        _isLoading = false;
      });
    }
  }

  Future<void> _saveTemplates() async {
    await widget.settingsStore.saveWhatsAppTemplates(_templates);
  }

  Future<void> _addOrEditTemplate([WhatsAppTemplate? existing]) async {
    final saved = await showDialog<WhatsAppTemplate>(
      context: context,
      builder: (_) => _TemplateEditorDialog(template: existing),
    );

    if (saved != null && mounted) {
      setState(() {
        if (existing == null) {
          _templates.add(saved);
        } else {
          final index = _templates.indexWhere((t) => t.id == existing.id);
          if (index != -1) {
            _templates[index] = saved;
          }
        }
      });
      await _saveTemplates();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              existing == null ? 'Template added' : 'Template updated',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _deleteTemplate(WhatsAppTemplate template) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Delete Template'),
        content: Text('Are you sure you want to delete "${template.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() {
        _templates.removeWhere((t) => t.id == template.id);
      });
      await _saveTemplates();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Template deleted'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'WhatsApp & SMS Templates',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => _addOrEditTemplate(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Pre-written messages for WhatsApp & SMS with {name} placeholder support.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (_isLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_templates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Column(
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 48,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No templates yet',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tap "Add" to create your first WhatsApp template.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _templates.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = _templates[index];
                    return Card(
                      color: theme.colorScheme.surfaceContainerLow,
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          item.name,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      if (item.hasDocument) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: theme
                                                .colorScheme.primaryContainer,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.attach_file,
                                                size: 13,
                                                color: theme.colorScheme
                                                    .onPrimaryContainer,
                                              ),
                                              const SizedBox(width: 3),
                                              ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                  maxWidth: 130,
                                                ),
                                                child: Text(
                                                  item.documentName ?? 'Doc',
                                                  style: theme
                                                      .textTheme.labelSmall
                                                      ?.copyWith(
                                                    color: theme.colorScheme
                                                        .onPrimaryContainer,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 20,
                                  ),
                                  tooltip: 'Edit template',
                                  onPressed: () => _addOrEditTemplate(item),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                    color: theme.colorScheme.error,
                                  ),
                                  tooltip: 'Delete template',
                                  onPressed: () => _deleteTemplate(item),
                                ),
                              ],
                            ),
                            if (item.message.trim().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                item.message,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            if (item.hasDocument) ...[
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(
                                    Icons.description_outlined,
                                    size: 14,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      'File: ${item.documentName}',
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.primary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

