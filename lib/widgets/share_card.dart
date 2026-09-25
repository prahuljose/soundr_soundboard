import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../theme/app_colors.dart';

const soundrPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=com.soundr.app';

/// A branded, fixed-size (4:5) card for sharing a result — a game score or a
/// hearing check. It deliberately ignores the app theme so every shared card
/// looks the same, on brand, whatever the sender's settings.
class ShareCard extends StatelessWidget {
  static const size = Size(360, 450);

  final String eyebrow;
  final String emoji;
  final String value;
  final String unit;
  final String? badge;
  final List<String> stats;
  final String tagline;

  const ShareCard({
    super.key,
    required this.eyebrow,
    required this.emoji,
    required this.value,
    required this.unit,
    required this.tagline,
    this.badge,
    this.stats = const [],
  });

  static const _ink = Color(0xFF0D0820);
  static const _lavender = Color(0xFFC4B5FD);
  static const _lilac = Color(0xFFDDD6FE);

  @override
  Widget build(BuildContext context) {
    return SizedBox.fromSize(
      size: size,
      // Own Material so the text never picks up the "no Material ancestor"
      // debug underline, wherever the card is rendered.
      child: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF221248), _ink],
            ),
          ),
          child: Stack(
            children: [
              // Soft violet glow behind the headline number.
              Positioned(
                left: -60,
                top: 40,
                child: Container(
                  width: 480,
                  height: 300,
                  decoration: const BoxDecoration(
                    gradient: RadialGradient(
                      colors: [Color(0x557C3AED), Color(0x007C3AED)],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 26, 28, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const _LogoBars(),
                        const SizedBox(width: 10),
                        const Text(
                          'Soundr',
                          style: TextStyle(
                            fontFamily: 'Outfit',
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const Spacer(),
                        Text(emoji, style: const TextStyle(fontSize: 26)),
                      ],
                    ),
                    const Spacer(flex: 2),
                    Text(
                      eyebrow.toUpperCase(),
                      style: const TextStyle(
                        fontFamily: 'Outfit',
                        color: _lavender,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value,
                        style: const TextStyle(
                          fontFamily: 'Outfit',
                          color: Colors.white,
                          fontSize: 104,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -4,
                          height: 1.0,
                        ),
                      ),
                    ),
                    Text(
                      unit,
                      style: const TextStyle(
                        fontFamily: 'Outfit',
                        color: _lilac,
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFFFFC857,
                          ).withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(
                              0xFFFFC857,
                            ).withValues(alpha: 0.55),
                          ),
                        ),
                        child: Text(
                          badge!,
                          style: const TextStyle(
                            fontFamily: 'Outfit',
                            color: Color(0xFFFFD98A),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                    if (stats.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final s in stats)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: const Color(
                                    0xFFA78BFA,
                                  ).withValues(alpha: 0.45),
                                ),
                              ),
                              child: Text(
                                s,
                                style: const TextStyle(
                                  fontFamily: 'Outfit',
                                  color: _lilac,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    const Spacer(flex: 3),
                    Text(
                      tagline,
                      style: const TextStyle(
                        fontFamily: 'Outfit',
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Free on Google Play · Offline · No ads',
                      style: TextStyle(
                        fontFamily: 'Outfit',
                        color: _lavender.withValues(alpha: 0.75),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The five-bar Soundr mark, drawn with plain containers.
class _LogoBars extends StatelessWidget {
  const _LogoBars();

  static const _heights = [10.0, 16.0, 20.0, 16.0, 10.0];

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < _heights.length; i++) ...[
          if (i > 0) const SizedBox(width: 2.5),
          Container(
            width: 3.5,
            height: _heights[i],
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Color(0xFFA78BFA)],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Shows [card] in a bottom sheet with a Share button. Sharing renders the
/// card to a 1080×1350 PNG (Instagram's portrait size) and opens the system
/// share sheet with [shareText] as the caption.
Future<void> showShareCardSheet(
  BuildContext context, {
  required ShareCard card,
  required String shareText,
  required String fileName,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) =>
        _ShareCardSheet(card: card, shareText: shareText, fileName: fileName),
  );
}

class _ShareCardSheet extends StatefulWidget {
  final ShareCard card;
  final String shareText;
  final String fileName;

  const _ShareCardSheet({
    required this.card,
    required this.shareText,
    required this.fileName,
  });

  @override
  State<_ShareCardSheet> createState() => _ShareCardSheetState();
}

class _ShareCardSheetState extends State<_ShareCardSheet> {
  final _boundaryKey = GlobalKey();
  bool _busy = false;

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final boundary =
          _boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final dir = Directory('${(await getTemporaryDirectory()).path}/share');
      await dir.create(recursive: true);
      final file = File('${dir.path}/${widget.fileName}.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      await Share.shareXFiles([
        XFile(file.path, mimeType: 'image/png'),
      ], text: '${widget.shareText}\n$soundrPlayStoreUrl');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t create the image — try again'),
          ),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: c.handleBar,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.58,
              ),
              child: AspectRatio(
                aspectRatio: ShareCard.size.aspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: FittedBox(
                    child: RepaintBoundary(
                      key: _boundaryKey,
                      child: widget.card,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _busy ? null : _share,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.ios_share_rounded, size: 20),
                label: const Text(
                  'Share',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
