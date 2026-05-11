import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import '../data/sounds_data.dart';
import '../models/sound_model.dart';
import '../widgets/sound_button.dart';
import 'package:flutter/services.dart';

class SoundboardScreen extends StatefulWidget {
  const SoundboardScreen({super.key});

  @override
  State<SoundboardScreen> createState() => _SoundboardScreenState();
}

class _SoundboardScreenState extends State<SoundboardScreen> {
  final Map<String, AudioSource> _preloaded = {};
  String _selectedCategory = 'All';
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  Future<void> _initAudio() async {
    await SoLoud.instance.init();

    for (final sound in SoundsData.all) {
      final bytes = await rootBundle.load(
        'assets/sounds/raw/${sound.file}',
      );

      _preloaded[sound.id] =
      await SoLoud.instance.loadMem(
        sound.file,
        bytes.buffer.asUint8List(),
      );
    }

    if (!mounted) return;

    setState(() => _ready = true);
  }

  @override
  void dispose() {
    SoLoud.instance.deinit();
    super.dispose();
  }
  final List<SoundHandle> _activeHandles = [];

  Future<void> _play(SoundModel sound) async {
    final source = _preloaded[sound.id];

    if (source != null) {
      final handle = await SoLoud.instance.play(source);
      _activeHandles.add(handle);
    }
  }

  void _stopAll() {

    for (final handle in _activeHandles) {

      SoLoud.instance.stop(handle);

    }

    _activeHandles.clear();

  }

  List<SoundModel> get _filtered => _selectedCategory == 'All'
      ? SoundsData.all
      : SoundsData.all.where((s) => s.category == _selectedCategory).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E0E),
        elevation: 0,
        title: const Text(
          'Soundr',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.stop_circle_outlined, color: Colors.white),
            tooltip: 'Stop all',
            onPressed: () => _stopAll,
          ),
        ],
      ),
      body: _ready ? Column(
        children: [
          // Category tabs
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: SoundsData.categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final cat = SoundsData.categories[i];
                final active = cat == _selectedCategory;
                return GestureDetector(
                  onTap: () => setState(() => _selectedCategory = cat),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    decoration: BoxDecoration(
                      color: active ? Colors.white : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: active ? Colors.white : Colors.white24,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      cat,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: active ? Colors.black : Colors.white60,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          // Sound grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 0.95,
              ),
              itemCount: _filtered.length,
              itemBuilder: (context, i) => SoundButton(
                sound: _filtered[i],
                onTap: () => _play(_filtered[i]),
              ),
            ),
          ),
        ],
      )
          : const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}

