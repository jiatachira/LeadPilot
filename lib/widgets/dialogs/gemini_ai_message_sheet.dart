part of '../../main.dart';

class GeminiAiMessageSheet extends StatefulWidget {
  const GeminiAiMessageSheet({
    super.key,
    required this.student,
    required this.initialApiKey,
    required this.settingsStore,
    this.geminiService,
    this.isSms = false,
  });

  final Student student;
  final String initialApiKey;
  final AppSettingsStore settingsStore;
  final GeminiService? geminiService;
  final bool isSms;

  @override
  State<GeminiAiMessageSheet> createState() => _GeminiAiMessageSheetState();
}

class _GeminiAiMessageSheetState extends State<GeminiAiMessageSheet> {
  late String _apiKey;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _instructionController;
  late final TextEditingController _messageController;
  late final GeminiService _geminiService;

  String _selectedLanguage = 'Sinhala';
  bool _isGenerating = false;
  String? _errorMessage;
  bool _obscureApiKey = true;
  String _companySummary = '';

  final List<String> _languages = const ['Sinhala', 'Singlish', 'English'];

  @override
  void initState() {
    super.initState();
    _apiKey = widget.initialApiKey.trim();
    _apiKeyController = TextEditingController(text: _apiKey);
    _instructionController = TextEditingController();
    _messageController = TextEditingController();
    _geminiService = widget.geminiService ?? GeminiService();
    _loadCompanyInfo();

    final st = widget.student.callStatus.toLowerCase();
    final streak = studentActivityStatus(widget.student).unansweredStreak;
    if (st.contains('no answer') ||
        st.contains('busy') ||
        st.contains('call cut') ||
        streak >= 2) {
      _instructionController.text = 'Follow-up regarding missed call';
    } else if (st.contains('interest') || st.contains('register')) {
      _instructionController.text = 'Follow-up on class details and registration';
    } else {
      _instructionController.text = 'General class follow-up';
    }

    if (_apiKey.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _generateMessage();
      });
    }
  }

  Future<void> _loadCompanyInfo() async {
    final company = await widget.settingsStore.readCompanyDescription();
    if (!mounted) return;
    setState(() {
      _companySummary = company.contains('-')
          ? company.split('-').first.trim()
          : (company.length > 30 ? '${company.substring(0, 30)}...' : company);
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _instructionController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _saveApiKey() async {
    final cleanKey = GeminiService.sanitizeApiKey(_apiKeyController.text);
    _apiKeyController.text = cleanKey;
    if (cleanKey.isEmpty) {
      setState(() => _errorMessage = 'Please paste a valid Gemini API Key.');
      return;
    }
    await widget.settingsStore.saveGeminiApiKey(cleanKey);
    if (!mounted) return;
    setState(() {
      _apiKey = cleanKey;
      _errorMessage = null;
    });
    await _generateMessage();
  }

  Future<void> _generateMessage() async {
    final groqKey = await widget.settingsStore.readGroqApiKey();
    final provider = await widget.settingsStore.readAiProvider();
    final groqModel = await widget.settingsStore.readGroqModel();
    if (_apiKey.isEmpty && groqKey.isEmpty) return;
    setState(() {
      _isGenerating = true;
      _errorMessage = null;
    });

    try {
      final savedModel = await widget.settingsStore.readGeminiModel();
      final companyDesc = await widget.settingsStore.readCompanyDescription();
      final result = await _geminiService.generateFollowUp(
        apiKey: _apiKey,
        student: widget.student,
        model: savedModel,
        language: _selectedLanguage,
        customInstructions: _instructionController.text.trim(),
        companyDescription: companyDesc,
        provider: provider,
        groqApiKey: groqKey,
        groqModel: groqModel,
      );
      if (!mounted) return;
      setState(() {
        _messageController.text = result;
        _isGenerating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isGenerating = false;
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    final clean = GeminiService.sanitizeApiKey(text);
    if (clean.isNotEmpty) {
      _apiKeyController.text = clean;
    }
  }

  Future<void> _openGoogleAiStudio() async {
    final uri = Uri.parse('https://aistudio.google.com/app/apikey');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _copyMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message copied to clipboard!'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _saveAsTemplate() async {
    final currentText = _messageController.text.trim();
    if (currentText.isEmpty) return;

    var templateMsg = currentText;
    final sName = widget.student.name.trim();
    if (sName.isNotEmpty && templateMsg.contains(sName)) {
      templateMsg = templateMsg.replaceFirst(sName, '{name}');
    } else if (sName.isNotEmpty) {
      final firstName = sName.split(RegExp(r'\s+')).first;
      if (firstName.length >= 3 && templateMsg.contains(firstName)) {
        templateMsg = templateMsg.replaceFirst(firstName, '{name}');
      }
    }

    final promptText = _instructionController.text.trim();
    final defaultTitle = promptText.isNotEmpty
        ? 'AI: ${promptText.length > 20 ? "${promptText.substring(0, 20)}..." : promptText}'
        : 'AI Follow-up';

    final newTemplate = await showDialog<WhatsAppTemplate>(
      context: context,
      builder: (_) => _TemplateEditorDialog(
        initialName: defaultTitle,
        initialMessage: templateMsg,
      ),
    );

    if (newTemplate != null && mounted) {
      final list = await widget.settingsStore.readWhatsAppTemplates();
      final updated = List<WhatsAppTemplate>.from(list)..add(newTemplate);
      await widget.settingsStore.saveWhatsAppTemplates(updated);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved "${newTemplate.name}" to WhatsApp Templates!'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
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
              const SizedBox(height: 18),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      color: Color(0xFF8B5CF6),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.isSms
                              ? 'Generate SMS with AI'
                              : 'Generate AI Message',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Personalized for ${widget.student.name}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // If API Key is missing, show Setup Card
              if (_apiKey.isEmpty) ...[
                Card(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.key_rounded,
                              color: Color(0xFF8B5CF6),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Gemini API Key Required',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'To generate personalized messages, paste your free Google Gemini API key below. You can get one in seconds from Google AI Studio without a credit card.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _openGoogleAiStudio,
                          icon: const Icon(Icons.open_in_new_rounded, size: 16),
                          label: const Text('Get Free Key (Google AI Studio)'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF8B5CF6),
                            side: const BorderSide(color: Color(0xFF8B5CF6)),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _apiKeyController,
                          obscureText: _obscureApiKey,
                          decoration: InputDecoration(
                            labelText: 'Paste Gemini API Key',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureApiKey
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () => setState(
                                () => _obscureApiKey = !_obscureApiKey,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            TextButton.icon(
                              onPressed: _pasteFromClipboard,
                              icon: const Icon(Icons.paste_rounded, size: 16),
                              label: const Text('Paste'),
                            ),
                            const Spacer(),
                            FilledButton(
                              onPressed: _saveApiKey,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF8B5CF6),
                              ),
                              child: const Text('Save & Generate'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                // Student Context Pill Card
                Card(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${widget.student.name} • ${widget.student.examType} ${widget.student.examYear}'.trim(),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                widget.student.callStatus,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (buildStudentHistoryEntries(widget.student).isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(
                                Icons.history_rounded,
                                size: 14,
                                color: Color(0xFF8B5CF6),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '${buildStudentHistoryEntries(widget.student).length} past interaction(s) analyzed by AI',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: const Color(0xFF8B5CF6),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Latest: "${buildStudentHistoryEntries(widget.student).last.text.isNotEmpty ? buildStudentHistoryEntries(widget.student).last.text : (widget.student.comment.isNotEmpty ? widget.student.comment : "No remark")}"',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ] else if (widget.student.comment.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            '💬 "${widget.student.comment.trim()}"',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(
                              Icons.business_rounded,
                              size: 13,
                              color: Color(0xFF8B5CF6),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                'On behalf of: ${_companySummary.isNotEmpty ? _companySummary : "LNBTI"}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Language selector
                Text(
                  'Language:',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: _languages.map((lang) {
                    final selected = _selectedLanguage == lang;
                    final displayLabel = lang == 'Sinhala' ? 'සිංහල' : lang;
                    return ChoiceChip(
                      label: Text(displayLabel),
                      selected: selected,
                      selectedColor: const Color(0xFF8B5CF6).withValues(alpha: 0.2),
                      labelStyle: TextStyle(
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected
                            ? const Color(0xFF8B5CF6)
                            : theme.colorScheme.onSurface,
                      ),
                      onSelected: (val) {
                        if (val) {
                          setState(() => _selectedLanguage = lang);
                          _generateMessage();
                        }
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),

                // What to generate input area
                Text(
                  'What should this message be about?',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _instructionController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: 'e.g. Follow up on missed call, give fees for A/L 2026 batch...',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Padding(
                      padding: EdgeInsets.only(bottom: 24),
                      child: Icon(Icons.edit_note_rounded),
                    ),
                    suffixIcon: _instructionController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () {
                              _instructionController.clear();
                              setState(() {});
                            },
                          )
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _generateMessage(),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _isGenerating ? null : _generateMessage,
                  icon: _isGenerating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: Text(_isGenerating ? 'Generating...' : 'Generate Message'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8B5CF6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),

                // Error Message if any
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],

                // Loading State or Editable Message
                if (_isGenerating) ...[
                  const SizedBox(height: 20),
                  const Center(
                    child: Column(
                      children: [
                        CircularProgressIndicator(
                          color: Color(0xFF8B5CF6),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Gemini is crafting a personalized message...',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ] else if (_messageController.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Generated Message (Editable):',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _messageController,
                    maxLines: 8,
                    minLines: 4,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isGenerating ? null : _generateMessage,
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text('Regenerate'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _saveAsTemplate,
                          icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                          label: const Text('Save Template'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        onPressed: _copyMessage,
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        tooltip: 'Copy text',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    onPressed: () =>
                        Navigator.pop(context, _messageController.text),
                    icon: widget.isSms
                        ? const Icon(Icons.sms_rounded, size: 18)
                        : const FaIcon(FontAwesomeIcons.whatsapp, size: 18),
                    label: Text(widget.isSms ? 'Send via SMS' : 'Send on WhatsApp'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.isSms
                          ? const Color(0xFF2E6FA3)
                          : const Color(0xFF25D366),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 2,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
