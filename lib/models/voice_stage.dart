/// What a voice conversation is doing right now.
enum VoiceStage {
  /// Not in a voice conversation.
  idle,

  /// The microphone is open but no speech is detected.
  listening,

  /// The user is speaking.
  hearing,

  /// Waiting for the first words of a reply.
  thinking,

  /// A reply is streaming in.
  responding,

  /// A reply is being read aloud.
  speaking,
}
