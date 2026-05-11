import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import '../data/sounds_data.dart';
import '../models/sound_model.dart';
import '../widgets/sound_button.dart';

class SoundboardScreen extends StatefulWidget {
  const SoundboardScreen({super.key});

  @override
  State<SoundboardScreen> createState() => _SoundboardScreenState();
}

class _SoundboardScreenState extends State<SoundboardScreen> {
  final Map<String, AudioSource> _preloaded = {};
  String _selectedCategory = 'All';
  bool _ready = true;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  Future<void> _initAudio() async {
    await SoLoud.instance.init();
    for (final sound in SoundsData.all) {
      _preloaded[sound.id] =
      await SoLoud.instance.loadAsset('assets/sounds/raw/${sound.file}');
    }
    setState(() => _ready = true);
  }

  @override
  void dispose() {
    SoLoud.instance.deinit();
    super.dispose();
  }

  void _play(SoundModel sound) {
    final source = _preloaded[sound.id];
    if (source != null) SoLoud.instance.play(source); // fire & forget
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
            onPressed: () => SoLoud.instance.stopAll(),
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

extension on SoLoud {
  void stopAll() {}
}