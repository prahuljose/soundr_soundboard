import '../models/sound_model.dart';

class SoundsData {
  static const List<SoundModel> all = [
    SoundModel(id: 's1',  name: 'Drum Hit',        file: 'drum_hit.wav',          category: 'Instruments', emoji: '🥁'),
    SoundModel(id: 's2',  name: 'Snare',           file: 'snare.wav',             category: 'Instruments', emoji: '🪘'),
    // SoundModel(id: 's3',  name: 'Hi-Hat',          file: 'hihat.mp3',             category: 'Instruments', emoji: '🎵'),
    SoundModel(id: 's4',  name: 'Kick',            file: 'kick.wav',              category: 'Instruments', emoji: '💥'),
    // SoundModel(id: 's5',  name: 'Synth Lead',      file: 'synth_lead.mp3',        category: 'Instruments', emoji: '🎹'),
    // SoundModel(id: 's6',  name: 'Bass Drop',       file: 'bass_drop.mp3',         category: 'Instruments', emoji: '🔊'),
    // SoundModel(id: 's7',  name: 'Arp Up',          file: 'arp_up.mp3',            category: 'Instruments', emoji: '🎶'),
    // SoundModel(id: 's8',  name: 'Air Horn',        file: 'air_horn.mp3',          category: 'Instruments', emoji: '📯'),
    // SoundModel(id: 's9',  name: 'Clap',            file: 'clap.mp3',              category: 'Instruments', emoji: '👏'),
    // SoundModel(id: 's10', name: 'Swoosh',          file: 'swoosh.mp3',            category: 'Instruments', emoji: '💨'),

    SoundModel(id: 's11', name: 'F***in',          file: 'fuckin.wav',            category: 'Memes',      emoji: '🤬'),
    SoundModel(id: 's12', name: 'Goofy Car Horn',  file: 'goofy_car_horn.wav',    category: 'Memes',      emoji: '🚗'),
    SoundModel(id: 's13', name: 'Hello There',     file: 'hello_there.wav',       category: 'Memes',      emoji: '👋'),
    SoundModel(id: 's14', name: 'Isn’t That Amazing', file: 'isnt_that_amazing.wav', category: 'Reactions', emoji: '✨'),
    SoundModel(id: 's15', name: 'My God',          file: 'my_god.wav',            category: 'Reactions',  emoji: '😲'),
    SoundModel(id: 's16', name: 'Short Cough',     file: 'short_cough_noise.wav', category: 'Effects',    emoji: '😷'),
    SoundModel(id: 's17', name: 'UI Click',        file: 'ui_click.wav',          category: 'UI',         emoji: '🖱️'),
    SoundModel(id: 's18', name: 'Whip',            file: 'whip.wav',              category: 'Effects',    emoji: '💥'),
    SoundModel(id: 's19', name: 'Woman Calling Dog', file: 'woman_calling_dog.wav', category: 'Memes',    emoji: '🐶'),
    SoundModel(id: 's20', name: 'Yeah Boy',        file: 'yeah_boy.wav',          category: 'Memes',      emoji: '🔥'),

    SoundModel(id: 's21', name: 'Android Notification', file: 'android_notification.wav', category: 'UI',       emoji: '📱'),
    SoundModel(id: 's22', name: 'Augh',            file: 'augh.wav',              category: 'Reactions',  emoji: '😩'),
    SoundModel(id: 's23', name: 'Bad To The Bone', file: 'bad_to_the_bone.wav',   category: 'Music',      emoji: '💀'),
    SoundModel(id: 's24', name: 'Bomboclat',       file: 'bomboclat.wav',         category: 'Memes',      emoji: '💣'),
    SoundModel(id: 's25', name: 'Bonk',            file: 'bonk.wav',              category: 'Memes',      emoji: '🔨'),
    SoundModel(id: 's26', name: 'Correct Buzzer',  file: 'correct_buzzer.wav',    category: 'UI',         emoji: '✅'),
    SoundModel(id: 's27', name: 'Daddy Chill',     file: 'daddy_chill.wav',       category: 'Memes',      emoji: '🧊'),
    SoundModel(id: 's28', name: 'Discord',         file: 'discord.wav',           category: 'UI',         emoji: '🎮'),
    SoundModel(id: 's29', name: 'Eagle',           file: 'eagle.wav',             category: 'Animals',    emoji: '🦅'),
    SoundModel(id: 's30', name: 'Emotional Damage', file: 'emotional_damage.wav', category: 'Memes',      emoji: '💔'),

    SoundModel(id: 's31', name: 'Erm What The Sigma', file: 'erm_what_the_sigma.wav', category: 'Memes',  emoji: '🤨'),
    SoundModel(id: 's32', name: 'Fail',            file: 'fail.wav',              category: 'Reactions',  emoji: '❌'),
    SoundModel(id: 's33', name: 'Get Out',         file: 'get_out.wav',           category: 'Reactions',  emoji: '🚪'),
    SoundModel(id: 's34', name: 'Holy Moly',       file: 'holy_moly.wav',         category: 'Reactions',  emoji: '😮'),
    SoundModel(id: 's35', name: 'Huh',             file: 'huh.wav',               category: 'Reactions',  emoji: '❓'),
    SoundModel(id: 's36', name: 'Laugh',           file: 'laugh.wav',             category: 'Reactions',  emoji: '😂'),
    SoundModel(id: 's37', name: 'Lego',            file: 'lego.wav',              category: 'Memes',      emoji: '🧱'),
    SoundModel(id: 's38', name: 'Meme',            file: 'meme.wav',              category: 'Memes',      emoji: '🤣'),
    SoundModel(id: 's39', name: 'Radio Beep',      file: 'radio_beep.wav',        category: 'Effects',    emoji: '📻'),
    SoundModel(id: 's40', name: 'Rizz',            file: 'rizz.wav',              category: 'Memes',      emoji: '😎'),

    SoundModel(id: 's41', name: 'Taco Bell Bell',  file: 'taco_bell_bell.wav',    category: 'Memes',      emoji: '🔔'),
    SoundModel(id: 's42', name: 'Two Hours Later', file: 'two_hours_later.wav',   category: 'Memes',      emoji: '⏳'),
    SoundModel(id: 's43', name: 'UI Click Deep',   file: 'ui_click_deep.wav',     category: 'UI',         emoji: '🖲️'),
    SoundModel(id: 's44', name: 'UI Click Soft',   file: 'ui_click_soft.wav',     category: 'UI',         emoji: '👆'),
    SoundModel(id: 's45', name: 'UI Success Chime', file: 'ui_success_chime.wav', category: 'UI',         emoji: '✨'),
    SoundModel(id: 's46', name: 'UWU',             file: 'uwu.wav',               category: 'Memes',      emoji: '🥺'),
    SoundModel(id: 's47', name: 'Vine Boom',       file: 'vine_boom.wav',         category: 'Memes',      emoji: '💥'),
    SoundModel(id: 's48', name: 'Why Are You Gay', file: 'why_are_you_gay.wav',   category: 'Memes',      emoji: '🤔'),
    SoundModel(id: 's49', name: 'Wow',             file: 'wow.wav',               category: 'Reactions',  emoji: '😮'),
    SoundModel(id: 's50', name: 'Yippee',          file: 'yippee.wav',            category: 'Reactions',  emoji: '🎉'),

    SoundModel(id: 's51', name: 'Bruh',        file: 'bruh.wav',        category: 'Memes',     emoji: '💀'),

    //SoundModel(id: 's52', name: 'Bonk Alert',  file: 'bonk.wav',        category: 'Memes',     emoji: '🔨'),

    SoundModel(id: 's53', name: 'Alert',       file: 'alert.wav',       category: 'Effects',   emoji: '🚨'),

    SoundModel(id: 's54', name: 'Baba Booey',  file: 'baba_booey.wav',  category: 'Memes',     emoji: '📢'),

    SoundModel(id: 's55', name: 'Based',       file: 'based.wav',       category: 'Memes',     emoji: '🗿'),
  ]

  ;

  static List<String> get categories =>
      ['All', ...{...all.map((s) => s.category)}];
}