part of '../../main.dart';

class ManageGeminiAiSheet extends StatefulWidget {
  const ManageGeminiAiSheet({
    super.key,
    required this.settingsStore,
    this.geminiService,
  });

  final AppSettingsStore settingsStore;
  final GeminiService? geminiService;

  @override
  State<ManageGeminiAiSheet> createState() => _ManageGeminiAiSheetState();
}

class _ManageGeminiAiSheetState extends State<ManageGeminiAiSheet> {
  late final TextEditingController _controller;
  late final TextEditingController _companyController;
  late final GeminiService _geminiService;
  bool _obscure = true;
  bool _isTesting = false;
  String? _testResult;
  bool _isSuccess = false;
  final List<GeminiModelInfo> _availableModels = List.of(GeminiService.defaultModels);
  String _selectedModel = 'gemini-1.5-flash';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _companyController = TextEditingController();
    _geminiService = widget.geminiService ?? GeminiService();
    _loadKeyAndModel();
  }

  Future<void> _loadKeyAndModel() async {
    final key = await widget.settingsStore.readGeminiApiKey();
    final model = await widget.settingsStore.readGeminiModel();
    final company = await widget.settingsStore.readCompanyDescription();
    if (mounted) {
      setState(() {
        _controller.text = key;
        _companyController.text = company;
        _selectedModel = model.isNotEmpty ? model : 'gemini-1.5-flash';
      });
      if (key.isNotEmpty) {
        _fetchModelsQuietly(key);
      }
    }
  }

  Future<void> _fetchModelsQuietly(String key) async {
    try {
      final models = await _geminiService.fetchAvailableModels(key);
      if (models.isNotEmpty && mounted) {
        setState(() {
          final existingIds = _availableModels.map((m) => m.id).toSet();
          for (final m in models) {
            if (!existingIds.contains(m.id)) {
              _availableModels.add(m);
            }
          }
          if (!_availableModels.any((m) => m.id == _selectedModel)) {
            _selectedModel = _availableModels.first.id;
          }
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _controller.dispose();
    _companyController.dispose();
    super.dispose();
  }

  Future<void> _saveKey() async {
    final cleanKey = GeminiService.sanitizeApiKey(_controller.text);
    _controller.text = cleanKey;
    await widget.settingsStore.saveGeminiApiKey(cleanKey);
    await widget.settingsStore.saveGeminiModel(_selectedModel);
    await widget.settingsStore.saveCompanyDescription(_companyController.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cleanKey.isNotEmpty
              ? 'Gemini API Key, Model ($_selectedModel), and Company Description saved!'
              : 'Gemini settings saved.',
        ),
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _testConnection() async {
    final rawKey = _controller.text;
    final cleanKey = GeminiService.sanitizeApiKey(rawKey);
    if (cleanKey != rawKey) {
      _controller.text = cleanKey;
    }

    if (cleanKey.isEmpty) {
      setState(() {
        _testResult = 'Please enter an API Key to test.';
        _isSuccess = false;
      });
      return;
    }
    setState(() {
      _isTesting = true;
      _testResult = null;
    });

    final result = await _geminiService.testConnection(
      cleanKey,
      targetModel: _selectedModel,
    );
    if (!mounted) return;
    setState(() {
      _isTesting = false;
      _isSuccess = result.isSuccess;
      _testResult = result.message;
      if (result.availableModels.isNotEmpty) {
        final existingIds = _availableModels.map((m) => m.id).toSet();
        for (final m in result.availableModels) {
          if (!existingIds.contains(m.id)) {
            _availableModels.add(m);
          }
        }
        if (result.isSuccess && result.modelName != null) {
          _selectedModel = result.modelName!;
        } else if (!_availableModels.any((m) => m.id == _selectedModel)) {
          _selectedModel = _availableModels.first.id;
        }
      }
    });
  }

  Future<void> _openGoogleAiStudio() async {
    final uri = Uri.parse('https://aistudio.google.com/app/apikey');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    final clean = GeminiService.sanitizeApiKey(text);
    if (clean.isNotEmpty) {
      setState(() => _controller.text = clean);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasKey = _controller.text.trim().isNotEmpty;

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
                          'Gemini AI Assistant',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Connect your free Google Gemini API key',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            hasKey
                                ? Icons.check_circle_rounded
                                : Icons.info_outline_rounded,
                            color: hasKey
                                ? const Color(0xFF159A76)
                                : const Color(0xFF8B5CF6),
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            hasKey ? 'API Key Configured' : '100% Free API Access',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: hasKey
                                  ? const Color(0xFF159A76)
                                  : const Color(0xFF8B5CF6),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Google AI Studio offers 1,500 requests per day for Gemini 1.5 Flash completely free (no credit card required). You can create an API key in under 1 minute.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _openGoogleAiStudio,
                        icon: const Icon(Icons.open_in_new_rounded, size: 16),
                        label: const Text('Get Free Key (Google AI Studio)'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF8B5CF6),
                          side: const BorderSide(color: Color(0xFF8B5CF6)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Gemini API Key',
                  hintText: 'Paste key (starts with AIzaSy...)',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '💡 Gemini API keys start with "AIzaSy..." or "AQ." (100% Free on Gemini 1.5 Flash). Newly created keys can take 30–60s to activate.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.paste_rounded, size: 16),
                    label: const Text('Paste from clipboard'),
                  ),
                  const Spacer(),
                  if (_controller.text.trim().isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() => _controller.clear()),
                      child: const Text('Clear'),
                    ),
                ],
              ),
              if (_availableModels.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey('$_selectedModel-${_availableModels.length}'),
                  initialValue: _availableModels.any((m) => m.id == _selectedModel)
                      ? _selectedModel
                      : _availableModels.first.id,
                  decoration: const InputDecoration(
                    labelText: 'Selected Gemini Model',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.psychology_rounded),
                  ),
                  isExpanded: true,
                  items: _availableModels.map((info) {
                    final isFree = info.id.contains('flash');
                    return DropdownMenuItem<String>(
                      value: info.id,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              info.displayName,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (isFree)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF159A76).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'FREE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF159A76),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (newModel) {
                    if (newModel != null) {
                      setState(() => _selectedModel = newModel);
                    }
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  '⚡ ${_availableModels.length} models accessible to this key. Select your preferred model.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: _companyController,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: 'Description about your company',
                  hintText: 'e.g. LNBTI (Lanka Nippon BizTech Institute)...',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Padding(
                    padding: EdgeInsets.only(bottom: 24),
                    child: Icon(Icons.business_rounded),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.restart_alt_rounded, size: 20),
                    tooltip: 'Reset to LNBTI default',
                    onPressed: () {
                      setState(() {
                        _companyController.text = _defaultCompanyDescription;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '🏢 AI uses this company description to represent LNBTI politely without overloading the message with excessive details.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
              if (_testResult != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _isSuccess
                        ? const Color(0xFF159A76).withValues(alpha: 0.12)
                        : theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isSuccess
                          ? const Color(0xFF159A76).withValues(alpha: 0.3)
                          : theme.colorScheme.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: SelectableText(
                    _testResult!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _isSuccess
                          ? const Color(0xFF159A76)
                          : theme.colorScheme.error,
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isTesting ? null : _testConnection,
                      icon: _isTesting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bolt_rounded, size: 18),
                      label: Text(_isTesting ? 'Testing...' : 'Test Key'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saveKey,
                      icon: const Icon(Icons.save_rounded, size: 18),
                      label: const Text('Save Key'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6),
                        foregroundColor: Colors.white,
                      ),
                    ),
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

