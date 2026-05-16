class SceneModel {
  final String id;
  final String name;
  final String emoji;
  final int orderIndex;

  const SceneModel({
    required this.id,
    required this.name,
    required this.emoji,
    required this.orderIndex,
  });

  SceneModel copyWith({String? name, String? emoji}) => SceneModel(
        id: id,
        name: name ?? this.name,
        emoji: emoji ?? this.emoji,
        orderIndex: orderIndex,
      );
}
