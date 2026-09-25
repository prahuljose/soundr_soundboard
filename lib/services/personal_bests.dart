import 'clip_repository.dart';

/// Saved personal bests for the sound games, stored in the settings table.
/// Reads return null when there's no record yet (or the DB is unavailable).
class PersonalBests {
  PersonalBests._();

  static const _kSpeedScore = 'best_speed_round_score';
  static const _kSpeedStreak = 'best_speed_round_streak';

  static Future<int?> speedRoundScore() => _read(_kSpeedScore);
  static Future<int?> speedRoundStreak() => _read(_kSpeedStreak);

  /// Records a finished Speed Round. Returns true if [score] is a new best.
  static Future<bool> recordSpeedRound({
    required int score,
    required int streak,
  }) async {
    final best = await speedRoundScore();
    final bestStreak = await speedRoundStreak();
    if (bestStreak == null || streak > bestStreak) {
      await _write(_kSpeedStreak, streak);
    }
    if (score > 0 && (best == null || score > best)) {
      await _write(_kSpeedScore, score);
      return true;
    }
    return false;
  }

  /// Pair Match bests are per difficulty (`easy`, `medium`, `hard`).
  static Future<({int? seconds, int? moves})> pairMatch(String difficulty) async =>
      (
        seconds: await _read('best_pair_${difficulty}_seconds'),
        moves: await _read('best_pair_${difficulty}_moves'),
      );

  /// Records a won Pair Match game. Returns which records it beat.
  static Future<({bool time, bool moves})> recordPairMatch({
    required String difficulty,
    required int seconds,
    required int moves,
  }) async {
    final best = await pairMatch(difficulty);
    final newTime = best.seconds == null || seconds < best.seconds!;
    final newMoves = best.moves == null || moves < best.moves!;
    if (newTime) await _write('best_pair_${difficulty}_seconds', seconds);
    if (newMoves) await _write('best_pair_${difficulty}_moves', moves);
    return (time: newTime, moves: newMoves);
  }

  static Future<int?> _read(String key) async {
    try {
      return await ClipRepository.getInt(key);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _write(String key, int value) async {
    try {
      await ClipRepository.setInt(key, value);
    } catch (_) {}
  }
}
