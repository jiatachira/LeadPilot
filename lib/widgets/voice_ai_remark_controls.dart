part of '../main.dart';

class VoiceAiRemarkControls extends StatefulWidget {
  const VoiceAiRemarkControls({
    super.key,
    required this.controller,
    this.settingsStore,
    this.geminiService,
    this.voiceToTextService,
    this.compact = false,
  });

  final TextEditingController controller;
  final AppSettingsStore? settingsStore;
  final GeminiService? geminiService;
  final VoiceToTextService? voiceToTextService;
  final bool compact;

  @override
  State<VoiceAiRemarkControls> createState() => _VoiceAiRemarkControlsState();
}

class _VoiceAiRemarkControlsState extends State<VoiceAiRemarkControls> {
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

  @override
  void dispose() {
    if (_isListeningVoice) {
      _voiceService.stop();
    }
    super.dispose();
  }

  Future<void> _toggleVoice() async {
    if (_isListeningVoice) {
      await _voiceService.stop();
      if (mounted) setState(() => _isListeningVoice = false);
      return;
    }

    _preVoiceText = widget.controller.text;
    setState(() => _isListeningVoice = true);

    final localeId = _voiceLanguage == 'si' ? 'si_LK' : 'en_US';

    await _voiceService.listen(
      localeId: localeId,
      onResult: (words) {
        if (!mounted || words.trim().isEmpty) return;
        setState(() {
          final prefix = _preVoiceText.trim();
          if (prefix.isEmpty) {
            widget.controller.text = words.trim();
          } else {
            widget.controller.text = '$prefix ${words.trim()}';
          }
          widget.controller.selection = TextSelection.fromPosition(
            TextPosition(offset: widget.controller.text.length),
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
    final rawRemark = widget.controller.text.trim();
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
    final groqApiKey = await _settingsStore.readGroqApiKey();
    final aiProvider = await _settingsStore.readAiProvider();
    final groqModel = await _settingsStore.readGroqModel();

    if (apiKey.trim().isEmpty && groqApiKey.trim().isEmpty) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.removeCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: const Text(
            'AI API key not configured. Please add your free Gemini or Groq key in Settings.',
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
    final originalText = widget.controller.text;

    try {
      final model = await _settingsStore.readGeminiModel();
      final polished = await _geminiService.polishRemark(
        apiKey: apiKey,
        rawRemark: rawRemark,
        model: model,
        provider: aiProvider,
        groqApiKey: groqApiKey,
        groqModel: groqModel,
      );

      if (!mounted) return;
      if (polished.isNotEmpty) {
        setState(() {
          widget.controller.text = polished;
          widget.controller.selection = TextSelection.fromPosition(
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
                  widget.controller.text = originalText;
                  widget.controller.selection = TextSelection.fromPosition(
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
    final theme = Theme.of(context);

    return Row(
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
                        style: theme.textTheme.labelSmall?.copyWith(
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
              : widget.compact
              ? const SizedBox.shrink()
              : Text(
                  'Draft in Sinhala, Singlish, or English',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                ),
        ),
        const SizedBox(width: 4),
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
              color: theme.colorScheme.surfaceContainerHighest,
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.language_rounded,
                  size: 13,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  _voiceLanguage == 'si' ? 'සිංහල' : 'English',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
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
    );
  }
}
