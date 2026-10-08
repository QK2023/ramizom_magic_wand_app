import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import '../models/voice_stage.dart';

/// Shared motion tokens so transitions feel like one system.
abstract final class Motion {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 300);
  static const slow = Duration(milliseconds: 560);

  /// Material 3 "emphasized" easing: quick start, long gentle settle.
  static const emphasized = Cubic(.2, 0, 0, 1);

  /// Hues taken from the app icon, used for every glow and the voice orb.
  static const aurora = [
    Color(0xFF2F6BFF),
    Color(0xFF22B8F0),
    Color(0xFF2CD3E8),
    Color(0xFF3EE6B4),
    Color(0xFFFFCF40),
    Color(0xFF2F6BFF),
  ];

  static const iconAsset = 'assets/app_icon.png';

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Fades and glides its child into place once, after an optional delay.
class Appear extends StatefulWidget {
  const Appear({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = Motion.medium,
    this.offset = const Offset(0, 12),
    this.scale = 1,
    this.enabled = true,
  });
  final Widget child;
  final Duration delay;
  final Duration duration;
  final Offset offset;
  final double scale;
  final bool enabled;
  @override
  State<Appear> createState() => _AppearState();
}

class _AppearState extends State<Appear> with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late final Animation<double> progress;
  @override
  void initState() {
    super.initState();
    final total = widget.delay + widget.duration;
    controller = AnimationController(
      vsync: this,
      duration: total,
      value: widget.enabled ? 0 : 1,
    );
    // The delay is part of the curve so no timer outlives the widget.
    final start = total == Duration.zero
        ? 0.0
        : widget.delay.inMicroseconds / total.inMicroseconds;
    progress = CurvedAnimation(
      parent: controller,
      curve: Interval(start, 1, curve: Motion.emphasized),
    );
    if (widget.enabled) controller.forward();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return widget.child;
    return AnimatedBuilder(
      animation: progress,
      child: widget.child,
      builder: (context, child) {
        final t = progress.value;
        return Opacity(
          opacity: t.clamp(0, 1),
          child: Transform.translate(
            offset: widget.offset * (1 - t),
            child: widget.scale == 1
                ? child
                : Transform.scale(
                    scale: ui.lerpDouble(widget.scale, 1, t)!,
                    child: child,
                  ),
          ),
        );
      },
    );
  }
}

/// Paints a slowly rotating aurora border around [child] while [active].
class GlowBorder extends StatefulWidget {
  const GlowBorder({
    super.key,
    required this.active,
    required this.child,
    this.radius = 18,
  });
  final bool active;
  final double radius;
  final Widget child;
  @override
  State<GlowBorder> createState() => _GlowBorderState();
}

class _GlowBorderState extends State<GlowBorder> with TickerProviderStateMixin {
  late final spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );
  late final fade = AnimationController(
    vsync: this,
    duration: Motion.slow,
    value: widget.active ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    fade.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) spin.stop();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(GlowBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync();
  }

  void sync() {
    if (widget.active) {
      if (!Motion.reduced(context) && !spin.isAnimating) spin.repeat();
      fade.forward();
    } else {
      fade.reverse();
    }
  }

  @override
  void dispose() {
    spin.dispose();
    fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    foregroundPainter: _GlowPainter(
      spin: spin,
      fade: CurvedAnimation(parent: fade, curve: Curves.easeInOut),
      radius: widget.radius,
    ),
    child: widget.child,
  );
}

class _GlowPainter extends CustomPainter {
  _GlowPainter({required this.spin, required this.fade, required this.radius})
    : super(repaint: Listenable.merge([spin, fade]));
  final Animation<double> spin;
  final Animation<double> fade;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final strength = fade.value;
    if (strength <= 0) return;
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(
      rect.deflate(.75),
      Radius.circular(radius),
    );
    Shader shader(double alpha) => SweepGradient(
      colors: [for (final c in Motion.aurora) c.withValues(alpha: alpha)],
      transform: GradientRotation(spin.value * 2 * math.pi),
    ).createShader(rect);
    // A blurred halo under a crisp hairline reads as light, not a border.
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = shader(.35 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = shader(strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_GlowPainter oldDelegate) => oldDelegate.radius != radius;
}

/// Expanding rings behind a control, used while the microphone listens.
class PulseRings extends StatefulWidget {
  const PulseRings({
    super.key,
    required this.active,
    required this.color,
    required this.child,
  });
  final bool active;
  final Color color;
  final Widget child;
  @override
  State<PulseRings> createState() => _PulseRingsState();
}

class _PulseRingsState extends State<PulseRings>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(PulseRings oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync();
  }

  void sync() {
    if (widget.active && !Motion.reduced(context)) {
      if (!controller.isAnimating) controller.repeat();
    } else {
      controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _RingsPainter(controller, widget.color, widget.active),
    child: widget.child,
  );
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.progress, this.color, this.active)
    : super(repaint: progress);
  final Animation<double> progress;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    if (!active) return;
    final center = size.center(Offset.zero);
    final base = size.shortestSide / 2;
    for (var ring = 0; ring < 2; ring++) {
      final t = (progress.value + ring / 2) % 1;
      canvas.drawCircle(
        center,
        base + t * 12,
        Paint()
          ..color = color.withValues(alpha: (1 - t) * .28)
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.active != active;
}

/// Three softly bouncing dots followed by a shimmering label.
class ThinkingIndicator extends StatefulWidget {
  const ThinkingIndicator({super.key, required this.label});
  final String label;
  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Motion.reduced(context) && !controller.isAnimating) {
      controller.repeat();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = colors.onSurfaceVariant;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var dot = 0; dot < 3; dot++)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Transform.translate(
                  offset: Offset(
                    0,
                    -3 * math.max(0, math.sin((t - dot * .14) * 2 * math.pi)),
                  ),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color.lerp(
                        muted.withValues(alpha: .45),
                        colors.primary,
                        math.max(0, math.sin((t - dot * .14) * 2 * math.pi)),
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) => LinearGradient(
                colors: [muted, colors.onSurface, muted],
                stops: const [0, .5, 1],
                begin: Alignment(-3 + t * 6, 0),
                end: Alignment(-1 + t * 6, 0),
              ).createShader(bounds),
              child: Text(
                widget.label,
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A soft blinking caret shown while a reply is still streaming.
class StreamingCaret extends StatefulWidget {
  const StreamingCaret({super.key});
  @override
  State<StreamingCaret> createState() => _StreamingCaretState();
}

class _StreamingCaretState extends State<StreamingCaret>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Motion.reduced(context) && !controller.isAnimating) {
      controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(
      begin: .25,
      end: 1,
    ).animate(CurvedAnimation(parent: controller, curve: Curves.easeInOut)),
    child: Container(
      width: 9,
      height: 9,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: SweepGradient(colors: Motion.aurora),
      ),
    ),
  );
}

/// The app icon. While [spinning], a halo of light circles its edge.
class WandMark extends StatefulWidget {
  const WandMark({
    super.key,
    this.size = 24,
    this.spinning = false,
    this.glow = false,
  });
  final double size;
  final bool spinning;

  /// A soft blue bloom behind the icon, for hero placements.
  final bool glow;
  @override
  State<WandMark> createState() => _WandMarkState();
}

class _WandMarkState extends State<WandMark> with TickerProviderStateMixin {
  late final spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  late final fade = AnimationController(vsync: this, duration: Motion.medium);

  @override
  void initState() {
    super.initState();
    fade.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) spin.stop();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(WandMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync();
  }

  void sync() {
    if (widget.spinning) {
      if (!Motion.reduced(context) && !spin.isAnimating) spin.repeat();
      fade.forward();
    } else {
      fade.reverse();
    }
  }

  @override
  void dispose() {
    spin.dispose();
    fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.size * .215);
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        foregroundPainter: _HaloPainter(
          spin: spin,
          fade: CurvedAnimation(parent: fade, curve: Curves.easeInOut),
          radius: widget.size * .215,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: widget.glow
                ? [
                    BoxShadow(
                      color: const Color(0xFF2F80FF).withValues(alpha: .45),
                      blurRadius: widget.size * .5,
                      spreadRadius: widget.size * .02,
                    ),
                    BoxShadow(
                      color: const Color(0xFF3EE6B4).withValues(alpha: .25),
                      blurRadius: widget.size * .8,
                      offset: Offset(0, widget.size * .12),
                    ),
                  ]
                : null,
          ),
          child: Image.asset(
            Motion.iconAsset,
            width: widget.size,
            height: widget.size,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}

class _HaloPainter extends CustomPainter {
  _HaloPainter({required this.spin, required this.fade, required this.radius})
    : super(repaint: Listenable.merge([spin, fade]));
  final Animation<double> spin;
  final Animation<double> fade;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final strength = fade.value;
    if (strength <= 0) return;
    final gap = size.shortestSide * .12;
    final rect = (Offset.zero & size).inflate(gap);
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius + gap));
    // A bright comet sweeping around the icon, fading along its tail.
    final shader = SweepGradient(
      colors: [
        for (final c in Motion.aurora) c.withValues(alpha: 0),
        Motion.aurora[1].withValues(alpha: strength),
        Motion.aurora[3].withValues(alpha: strength),
      ],
      stops: [
        for (var i = 0; i < Motion.aurora.length; i++)
          .55 * i / (Motion.aurora.length - 1),
        .8,
        1,
      ],
      transform: GradientRotation(spin.value * 2 * math.pi),
    ).createShader(rect);
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, size.shortestSide * .07)
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_HaloPainter oldDelegate) => oldDelegate.radius != radius;
}

/// A living orb for voice conversations. It breathes while listening, swells
/// when it hears you, swirls while thinking and pulses while it talks.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({super.key, required this.stage, this.size = 96});
  final VoiceStage stage;
  final double size;
  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _OrbFrame extends ChangeNotifier {
  double time = 0, phase = 0, energy = 0, speed = .15, pulse = 0, swirl = 0;
  double tint = 0;
  void tick() => notifyListeners();
}

class _VoiceOrbState extends State<VoiceOrb>
    with SingleTickerProviderStateMixin {
  final frame = _OrbFrame();
  late final Ticker ticker = createTicker(advance);
  Duration last = Duration.zero;

  // Targets per stage: (energy, speed, pulse, swirl).
  static const targets = {
    VoiceStage.idle: (0.0, .15, 0.0, 0.0),
    VoiceStage.listening: (.3, .45, 0.0, 0.0),
    VoiceStage.hearing: (.85, .9, .25, 0.0),
    VoiceStage.thinking: (.4, 1.6, 0.0, 1.0),
    VoiceStage.responding: (.6, .9, .45, .2),
    VoiceStage.speaking: (.75, 1.0, 1.0, 0.0),
  };

  @override
  void initState() {
    super.initState();
    final target = targets[widget.stage]!;
    frame
      ..energy = target.$1
      ..speed = target.$2
      ..pulse = target.$3
      ..swirl = target.$4;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(VoiceOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync();
  }

  void sync() {
    if (Motion.reduced(context)) {
      if (ticker.isActive) ticker.stop();
      final target = targets[widget.stage]!;
      frame
        ..energy = target.$1
        ..pulse = 0
        ..tick();
      return;
    }
    if (!ticker.isActive) {
      last = Duration.zero;
      ticker.start();
    }
  }

  void advance(Duration elapsed) {
    final dt = last == Duration.zero
        ? 0.016
        : math.min(.05, (elapsed - last).inMicroseconds / 1e6);
    last = elapsed;
    final target = targets[widget.stage]!;
    // Ease every parameter toward the stage so changes flow, never jump.
    final k = 1 - math.exp(-dt * 5);
    frame
      ..energy += (target.$1 - frame.energy) * k
      ..speed += (target.$2 - frame.speed) * k
      ..pulse += (target.$3 - frame.pulse) * k
      ..swirl += (target.$4 - frame.swirl) * k
      ..tint += ((widget.stage == VoiceStage.thinking ? 1 : 0) - frame.tint) * k
      ..time += dt
      ..phase += dt * frame.speed
      ..tick();
    // At rest the orb is still, so the ticker sleeps.
    final settled =
        widget.stage == VoiceStage.idle &&
        (frame.energy - target.$1).abs() < .004 &&
        frame.pulse.abs() < .004 &&
        frame.swirl.abs() < .004 &&
        frame.tint.abs() < .004;
    if (settled) ticker.stop();
  }

  @override
  void dispose() {
    ticker.dispose();
    frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: CustomPaint(
      painter: _OrbPainter(frame, Theme.of(context).colorScheme.primary),
    ),
  );
}

/// A clean circle in the theme colour holding layered waves that rise,
/// roll and pulse with the conversation.
class _OrbPainter extends CustomPainter {
  _OrbPainter(this.frame, this.color) : super(repaint: frame);
  final _OrbFrame frame;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final full = size.shortestSide / 2;
    final beat = .5 + .5 * math.sin(frame.time * 2 * math.pi * 1.9);
    final radius = full * (.9 + .03 * frame.energy + .02 * frame.pulse * beat);
    final circle = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = color.withValues(alpha: .07),
    );
    canvas.save();
    canvas.clipPath(Path()..addOval(circle));

    // The water rises as the conversation gets livelier.
    final level =
        circle.top +
        circle.height * (.58 - .1 * frame.energy - .06 * frame.pulse * beat);
    // Back layers sit higher and lighter, the front one lower and deeper.
    const alphas = [.16, .3, .5];
    for (var layer = 0; layer < 3; layer++) {
      final amplitude =
          radius *
          (.045 + .07 * frame.energy + .06 * frame.pulse * beat) *
          (1 - layer * .12);
      final cycles = 1.0 + layer * .3;
      final direction = layer.isEven ? 1.0 : -1.0;
      final shift =
          frame.phase * (1.3 + layer * .45) * direction +
          frame.swirl * frame.time * 2 * direction +
          layer * 2.1;
      final rise = (layer - 1) * radius * .14;
      final wave = Path()..moveTo(circle.left, circle.bottom);
      const steps = 64;
      for (var i = 0; i <= steps; i++) {
        final t = i / steps;
        final x = circle.left + circle.width * t;
        final y =
            level +
            rise +
            amplitude * math.sin(2 * math.pi * cycles * t + shift) +
            amplitude * .18 * math.sin(2 * math.pi * cycles * 2.1 * t - shift);
        wave.lineTo(x, y);
      }
      wave
        ..lineTo(circle.right, circle.bottom)
        ..close();
      final crest = level + rise - amplitude;
      canvas.drawPath(
        wave,
        Paint()
          ..shader =
              LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  color.withValues(alpha: alphas[layer]),
                  color.withValues(alpha: alphas[layer] * .45),
                ],
              ).createShader(
                Rect.fromLTRB(circle.left, crest, circle.right, circle.bottom),
              ),
      );
    }
    canvas.restore();

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, radius * .02)
        ..color = color.withValues(alpha: .18 + .2 * frame.energy),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter oldDelegate) => oldDelegate.color != color;
}

/// Opens a dialog that scales in over a softly blurred backdrop.
Future<T?> showMagicDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final reduced = Motion.reduced(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: reduced ? Duration.zero : Motion.medium,
    pageBuilder: (context, _, _) => Builder(builder: builder),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Motion.emphasized,
        reverseCurve: Curves.easeInCubic,
      );
      return Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: animation,
                builder: (context, _) => BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: 6 * animation.value,
                    sigmaY: 6 * animation.value,
                  ),
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: .22 * animation.value,
                    ),
                  ),
                ),
              ),
            ),
          ),
          FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: .94, end: 1).animate(curved),
              child: child,
            ),
          ),
        ],
      );
    },
  );
}

/// Reports its child's laid-out size whenever it changes.
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({super.key, required this.onChange, super.child});
  final ValueChanged<Size> onChange;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderMeasureSize(onChange);
  @override
  void updateRenderObject(
    BuildContext context,
    RenderMeasureSize renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class RenderMeasureSize extends RenderProxyBox {
  RenderMeasureSize(this.onChange);
  ValueChanged<Size> onChange;
  Size? _last;
  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    final current = _last = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(current));
  }
}
