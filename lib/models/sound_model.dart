class SoundModel {
  final String id;
  final String name;
  final String file;
  final String category;
  final String emoji;
  final bool isUserClip;
  final String? filePath;
  final double trimStart;
  final double trimEnd;
  // Optional custom accent color (stored as ARGB int). Null = use category default.
  final int? customColor;

  const SoundModel({
    required this.id,
    required this.name,
    required this.file,
    required this.category,
    required this.emoji,
    this.isUserClip = false,
    this.filePath,
    this.trimStart = 0.0,
    this.trimEnd = 0.0,
    this.customColor,
  });

  double get trimDuration => trimEnd - trimStart;

  SoundModel copyWith({
    String? name,
    String? category,
    String? emoji,
    double? trimStart,
    double? trimEnd,
    int? customColor,
    bool clearColor = false,
  }) {
    return SoundModel(
      id: id,
      name: name ?? this.name,
      file: file,
      category: category ?? this.category,
      emoji: emoji ?? this.emoji,
      isUserClip: isUserClip,
      filePath: filePath,
      trimStart: trimStart ?? this.trimStart,
      trimEnd: trimEnd ?? this.trimEnd,
      customColor: clearColor ? null : (customColor ?? this.customColor),
    );
  }
}
