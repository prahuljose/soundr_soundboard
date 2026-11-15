import 'dart:math';

import 'package:flutter/material.dart';

import '../services/haptics.dart';
import '../theme/app_colors.dart';

/// Four quick cards shown once after the first launch (and from Settings):
/// tap to play · long-press for more · make your own · tools & games.
///
/// [tabs] switches the last card between the side-menu and bottom-tab
/// wording so it always describes the navigation the user actually has.
Future<void> showFirstRunTour(BuildContext context, {bool tabs = false}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'Intro tour',
    barrierColor: Colors.black.withValues(alpha: 0.72),
    transitionDuration: const Duration(milliseconds: 260),
    transitionBuilder: (context, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(
        scale: Tween(begin: 0.94, end: 1.0)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
    pageBuilder: (context, _, _) => _Tour(tabs: tabs),
  );
}

class _Tour extends StatefulWidget {
  final bool tabs;
  const _Tour({required this.tabs});

  @override
  State<_Tour> createState() => _TourState();
}

class _TourState extends State<_Tour> with SingleTickerProviderStateMixin {
  final _pages = PageController();
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();
  int _page = 0;

  static const _count = 4;

  @override
  void dispose() {
    _pages.dispose();
    _loop.dispose();
    super.dispose();
  }

  void _next() {
    Haptics.selection();
    if (_page == _count - 1) {
      Navigator.pop(context);
    } else {
      _pages.nextPage(
          duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    final font = Theme.of(context).textTheme.bodyMedium?.fontFamily;

    final steps = [
      (
        title: 'Tap to play',
        body: 'Every button plays instantly. Tap a few in a row to layer sounds.',
        art: _TapArt(loop: _loop, accent: accent),
      ),
      (
        title: 'Long-press for more',
        body: 'Loop it, change the speed, share it, or pin it to your '
            'home-screen widget.',
        art: _LongPressArt(loop: _loop, accent: accent),
      ),
      (
        title: 'Make your own',
        body: 'Record a clip or import any audio. It becomes a button '
            'in My Clips.',
        art: _MakeArt(loop: _loop, accent: accent),
      ),
      widget.tabs
          ? (
              title: 'Tools & games',
              body: 'A tuner, voice changer, Zen Mode, quick games and '
                  'more, in the tabs at the bottom.',
              art: _TabsArt(loop: _loop, accent: accent),
            )
          : (
              title: 'Tools & games',
              body: 'Swipe in from the left edge (or tap the menu icon) for '
                  'a tuner, voice changer, Zen Mode, games and more.',
              art: _DrawerArt(loop: _loop, accent: accent),
            ),
    ];

    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380, maxHeight: 560),
          child: Material(
            color: c.surfaceCard,
            borderRadius: BorderRadius.circular(28),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 22),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 150),
                      opacity: _page == _count - 1 ? 0 : 1,
                      child: TextButton(
                        onPressed: _page == _count - 1
                            ? null
                            : () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          foregroundColor: c.textSecondary,
                          textStyle: TextStyle(
                              fontFamily: font, fontWeight: FontWeight.w600),
                        ),
                        child: const Text('Skip'),
                      ),
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      controller: _pages,
                      itemCount: _count,
                      onPageChanged: (i) => setState(() => _page = i),
                      itemBuilder: (context, i) {
                        final step = steps[i];
                        return Column(
                          children: [
                            Expanded(
                              child: Center(
                                // Decorative: the title and body say it all.
                                child: ExcludeSemantics(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: step.art,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                            Semantics(
                              header: true,
                              child: Text(step.title,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: c.textPrimary,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.4,
                                )),
                            ),
                            const SizedBox(height: 10),
                            Text(step.body,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: c.textSecondary,
                                  fontSize: 15,
                                  height: 1.45,
                                )),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 22),
                  Semantics(
                    label: 'Step ${_page + 1} of $_count',
                    child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _count; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: i == _page ? 22 : 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: i == _page ? accent : c.border,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                    ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: _next,
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        // Dark themes use a pale accent: white would wash out.
                        foregroundColor:
                            Theme.of(context).colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(
                        _page == _count - 1 ? 'Let’s go' : 'Next',
                        style: TextStyle(
                            fontFamily: font,
                            fontSize: 16,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Illustrations ─────────────────────────────────────────────────────────────
// Small, looping sketches of the real UI, drawn with plain widgets.

class _MiniButton extends StatelessWidget {
  final String emoji;
  final String name;
  final Color accent;
  final double glow;

  const _MiniButton({
    required this.emoji,
    required this.name,
    required this.accent,
    this.glow = 0,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Container(
      width: 96,
      height: 104,
      padding: const EdgeInsets.fromLTRB(11, 11, 11, 12),
      decoration: BoxDecoration(
        color: Color.lerp(c.surfaceElevated, accent, 0.12 + 0.1 * glow),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.2 + 0.6 * glow)),
        boxShadow: [
          if (glow > 0)
            BoxShadow(color: accent.withValues(alpha: 0.3 * glow), blurRadius: 18),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 26)),
          const Spacer(),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: glow > 0 ? 1 - glow : 0,
              minHeight: 3,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation(accent.withValues(alpha: 0.6)),
            ),
          ),
        ],
      ),
    );
  }
}

/// A fingertip ring that taps the button; the button lights up.
class _TapArt extends StatelessWidget {
  final Animation<double> loop;
  final Color accent;
  const _TapArt({required this.loop, required this.accent});

  @override
  Widget build(BuildContext context) {
    // White vanishes on the light card, so the fingertip follows the theme.
    final ringColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Theme.of(context).extension<AppColors>()!.textPrimary;
    return AnimatedBuilder(
      animation: loop,
      builder: (context, _) {
        final t = loop.value;
        final glow = t < 0.15 ? 0.0 : max(0.0, 1 - (t - 0.15) / 0.7);
        final ring = t < 0.15 ? t / 0.15 : 1.0;
        return SizedBox(
          width: 200,
          height: 180,
          child: Stack(
            alignment: Alignment.center,
            children: [
              _MiniButton(emoji: '🔥', name: 'Yeah Boy', accent: accent, glow: glow),
              Positioned(
                right: 44,
                bottom: 22,
                child: Opacity(
                  opacity: (1 - ring * 0.6).clamp(0.0, 1.0),
                  child: Container(
                    width: 30 + 16 * ring,
                    height: 30 + 16 * ring,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ringColor.withValues(alpha: 0.18),
                      border: Border.all(color: ringColor.withValues(alpha: 0.7), width: 2),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A held fingertip on the button, with the options sheet rising beside it:
/// loop, speed, share and pin-to-widget.
class _LongPressArt extends StatelessWidget {
  final Animation<double> loop;
  final Color accent;
  const _LongPressArt({required this.loop, required this.accent});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ringColor = dark ? Colors.white : c.textPrimary;
    return AnimatedBuilder(
      animation: loop,
      builder: (context, _) {
        final hold = (loop.value / 0.25).clamp(0.0, 1.0);
        final t = Curves.easeOutBack
            .transform(((loop.value - 0.15) * 2.2).clamp(0.0, 1.0));
        Widget option(IconData icon, String label, {Widget? trailing}) =>
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Icon(icon, size: 15, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500)),
                ),
                ?trailing,
              ]),
            );
        // A tiny "on" switch for the Loop row.
        final toggle = Container(
          width: 22,
          height: 13,
          padding: const EdgeInsets.all(2),
          alignment: Alignment.centerRight,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Container(
            width: 9,
            height: 9,
            decoration: const BoxDecoration(
                color: Colors.white, shape: BoxShape.circle),
          ),
        );
        final speed = Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text('1.5×',
              style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700)),
        );
        return SizedBox(
          width: 256,
          height: 180,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: 0,
                child: _MiniButton(
                    emoji: '💔', name: 'Emotional Da…', accent: accent),
              ),
              // The finger stays down: the ring shrinks in and holds.
              Positioned(
                left: 48,
                bottom: 30,
                child: Container(
                  width: 44 - 12 * hold,
                  height: 44 - 12 * hold,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ringColor.withValues(alpha: 0.10 + 0.12 * hold),
                    border: Border.all(
                        color: ringColor.withValues(alpha: 0.7), width: 2),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                child: Transform.translate(
                  offset: Offset(0, 24 * (1 - t)),
                  child: Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Container(
                      width: 146,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      decoration: BoxDecoration(
                        color: c.surfaceElevated,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: c.border),
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 12),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          option(Icons.repeat_rounded, 'Loop',
                              trailing: toggle),
                          option(Icons.speed_rounded, 'Speed',
                              trailing: speed),
                          option(Icons.share_rounded, 'Share'),
                          option(Icons.push_pin_rounded, 'Pin to widget'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Record or import on the left; a brand-new button pops out on the right.
class _MakeArt extends StatelessWidget {
  final Animation<double> loop;
  final Color accent;
  const _MakeArt({required this.loop, required this.accent});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return AnimatedBuilder(
      animation: loop,
      builder: (context, _) {
        final v = loop.value;
        // Mic pulses first, then the arrow and the new button follow.
        final pulse = (v / 0.35).clamp(0.0, 1.0);
        final arrow = ((v - 0.25) / 0.2).clamp(0.0, 1.0);
        final pop =
            Curves.easeOutBack.transform(((v - 0.35) / 0.3).clamp(0.0, 1.0));
        Widget source(IconData icon, String label, {double ring = 0}) =>
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.surfaceElevated,
                    border: Border.all(
                      color: Color.lerp(c.border, accent, ring)!,
                      width: 1 + ring,
                    ),
                    boxShadow: [
                      if (ring > 0)
                        BoxShadow(
                          color: accent.withValues(alpha: 0.35 * ring),
                          blurRadius: 14,
                        ),
                    ],
                  ),
                  child: Icon(icon, size: 22, color: c.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    )),
              ],
            );
        return SizedBox(
          width: 256,
          height: 180,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  source(Icons.mic_rounded, 'Record',
                      ring: sin(pulse * pi).clamp(0.0, 1.0)),
                  const SizedBox(height: 12),
                  source(Icons.file_open_rounded, 'Import'),
                ],
              ),
              const SizedBox(width: 14),
              Opacity(
                opacity: 0.25 + 0.75 * arrow,
                child: Transform.translate(
                  offset: Offset(-6 * (1 - arrow), 0),
                  child: Icon(Icons.arrow_forward_rounded,
                      color: accent, size: 24),
                ),
              ),
              const SizedBox(width: 14),
              Opacity(
                opacity: pop.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.7 + 0.3 * pop,
                  child: _MiniButton(
                    emoji: '🎤',
                    name: 'My clip',
                    accent: accent,
                    glow: v > 0.65 ? (1 - (v - 0.65) / 0.35) * 0.8 : 0,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A miniature drawer sliding in from the left edge.
class _DrawerArt extends StatelessWidget {
  final Animation<double> loop;
  final Color accent;
  const _DrawerArt({required this.loop, required this.accent});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return AnimatedBuilder(
      animation: loop,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform((loop.value * 1.5).clamp(0.0, 1.0));
        Widget item(IconData icon, String label) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Icon(icon, size: 15, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: TextStyle(color: c.textPrimary, fontSize: 12)),
                ),
              ]),
            );
        return Container(
          width: 220,
          height: 170,
          decoration: BoxDecoration(
            color: c.scaffoldBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: c.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Faint grid behind the drawer.
              Padding(
                padding: const EdgeInsets.all(12),
                child: GridView.count(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  physics: const NeverScrollableScrollPhysics(),
                  children: List.generate(
                    6,
                    (_) => Container(
                      decoration: BoxDecoration(
                        color: c.surfaceElevated.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: -138 * (1 - t),
                top: 0,
                bottom: 0,
                child: Container(
                  width: 138,
                  padding: const EdgeInsets.fromLTRB(12, 14, 8, 8),
                  decoration: BoxDecoration(
                    color: c.drawerBg,
                    boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 14)],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      item(Icons.tune_rounded, 'Guitar Tuner'),
                      item(Icons.record_voice_over_rounded, 'Voice Changer'),
                      item(Icons.self_improvement_rounded, 'Zen Mode'),
                      item(Icons.sports_esports_rounded, 'Games'),
                    ],
                  ),
                ),
              ),
              // Swipe hint arrow at the edge.
              Positioned(
                left: 6 + 126 * t,
                top: 70,
                child: Opacity(
                  opacity: (1 - t).clamp(0.0, 1.0),
                  child: Icon(Icons.arrow_forward_rounded, color: accent, size: 22),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A miniature of the floating pill tab bar, hopping between Tools and Games.
class _TabsArt extends StatelessWidget {
  final Animation<double> loop;
  final Color accent;
  const _TabsArt({required this.loop, required this.accent});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    const tabs = [
      (Icons.grid_view_outlined, 'Sounds'),
      (Icons.handyman_rounded, 'Tools'),
      (Icons.sports_esports_rounded, 'Games'),
      (Icons.settings_outlined, 'Settings'),
    ];
    // What each tab holds, as three little tiles.
    const tiles = {
      1: [
        Icons.tune_rounded,
        Icons.record_voice_over_rounded,
        Icons.self_improvement_rounded,
      ],
      2: [
        Icons.bolt_rounded,
        Icons.grid_on_rounded,
        Icons.music_note_rounded,
      ],
    };
    return AnimatedBuilder(
      animation: loop,
      builder: (context, _) {
        final active = loop.value < 0.5 ? 1 : 2;
        // Tiles rise in a little after each hop.
        final phase = (loop.value % 0.5) / 0.5;
        final rise = Curves.easeOutCubic.transform((phase * 3).clamp(0.0, 1.0));
        return Container(
          width: 240,
          height: 170,
          decoration: BoxDecoration(
            color: c.scaffoldBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: c.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: Opacity(
                    opacity: rise,
                    child: Transform.translate(
                      offset: Offset(0, 8 * (1 - rise)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final icon in tiles[active]!)
                            Container(
                              width: 50,
                              height: 50,
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 5),
                              decoration: BoxDecoration(
                                color: Color.lerp(
                                    c.surfaceElevated, accent, 0.14),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                    color: accent.withValues(alpha: 0.3)),
                              ),
                              child: Icon(icon, size: 24, color: accent),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // The floating pill bar.
              Container(
                height: 40,
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: c.surfaceCard,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: dark
                        ? Colors.white.withValues(alpha: 0.1)
                        : c.border,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: dark ? 0.35 : 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      if (i == active)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                          decoration: BoxDecoration(
                            color:
                                accent.withValues(alpha: dark ? 0.22 : 0.14),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(tabs[i].$1, size: 16, color: accent),
                              const SizedBox(width: 5),
                              Text(tabs[i].$2,
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: c.textPrimary,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                  )),
                            ],
                          ),
                        )
                      else
                        Expanded(
                          child: Icon(tabs[i].$1,
                              size: 16, color: c.iconSecondary),
                        ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
