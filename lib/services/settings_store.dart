import 'dart:ui';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/model_catalog.dart';
import 'edge_tts.dart';

class SettingsStore {
  static const _secure = FlutterSecureStorage();

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final defaults = const AppSettings();
    final provider = storedProvider(
      prefs.getString('provider_id'),
      prefs.getInt('provider'),
    );
    final language = prefs.getString('language');
    return ModelCatalog.normalize(
      defaults.copyWith(
        provider: provider,
        apiKey: await _secure.read(key: 'ai_api_key') ?? '',
        baseUrl: prefs.getString('base_url') ?? defaults.baseUrl,
        model: prefs.getString('model') ?? defaults.model,
        thinking: ThinkingMode.values.asNameMap()[prefs.getString('thinking')],
        // Voices from before (or an API's voice name) fall back to the
        // default Edge voice.
        speechVoice:
            EdgeTts.voices.any((v) => v.id == prefs.getString('speech_voice'))
            ? prefs.getString('speech_voice')
            : defaults.speechVoice,
        speechRate: prefs.getDouble('speech_rate') ?? defaults.speechRate,
        sendScreen: prefs.getBool('send_screen') ?? defaults.sendScreen,
        speakReplies: prefs.getBool('speak_replies') ?? defaults.speakReplies,
        annotations: prefs.getBool('annotations') ?? defaults.annotations,
        learning: prefs.getBool('learning') ?? defaults.learning,
        language: language == null
            ? systemLanguage()
            : storedLanguage(language),
        theme: prefs.getString('theme') ?? defaults.theme,
        accentColor: prefs.getString('accent_color') ?? defaults.accentColor,
      ),
    );
  }

  /// The saved provider. Earlier versions stored an index into
  /// [OpenRouter, DeepSeek, custom, Gemini]; OpenRouter and Gemini became
  /// custom endpoints, keeping their saved URL, model and key.
  static AiProvider storedProvider(String? name, int? legacyIndex) {
    final named = AiProvider.values.asNameMap()[name];
    if (named != null) return named;
    if (legacyIndex == null) return const AppSettings().provider;
    return legacyIndex == 1 ? AiProvider.deepSeek : AiProvider.custom;
  }

  /// Languages saved by earlier versions (zh-CN, zh-TW, es, fr) map onto
  /// the two the app now offers.
  static String storedLanguage(String value) =>
      value.startsWith('zh') ? 'zh' : 'en';

  /// First-run language follows Windows when it is one of the app's locales.
  static String systemLanguage([Locale? locale]) {
    final system = locale ?? PlatformDispatcher.instance.locale;
    return switch (system.languageCode) {
      'zh' => 'zh',
      'en' => 'en',
      _ => 'en',
    };
  }

  Future<void> save(AppSettings value) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      _secure.write(key: 'ai_api_key', value: value.apiKey),
      _secure.delete(key: 'speech_api_key'),
      _secure.delete(key: 'azure_speech_key'),
      prefs.setString('provider_id', value.provider.name),
      prefs.remove('provider'),
      prefs.setString('thinking', value.thinking.name),
      prefs.setString('base_url', value.baseUrl),
      prefs.setString('model', value.model),
      // The built-in voices are gone; their choice goes with them.
      prefs.remove('voice'),
      for (final old in ['speech_base_url', 'speech_model', 'speech_format'])
        prefs.remove(old),
      prefs.setString('speech_voice', value.speechVoice),
      prefs.setDouble('speech_rate', value.speechRate),
      prefs.setBool('send_screen', value.sendScreen),
      prefs.setBool('speak_replies', value.speakReplies),
      prefs.setBool('annotations', value.annotations),
      prefs.setBool('learning', value.learning),
      prefs.setString('language', value.language),
      prefs.setString('theme', value.theme),
      prefs.setString('accent_color', value.accentColor),
    ]);
  }
}
