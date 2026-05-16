import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/scene_model.dart';
import '../models/sound_model.dart';

class ClipRepository {
  static Database? _db;

  static Future<Database> get _database async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(
      p.join(dbPath, 'clips.db'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE user_clips (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            filePath TEXT NOT NULL,
            category TEXT NOT NULL,
            emoji TEXT NOT NULL,
            trimStart REAL NOT NULL DEFAULT 0.0,
            trimEnd REAL NOT NULL DEFAULT 0.0,
            color INTEGER,
            createdAt INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE TABLE favorites (id TEXT PRIMARY KEY)',
        );
        await db.execute(
          'CREATE TABLE play_counts (id TEXT PRIMARY KEY, count INTEGER NOT NULL DEFAULT 0)',
        );
        await db.execute('''
          CREATE TABLE scenes (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            emoji TEXT NOT NULL,
            orderIndex INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE scene_sounds (
            scene_id TEXT NOT NULL,
            sound_id TEXT NOT NULL,
            orderIndex INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (scene_id, sound_id),
            FOREIGN KEY (scene_id) REFERENCES scenes(id) ON DELETE CASCADE
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'CREATE TABLE IF NOT EXISTS favorites (id TEXT PRIMARY KEY)',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE user_clips ADD COLUMN color INTEGER',
          );
          await db.execute(
            'CREATE TABLE IF NOT EXISTS play_counts (id TEXT PRIMARY KEY, count INTEGER NOT NULL DEFAULT 0)',
          );
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS scenes (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              emoji TEXT NOT NULL,
              orderIndex INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS scene_sounds (
              scene_id TEXT NOT NULL,
              sound_id TEXT NOT NULL,
              orderIndex INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (scene_id, sound_id)
            )
          ''');
        }
      },
      version: 4,
    );
  }

  // ── Clips ────────────────────────────────────────────────────────────────

  static Future<void> insert(SoundModel clip) async {
    final db = await _database;
    await db.insert(
      'user_clips',
      {
        'id': clip.id,
        'name': clip.name,
        'filePath': clip.filePath,
        'category': clip.category,
        'emoji': clip.emoji,
        'trimStart': clip.trimStart,
        'trimEnd': clip.trimEnd,
        'color': clip.customColor,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<SoundModel>> getAll() async {
    final db = await _database;
    final rows = await db.query('user_clips', orderBy: 'createdAt DESC');
    return rows
        .map(
          (row) => SoundModel(
            id: row['id'] as String,
            name: row['name'] as String,
            file: '',
            category: row['category'] as String,
            emoji: row['emoji'] as String,
            isUserClip: true,
            filePath: row['filePath'] as String,
            trimStart: (row['trimStart'] as num).toDouble(),
            trimEnd: (row['trimEnd'] as num).toDouble(),
            customColor: row['color'] as int?,
          ),
        )
        .toList();
  }

  static Future<void> update(SoundModel clip) async {
    final db = await _database;
    await db.update(
      'user_clips',
      {
        'name': clip.name,
        'category': clip.category,
        'emoji': clip.emoji,
        'trimStart': clip.trimStart,
        'trimEnd': clip.trimEnd,
        'color': clip.customColor,
      },
      where: 'id = ?',
      whereArgs: [clip.id],
    );
  }

  static Future<void> delete(String id, String filePath) async {
    final db = await _database;
    await db.delete('user_clips', where: 'id = ?', whereArgs: [id]);
    await db.delete('play_counts', where: 'id = ?', whereArgs: [id]);
    final file = File(filePath);
    if (await file.exists()) await file.delete();
  }

  // ── Favorites ────────────────────────────────────────────────────────────

  static Future<Set<String>> getFavorites() async {
    final db = await _database;
    final rows = await db.query('favorites');
    return rows.map((r) => r['id'] as String).toSet();
  }

  static Future<void> addFavorite(String id) async {
    final db = await _database;
    await db.insert(
      'favorites',
      {'id': id},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> removeFavorite(String id) async {
    final db = await _database;
    await db.delete('favorites', where: 'id = ?', whereArgs: [id]);
  }

  // ── Play counts ──────────────────────────────────────────────────────────

  static Future<Map<String, int>> getPlayCounts() async {
    final db = await _database;
    final rows = await db.query('play_counts');
    return {for (final r in rows) r['id'] as String: r['count'] as int};
  }

  static Future<void> incrementPlayCount(String id) async {
    final db = await _database;
    await db.rawInsert(
      'INSERT INTO play_counts (id, count) VALUES (?, 1) '
      'ON CONFLICT(id) DO UPDATE SET count = count + 1',
      [id],
    );
  }

  static Future<void> resetPlayCount(String id) async {
    final db = await _database;
    await db.delete('play_counts', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> resetAllPlayCounts() async {
    final db = await _database;
    await db.delete('play_counts');
  }

  // ── Scenes ───────────────────────────────────────────────────────────────

  static Future<List<SceneModel>> getScenes() async {
    final db = await _database;
    final rows = await db.query('scenes', orderBy: 'orderIndex ASC');
    return rows
        .map((r) => SceneModel(
              id: r['id'] as String,
              name: r['name'] as String,
              emoji: r['emoji'] as String,
              orderIndex: r['orderIndex'] as int,
            ))
        .toList();
  }

  static Future<SceneModel> createScene(String name, String emoji) async {
    final db = await _database;
    final count = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM scenes'),
        ) ??
        0;
    final id = 'scene_${DateTime.now().millisecondsSinceEpoch}';
    await db.insert('scenes', {
      'id': id,
      'name': name,
      'emoji': emoji,
      'orderIndex': count,
    });
    return SceneModel(id: id, name: name, emoji: emoji, orderIndex: count);
  }

  static Future<void> updateScene(SceneModel scene) async {
    final db = await _database;
    await db.update(
      'scenes',
      {'name': scene.name, 'emoji': scene.emoji},
      where: 'id = ?',
      whereArgs: [scene.id],
    );
  }

  static Future<void> deleteScene(String id) async {
    final db = await _database;
    await db.delete('scene_sounds', where: 'scene_id = ?', whereArgs: [id]);
    await db.delete('scenes', where: 'id = ?', whereArgs: [id]);
  }

  static Future<Set<String>> getSceneSoundIds(String sceneId) async {
    final db = await _database;
    final rows = await db.query(
      'scene_sounds',
      where: 'scene_id = ?',
      whereArgs: [sceneId],
      orderBy: 'orderIndex ASC',
    );
    return rows.map((r) => r['sound_id'] as String).toSet();
  }

  static Future<void> addSoundToScene(String sceneId, String soundId) async {
    final db = await _database;
    final count = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM scene_sounds WHERE scene_id = ?',
          [sceneId],
        )) ??
        0;
    await db.insert(
      'scene_sounds',
      {'scene_id': sceneId, 'sound_id': soundId, 'orderIndex': count},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> removeSoundFromScene(
      String sceneId, String soundId) async {
    final db = await _database;
    await db.delete(
      'scene_sounds',
      where: 'scene_id = ? AND sound_id = ?',
      whereArgs: [sceneId, soundId],
    );
  }

  static Future<void> removeSoundFromAllScenes(String soundId) async {
    final db = await _database;
    await db.delete(
      'scene_sounds',
      where: 'sound_id = ?',
      whereArgs: [soundId],
    );
  }
}
