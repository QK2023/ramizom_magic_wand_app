import 'app_settings.dart';

/// A model offered out of the box, so nobody has to type a model ID.
class ModelPreset {
  const ModelPreset(this.id, this.name, {this.vision = true});
  final String id;
  final String name;

  /// Whether the model reads images, so screens and photos can be shared.
  final bool vision;
}

/// How the app reaches a built-in provider: its OpenAI-compatible endpoint
/// and its current models, the first being the default.
class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.baseUrl,
    required this.models,
    required this.keyUrl,
  });
  final String name;
  final String baseUrl;
  final List<ModelPreset> models;

  /// Where to create an API key.
  final String keyUrl;
  ModelPreset get defaultModel => models.first;
}

class ModelCatalog {
  /// Providers in the order they are offered.
  static const providers = [AiProvider.deepSeek, AiProvider.custom];

  static const deepSeek = ProviderPreset(
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    keyUrl: 'platform.deepseek.com/api_keys',
    models: [
      ModelPreset('deepseek-flash', 'DeepSeek V4.1 Flash'),
      ModelPreset('deepseek-v4-pro', 'DeepSeek V4 Pro', vision: false),
    ],
  );

  /// The preset for [provider], or null for a custom endpoint.
  static ProviderPreset? of(AiProvider provider) => switch (provider) {
    AiProvider.deepSeek => deepSeek,
    AiProvider.custom => null,
  };

  /// DeepSeek models that have been retired, and what replaces them.
  static const retired = {
    'deepseek-chat': 'deepseek-flash',
    'deepseek-reasoner': 'deepseek-flash',
  };

  static ModelPreset? find(AiProvider provider, String id) {
    for (final model in of(provider)?.models ?? const <ModelPreset>[]) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// A readable name for a model ID, known or not.
  static String displayName(AiProvider provider, String id) =>
      find(provider, id)?.name ?? id.split('/').last.replaceAll('-', ' ');

  /// Settings pointed at the provider's own endpoint, with a model it still
  /// serves. Custom endpoints are left as they are.
  static AppSettings normalize(AppSettings settings) {
    final preset = of(settings.provider);
    if (preset == null) return settings;
    var model = retired[settings.model] ?? settings.model;
    final known = find(settings.provider, model);
    if (known == null) model = preset.defaultModel.id;
    return settings.copyWith(
      baseUrl: preset.baseUrl,
      model: model,
      sendScreen: (known ?? preset.defaultModel).vision,
    );
  }
}
