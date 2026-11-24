part of '../main.dart';

class DefaultVoiceToTextService implements VoiceToTextService {
  DefaultVoiceToTextService({stt.SpeechToText? speech})
      : _speech = speech ?? stt.SpeechToText();

  final stt.SpeechToText _speech;
  bool _initialized = false;
  void Function(String status)? _activeOnStatus;
  void Function(String error)? _activeOnError;

  @override
  bool get isAvailable => _speech.isAvailable;

  @override
  bool get isListening => _speech.isListening;

  @override
  Future<bool> initialize() async {
    if (_initialized && _speech.isAvailable) return true;
    try {
      _initialized = await _speech.initialize(
        onError: (err) {
          debugPrint('SpeechToText error: ${err.errorMsg}');
          _activeOnError?.call(err.errorMsg);
        },
        onStatus: (status) {
          debugPrint('SpeechToText status: $status');
          _activeOnStatus?.call(status);
        },
        debugLogging: false,
      );
      return _initialized;
    } catch (e) {
      debugPrint('SpeechToText init exception: $e');
      return false;
    }
  }

  @override
  Future<void> listen({
    required void Function(String recognizedWords) onResult,
    void Function(String status)? onStatus,
    void Function(String error)? onError,
    String? localeId,
  }) async {
    _activeOnStatus = onStatus;
    _activeOnError = onError;

    final available = await initialize();
    if (!available) {
      onError?.call(
        'Microphone permission or speech recognition is not available.',
      );
      return;
    }

    String effectiveLocale = localeId ?? 'si_LK';

    // Match exact device locale (e.g. si_LK or si-LK, en_US or en-US)
    try {
      final locales = await _speech.locales();
      final prefix = effectiveLocale.split(RegExp('[-_]')).first.toLowerCase();
      final match = locales.firstWhere(
        (l) => l.localeId.toLowerCase().startsWith(prefix),
        orElse: () => stt.LocaleName(effectiveLocale, effectiveLocale),
      );
      effectiveLocale = match.localeId;
    } catch (_) {}

    try {
      await _speech.listen(
        onResult: (result) {
          if (result.recognizedWords.isNotEmpty) {
            onResult(result.recognizedWords);
          }
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 4),
          localeId: effectiveLocale,
          onDevice: false,
        ),
      );
    } catch (e) {
      onError?.call(e.toString());
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    try {
      await _speech.cancel();
    } catch (_) {}
  }
}

