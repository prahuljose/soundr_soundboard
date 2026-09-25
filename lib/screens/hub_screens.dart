import 'package:flutter/material.dart';

import '../services/personal_bests.dart';
import '../theme/app_colors.dart';

/// One destination card on the Tools / Games tabs.
class HubItem {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  /// Opens the screen; completes when the user comes back.
  final Future<void> Function() onOpen;

  const HubItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onOpen,
  });
}

// ── Bottom navigation bar ────────────────────────────────────────────────────

/// Sounds · Tools · Games · Settings.
class SoundrNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const SoundrNavBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    NavigationDestination dest(IconData icon, IconData selected, String label) =>
        NavigationDestination(
          icon: Icon(icon, color: c.iconSecondary),
          selectedIcon: Icon(selected, color: accent),
          label: label,
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.borderSubtle)),
      ),
      child: NavigationBar(
        selectedIndex: selectedIndex,
        height: 66,
        backgroundColor: c.surfaceCard,
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.withValues(alpha: 0.18),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: onSelected,
        destinations: [
          dest(Icons.grid_view_outlined, Icons.grid_view_rounded, 'Sounds'),
          dest(Icons.handyman_outlined, Icons.handyman_rounded, 'Tools'),
          dest(Icons.sports_esports_outlined, Icons.sports_esports_rounded, 'Games'),
          dest(Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
        ],
      ),
    );
  }
}

// ── Tools tab ────────────────────────────────────────────────────────────────

class ToolsHub extends StatelessWidget {
  final HubItem zen;
  final List<HubItem> morse;
  final List<HubItem> tools;

  const ToolsHub({
    super.key,
    required this.zen,
    required this.morse,
    required this.tools,
  });

  @override
  Widget build(BuildContext context) {
    return _HubScaffold(
      title: 'Tools',
      children: [
        _HeroCard(item: zen),
        const _HubLabel('MORSE CODE'),
        _TileGrid(items: morse),
        const _HubLabel('AUDIO TOOLS'),
        _TileGrid(items: tools),
      ],
    );
  }
}

// ── Games tab ────────────────────────────────────────────────────────────────

/// Sound games with their personal bests, refreshed after every game.
class GamesHub extends StatefulWidget {
  final HubItem speedRound;
  final HubItem pairMatch;
  final List<HubItem> morseGames;

  const GamesHub({
    super.key,
    required this.speedRound,
    required this.pairMatch,
    required this.morseGames,
  });

  @override
  State<GamesHub> createState() => _GamesHubState();
}

class _GamesHubState extends State<GamesHub> {
  String? _speedBest;
  String? _pairBest;

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
    if (!mounted) return;
    setState(() {
      _speedBest = score == null ? null : '$score pts';
      _pairBest = pair;
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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
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

/// Big feature card — Zen Mode gets top billing on the Tools tab.
class _HeroCard extends StatelessWidget {
  final HubItem item;
  const _HeroCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: item.onOpen,
        child: Ink(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                item.color.withValues(alpha: 0.28),
                item.color.withValues(alpha: 0.06),
              ],
            ),
            border: Border.all(color: item.color.withValues(alpha: 0.35)),
          ),
          child: Row(children: [
            _IconBadge(icon: item.icon, color: item.color, size: 56),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      )),
                  const SizedBox(height: 4),
                  Text(item.subtitle,
                      style: TextStyle(
                          color: c.textSecondary, fontSize: 13, height: 1.35)),
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
