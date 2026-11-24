part of '../../main.dart';

class StudentHistoryDialog extends StatefulWidget {
  const StudentHistoryDialog({
    super.key,
    required this.student,
    required this.title,
    this.onStudentUpdated,
    this.settingsStore,
    this.geminiService,
    this.voiceToTextService,
  });

  final Student student;
  final String title;
  final Future<void> Function(Student updatedStudent)? onStudentUpdated;
  final AppSettingsStore? settingsStore;
  final GeminiService? geminiService;
  final VoiceToTextService? voiceToTextService;

  @override
  State<StudentHistoryDialog> createState() => _StudentHistoryDialogState();
}

class _StudentHistoryDialogState extends State<StudentHistoryDialog> {
  late Student _currentStudent = widget.student;
  bool _isSaving = false;

  List<StudentHistoryEntry> _buildEntries(Student student) =>
      buildStudentHistoryEntries(student);

  Future<void> _editLastRemark(String currentText) async {
    final controller = TextEditingController(text: currentText);
    bool isPolishing = false;
    bool isListeningVoice = false;
    String voiceLanguage = 'si';
    String preVoiceText = '';
    final voiceService =
        widget.voiceToTextService ?? DefaultVoiceToTextService();

    final updatedText = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> toggleVoice() async {
            if (isListeningVoice) {
              await voiceService.stop();
              setDialogState(() => isListeningVoice = false);
              return;
            }
            preVoiceText = controller.text;
            setDialogState(() => isListeningVoice = true);
            final localeId = voiceLanguage == 'si' ? 'si_LK' : 'en_US';
            await voiceService.listen(
              localeId: localeId,
              onResult: (words) {
                if (words.trim().isEmpty) return;
                setDialogState(() {
                  final p = preVoiceText.trim();
                  controller.text = p.isEmpty ? words.trim() : '$p ${words.trim()}';
                  controller.selection = TextSelection.fromPosition(
                    TextPosition(offset: controller.text.length),
                  );
                });
              },
              onStatus: (st) {
                if (st == 'notListening' || st == 'done') {
                  setDialogState(() => isListeningVoice = false);
                }
              },
              onError: (err) {
                setDialogState(() => isListeningVoice = false);
              },
            );
          }

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.edit_note_rounded, color: Color(0xFF8B5CF6)),
                SizedBox(width: 8),
                Text('Edit Last Remark', style: TextStyle(fontSize: 18)),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Correct or update the most recent call remark for ${_currentStudent.name}:',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: controller,
                    minLines: 2,
                    maxLines: 4,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Remark / Comment',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (isListeningVoice)
                        Row(
                          children: [
                            const Icon(
                              Icons.fiber_manual_record,
                              color: Colors.redAccent,
                              size: 10,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Listening (${voiceLanguage == 'si' ? 'Sinhala' : 'EN'})...',
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        )
                      else
                        const SizedBox.shrink(),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                              setDialogState(() {
                                voiceLanguage =
                                    voiceLanguage == 'si' ? 'en' : 'si';
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
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
                              child: Text(
                                voiceLanguage == 'si' ? 'සිංහල' : 'EN',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              foregroundColor: isListeningVoice
                                  ? Colors.redAccent
                                  : const Color(0xFF00966D),
                              side: BorderSide(
                                color: isListeningVoice
                                    ? Colors.redAccent
                                    : const Color(0xFF00966D)
                                        .withValues(alpha: 0.6),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: toggleVoice,
                            icon: Icon(
                              isListeningVoice
                                  ? Icons.stop_rounded
                                  : Icons.mic_rounded,
                              size: 13,
                            ),
                            label: Text(
                              isListeningVoice ? 'Stop' : '🎙️ Speak',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              foregroundColor: const Color(0xFF8B5CF6),
                              side: BorderSide(
                                color: const Color(0xFF8B5CF6)
                                    .withValues(alpha: 0.6),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: isPolishing
                                ? null
                                : () async {
                                    final raw = controller.text.trim();
                                    if (raw.isEmpty) return;
                                    final store = widget.settingsStore ??
                                        SecureAppSettingsStore();
                                    final apiKey =
                                        await store.readGeminiApiKey();
                                    if (apiKey.trim().isEmpty) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Please configure Gemini API key in Settings.',
                                            ),
                                            duration: Duration(seconds: 3),
                                          ),
                                        );
                                      }
                                      return;
                                    }
                                    setDialogState(() => isPolishing = true);
                                    try {
                                      final service = widget.geminiService ??
                                          GeminiService();
                                      final model =
                                          await store.readGeminiModel();
                                      final polished =
                                          await service.polishRemark(
                                        apiKey: apiKey,
                                        rawRemark: raw,
                                        model: model,
                                      );
                                      if (polished.isNotEmpty) {
                                        controller.text = polished;
                                        controller.selection =
                                            TextSelection.fromPosition(
                                          TextPosition(offset: polished.length),
                                        );
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content:
                                                Text('Could not polish: $e'),
                                          ),
                                        );
                                      }
                                    } finally {
                                      setDialogState(() => isPolishing = false);
                                    }
                                  },
                            icon: isPolishing
                                ? const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.auto_awesome_rounded,
                                    size: 14,
                                  ),
                            label: Text(
                              isPolishing ? 'Polishing...' : '✨ Polish',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final text = controller.text.trim();
                  Navigator.pop(dialogCtx, text);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    if (updatedText == null || updatedText == currentText.trim()) return;

    setState(() => _isSaving = true);
    final updatedStudent = _currentStudent.updateLastComment(updatedText);
    try {
      if (widget.onStudentUpdated != null) {
        await widget.onStudentUpdated!(updatedStudent);
      }
      setState(() {
        _currentStudent = updatedStudent;
        _isSaving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✨ Last remark updated!'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update remark: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _buildEntries(_currentStudent);
    final lastCommentIndex =
        entries.lastIndexWhere((e) => e.text.trim().isNotEmpty);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: entries.isEmpty && _currentStudent.note.isEmpty
            ? const Text('No call history or comments have been saved.')
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: entries.isEmpty ? 1 : entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 22),
                  itemBuilder: (context, index) {
                    if (entries.isEmpty) return Text(_currentStudent.note);
                    final entry = entries[index];
                    final isLatestComment = (index == lastCommentIndex);

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (entry.status.isNotEmpty ||
                            entry.dateLabel.isNotEmpty ||
                            isLatestComment)
                          Row(
                            children: [
                              if (entry.status.isNotEmpty)
                                Text(
                                  entry.status,
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              if (isLatestComment) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'Latest',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                              const Spacer(),
                              if (entry.dateLabel.isNotEmpty)
                                Text(
                                  entry.dateLabel,
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        if (entry.text.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(entry.text),
                        ],
                        if (isLatestComment &&
                            entry.text.trim().isNotEmpty &&
                            widget.onStudentUpdated != null) ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              key: const Key('edit_last_remark_button'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                foregroundColor: const Color(0xFF8B5CF6),
                              ),
                              icon: const Icon(Icons.edit_rounded, size: 14),
                              label: const Text(
                                'Edit last remark',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              onPressed: _isSaving
                                  ? null
                                  : () => _editLastRemark(entry.text),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

