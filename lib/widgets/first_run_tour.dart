import 'dart:math';

import 'package:flutter/material.dart';

import '../services/haptics.dart';
import '../theme/app_colors.dart';

/// Three quick cards shown once after the first launch (and from Settings):
/// tap to play · long-press for options · where the tools live.
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

  static const _count = 3;

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

    final steps = [
      (
        title: 'Tap to play',
        body: 'Every button plays instantly. Tap a few in a row to layer sounds.',
        art: _TapArt(loop: _loop, accent: accent),
      ),
      (
        title: 'Long-press for options',
        body: 'Favourite a sound, share it to a chat, or add it to a board.',
        art: _LongPressArt(loop: _loop, accent: accent),
      ),
      widget.tabs
          ? (
              title: 'Explore tools & games',
              body: 'Zen Mode, Morse code, games and audio tools live in the '
                  'tabs at the bottom.',
              art: _TabsArt(loop: _loop, accent: accent),
            )
          : (
              title: 'Swipe to explore tools',
              body: 'Swipe in from the left edge (or tap the menu icon) for '
                  'Zen Mode, Morse code, games and audio tools.',
              art: _DrawerArt(loop: _loop, accent: accent),
            ),
    ];

    return SafeArea(
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
                            foregroundColor: c.textSecondary),
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
                            Expanded(child: Center(child: step.art)),
                            const SizedBox(height: 20),
                            Text(step.title,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: c.textPrimary,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.4,
                                )),
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
                  Row(
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
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: _next,
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(
                        _page == _count - 1 ? 'Let’s go' : 'Next',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
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
                      color: Colors.white.withValues(alpha: 0.18),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.7), width: 2),
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

/// The button with a small options sheet rising beside it.
class _LongPressArt extends StatelessWidget {
  final Animation<double> loop;
  final Color accent;
  const _LongPressArt({required this.loop, required this.accent});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return AnimatedBuilder(
      animation: loop,
      builder: (context, _) {
        final t = Curves.easeOutBack.transform((loop.value * 1.6).clamp(0.0, 1.0));
        Widget option(IconData icon, String label, Color color) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500)),
              ]),
            );
        return SizedBox(
          width: 256,
          height: 180,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: 4,
                child: _MiniButton(emoji: '💔', name: 'Emotional Da…', accent: accent),
              ),
              Positioned(
                right: 6,
                child: Transform.translate(
                  offset: Offset(0, 24 * (1 - t)),
                  child: Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
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
                          option(Icons.star_rounded, 'Favourite', Colors.amber),
                          option(Icons.share_rounded, 'Share', accent),
                          option(Icons.dashboard_customize_rounded, 'Add to board', accent),
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
                Text(label,
                    style: TextStyle(color: c.textPrimary, fontSize: 12)),
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
                left: -130 * (1 - t),
                top: 0,
                bottom: 0,
                child: Container(
                  width: 130,
                  padding: const EdgeInsets.fromLTRB(12, 14, 8, 8),
                  decoration: BoxDecoration(
                    color: c.drawerBg,
                    boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 14)],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      item(Icons.self_improvement_rounded, 'Zen Mode'),
                      item(Icons.radio_rounded, 'Morse Code'),
                      item(Icons.bolt_rounded, 'Sound Games'),
                      item(Icons.graphic_eq_rounded, 'Decibel Meter'),
                    ],
                  ),
                ),
              ),
              // Swipe hint arrow at the edge.
              Positioned(
                left: 6 + 118 * t,
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

/// A miniature bottom tab bar with the active tab moving across.
class _TabsArt extends StatelessWidget {
  final Animation<double> loop;
  final Color accent;
  const _TabsArt({required this.loop, required this.accent});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    const tabs = [
      (Icons.grid_view_rounded, 'Sounds'),
      (Icons.handyman_rounded, 'Tools'),
      (Icons.sports_esports_rounded, 'Games'),
      (Icons.settings_rounded, 'Settings'),
    ];
    return AnimatedBuilder(
      animation: loop,
      builder: (context, _) {
        final active = (loop.value * 3).floor().clamp(0, 2) + 1;
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
                  child: Icon(tabs[active].$1,
                      size: 44, color: accent.withValues(alpha: 0.8)),
                ),
              ),
              Container(
                color: c.surfaceCard,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      Expanded(
                        child: Column(
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: i == active
                                    ? accent.withValues(alpha: 0.2)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(tabs[i].$1,
                                  size: 17,
                                  color: i == active ? accent : c.iconSecondary),
                            ),
                            const SizedBox(height: 3),
                            Text(tabs[i].$2,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                style: TextStyle(
                                  color: i == active ? c.textPrimary : c.textMuted,
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w600,
                                )),
                          ],
                        ),
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
