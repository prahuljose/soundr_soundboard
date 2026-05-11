import '../models/sound_model.dart';

class SoundsData {
  static const List<SoundModel> all = [
    SoundModel(id: 's1', name: 'Drum Hit',  file: 'drum_hit.wav',  category: 'Drums', emoji: '🥁', duration: 1),
    SoundModel(id: 's2', name: 'Snare',     file: 'snare.wav',     category: 'Drums', emoji: '🪘', duration: 1),
    // SoundModel(id: 's3', name: 'Hi-Hat',    file: 'hihat.mp3',     category: 'Drums', emoji: '🎵'),
    SoundModel(id: 's4', name: 'Kick',      file: 'kick.wav',      category: 'Drums', emoji: '💥', duration: 1),
    // SoundModel(id: 's5', name: 'Synth Lead',file: 'synth_lead.mp3',category: 'Synth', emoji: '🎹'),
    // SoundModel(id: 's6', name: 'Bass Drop', file: 'bass_drop.mp3', category: 'Synth', emoji: '🔊'),
    // SoundModel(id: 's7', name: 'Arp Up',    file: 'arp_up.mp3',    category: 'Synth', emoji: '🎶'),
    // SoundModel(id: 's8', name: 'Air Horn',  file: 'air_horn.mp3',  category: 'FX',    emoji: '📯'),
    // SoundModel(id: 's9', name: 'Clap',      file: 'clap.mp3',      category: 'FX',    emoji: '👏'),
    // SoundModel(id: 's10',name: 'Swoosh',    file: 'swoosh.mp3',    category: 'FX',    emoji: '💨'),
  ];

  static List<String> get categories =>
      ['All', ...{...all.map((s) => s.category)}];
}