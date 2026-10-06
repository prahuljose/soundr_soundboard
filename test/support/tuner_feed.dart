import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Streams samples to a widget as 16-bit PCM in ~23 ms chunks, pumping
/// the tester between chunks the way a live mic would.
Future<void> feed(
  WidgetTester tester,
  StreamController<Uint8List> mic,
  List<double> samples,
) async {
  const chunk = 1024;
  for (var i = 0; i < samples.length; i += chunk) {
    final end = (i + chunk).clamp(0, samples.length);
    final b = ByteData((end - i) * 2);
    for (var j = i; j < end; j++) {
      b.setInt16((j - i) * 2, (samples[j].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    mic.add(b.buffer.asUint8List());
    await tester.pump(const Duration(milliseconds: 23));
  }
}

List<double> silence(double seconds) =>
    List.filled((seconds * 44100).round(), 0.0);
