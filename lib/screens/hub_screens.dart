import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../services/clip_repository.dart';
import '../services/personal_bests.dart';
import '../services/zen_last_mix.dart';
import '../theme/app_colors.dart';

/// One destination card on the Tools / Games tabs.
class HubItem {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  /// Optional text mark shown instead of [icon] (the Morse cards' call signs).
  final String? glyph;

  /// Opens the screen; completes when the user comes back.
  final Future<void> Function() onOpen;

  const HubItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onOpen,
    this.glyph,
  });
}

// ── Bottom navigation bar ────────────────────────────────────────────────────

/// Sounds · Tools · Games · Settings, as a floating frosted pill.
///
/// Sits in [Scaffold.bottomNavigationBar] with `extendBody: true`, so pages
/// scroll underneath and show through the blur. Scaffold adds the bar's
/// height to the body's bottom padding — lists pad by
/// `MediaQuery.paddingOf(context).bottom` to stay clear of it.
class SoundrNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const SoundrNavBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  static const _items = [
    (Icons.grid_view_outlined, Icons.grid_view_rounded, 'Sounds'),
    (Icons.handyman_outlined, Icons.handyman_rounded, 'Tools'),
    (Icons.sports_esports_outlined, Icons.sports_esports_rounded, 'Games'),
    (Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
  ];

  static const barHeight = 64.0;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(barHeight / 2);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            // A pill, not a slab, on tablets and in landscape.
            constraints: const BoxConstraints(maxWidth: 440),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.35 : 0.06),
                    blurRadius: 28,
                    spreadRadius: -6,
                    offset: const Offset(0, 10),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.25 : 0.05),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                  child: Container(
                    height: barHeight,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: c.surfaceCard.withValues(alpha: dark ? 0.6 : 0.62),
                      borderRadius: radius,
                      border: Border.all(
                        color: dark
                            ? Colors.white.withValues(alpha: 0.1)
                            : Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < _items.length; i++)
                          Expanded(
                            // The selected tab grows to fit its label.
                            flex: i == selectedIndex ? 15 : 10,
                            child: _NavItem(
                              icon: _items[i].$1,
                              selectedIcon: _items[i].$2,
                              label: _items[i].$3,
                              selected: i == selectedIndex,
                              onTap: () => onSelected(i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  static const _duration = Duration(milliseconds: 260);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: _duration,
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: dark ? 0.22 : 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(26),
            ),
            child: ClipRect(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedSwitcher(
                    duration: _duration,
                    transitionBuilder: (child, a) =>
                        ScaleTransition(scale: a, child: child),
                    child: Icon(
                      selected ? selectedIcon : icon,
                      key: ValueKey(selected),
                      size: 23,
                      color: selected ? accent : c.iconSecondary,
                    ),
                  ),
                  // The label slides out beside the icon when selected.
                  Flexible(
                    child: AnimatedSize(
                      duration: _duration,
                      curve: Curves.easeOutCubic,
                      child: selected
                          ? Padding(
                              padding: const EdgeInsets.only(left: 7),
                              child: Text(
                                label,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.fade,
                                style: TextStyle(
                                  color: c.textPrimary,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
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

// ── Tools tab ────────────────────────────────────────────────────────────────

/// A labelled group of tools on the Tools tab.
class HubSection {
  final String title;
  final List<HubItem> items;
  const HubSection(this.title, this.items);
}

/// Zen Mode hero, the two Morse tools, then the other tools in sections.
class ToolsHub extends StatefulWidget {
  /// Opens Zen Mode; [resume] restarts the last mix. Completes on return.
  final Future<void> Function(bool resume) onOpenZen;

  /// Morse tools — shown as cards with their [HubItem.glyph].
  final List<HubItem> morse;

  /// Grouped lists below the Morse cards (Music, Voice, Sound check…).
  final List<HubSection> sections;

  /// Loads the last Zen mix; defaults to [ZenLastMix.load]. Tests override it.
  final Future<ZenLastMix?> Function()? lastMixLoader;

  const ToolsHub({
    super.key,
    required this.onOpenZen,
    required this.morse,
    required this.sections,
    this.lastMixLoader,
  });

  @override
  State<ToolsHub> createState() => _ToolsHubState();
}

class _ToolsHubState extends State<ToolsHub> {
  ZenLastMix? _lastMix;

  @override
  void initState() {
    super.initState();
    _loadLastMix();
  }

  Future<void> _loadLastMix() async {
    final mix = await (widget.lastMixLoader ?? ZenLastMix.load)();
    if (!mounted) return;
    setState(() => _lastMix = mix);
  }

  /// Runs [open], then refreshes the Zen card — any screen could have changed
  /// the last mix by the time the user comes back.
  Future<void> _thenReload(Future<void> Function() open) async {
    await open();
    await _loadLastMix();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(builder: (context, box) {
          // Phones use the full width; tablets / landscape get a centred column.
          final side = ((box.maxWidth - 600) / 2).clamp(16.0, double.infinity);
          return ListView(
            padding: EdgeInsets.fromLTRB(
                side, 0, side, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 26, 4, 16),
                child: Text('Tools',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.8,
                      height: 1.15,
                    )),
              ),
              _ZenCard(
                mix: _lastMix,
                onOpen: (resume) =>
                    _thenReload(() => widget.onOpenZen(resume)),
              ),
              const _ToolsLabel('MORSE CODE'),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < widget.morse.length; i++) ...[
                      if (i > 0) const SizedBox(width: 10),
                      Expanded(
                        child: _MorseCard(
                          item: widget.morse[i],
                          onTap: () => _thenReload(widget.morse[i].onOpen),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              for (final section in widget.sections) ...[
                _ToolsLabel(section.title.toUpperCase()),
                _ToolList(
                  items: section.items,
                  onTap: (item) => _thenReload(item.onOpen),
                ),
              ],
            ],
          );
        }),
      ),
    );
  }
}

class _ToolsLabel extends StatelessWidget {
  final String text;
  const _ToolsLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Text(text,
          style: TextStyle(
            color: c.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
          )),
    );
  }
}

/// Zen Mode's teal palette, deeper in light mode so text and borders keep
/// their contrast on a pale card.
class _ZenColors {
  final Color teal;
  final Color background;
  final Color border;
  final Color subtitle;
  final Color onPill;

  const _ZenColors({
    required this.teal,
    required this.background,
    required this.border,
    required this.subtitle,
    required this.onPill,
  });

  factory _ZenColors.of(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    if (Theme.of(context).brightness == Brightness.dark) {
      const teal = Color(0xFF7FE0C2);
      return _ZenColors(
        teal: teal,
        background: Color.alphaBlend(
            teal.withValues(alpha: 0.09), c.scaffoldBg),
        border: teal.withValues(alpha: 0.28),
        subtitle: const Color(0xFFB5D9CF),
        onPill: const Color(0xFF06221B),
      );
    }
    const teal = Color(0xFF0F7A62);
    return _ZenColors(
      teal: teal,
      background: Color.alphaBlend(
          const Color(0xFF2FB58F).withValues(alpha: 0.12), c.surfaceCard),
      border: teal.withValues(alpha: 0.35),
      subtitle: const Color(0xFF3B6559),
      onPill: Colors.white,
    );
  }
}

/// Zen Mode hero — resumes the last mix when there is one.
class _ZenCard extends StatelessWidget {
  final ZenLastMix? mix;
  final Future<void> Function(bool resume) onOpen;
  const _ZenCard({required this.mix, required this.onOpen});

  static String _subtitle(ZenLastMix mix) {
    final names = [for (final t in mix.tracks) t.name];
    const shown = 3;
    if (names.length <= shown) return names.join(' · ');
    return '${names.take(shown).join(' · ')} +${names.length - shown}';
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final z = _ZenColors.of(context);
    final mix = this.mix;
    final headline = mix == null
        ? 'Make your own calm'
        : mix.presetName == null
            ? 'Resume your mix'
            : 'Resume ${mix.presetName}';
    final subtitle =
        mix == null ? 'Rain, waves, fire and more' : _subtitle(mix);
    final radius = BorderRadius.circular(24);

    return Material(
      color: z.background,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: z.border),
      ),
      child: InkWell(
        onTap: () => onOpen(false),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned(
              right: -44,
              top: -8,
              width: 190,
              height: 190,
              child: IgnorePointer(
                child: CustomPaint(painter: _RingsPainter(z.teal)),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 160),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('ZEN MODE',
                        style: TextStyle(
                          color: z.teal,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                          height: 1.2,
                        )),
                    const SizedBox(height: 6),
                    Text(headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                          height: 1.2,
                        )),
                    const SizedBox(height: 6),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: z.subtitle,
                          fontSize: 14,
                          height: 1.25,
                        )),
                    const SizedBox(height: 12),
                    Material(
                      color: z.teal,
                      shape: const StadiumBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => onOpen(mix != null),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 16, 0),
                          child: SizedBox(
                            height: 40,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  mix == null
                                      ? Icons.arrow_forward_rounded
                                      : Icons.play_arrow_rounded,
                                  color: z.onPill,
                                  size: 20,
                                ),
                                const SizedBox(width: 6),
                                Text(mix == null ? 'Open' : 'Play',
                                    style: TextStyle(
                                      color: z.onPill,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    )),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Concentric rings bleeding off the Zen card's top-right corner.
class _RingsPainter extends CustomPainter {
  final Color color;
  const _RingsPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color.withValues(alpha: 0.35);
    final centre = size.center(Offset.zero);
    final scale = size.shortestSide / 190;
    for (final r in const [30.0, 52.0, 74.0, 94.0]) {
      canvas.drawCircle(centre, r * scale, paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.color != color;
}

/// Morse tool card: the tool's call sign in Morse, then its name.
class _MorseCard extends StatelessWidget {
  final HubItem item;
  final VoidCallback onTap;
  const _MorseCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final radius = BorderRadius.circular(20);
    return Material(
      color: c.surfaceCard,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: c.borderSubtle),
      ),
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 100),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.glyph != null)
                  Text(item.glyph!,
                      style: TextStyle(
                        color: item.color,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 4,
                        height: 1.1,
                      ))
                else
                  Icon(item.icon, color: item.color, size: 22),
                // Title sits at a fixed spot so both cards line up even when
                // one subtitle wraps.
                const SizedBox(height: 16),
                Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    )),
                const SizedBox(height: 3),
                Text(item.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 12.5,
                      height: 1.25,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One grouped card of tool rows with dividers between them.
class _ToolList extends StatelessWidget {
  final List<HubItem> items;
  final void Function(HubItem item) onTap;
  const _ToolList({required this.items, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    return Material(
      color: c.surfaceCard,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: c.borderSubtle),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: c.borderSubtle),
            InkWell(
              onTap: () => onTap(items[i]),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 58),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
                  child: Row(children: [
                    _IconBadge(
                      icon: items[i].icon,
                      // Pastel tool colours wash out on white; deepen them.
                      color: light
                          ? Color.lerp(items[i].color, Colors.black, 0.22)!
                          : items[i].color,
                      size: 38,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(items[i].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                height: 1.25,
                              )),
                          Text(items[i].subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: c.textSecondary,
                                fontSize: 12.5,
                                height: 1.3,
                              )),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right_rounded,
                        color: c.iconSecondary, size: 22),
                  ]),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Games tab ────────────────────────────────────────────────────────────────

/// Sound games with their personal bests, refreshed after every game.
class GamesHub extends StatefulWidget {
  final HubItem speedRound;
  final HubItem pairMatch;
  final HubItem reverseChallenge;
  final List<HubItem> morseGames;

  const GamesHub({
    super.key,
    required this.speedRound,
    required this.pairMatch,
    required this.reverseChallenge,
    required this.morseGames,
  });

  @override
  State<GamesHub> createState() => _GamesHubState();
}

class _GamesHubState extends State<GamesHub> {
  String? _speedBest;
  String? _pairBest;
  String? _reverseBest;

  @override
  void initState() {
    super.initState();
    _loadBests();
  }

  Future<void> _loadBests() async {
    final score = await PersonalBests.speedRoundScore();
    String? pair;
    // Show the hardest level the player has finished.
    for (final (key, label) in const [
      ('hard', 'Hard'),
      ('medium', 'Medium'),
      ('easy', 'Easy'),
    ]) {
      final best = await PersonalBests.pairMatch(key);
      if (best.seconds != null) {
        final s = best.seconds!;
        pair = '${(s ~/ 60).toString().padLeft(2, '0')}:'
            '${(s % 60).toString().padLeft(2, '0')} · $label';
        break;
      }
    }
    int? reverse;
    try {
      reverse = await ClipRepository.getInt('reverse_best');
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _speedBest = score == null ? null : '$score pts';
      _pairBest = pair;
      _reverseBest = reverse == null ? null : '$reverse% match';
    });
  }

  HubItem _refreshing(HubItem item) => HubItem(
        icon: item.icon,
        color: item.color,
        title: item.title,
        subtitle: item.subtitle,
        onOpen: () async {
          await item.onOpen();
          await _loadBests();
        },
      );

  @override
  Widget build(BuildContext context) {
    return _HubScaffold(
      title: 'Games',
      children: [
        _GameCard(item: _refreshing(widget.speedRound), best: _speedBest),
        const SizedBox(height: 12),
        _GameCard(item: _refreshing(widget.pairMatch), best: _pairBest),
        const SizedBox(height: 12),
        _GameCard(item: _refreshing(widget.reverseChallenge), best: _reverseBest),
        const _HubLabel('MORSE GAMES'),
        _TileGrid(items: widget.morseGames),
      ],
    );
  }
}

// ── Building blocks ──────────────────────────────────────────────────────────

class _HubScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _HubScaffold({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(title,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            )),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 4, 16, 24 + MediaQuery.paddingOf(context).bottom),
        children: children,
      ),
    );
  }
}

class _HubLabel extends StatelessWidget {
  final String text;
  const _HubLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Text(text,
          style: TextStyle(
            color: c.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          )),
    );
  }
}

class _IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const _IconBadge({required this.icon, required this.color, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(icon, color: color, size: size * 0.55),
    );
  }
}

/// Two-column grid of compact tool cards.
class _TileGrid extends StatelessWidget {
  final List<HubItem> items;
  const _TileGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      // Two columns on phones; more on tablets / landscape.
      final columns = (box.maxWidth / 220).floor().clamp(2, 4);
      const gap = 12.0;
      final width = (box.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final item in items)
            SizedBox(width: width, child: _Tile(item: item)),
        ],
      );
    });
  }
}

class _Tile extends StatelessWidget {
  final HubItem item;
  const _Tile({required this.item});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: item.onOpen,
        child: Ink(
          height: 128,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.surfaceCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: c.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _IconBadge(icon: item.icon, color: item.color),
              const Spacer(),
              Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  )),
              const SizedBox(height: 2),
              Text(item.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: c.textMuted, fontSize: 12, height: 1.3)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-width game card with the player's personal best.
class _GameCard extends StatelessWidget {
  final HubItem item;
  final String? best;
  const _GameCard({required this.item, required this.best});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: item.onOpen,
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: c.surfaceCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: item.color.withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            _IconBadge(icon: item.icon, color: item.color, size: 52),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      )),
                  const SizedBox(height: 3),
                  Text(item.subtitle,
                      style: TextStyle(
                          color: c.textSecondary, fontSize: 13, height: 1.35)),
                  const SizedBox(height: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: best == null
                          ? c.surfaceElevated.withValues(alpha: 0.6)
                          : Colors.amber.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      best == null ? 'No best yet — play a round' : '🏆  Best $best',
                      style: TextStyle(
                        color: best == null ? c.textMuted : c.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.iconSecondary),
          ]),
        ),
      ),
    );
  }
}
