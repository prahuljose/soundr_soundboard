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
  final Map<String, double> _durations = {};

  //late double duration;
  int _stopSignal = 0;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  Future<void> _initAudio() async {
    await SoLoud.instance.init();

    for (final sound in SoundsData.all) {
      final bytes = await rootBundle.load('assets/sounds/raw/${sound.file}');

      final source = await SoLoud.instance.loadMem(
        sound.file,
        bytes.buffer.asUint8List(),
      );

      _preloaded[sound.id] = source;

      final duration = await SoLoud.instance.getLength(source);

      _durations[sound.id] = duration.inMilliseconds / 1000;
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

  Future<void> _stopAll() async {
    for (final handle in _activeHandles.toList()) {
      final valid = SoLoud.instance.getIsValidVoiceHandle(handle);

      if (valid) {
        await SoLoud.instance.stop(handle);
      }
    }
    setState(() {
      _stopSignal++;
    });

    _activeHandles.clear();
  }

  List<SoundModel> get _filtered => _selectedCategory == 'All'
      ? SoundsData.all
      : SoundsData.all.where((s) => s.category == _selectedCategory).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      //floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      // floatingActionButton: Padding(
      //   padding: const EdgeInsets.only(bottom: 260),
      //   child: GestureDetector(
      //     onTap: _stopAll,
      //     child: AnimatedContainer(
      //       duration: const Duration(milliseconds: 180),
      //       width: 58,
      //       height: 58,
      //       decoration: BoxDecoration(
      //         color: const Color(0xFF1B1B1B)
      //             .withOpacity(0.92),
      //         borderRadius: BorderRadius.circular(18),
      //         border: Border.all(
      //           color: Colors.redAccent
      //               .withOpacity(0.35),
      //         ),
      //         boxShadow: [
      //           BoxShadow(
      //             color: Colors.redAccent
      //                 .withOpacity(0.18),
      //             blurRadius: 18,
      //             spreadRadius: 1,
      //           ),
      //         ],
      //       ),
      //       child: const Icon(
      //         Icons.stop_rounded,
      //         color: Colors.redAccent,
      //         size: 28,
      //       ),
      //     ),
      //   ),
      // ),
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E0E),

        surfaceTintColor: Colors.transparent,

        scrolledUnderElevation: 0,

        elevation: 0,
        title: const Text(
          'Soundr Soundboard',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: -0.4,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.stop_circle_outlined, color: Colors.white),
            tooltip: 'Stop all',
            onPressed: () async => await _stopAll(),
          ),
        ],
      ),
      body: _ready
          ? Column(
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
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 0.95,
                        ),
                    itemCount: _filtered.length,
                    itemBuilder: (context, i) => SoundButton(
                      sound: _filtered[i],

                      duration: _durations[_filtered[i].id] ?? 0,

                      stopSignal: _stopSignal,

                      onTap: () => _play(_filtered[i]),
                    ),
                  ),
                ),
                const SizedBox(height: 15),
              ],
            )
          : const Center(child: CircularProgressIndicator(color: Colors.white)),
    );
  }
}
