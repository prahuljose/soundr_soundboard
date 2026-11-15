import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/metronome_presets.dart';

void main() {
  group('click schedule', () {
    List<ClickKind> bar(int beats, MetronomeSubdivision sub, {int bars = 1}) => [
      for (var t = 0; t < beats * sub.clicksPerBeat * bars; t++)
        clickKindAt(t, beatsPerBar: beats, clicksPerBeat: sub.clicksPerBeat),
    ];
    const a = ClickKind.accent, b = ClickKind.beat, s = ClickKind.sub;

    test('no subdivision: accent on one, beats after', () {
      expect(bar(4, MetronomeSubdivision.none, bars: 2), [a, b, b, b, a, b, b, b]);
      expect(bar(3, MetronomeSubdivision.none), [a, b, b]);
    });

    test('eighths, triplets and sixteenths fill between beats', () {
      expect(bar(2, MetronomeSubdivision.eighths), [a, s, b, s]);
      expect(bar(3, MetronomeSubdivision.triplets), [a, s, s, b, s, s, b, s, s]);
      expect(bar(4, MetronomeSubdivision.sixteenths),
          [a, s, s, s, b, s, s, s, b, s, s, s, b, s, s, s]);
    });

    test('6/8: six eighth-note beats, each one split', () {
      final k = bar(6, MetronomeSubdivision.eighths, bars: 2);
      expect(k.length, 24);
      expect(k.where((c) => c == a).length, 2);
      expect(k.where((c) => c == b).length, 10);
      expect(k[12], a);
    });

    test('beatAt follows the bar', () {
      expect([
        for (var t = 0; t < 10; t++) beatAt(t, beatsPerBar: 3, clicksPerBeat: 2),
      ], [0, 0, 1, 1, 2, 2, 0, 0, 1, 1]);
    });

    test('click times never drift, even at 240 BPM in sixteenths', () {
      // 16 clicks a second: 62.5 ms apart, which whole milliseconds can't hold.
      expect(clickTimeMicros(1, bpm: 240, clicksPerBeat: 4), 62500);
      expect(clickTimeMicros(16 * 600, bpm: 240, clicksPerBeat: 4), 600 * 1000000);
      // 140 BPM: 428.571… ms per beat; ten minutes later still exact.
      expect(clickTimeMicros(1400, bpm: 140, clicksPerBeat: 1), 600 * 1000000);
      expect(clickTimeMicros(3, bpm: 140, clicksPerBeat: 3), 428571);
      // Monotonic, evenly spaced to the microsecond.
      for (var t = 1; t < 2000; t++) {
        final gap = clickTimeMicros(t, bpm: 173, clicksPerBeat: 3) -
            clickTimeMicros(t - 1, bpm: 173, clicksPerBeat: 3);
        expect(gap, inInclusiveRange(115606, 115608));
      }
    });
  });

  group('MetronomeSetup', () {
    test('round-trips', () {
      const s = MetronomeSetup(
          bpm: 87, beatsPerBar: 6, subdivision: MetronomeSubdivision.triplets);
      expect(decodeSetup(encodeSetup(s)), s);
      expect(s.summary, '87 BPM · 6/8 · triplets');
      expect(const MetronomeSetup().summary, '120 BPM · 4/4');
    });

    test('repairs out-of-range values', () {
      expect(decodeSetup('{"bpm": 999, "beats": 5, "sub": 7}'),
          const MetronomeSetup(bpm: 240));
      expect(decodeSetup('{"bpm": 12.4}'), const MetronomeSetup(bpm: 40));
      expect(decodeSetup('{"bpm": 99.6, "beats": 3, "sub": 2}'),
          const MetronomeSetup(
              bpm: 100, beatsPerBar: 3, subdivision: MetronomeSubdivision.eighths));
    });

    test('unreadable input gives null', () {
      for (final bad in [null, '', 'nope', '[]', '{"bpm": "fast"}', '{"beats": 4}', '{']) {
        expect(decodeSetup(bad), isNull, reason: '$bad');
      }
    });
  });

  group('presets', () {
    test('round-trip keeps order, names and setups', () {
      final presets = [
        const MetronomePreset(name: 'Wonderwall – 87', setup: MetronomeSetup(bpm: 87)),
        const MetronomePreset(
            name: '',
            setup: MetronomeSetup(
                bpm: 152, beatsPerBar: 3, subdivision: MetronomeSubdivision.sixteenths)),
      ];
      final back = decodePresets(encodePresets(presets));
      expect(back.map((p) => p.name), ['Wonderwall – 87', '']);
      expect(back.map((p) => p.setup), presets.map((p) => p.setup));
      expect(back[0].title, 'Wonderwall – 87');
      expect(back[1].title, '152 BPM');
    });

    test('bad JSON is an empty list, bad entries are skipped', () {
      for (final bad in [null, '', '{', 'null', '{"a":1}', '42']) {
        expect(decodePresets(bad), isEmpty, reason: '$bad');
      }
      final mixed = decodePresets(
          '[{"name":"ok","bpm":90,"beats":4,"sub":1}, 3, "x", {"name":"no bpm"}, '
          '{"name":7,"bpm":300,"beats":"4"}]');
      expect(mixed.length, 2);
      expect(mixed[0].name, 'ok');
      expect(mixed[1].name, '');
      expect(mixed[1].setup, const MetronomeSetup(bpm: 240));
    });

    test('caps the list and the name length', () {
      final many = [
        for (var i = 0; i < 30; i++)
          MetronomePreset(name: 'p$i', setup: MetronomeSetup(bpm: 60 + i)),
      ];
      final back = decodePresets(encodePresets(many));
      expect(back.length, kMetronomeMaxPresets);
      expect(back.last.name, 'p19');

      expect(cleanPresetName('  Take   Five \n'), 'Take Five');
      expect(cleanPresetName('x' * 80).length, kMetronomePresetNameMax);
      expect(const MetronomePreset(name: 'a', setup: MetronomeSetup()).renamed('  b ').name, 'b');
    });
  });

  test('memory store reads back what it wrote', () async {
    final store = MemoryMetronomeStore();
    expect(await store.read(MetronomeStore.presetsKey), isNull);
    await store.write(MetronomeStore.presetsKey, '[]');
    expect(await store.read(MetronomeStore.presetsKey), '[]');
  });
}
