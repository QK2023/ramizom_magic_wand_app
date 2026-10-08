enum AiProvider { deepSeek, custom }

/// How much DeepSeek thinks before it answers.
enum ThinkingMode { none, low, high, max }

class AppSettings {
  const AppSettings({
    this.provider = AiProvider.deepSeek,
    this.apiKey = '',
    this.baseUrl = 'https://api.deepseek.com',
    this.model = 'deepseek-flash',
    this.thinking = ThinkingMode.none,
    this.speechVoice = 'zh-CN-XiaoxiaoNeural',
    this.speechRate = 1.0,
    this.sendScreen = true,
    this.speakReplies = false,
    this.annotations = true,
    this.learning = true,
    this.language = 'zh',
    this.theme = 'light',
    this.accentColor = 'graphite',
  });

  final AiProvider provider;
  final String apiKey;
  final String baseUrl;
  final String model;

  /// DeepSeek's thinking mode; other endpoints ignore it.
  final ThinkingMode thinking;

  /// The Microsoft Edge voice replies are read in (EdgeTts.voices).
  final String speechVoice;
  final double speechRate;
  final bool sendScreen;
  final bool speakReplies;

  /// Whether the assistant may offer to mark up a shared screen.
  final bool annotations;

  /// Whether lessons are noted down for later review.
  final bool learning;

  /// 'en' or 'zh'.
  final String language;
  final String theme;
  final String accentColor;

  AppSettings copyWith({
    AiProvider? provider,
    String? apiKey,
    String? baseUrl,
    String? model,
    ThinkingMode? thinking,
    String? speechVoice,
    double? speechRate,
    bool? sendScreen,
    bool? speakReplies,
    bool? annotations,
    bool? learning,
    String? language,
    String? theme,
    String? accentColor,
  }) {
    return AppSettings(
      provider: provider ?? this.provider,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      thinking: thinking ?? this.thinking,
      speechVoice: speechVoice ?? this.speechVoice,
      speechRate: speechRate ?? this.speechRate,
      sendScreen: sendScreen ?? this.sendScreen,
      speakReplies: speakReplies ?? this.speakReplies,
      annotations: annotations ?? this.annotations,
      learning: learning ?? this.learning,
      language: language ?? this.language,
      theme: theme ?? this.theme,
      accentColor: accentColor ?? this.accentColor,
    );
  }

  /// PDFs are sent in OpenRouter's file format, so only an OpenRouter
  /// endpoint receives them.
  bool get acceptsPdf => isOpenRouter;

  bool get isOpenRouter {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    return host == 'openrouter.ai' || host.endsWith('.openrouter.ai');
  }
}
