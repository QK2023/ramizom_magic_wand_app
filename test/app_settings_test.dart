import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramizom_magic_wand/l10n/app_strings.dart';
import 'package:ramizom_magic_wand/models/app_settings.dart';
import 'package:ramizom_magic_wand/models/model_catalog.dart';
import 'package:ramizom_magic_wand/services/ai_service.dart';
import 'package:ramizom_magic_wand/services/settings_store.dart';
import 'package:ramizom_magic_wand/services/edge_tts.dart';
import 'package:ramizom_magic_wand/services/speech_service.dart';

void main() {
  test('ships with DeepSeek, its vision model and thinking off', () {
    const settings = AppSettings();

    expect(settings.provider, AiProvider.deepSeek);
    expect(settings.baseUrl, ModelCatalog.deepSeek.baseUrl);
    expect(settings.model, ModelCatalog.deepSeek.defaultModel.id);
    expect(settings.thinking, ThinkingMode.none);
    expect(settings.sendScreen, isTrue);
    expect(settings.speakReplies, isFalse);
    expect(ModelCatalog.providers, [AiProvider.deepSeek, AiProvider.custom]);
    expect(AiService.validBaseUrl(ModelCatalog.deepSeek.baseUrl), isTrue);
  });

  test('providers saved by earlier versions keep working', () {
    // Earlier versions stored [OpenRouter, DeepSeek, custom, Gemini] indexes;
    // OpenRouter and Gemini continue as custom endpoints.
    expect(SettingsStore.storedProvider(null, null), AiProvider.deepSeek);
    expect(SettingsStore.storedProvider(null, 0), AiProvider.custom);
    expect(SettingsStore.storedProvider(null, 1), AiProvider.deepSeek);
    expect(SettingsStore.storedProvider(null, 2), AiProvider.custom);
    expect(SettingsStore.storedProvider(null, 3), AiProvider.custom);
    expect(SettingsStore.storedProvider('custom', 1), AiProvider.custom);
    expect(SettingsStore.storedProvider('gone', null), AiProvider.deepSeek);
  });

  test('saved settings move to current endpoints and models', () {
    final deepSeek = ModelCatalog.normalize(
      const AppSettings(
        provider: AiProvider.deepSeek,
        baseUrl: 'https://api.deepseek.com/v1',
        model: 'deepseek-chat',
        sendScreen: false,
      ),
    );
    expect(deepSeek.baseUrl, ModelCatalog.deepSeek.baseUrl);
    expect(deepSeek.model, 'deepseek-flash');
    expect(deepSeek.sendScreen, isTrue);
    final pro = ModelCatalog.normalize(
      const AppSettings(model: 'deepseek-v4-pro'),
    );
    expect(pro.sendScreen, isFalse);
    // Custom endpoints are never rewritten.
    const custom = AppSettings(
      provider: AiProvider.custom,
      baseUrl: 'https://openrouter.ai/api/v1',
      model: 'google/gemini-3.8-flash',
    );
    expect(ModelCatalog.normalize(custom).model, custom.model);
    expect(ModelCatalog.normalize(custom).baseUrl, custom.baseUrl);
    // PDFs go only where OpenRouter's file format is understood.
    expect(custom.acceptsPdf, isTrue);
    expect(const AppSettings().acceptsPdf, isFalse);
  });

  test('DeepSeek thinking follows the setting; other APIs get nothing', () {
    expect(AiService.thinkingOptions(const AppSettings()), {
      'thinking': {'type': 'disabled'},
    });
    for (final mode in [
      ThinkingMode.low,
      ThinkingMode.high,
      ThinkingMode.max,
    ]) {
      expect(AiService.thinkingOptions(AppSettings(thinking: mode)), {
        'thinking': {'type': 'enabled'},
        'reasoning_effort': mode.name,
      });
    }
    expect(
      AiService.thinkingOptions(
        const AppSettings(
          provider: AiProvider.custom,
          thinking: ThinkingMode.max,
        ),
      ),
      isEmpty,
    );
  });

  test('language is English or Chinese', () {
    expect(AppStrings.languages, {'en': 'English', 'zh': '中文'});
    expect(SettingsStore.systemLanguage(const Locale('zh', 'TW')), 'zh');
    expect(SettingsStore.systemLanguage(const Locale('zh', 'CN')), 'zh');
    expect(SettingsStore.systemLanguage(const Locale('en', 'GB')), 'en');
    expect(SettingsStore.systemLanguage(const Locale('fr', 'CA')), 'en');
    for (final old in ['zh-CN', 'zh-TW']) {
      expect(SettingsStore.storedLanguage(old), 'zh');
    }
    for (final old in ['en', 'es', 'fr']) {
      expect(SettingsStore.storedLanguage(old), 'en');
    }
    expect(AppStrings('zh').t('settings'), '设置');
    expect(AppStrings('en').t('settings'), 'Settings');
  });

  test('copyWith keeps untouched voice settings', () {
    const settings = AppSettings();
    final updated = settings.copyWith(model: 'custom-vision-model');

    expect(updated.model, 'custom-vision-model');
    expect(updated.speechVoice, settings.speechVoice);
    expect(updated.speechRate, settings.speechRate);
  });

  test('replies are read in an Edge voice from the start', () {
    const settings = AppSettings();
    expect(settings.speechVoice, EdgeTts.defaultVoice);
    expect(SpeechConfig.of(settings).ready, isTrue);
    expect(SpeechConfig.of(settings).voice, EdgeTts.defaultVoice);
  });

  test('theme color is independent from light and dark appearance', () {
    const settings = AppSettings();
    final updated = settings.copyWith(theme: 'dark', accentColor: 'violet');

    expect(updated.theme, 'dark');
    expect(updated.accentColor, 'violet');
    expect(updated.provider, settings.provider);
  });
}
