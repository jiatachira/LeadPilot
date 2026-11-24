part of '../main.dart';

class GeminiException implements Exception {
  const GeminiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GeminiModelInfo {
  const GeminiModelInfo({
    required this.id,
    required this.displayName,
    this.description = '',
  });

  final String id;
  final String displayName;
  final String description;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeminiModelInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class GeminiTestResult {
  const GeminiTestResult({
    required this.isSuccess,
    required this.message,
    this.modelName,
    this.statusCode,
    this.availableModels = const [],
  });

  final bool isSuccess;
  final String message;
  final String? modelName;
  final int? statusCode;
  final List<GeminiModelInfo> availableModels;
}

class GeminiService {
  GeminiService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static const List<String> candidateModels = [
    'gemini-1.5-flash',
    'gemini-2.0-flash',
    'gemini-1.5-flash-8b',
    'gemini-1.5-pro',
  ];

  static const List<String> candidateGroqModels = [
    'llama-3.3-70b-versatile',
    'llama-3.1-8b-instant',
    'mixtral-8x7b-32768',
    'gemma2-9b-it',
  ];

  static const List<GeminiModelInfo> defaultGroqModels = [
    GeminiModelInfo(
      id: 'llama-3.3-70b-versatile',
      displayName: 'Llama 3.3 70B (Recommended - Smart & Free)',
      description: 'Meta\'s top model with ultra-fast Groq LPU inference',
    ),
    GeminiModelInfo(
      id: 'llama-3.1-8b-instant',
      displayName: 'Llama 3.1 8B Instant (Ultra Fast)',
      description: 'Lightweight model with instantaneous response speed',
    ),
    GeminiModelInfo(
      id: 'mixtral-8x7b-32768',
      displayName: 'Mixtral 8x7B (MoE Architecture)',
      description: 'High context window with reliable structured generation',
    ),
    GeminiModelInfo(
      id: 'gemma2-9b-it',
      displayName: 'Gemma 2 9B (Google on Groq)',
      description: 'Google\'s Gemma 2 running on Groq hardware',
    ),
  ];

  static const List<GeminiModelInfo> defaultModels = [
    GeminiModelInfo(
      id: 'gemini-1.5-flash',
      displayName: 'Gemini 1.5 Flash (Recommended - 100% Free)',
      description: 'Fast, versatile, and generous free tier (1,500 requests/day)',
    ),
    GeminiModelInfo(
      id: 'gemini-2.0-flash',
      displayName: 'Gemini 2.0 Flash (Next-Gen Fast)',
      description: 'Ultra-fast next generation model',
    ),
    GeminiModelInfo(
      id: 'gemini-1.5-flash-8b',
      displayName: 'Gemini 1.5 Flash 8B (High Speed)',
      description: 'Lightweight model built for maximum throughput',
    ),
    GeminiModelInfo(
      id: 'gemini-1.5-pro',
      displayName: 'Gemini 1.5 Pro (Advanced Reasoning)',
      description: 'High capacity model for complex queries',
    ),
  ];

  static String sanitizeApiKey(String raw) {
    var key = raw.trim();
    while ((key.startsWith('"') && key.endsWith('"')) ||
        (key.startsWith("'") && key.endsWith("'")) ||
        (key.startsWith('`') && key.endsWith('`'))) {
      if (key.length <= 1) break;
      key = key.substring(1, key.length - 1).trim();
    }
    final urlMatch = RegExp(r'[?&]key=([a-zA-Z0-9_\-\.]+)').firstMatch(key);
    if (urlMatch != null) {
      key = urlMatch.group(1)!;
    } else if (key.startsWith('key=')) {
      key = key.substring(4);
    } else if (key.startsWith('apiKey=')) {
      key = key.substring(7);
    }
    return key.replaceAll(RegExp(r'\s+'), '');
  }

  static bool looksLikeGoogleApiKey(String key) {
    return (key.startsWith('AIza') || key.startsWith('AQ.')) && key.length >= 25;
  }

  Future<List<GeminiModelInfo>> fetchAvailableModels(String apiKey) async {
    final cleanKey = sanitizeApiKey(apiKey);
    if (cleanKey.isEmpty) return const [];

    for (final apiVersion in ['v1beta', 'v1']) {
      try {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/$apiVersion/models?key=$cleanKey',
        );
        final response = await _client.get(
          url,
          headers: {
            'Accept': 'application/json',
            'x-goog-api-key': cleanKey,
          },
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map && data['models'] is List) {
            final list = <GeminiModelInfo>[];
            for (final item in data['models'] as List) {
              if (item is Map) {
                final rawName = (item['name'] as String?) ?? '';
                final methods = (item['supportedGenerationMethods'] as List?)
                        ?.map((e) => e.toString())
                        .toList() ??
                    [];
                if (methods.isNotEmpty && !methods.contains('generateContent')) {
                  continue;
                }
                final id = rawName.startsWith('models/')
                    ? rawName.substring(7)
                    : rawName;
                if (id.isEmpty) continue;
                final displayName = (item['displayName'] as String?) ?? id;
                final description = (item['description'] as String?) ?? '';

                final lowerId = id.toLowerCase();
                final lowerDisplay = displayName.toLowerCase();
                final lowerDesc = description.toLowerCase();

                // Exclude models that do not produce standard text response
                if (lowerId.contains('embedding') ||
                    lowerId.contains('embed') ||
                    lowerId.contains('aqa') ||
                    lowerId.contains('text-bison') ||
                    lowerId.contains('chat-bison') ||
                    lowerId.contains('tts') ||
                    lowerId.contains('audio') ||
                    lowerId.contains('realtime') ||
                    lowerId.contains('imagen') ||
                    lowerId.contains('image') ||
                    lowerId.contains('vision') ||
                    lowerDesc.contains('audio') ||
                    lowerDesc.contains('speech') ||
                    lowerDisplay.contains('tts')) {
                  continue;
                }

                list.add(GeminiModelInfo(
                  id: id,
                  displayName: displayName,
                  description: description,
                ));
              }
            }
            if (list.isNotEmpty) {
              list.sort((a, b) {
                int score(String id) {
                  final lower = id.toLowerCase();
                  if (lower == 'gemini-1.5-flash') return 0;
                  if (lower == 'gemini-2.0-flash') return 1;
                  if (lower == 'gemini-1.5-flash-8b') return 2;
                  if (lower.contains('1.5-flash')) return 3;
                  if (lower.contains('2.0-flash')) return 4;
                  if (lower.contains('flash') &&
                      !lower.contains('preview') &&
                      !lower.contains('exp')) {
                    return 5;
                  }
                  if (lower.contains('flash')) return 6;
                  if (lower == 'gemini-1.5-pro') return 7;
                  if (lower.contains('pro')) return 8;
                  return 9;
                }

                final sA = score(a.id);
                final sB = score(b.id);
                if (sA != sB) return sA.compareTo(sB);
                return a.displayName.compareTo(b.displayName);
              });
              return list;
            }
          }
        }
      } catch (_) {}
    }
    return const [];
  }

  Future<String> _generateWithPrompt({
    required String apiKey,
    required String prompt,
    String? model,
    double temperature = 0.7,
    int maxOutputTokens = 500,
  }) async {
    final cleanKey = sanitizeApiKey(apiKey);
    if (cleanKey.isEmpty) {
      throw const GeminiException('Please configure a valid Gemini API Key in Settings.');
    }

    String? lastError;

    final modelsToTry = <String>[];
    if (model != null && model.trim().isNotEmpty) {
      modelsToTry.add(model.trim());
    }
    for (final m in candidateModels) {
      if (!modelsToTry.contains(m)) {
        modelsToTry.add(m);
      }
    }

    for (final targetModel in modelsToTry) {
      try {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$targetModel:generateContent?key=$cleanKey',
        );
        final response = await _client.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': cleanKey,
          },
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'temperature': temperature,
              'maxOutputTokens': maxOutputTokens,
            },
          }),
        ).timeout(const Duration(seconds: 25));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final candidates = data['candidates'] as List?;
          if (candidates != null && candidates.isNotEmpty) {
            final content = candidates.first['content'] as Map?;
            final parts = content?['parts'] as List?;
            if (parts != null && parts.isNotEmpty) {
              final text = parts.first['text'] as String?;
              if (text != null && text.trim().isNotEmpty) {
                return text.trim();
              }
            }
          }
          throw const GeminiException(
            'Gemini did not return any message content.',
          );
        }

        String rawApiMessage = '';
        String rawReason = '';
        try {
          final errJson = jsonDecode(response.body);
          if (errJson is Map && errJson['error'] is Map) {
            final err = errJson['error'] as Map;
            rawApiMessage = (err['message'] as String?) ?? '';
            final details = err['details'] as List?;
            if (details != null && details.isNotEmpty) {
              final first = details.first as Map?;
              rawReason = (first?['reason'] as String?) ?? '';
            }
          }
        } catch (_) {}

        final isModelIncompatible = response.statusCode == 404 ||
            (response.statusCode == 400 &&
                (rawApiMessage.toLowerCase().contains('modalities') ||
                    rawApiMessage.toLowerCase().contains('not supported by the model') ||
                    rawApiMessage.toLowerCase().contains('not found') ||
                    rawApiMessage.toLowerCase().contains('unsupported for generatecontent')));

        if (isModelIncompatible) {
          final isApiDisabled = rawApiMessage.contains('is not found for API version') ||
              rawApiMessage.contains('not supported for generateContent') ||
              rawApiMessage.contains('ListModels');
          if (isApiDisabled) {
            lastError =
                'Generative Language API is disabled on this Google project (404).\n\n'
                'Please open Google AI Studio (aistudio.google.com/app/apikey) and click "Create API key in new project" to get an active free key.';
          } else {
            lastError = rawApiMessage.isNotEmpty ? rawApiMessage : 'Model $targetModel not supported.';
          }
          continue;
        }

        if (rawReason == 'ACCESS_TOKEN_TYPE_UNSUPPORTED' ||
            (response.statusCode == 401 && rawApiMessage.contains('API key not valid'))) {
          throw const GeminiException(
            'Google rejected this API Key (ACCESS_TOKEN_TYPE_UNSUPPORTED).\n\n'
            'Please generate an unrestricted key from Google AI Studio:\n'
            '1. Go to aistudio.google.com/app/apikey\n'
            '2. Click "Create API Key" -> "Create API key in new project"\n'
            '3. Copy and paste the new key here.',
          );
        }

        if (response.statusCode == 400 &&
            (rawApiMessage.toLowerCase().contains('api key not valid') ||
                rawApiMessage.toLowerCase().contains('api_key_invalid'))) {
          throw const GeminiException(
            'Invalid API Key: Google rejected this key. Please check your Gemini API key in Settings.',
          );
        }

        if (rawApiMessage.isNotEmpty) {
          throw GeminiException('Gemini API (${response.statusCode}): $rawApiMessage');
        }

        throw GeminiException(
          'Gemini request failed (status ${response.statusCode}). Check your API key or network.',
        );
      } on SocketException {
        throw const GeminiException(
          'No internet connection. Please check your network connection.',
        );
      } on TimeoutException {
        throw const GeminiException(
          'Request timed out. Google servers took too long to respond.',
        );
      } catch (e) {
        if (e is GeminiException) rethrow;
        lastError = e.toString();
      }
    }

    throw GeminiException(
      lastError != null && lastError.isNotEmpty
          ? lastError
          : 'Could not connect to Gemini service. Please check your API key.',
    );
  }

  Future<String> generateWithGroq({
    required String apiKey,
    required String prompt,
    String? model,
    double temperature = 0.7,
    int maxTokens = 500,
  }) async {
    final cleanKey = sanitizeApiKey(apiKey);
    if (cleanKey.isEmpty) {
      throw const GeminiException(
        'Please configure a valid Groq API Key in Settings.',
      );
    }

    final targetModel = (model != null && model.trim().isNotEmpty)
        ? model.trim()
        : 'llama-3.3-70b-versatile';

    try {
      final url = Uri.parse('https://api.groq.com/openai/v1/chat/completions');
      final response = await _client.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $cleanKey',
        },
        body: jsonEncode({
          'model': targetModel,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'temperature': temperature,
          'max_tokens': maxTokens,
        }),
      ).timeout(const Duration(seconds: 25));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final choices = data['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final message = choices.first['message'] as Map?;
          final content = message?['content'] as String?;
          if (content != null && content.trim().isNotEmpty) {
            return content.trim();
          }
        }
        throw const GeminiException(
          'Groq did not return any message content.',
        );
      }

      String rawError = '';
      try {
        final errJson = jsonDecode(response.body);
        if (errJson is Map && errJson['error'] is Map) {
          rawError = (errJson['error']['message'] as String?) ?? '';
        }
      } catch (_) {}

      if (response.statusCode == 401) {
        throw const GeminiException(
          'Invalid Groq API Key. Please verify your key from console.groq.com/keys.',
        );
      }

      if (rawError.isNotEmpty) {
        throw GeminiException(
          'Groq API error (${response.statusCode}): $rawError',
        );
      }

      throw GeminiException(
        'Groq request failed with status ${response.statusCode}.',
      );
    } on SocketException {
      throw const GeminiException(
        'No internet connection. Please check your network connection.',
      );
    } on TimeoutException {
      throw const GeminiException(
        'Request timed out. Groq servers took too long to respond.',
      );
    } catch (e) {
      if (e is GeminiException) rethrow;
      throw GeminiException('Groq error: $e');
    }
  }

  Future<GeminiTestResult> testGroqConnection(
    String apiKey, {
    String? model,
  }) async {
    final cleanKey = sanitizeApiKey(apiKey);
    if (cleanKey.isEmpty) {
      return const GeminiTestResult(
        isSuccess: false,
        message: 'Groq API Key is empty. Please enter your key.',
        availableModels: defaultGroqModels,
      );
    }

    final targetModel = (model != null && model.trim().isNotEmpty)
        ? model.trim()
        : 'llama-3.3-70b-versatile';

    try {
      final res = await generateWithGroq(
        apiKey: cleanKey,
        prompt: 'Say "OK" to test API connection.',
        model: targetModel,
        maxTokens: 10,
      );
      if (res.isNotEmpty) {
        return GeminiTestResult(
          isSuccess: true,
          message:
              '✅ Connection successful!\nConnected to Groq Cloud ($targetModel).\nUltra-fast LPU inference is ready to use.',
          modelName: targetModel,
          statusCode: 200,
          availableModels: defaultGroqModels,
        );
      }
      return const GeminiTestResult(
        isSuccess: false,
        message: 'Groq returned an empty response.',
      );
    } catch (e) {
      return GeminiTestResult(
        isSuccess: false,
        message: '❌ Groq error: $e',
      );
    }
  }

  Future<String> _generateAiContent({
    String? apiKey,
    required String prompt,
    String? model,
    String? provider,
    String? groqApiKey,
    String? groqModel,
    double temperature = 0.7,
    int maxTokens = 500,
  }) async {
    final useGroq = provider == 'groq' ||
        (groqApiKey != null &&
            groqApiKey.trim().isNotEmpty &&
            (apiKey == null || apiKey.trim().isEmpty || provider != 'gemini'));

    if (useGroq && groqApiKey != null && groqApiKey.trim().isNotEmpty) {
      return generateWithGroq(
        apiKey: groqApiKey,
        prompt: prompt,
        model: groqModel,
        temperature: temperature,
        maxTokens: maxTokens,
      );
    }

    if (apiKey != null && apiKey.trim().isNotEmpty) {
      try {
        return await _generateWithPrompt(
          apiKey: apiKey,
          prompt: prompt,
          model: model,
          temperature: temperature,
          maxOutputTokens: maxTokens,
        );
      } catch (geminiError) {
        // Fallback to Groq if Groq key is present
        if (groqApiKey != null && groqApiKey.trim().isNotEmpty) {
          try {
            return await generateWithGroq(
              apiKey: groqApiKey,
              prompt: prompt,
              model: groqModel,
              temperature: temperature,
              maxTokens: maxTokens,
            );
          } catch (_) {}
        }
        rethrow;
      }
    }

    if (groqApiKey != null && groqApiKey.trim().isNotEmpty) {
      return generateWithGroq(
        apiKey: groqApiKey,
        prompt: prompt,
        model: groqModel,
        temperature: temperature,
        maxTokens: maxTokens,
      );
    }

    throw const GeminiException(
      'Please configure an AI API Key (Gemini or Groq) in Settings.',
    );
  }

  Future<String> generateFollowUp({
    required String apiKey,
    required Student student,
    String? model,
    String language = 'Sinhala',
    String tone = 'General Follow-up',
    String customInstructions = '',
    String? companyDescription,
    String? provider,
    String? groqApiKey,
    String? groqModel,
  }) async {
    final prompt = _buildPrompt(
      student: student,
      language: language,
      tone: tone,
      customInstructions: customInstructions,
      companyDescription: companyDescription,
    );

    return _generateAiContent(
      apiKey: apiKey,
      prompt: prompt,
      model: model,
      provider: provider,
      groqApiKey: groqApiKey,
      groqModel: groqModel,
      temperature: 0.7,
      maxTokens: 500,
    );
  }

  Future<String> polishRemark({
    required String apiKey,
    required String rawRemark,
    String? model,
    String? provider,
    String? groqApiKey,
    String? groqModel,
  }) async {
    final cleanRemark = rawRemark.trim();
    if (cleanRemark.isEmpty) {
      return '';
    }

    final prompt = '''
You are an expert CRM assistant for an educational institute (LNBTI).
A call agent wrote a rough or broken call remark about a student lead.
The agent's input may be in broken English, shorthand notes, or Singlish/Sinhala.

Raw remark from agent:
"$cleanRemark"

TASK:
Rewrite and polish this raw remark into a concise, professional CRM call remark in proper English.

CRITICAL RULES:
1. FACTUAL ACCURACY: Keep the exact meaning, dates, times, next steps, degree interests, and student situation intact. Do NOT invent new facts.
2. GRAMMAR & CLARITY: Correct all grammatical, spelling, capitalization, and phrasing issues.
3. CONCISENESS: Keep it brief and objective (1 to 2 clear sentences max).
4. OUTPUT FORMAT: Return ONLY the polished English remark text. Do not include quotes around the whole text, prefixes like "Polished Remark:", markdown code blocks, or explanations.
''';

    return _generateAiContent(
      apiKey: apiKey,
      prompt: prompt,
      model: model,
      provider: provider,
      groqApiKey: groqApiKey,
      groqModel: groqModel,
      temperature: 0.3,
      maxTokens: 200,
    );
  }

  Future<GeminiTestResult> testConnection(
    String apiKey, {
    String? targetModel,
  }) async {
    final cleanKey = sanitizeApiKey(apiKey);
    if (cleanKey.isEmpty) {
      return const GeminiTestResult(
        isSuccess: false,
        message: 'API Key is empty. Please enter your Gemini API key.',
        availableModels: defaultModels,
      );
    }

    // 1. Discover models accessible to this API key
    List<GeminiModelInfo> fetchedModels = [];
    try {
      fetchedModels = await fetchAvailableModels(cleanKey);
    } catch (_) {}

    final availableList = fetchedModels.isNotEmpty ? fetchedModels : defaultModels;

    final modelsToPing = <String>[];
    if (targetModel != null && targetModel.trim().isNotEmpty) {
      modelsToPing.add(targetModel.trim());
    }
    for (final m in availableList) {
      if (!modelsToPing.contains(m.id)) {
        modelsToPing.add(m.id);
      }
    }
    for (final m in candidateModels) {
      if (!modelsToPing.contains(m)) {
        modelsToPing.add(m);
      }
    }

    String? lastErrorMessage;
    int? lastStatusCode;

    for (final model in modelsToPing) {
      try {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$cleanKey',
        );
        final response = await _client.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': cleanKey,
          },
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': 'Ping'}
                ]
              }
            ],
            'generationConfig': {
              'maxOutputTokens': 5,
            },
          }),
        ).timeout(const Duration(seconds: 15));

        lastStatusCode = response.statusCode;

        if (response.statusCode == 200) {
          final matchedName = availableList
                  .where((m) => m.id == model)
                  .firstOrNull
                  ?.displayName ??
              model;
          final modelsCountNote = fetchedModels.isNotEmpty
              ? '\nFound ${fetchedModels.length} models supported by your API key.'
              : '';
          return GeminiTestResult(
            isSuccess: true,
            modelName: model,
            availableModels: availableList,
            statusCode: 200,
            message:
                '✅ Connection successful!\nConnected to Google Gemini ($matchedName).$modelsCountNote\nAI messaging is ready to use.',
          );
        }

        String rawApiMessage = '';
        String rawReason = '';
        try {
          final bodyJson = jsonDecode(response.body);
          if (bodyJson is Map && bodyJson['error'] is Map) {
            final err = bodyJson['error'] as Map;
            rawApiMessage = (err['message'] as String?) ?? '';
            final details = err['details'] as List?;
            if (details != null && details.isNotEmpty) {
              final first = details.first as Map?;
              rawReason = (first?['reason'] as String?) ?? '';
            }
          }
        } catch (_) {}

        final isModelIncompatible = response.statusCode == 404 ||
            (response.statusCode == 400 &&
                (rawApiMessage.toLowerCase().contains('modalities') ||
                    rawApiMessage.toLowerCase().contains('not supported by the model') ||
                    rawApiMessage.toLowerCase().contains('not found') ||
                    rawApiMessage.toLowerCase().contains('unsupported for generatecontent')));

        if (isModelIncompatible) {
          lastErrorMessage = rawApiMessage.isNotEmpty ? rawApiMessage : 'Model $model not supported.';
          continue;
        }

        final isUnsupportedToken = rawReason == 'ACCESS_TOKEN_TYPE_UNSUPPORTED' ||
            (response.statusCode == 401 && rawApiMessage.toLowerCase().contains('unsupported'));

        final isInvalidKey = response.statusCode == 401 ||
            (response.statusCode == 400 &&
                (rawApiMessage.toLowerCase().contains('api key not valid') ||
                    rawApiMessage.toLowerCase().contains('api_key_invalid') ||
                    rawApiMessage.toLowerCase().contains('invalid api key')));

        final isLocationBlocked = rawApiMessage
            .toLowerCase()
            .contains('user location is not supported');
        final isQuotaExhausted = response.statusCode == 429 ||
            rawApiMessage.toLowerCase().contains('resource has been exhausted');

        final buffer = StringBuffer();
        if (isUnsupportedToken) {
          buffer.writeln('❌ Google API Error: ACCESS_TOKEN_TYPE_UNSUPPORTED (401)');
          buffer.writeln();
          buffer.writeln(
            'Google rejected this key because of project API restrictions in Google Cloud / AI Studio.',
          );
          buffer.writeln();
          buffer.writeln('💡 Quick Fix (in 1 minute):');
          buffer.writeln('1. Open Google AI Studio (aistudio.google.com/app/apikey)');
          buffer.writeln('2. Click "Create API Key"');
          buffer.writeln('3. Select "Create API key in new project" (Do not restrict to "Gemini API")');
          buffer.writeln('4. Copy the new key and paste it here.');
        } else if (isInvalidKey) {
          buffer.writeln('❌ Google rejected this API key (Invalid API Key).');
          buffer.writeln();
          if (!looksLikeGoogleApiKey(cleanKey)) {
            buffer.writeln(
              '⚠️ Key format warning: Google Gemini API keys usually start with "AIzaSy..." or "AQ." (~33–39 characters). Make sure you copied the API Key, not the Google Cloud Project ID or Name.',
            );
            buffer.writeln();
          }
          buffer.writeln(
            '• Newly created keys in Google AI Studio often take 30–60 seconds to activate worldwide across Google servers. If you just created it, please wait ~30 seconds and test again.',
          );
          buffer.writeln('• Ensure you copied the entire key without extra text.');
        } else if (isLocationBlocked) {
          buffer.writeln(
            '❌ Region Not Supported: Google Gemini API is currently not available from your IP/region without VPN.',
          );
        } else if (isQuotaExhausted) {
          buffer.writeln(
            '❌ Quota Exceeded (429): Google AI Studio free rate limit reached. Please wait a minute and try again.',
          );
        } else {
          buffer.writeln('❌ Google API Error (Status ${response.statusCode}):');
          if (rawApiMessage.isNotEmpty) {
            buffer.writeln(rawApiMessage);
          } else {
            buffer.writeln('Connection rejected by server.');
          }
        }

        return GeminiTestResult(
          isSuccess: false,
          statusCode: response.statusCode,
          availableModels: availableList,
          message: buffer.toString().trim(),
        );
      } on SocketException {
        return GeminiTestResult(
          isSuccess: false,
          availableModels: availableList,
          message:
              '❌ No internet connection. Could not reach Google servers. Please check your Wi-Fi or mobile data.',
        );
      } on TimeoutException {
        return GeminiTestResult(
          isSuccess: false,
          availableModels: availableList,
          message:
              '❌ Connection timed out. Google servers took too long to respond. Please check your network.',
        );
      } on HandshakeException {
        return GeminiTestResult(
          isSuccess: false,
          availableModels: availableList,
          message:
              '❌ SSL/TLS handshake failed with Google servers. Please verify device date and time.',
        );
      } catch (e) {
        return GeminiTestResult(
          isSuccess: false,
          availableModels: availableList,
          message: '❌ Unexpected error testing connection: $e',
        );
      }
    }

    final isProjectDisabled = lastStatusCode == 404 &&
        (lastErrorMessage?.contains('is not found for API version') == true ||
            lastErrorMessage?.contains('not supported for generateContent') == true ||
            lastErrorMessage?.contains('ListModels') == true);

    if (isProjectDisabled) {
      return GeminiTestResult(
        isSuccess: false,
        statusCode: 404,
        availableModels: availableList,
        message:
            '❌ Google Error: Generative Language API is disabled for this project (404).\n\n'
            'This API key belongs to a Google Cloud project where the Generative Language API has not been activated.\n\n'
            '💡 Simple 30-Second Fix:\n'
            '1. Open Google AI Studio (aistudio.google.com/app/apikey)\n'
            '2. Click the blue "Create API key" button\n'
            '3. Choose "Create API key in new project" (Do NOT choose your existing project)\n'
            '4. Copy the new key and paste it here.',
      );
    }

    return GeminiTestResult(
      isSuccess: false,
      statusCode: lastStatusCode,
      availableModels: availableList,
      message:
          '❌ Could not connect to Gemini models.\n${lastErrorMessage ?? "Please verify your key in Google AI Studio."}\n\n💡 Tip: In Google AI Studio (aistudio.google.com/app/apikey), click "Create API key in new project" to get a clean unrestricted key for Gemini 1.5 Flash.',
    );
  }

  String _buildPrompt({
    required Student student,
    required String language,
    String tone = 'General Follow-up',
    String customInstructions = '',
    String? companyDescription,
  }) {
    final instituteInfo = (companyDescription != null && companyDescription.trim().isNotEmpty)
        ? companyDescription.trim()
        : _defaultCompanyDescription;
    final streak = studentActivityStatus(student).unansweredStreak;
    final streakNote = streak >= 2
        ? ' ($streak x consecutive unanswered attempts)'
        : '';
    final lastNote = student.comment.trim().isNotEmpty
        ? student.comment.trim()
        : (student.commentHistory.isNotEmpty
            ? student.commentHistory.last.trim()
            : 'No call comment yet');
    final examDetails = [student.examType, student.examYear]
        .where((s) => s.trim().isNotEmpty)
        .join(' ');
    final historySummary = formatStudentHistoryForPrompt(student);

    final goalText = customInstructions.trim().isNotEmpty
        ? customInstructions.trim()
        : tone;

    return '''
You are writing a WhatsApp / SMS follow-up message to a student lead on behalf of LNBTI ($instituteInfo).
Act as a warm, approachable, and respectful student advisor / counselor from LNBTI.

Target Student Details:
- Student Name: ${student.name}
- Stream/Class: ${examDetails.isNotEmpty ? examDetails : 'General Course'}
- Current Call Status: ${student.callStatus}$streakNote
- Recent Call Note/Comment: "$lastNote"
- Location/Town: ${student.location.isNotEmpty ? student.location : 'Not specified'}
- Scheduled Next Call: ${student.nextCallDateTime.isNotEmpty ? student.nextCallDateTime : 'None scheduled'}
- Purpose of message: "$goalText"
- Desired Language: $language

Complete Call & Interaction History (Chronological):
$historySummary

CRITICAL GUIDELINES:
1. USE OF COMPLETE CALL HISTORY (DEEP CONTEXTUAL AWARENESS):
   - You MUST carefully read and understand the entire call history above to determine the context of this follow-up.
   - Tailor the message to reflect past interactions accurately:
     * If previous remarks mention specific inquiries (e.g. degree programs, Software Engineering / IT, course fees, Japanese language classes, scholarships, intake dates, or A/L results), naturally reference or address that topic.
     * If the student previously asked for a callback, more time, or details to be sent, follow up warmly on that exact request.
     * If there were multiple missed calls / no-answer attempts, politely mention that you tried calling earlier and want to check in gently without guilt-tripping or being pushy.
     * Do NOT invent details that are not in the history, and do NOT recite the history like a robotic log. Weave the context naturally into a genuine human counselor message.

2. TONE & MANNER (POLITE, RESPECTFUL & APPROACHABLE):
   - Maintain a warm, friendly, and respectful student counseling tone.
   - Balance natural conversational warmth with polite respect. Do NOT be overly stiff/robotic, and do NOT be overly casual/slangy.
   - STRICTLY FORBIDDEN PHRASES:
     * NO archaic or stiff corporate speech (e.g. "ගරු ශිෂ්‍යතුමනි/ශිෂ්‍යාවනි", "මහතාණෙනි", "අප ආයතනය මඟින් දන්වා සිටින්නේ", "Dear Sir/Madam", "Respected Student").
     * NO overly casual buddy slang (strictly FORBIDDEN: "හොඳේ", "hode", "honde", "මචං", "machan", "හරිද", "harida", "onna"). Messages are sent to prospective students and must maintain courteous respect.
   - Start with a natural, polite greeting using their name (e.g., "හායි ${student.name}!", "කොහොමද ${student.name}?", "Hi ${student.name}! 👋").

3. SENDER IDENTITY (LNBTI):
   - Naturally mention LNBTI as an advisor would refer to their campus/team (e.g. "මම LNBTI එකෙන් කතා කරේ / මැසේජ් එකක් දැම්මේ", "LNBTI campus එකෙන්", "just checking in from LNBTI").

4. CONCISENESS (DO NOT OVER-DETAIL):
   - Keep it short, genuine, and light (2 to 3 sentences max).
   - Do NOT dump long course descriptions or heavy marketing text. Get straight to the point politely and leave room for them to reply easily.

5. LANGUAGE & PHRASING:
   - If Language is "Sinhala": Use natural, polite conversational Sinhala (e.g. "පුළුවන් වෙලාවක මැසේජ් එකක් දාන්න හෝ කතා කරන්න", "විස්තර දැනගන්න ඕන නම් අහන්න", "කෝල් එකක් ගන්න බැලුවේ සම්බන්ධ කරගන්න බැරි වුණා"). Strictly do NOT use "හොඳේ".
   - If Language is "Singlish": Use clean, polite conversational Singlish (e.g. "Hi ${student.name}! kohomada? Mama LNBTI eken message kale. Call ekak ganna baluwe connect karaganna bari una. Puluwan welawaka message ekak danna hari call ekak denna 👍"). Strictly do NOT use "hode".
   - If Language is "English": Use warm, polite conversational English (e.g. "Hi ${student.name}! Hope you are doing well. Just checking in from LNBTI. Tried calling you earlier, but couldn't reach you. Please let me know when you're free! 😊").

6. EMOJIS & FORMATTING:
   - Add 1-2 friendly, tasteful emojis (e.g. 👋, 😊, 👍).
   - Return ONLY the final ready-to-send text message. Do not include quotes, markdown code blocks, or introductory explanations.
''';
  }
}

