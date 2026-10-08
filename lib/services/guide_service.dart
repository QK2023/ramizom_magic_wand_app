import 'dart:convert';

/// A step the user is doing on their own screen during a walkthrough.
class GuideStep {
  const GuideStep(this.number, this.goal);
  final int number;

  /// What the screen will show once the step is done, in the model's words.
  final String goal;
}

/// How a step looks from the screen.
enum GuideStatus { done, wrong, waiting }

/// The walkthrough coach's eyes: whether the screen has changed enough to be
/// worth a look, the short request that asks the model whether a step is
/// done, and the notes sent back into the conversation when it is.
///
/// Watching is local and cheap (a tiny fingerprint of the screen); the
/// model is asked only once the screen has changed and settled.
class GuideService {
  /// Share of the screen's fingerprint that must change for a look to
  /// count as the user doing something (a clock ticking stays well below),
  /// and that may still change for the screen to count as settled.
  static const changed = 0.004;
  static const settled = 0.002;

  /// Asks whether [step] is done, from a screenshot and its text.
  static String checkPrompt({
    required GuideStep step,
    required String instruction,
  }) =>
      'You are watching a user follow your step-by-step guidance on their '
      'computer. Ignore any teaching instructions: answer with JSON only.\n'
      'Step ${step.number} you asked for: "$instruction"\n'
      'It is done when: "${step.goal}"\n'
      'From the screenshot, decide:\n'
      '{"status":"done"} — the step is done, or the screen has clearly moved '
      'past it;\n'
      '{"status":"wrong","reason":"..."} — they went a wrong way (another '
      'menu or window, an error, an unexpected dialog); give a short reason '
      'in the language of the step;\n'
      '{"status":"waiting"} — still in the middle of it, or the change has '
      'nothing to do with the step.';

  /// The model's verdict; anything unreadable counts as still waiting.
  static ({GuideStatus status, String reason}) verdict(String reply) {
    final json = RegExp(r'\{[\s\S]*?\}').firstMatch(reply)?[0];
    if (json != null) {
      try {
        final value = jsonDecode(json);
        if (value is Map) {
          final status = GuideStatus.values.asNameMap()[value['status']];
          final reason = value['reason'];
          if (status != null) {
            return (status: status, reason: reason is String ? reason : '');
          }
        }
      } on FormatException {
        // Fall through.
      }
    }
    return (status: GuideStatus.waiting, reason: '');
  }

  /// What the model is told, as the next turn, when the app sees a step
  /// finished or going wrong, or the user says so.
  static String doneNote(GuideStep step) =>
      '[Observation] The screen shows step ${step.number} is done '
      '("${step.goal}"). Acknowledge it in a few words and give the next step '
      'the same way. If the whole task is complete, say so and stop guiding.';

  static String wrongNote(GuideStep step, String reason) =>
      '[Observation] The screen changed, but step ${step.number} does not '
      'look right${reason.isEmpty ? '' : ': $reason'}. Gently say what '
      'happened and guide them back, one step at a time.';

  static String saidDoneNote(GuideStep step) =>
      '[Observation] The user says they have finished step ${step.number}. '
      'Check the screenshot: if it is done, give the next step; otherwise '
      'help them finish it.';

  static String skipNote(GuideStep step) =>
      '[Observation] The user wants to skip step ${step.number}. Give the '
      'next step.';
}
