part of '../../main.dart';

class WhatsAppTemplatePickerSheet extends StatefulWidget {
  const WhatsAppTemplatePickerSheet({
    super.key,
    required this.student,
    required this.templates,
    required this.onManageTemplates,
    this.isSms = false,
    this.isBulk = false,
  });

  final Student student;
  final List<WhatsAppTemplate> templates;
  final VoidCallback onManageTemplates;
  final bool isSms;
  final bool isBulk;

  @override
  State<WhatsAppTemplatePickerSheet> createState() =>
      _WhatsAppTemplatePickerSheetState();
}

class _WhatsAppTemplatePickerSheetState
    extends State<WhatsAppTemplatePickerSheet> {
  bool _isMultiSelect = false;
  final Set<String> _selectedTemplateIds = <String>{};

  String _formatMessage(String template) {
    final studentName = widget.student.name.trim();
    return template.replaceAll(
      '{name}',
      studentName.isNotEmpty ? studentName : 'there',
    );
  }

  void _sendSingle(WhatsAppTemplate item) {
    final messageToSend =
        widget.isBulk ? item.message : _formatMessage(item.message);
    final docs =
        (item.hasDocument && !widget.isSms && item.documentPath != null)
            ? [item.documentPath!]
            : <String>[];
    Navigator.pop(
      context,
      WhatsAppSendPayload(
        message: messageToSend,
        documentPaths: docs,
      ),
    );
  }

  void _sendMulti() {
    if (_selectedTemplateIds.isEmpty) return;

    final selected = widget.templates
        .where((t) => _selectedTemplateIds.contains(t.id))
        .toList();
    if (selected.isEmpty) return;

    final combinedMessage = selected
        .map((t) =>
            (widget.isBulk ? t.message : _formatMessage(t.message)).trim())
        .where((msg) => msg.isNotEmpty)
        .join('\n\n');

    final docs = <String>[];
    if (!widget.isSms) {
      for (final t in selected) {
        if (t.hasDocument && t.documentPath != null) {
          final p = t.documentPath!;
          if (!docs.contains(p)) {
            docs.add(p);
          }
        }
      }
    }

    Navigator.pop(
      context,
      WhatsAppSendPayload(
        message: combinedMessage,
        documentPaths: docs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final selectedCount = _selectedTemplateIds.length;
    final selectedDocsCount = widget.isSms
        ? 0
        : widget.templates
            .where((t) =>
                _selectedTemplateIds.contains(t.id) &&
                t.hasDocument &&
                t.documentPath != null)
            .length;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
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
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              'Select Template',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (_isMultiSelect && selectedCount > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '$selectedCount selected',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isMultiSelect
                            ? 'Check templates to combine and send together'
                            : (widget.isSms
                                ? 'Tap a template to send via SMS'
                                : 'Tap a template to send, or choose multi-select'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                FilterChip(
                  selected: _isMultiSelect,
                  showCheckmark: false,
                  avatar: Icon(
                    _isMultiSelect
                        ? Icons.checklist_rtl_rounded
                        : Icons.checklist_rounded,
                    size: 16,
                    color: _isMultiSelect
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.primary,
                  ),
                  label: Text(
                    _isMultiSelect ? 'Done' : 'Multi-Select',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _isMultiSelect
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.primary,
                    ),
                  ),
                  selectedColor: theme.colorScheme.primary,
                  backgroundColor:
                      theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
                  side: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  ),
                  onSelected: (val) {
                    setState(() {
                      _isMultiSelect = val;
                      if (!val) _selectedTemplateIds.clear();
                    });
                  },
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: widget.onManageTemplates,
                  icon: const Icon(Icons.settings_outlined, size: 20),
                  tooltip: 'Manage Templates',
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (widget.templates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Icon(
                      Icons.text_snippet_outlined,
                      size: 48,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No templates found',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: widget.onManageTemplates,
                      icon: const Icon(Icons.add),
                      label: const Text('Create Template'),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.templates.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = widget.templates[index];
                    final preview = _formatMessage(item.message);
                    final isSelected = _selectedTemplateIds.contains(item.id);

                    return Card(
                      color: isSelected
                          ? theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.35)
                          : theme.colorScheme.surfaceContainerLow,
                      margin: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: isSelected
                            ? BorderSide(
                                color: theme.colorScheme.primary,
                                width: 1.5,
                              )
                            : BorderSide(
                                color: theme.colorScheme.outlineVariant
                                    .withValues(alpha: 0.3),
                              ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          if (_isMultiSelect) {
                            setState(() {
                              if (isSelected) {
                                _selectedTemplateIds.remove(item.id);
                              } else {
                                _selectedTemplateIds.add(item.id);
                              }
                            });
                          } else {
                            _sendSingle(item);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  if (_isMultiSelect) ...[
                                    Checkbox(
                                      value: isSelected,
                                      visualDensity: VisualDensity.compact,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      onChanged: (val) {
                                        setState(() {
                                          if (val == true) {
                                            _selectedTemplateIds.add(item.id);
                                          } else {
                                            _selectedTemplateIds.remove(item.id);
                                          }
                                        });
                                      },
                                    ),
                                    const SizedBox(width: 6),
                                  ] else ...[
                                    Icon(
                                      widget.isSms
                                          ? Icons.sms_outlined
                                          : Icons.chat_bubble_outline,
                                      size: 18,
                                      color: widget.isSms
                                          ? const Color(0xFF2E6FA3)
                                          : theme.colorScheme.primary,
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Expanded(
                                    child: Text(
                                      item.name,
                                      style:
                                          theme.textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (!_isMultiSelect)
                                    Icon(
                                      Icons.send_rounded,
                                      size: 16,
                                      color: theme.colorScheme.primary,
                                    ),
                                ],
                              ),
                              if (preview.trim().isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  preview,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                              if (item.hasDocument && !widget.isSms) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primaryContainer
                                        .withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: theme.colorScheme.primary
                                          .withValues(alpha: 0.3),
                                    ),
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
                                          item.documentName ?? 'Attached document',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                            color: theme.colorScheme.primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (_isMultiSelect) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _selectedTemplateIds.isEmpty ? null : _sendMulti,
                icon: const Icon(Icons.send_rounded, size: 18),
                label: Text(
                  _selectedTemplateIds.isEmpty
                      ? 'Select templates to send'
                      : 'Send $selectedCount Template${selectedCount > 1 ? "s" : ""}${selectedDocsCount > 0 ? " ($selectedDocsCount with docs)" : ""}',
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _BulkItemStatus { pending, sent, skipped }

