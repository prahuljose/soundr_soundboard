import 'package:flutter/material.dart';

import '../data/sounds_data.dart';
import '../models/sound_model.dart';
import '../services/clip_repository.dart';
import '../services/haptics.dart';
import '../services/quick_sounds.dart';
import '../theme/app_colors.dart';

/// Settings → Home screen → Choose widget sounds.
///
/// Automatic keeps the favourites-first behaviour. Custom lets the user pick
/// up to [QuickSounds.maxSounds] sounds and drag them into order. Every change
/// is saved and pushed to the widget immediately.
class WidgetSoundsScreen extends StatefulWidget {
  const WidgetSoundsScreen({super.key});

  @override
  State<WidgetSoundsScreen> createState() => _WidgetSoundsScreenState();
}

class _WidgetSoundsScreenState extends State<WidgetSoundsScreen> {
  static const _max = QuickSounds.maxSounds;

  bool _loading = true;
  List<SoundModel> _all = [];
  Set<String> _favorites = {};
  Map<String, int> _plays = {};
  WidgetSoundsMode _mode = WidgetSoundsMode.automatic;
  List<String> _ids = [];

  Map<String, SoundModel> get _byId => {for (final s in _all) s.id: s};

  /// What the widget shows right now.
  List<SoundModel> get _showing => QuickSounds.pick(
        all: _all,
        favorites: _favorites,
        playCounts: _plays,
        mode: _mode,
        customIds: _ids,
      );

  /// Custom picks that still exist (a deleted clip drops out).
  List<SoundModel> get _custom =>
      _ids.map((id) => _byId[id]).whereType<SoundModel>().toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var clips = <SoundModel>[];
    try {
      clips = await ClipRepository.getAll();
      _favorites = await ClipRepository.getFavorites();
      _plays = await ClipRepository.getPlayCounts();
    } catch (_) {}
    final choice = await QuickSounds.loadChoice();
    if (!mounted) return;
    setState(() {
      _all = [...SoundsData.all, ...clips];
      _mode = choice.mode;
      _ids = [...choice.ids];
      _ids.removeWhere((id) => !_byId.containsKey(id));
      _loading = false;
    });
  }

  Future<void> _save() async {
    await QuickSounds.saveChoice(_mode, _ids);
    await QuickSounds.sync(all: _all, favorites: _favorites, playCounts: _plays);
  }

  void _setMode(WidgetSoundsMode mode) {
    if (mode == _mode) return;
    Haptics.selection();
    setState(() {
      // Start a fresh custom list from what the widget shows today.
      if (mode == WidgetSoundsMode.custom && _custom.isEmpty) {
        _ids = _showing.map((s) => s.id).toList();
      }
      _mode = mode;
    });
    _save();
  }

  void _remove(String id) {
    Haptics.selection();
    setState(() => _ids.remove(id));
    _save();
  }

  void _reorder(int from, int to) {
    setState(() {
      if (to > from) to -= 1;
      _ids.insert(to, _ids.removeAt(from));
    });
    _save();
  }

  Future<void> _openPicker() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SoundPicker(
        all: _all,
        favorites: _favorites,
        selected: _ids,
        max: _max,
        onToggle: (id) {
          setState(() {
            if (_ids.contains(id)) {
              _ids.remove(id);
            } else if (_ids.length < _max) {
              _ids.add(id);
            }
          });
          _save();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    final custom = _mode == WidgetSoundsMode.custom;
    final picks = _custom;

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: _ModeCard(
              icon: Icons.auto_awesome_rounded,
              title: 'Automatic',
              subtitle: 'Favourites first, then most played',
              selected: !custom,
              accent: accent,
              onTap: () => _setMode(WidgetSoundsMode.automatic),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ModeCard(
              icon: Icons.tune_rounded,
              title: 'Custom',
              subtitle: 'Your sounds, in your order',
              selected: custom,
              accent: accent,
              onTap: () => _setMode(WidgetSoundsMode.custom),
            ),
          ),
        ]),
        const _Label('PREVIEW'),
        _WidgetPreview(sounds: _showing),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'A one-row widget shows the first 4 · stretch it to two rows for all 8',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
        ),
        if (custom)
          _Label('YOUR SOUNDS · ${picks.length} OF $_max',
              trailing: picks.length > 1 ? 'Drag to reorder' : null)
        else
          const _Label('SHOWING NOW'),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('Widget sounds',
            style: TextStyle(
                color: c.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : custom
              ? ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  header: header,
                  buildDefaultDragHandles: false,
                  itemCount: picks.length,
                  onReorder: _reorder,
                  proxyDecorator: (child, _, _) => Material(
                    color: Colors.transparent,
                    elevation: 6,
                    shadowColor: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                    child: child,
                  ),
                  itemBuilder: (context, i) {
                    final s = picks[i];
                    return Padding(
                      key: ValueKey(s.id),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _SoundRow(
                        sound: s,
                        position: i + 1,
                        dimmed: i >= 4,
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: 'Remove ${s.name}',
                            icon: Icon(Icons.remove_circle_outline_rounded,
                                color: c.iconSecondary),
                            onPressed: () => _remove(s.id),
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
                              child: Icon(Icons.drag_handle_rounded,
                                  color: c.iconSecondary,
                                  semanticLabel: 'Drag to reorder'),
                            ),
                          ),
                        ]),
                      ),
                    );
                  },
                  footer: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(children: [
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: OutlinedButton.icon(
                          onPressed: _openPicker,
                          icon: Icon(picks.length < _max
                              ? Icons.add_rounded
                              : Icons.swap_horiz_rounded),
                          label: Text(
                            picks.length < _max ? 'Add sounds' : 'Change sounds',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: accent,
                            side: BorderSide(color: accent.withValues(alpha: 0.5)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                      ),
                      if (picks.isEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Until you add one, the widget stays on Automatic.',
                          style: TextStyle(color: c.textMuted, fontSize: 12),
                        ),
                      ],
                    ]),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  children: [
                    header,
                    for (final (i, s) in _showing.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _SoundRow(
                          sound: s,
                          position: i + 1,
                          dimmed: i >= 4,
                          trailing: _favorites.contains(s.id)
                              ? const Padding(
                                  padding: EdgeInsets.only(right: 12),
                                  child: Icon(Icons.star_rounded,
                                      color: Colors.amber, size: 20),
                                )
                              : null,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      'Star sounds on the soundboard to change these, or pick '
                      'them yourself:',
                      style: TextStyle(color: c.textMuted, fontSize: 12, height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 50,
                      child: OutlinedButton.icon(
                        onPressed: () => _setMode(WidgetSoundsMode.custom),
                        icon: const Icon(Icons.tune_rounded),
                        label: const Text('Customise this list',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: accent,
                          side: BorderSide(color: accent.withValues(alpha: 0.5)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

// ── Building blocks ──────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  final String? trailing;
  const _Label(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final style = TextStyle(
      color: c.textMuted,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
      child: Row(children: [
        Expanded(child: Text(text, style: style)),
        if (trailing != null)
          Text(trailing!,
              style: TextStyle(color: c.textMuted, fontSize: 11)),
      ]),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $subtitle',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 112,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.12)
                : c.surfaceCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? accent : c.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: selected ? accent : c.iconSecondary, size: 22),
                const Spacer(),
                Text(title,
                    style: TextStyle(
                      color: selected ? accent : c.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    )),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(color: c.textMuted, fontSize: 12, height: 1.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A sound in the list: position badge, emoji, name and category.
class _SoundRow extends StatelessWidget {
  final SoundModel sound;
  final int position;

  /// Rows 5–8 only show on a two-row widget, so they're drawn a little muted.
  final bool dimmed;
  final Widget? trailing;

  const _SoundRow({
    required this.sound,
    required this.position,
    required this.dimmed,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      height: 60,
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Row(children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: dimmed
                ? c.surfaceElevated.withValues(alpha: 0.7)
                : accent.withValues(alpha: 0.18),
            shape: BoxShape.circle,
          ),
          child: Text('$position',
              style: TextStyle(
                color: dimmed ? c.textMuted : accent,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              )),
        ),
        const SizedBox(width: 12),
        Text(sound.emoji, style: const TextStyle(fontSize: 22)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sound.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  )),
              Text(sound.category,
                  style: TextStyle(color: c.textMuted, fontSize: 12)),
            ],
          ),
        ),
        ?trailing,
      ]),
    );
  }
}

/// A look-alike of the native widget (widget_quick_sounds.xml): same card,
/// tiles and two-row rule, so what you see here is what you get.
class _WidgetPreview extends StatelessWidget {
  final List<SoundModel> sounds;
  const _WidgetPreview({required this.sounds});

  @override
  Widget build(BuildContext context) {
    Widget row(List<SoundModel> items, {bool pad = false}) => Row(children: [
          for (final s in items)
            Expanded(
              child: Container(
                height: 62,
                margin: const EdgeInsets.all(3),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: const Color(0xFFA78BFA).withValues(alpha: 0.25)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(s.emoji, style: const TextStyle(fontSize: 20)),
                    const SizedBox(height: 3),
                    Text(s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xE6FFFFFF),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                        )),
                  ],
                ),
              ),
            ),
          if (pad)
            for (var i = items.length; i < 4; i++) const Expanded(child: SizedBox()),
        ]);

    return Semantics(
      label: 'Widget preview: ${sounds.map((s) => s.name).join(', ')}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF221248), Color(0xFF0D0820)],
            ),
          ),
          child: Column(children: [
            row(sounds.take(4).toList()),
            if (sounds.length > 4)
              row(sounds.skip(4).take(4).toList(), pad: true),
          ]),
        ),
      ),
    );
  }
}

/// Searchable list of every sound (favourites first). Tapping toggles a sound
/// in or out of the custom list; changes apply live.
class _SoundPicker extends StatefulWidget {
  final List<SoundModel> all;
  final Set<String> favorites;
  final List<String> selected;
  final int max;
  final ValueChanged<String> onToggle;

  const _SoundPicker({
    required this.all,
    required this.favorites,
    required this.selected,
    required this.max,
    required this.onToggle,
  });

  @override
  State<_SoundPicker> createState() => _SoundPickerState();
}

class _SoundPickerState extends State<_SoundPicker> {
  String _query = '';

  List<SoundModel> get _results {
    final q = _query.trim().toLowerCase();
    final matches = widget.all.where((s) =>
        q.isEmpty ||
        s.name.toLowerCase().contains(q) ||
        s.category.toLowerCase().contains(q));
    final chosen = widget.selected.toSet();
    return [
      ...widget.selected
          .map((id) => matches.where((s) => s.id == id).firstOrNull)
          .whereType<SoundModel>(),
      ...matches.where(
          (s) => !chosen.contains(s.id) && widget.favorites.contains(s.id)),
      ...matches.where(
          (s) => !chosen.contains(s.id) && !widget.favorites.contains(s.id)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    final full = widget.selected.length >= widget.max;
    final results = _results;

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: c.handleBar,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
            child: Row(children: [
              Expanded(
                child: Text(
                  'Pick up to ${widget.max}  ·  ${widget.selected.length} chosen',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              cursorColor: accent,
              decoration: InputDecoration(
                hintText: 'Search sounds…',
                prefixIcon: Icon(Icons.search_rounded, color: c.iconSecondary),
                filled: true,
                fillColor: c.surfaceElevated.withValues(alpha: 0.5),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (full)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text(
                'That’s ${widget.max} — untick one to swap it for another.',
                style: TextStyle(color: c.textMuted, fontSize: 12),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
              itemCount: results.length,
              itemBuilder: (context, i) {
                final s = results[i];
                final chosen = widget.selected.contains(s.id);
                final enabled = chosen || !full;
                return ListTile(
                  enabled: enabled,
                  onTap: () {
                    Haptics.selection();
                    widget.onToggle(s.id);
                    setState(() {});
                  },
                  leading: Text(s.emoji, style: const TextStyle(fontSize: 22)),
                  title: Text(s.name,
                      style: TextStyle(
                        color: enabled ? c.textPrimary : c.textMuted,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      )),
                  subtitle: Text(
                    widget.favorites.contains(s.id)
                        ? '★  ${s.category}'
                        : s.category,
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                  trailing: Icon(
                    chosen
                        ? Icons.check_circle_rounded
                        : Icons.add_circle_outline_rounded,
                    color: chosen ? accent : c.iconSecondary,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
