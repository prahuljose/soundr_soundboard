import '../models/sound_model.dart';

class SoundsData {
  static const List<SoundModel> all = [
    SoundModel(id: 's1',  name: 'Drum Hit',        file: 'drum_hit.wav',          category: 'Instruments', emoji: '🥁'),
    SoundModel(id: 's2',  name: 'Snare',           file: 'snare.wav',             category: 'Instruments', emoji: '🪘'),
    SoundModel(id: 's3',  name: 'Hi-Hat',          file: 'hi_hat.mp3',             category: 'Instruments', emoji: '🎵'),
    SoundModel(id: 's4',  name: 'Kick',            file: 'kick.wav',              category: 'Instruments', emoji: '💥'),
    SoundModel(id: 's5',  name: 'Synth Lead',      file: 'synth_lead.mp3',        category: 'Instruments', emoji: '🎹'),
    //SoundModel(id: 's6',  name: 'Bass Drop',       file: 'bass_drop.mp3',         category: 'Instruments', emoji: '🔊'),
    SoundModel(id: 's7',  name: 'Arp Up',          file: 'arp_up.mp3',            category: 'Instruments', emoji: '🎶'),
    // SoundModel(id: 's8',  name: 'Air Horn',        file: 'air_horn.mp3',          category: 'Instruments', emoji: '📯'),
    SoundModel(id: 's9',  name: 'Single Clap',            file: 'single_clap.mp3',              category: 'Instruments', emoji: '👏'),
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

    SoundModel(id: 's56', name: 'Amogus',                 file: 'amogus.wav',                         category: 'Memes',      emoji: '🧑‍🚀'),
    SoundModel(id: 's57', name: 'Anita Max Wynn Drake',  file: 'anita_max_wynn_drake.wav',          category: 'Memes',      emoji: '🎤'),
    SoundModel(id: 's58', name: 'Cat Laugh Meme',        file: 'cat_laugh_meme.wav',                category: 'Animals',    emoji: '🐱'),
    SoundModel(id: 's59', name: 'Fire In The Hole',      file: 'fire_in_the_hole.wav',              category: 'Gaming',     emoji: '🔥'),
    SoundModel(id: 's60', name: 'Game Over Mario',       file: 'game_over_super_mario.wav',         category: 'Gaming',     emoji: '🎮'),

    SoundModel(id: 's61', name: 'Goku Prowler',          file: 'goku_prowler.wav',                  category: 'Anime',      emoji: '⚡'),
    SoundModel(id: 's62', name: 'Goofy',                 file: 'goofy.wav',                          category: 'Memes',      emoji: '🤪'),
    SoundModel(id: 's63', name: 'Gunshot',               file: 'gunshot.wav',                        category: 'Effects',    emoji: '🔫'),
    SoundModel(id: 's64', name: 'Heheha Clash Royale',   file: 'hehehe_ha_clash_royale.wav',        category: 'Gaming',     emoji: '👑'),
    SoundModel(id: 's65', name: 'I’m In Danger',         file: 'im_in_danger.wav',                  category: 'Memes',      emoji: '😬'),

    SoundModel(id: 's66', name: 'Ferris Wheel Shape',    file: 'im_not_shaped_like_a_ferris_wheel.wav', category: 'Memes', emoji: '🎡'),
    SoundModel(id: 's67', name: 'Lego Yoda Death',       file: 'lego_yoda_death.wav',               category: 'Memes',      emoji: '🟩'),
    SoundModel(id: 's68', name: 'Lie Detector Wrong',    file: 'lie_detector_wrong.wav',            category: 'Effects',    emoji: '🚨'),
    SoundModel(id: 's69', name: 'Minecraft Cave',        file: 'minecraft_cave_noise.wav',          category: 'Gaming',     emoji: '⛏️'),
    SoundModel(id: 's70', name: 'No God Please No',      file: 'no_god_no_please_god.wav',          category: 'Memes',      emoji: '🙅'),

    SoundModel(id: 's71', name: 'Nom Nom Nom',           file: 'nom_nom_nom.wav',                   category: 'Memes',      emoji: '🍔'),
    SoundModel(id: 's72', name: 'Pluh',                  file: 'pluh.wav',                           category: 'Memes',      emoji: '🫤'),
    SoundModel(id: 's73', name: 'Pornhub Intro',         file: 'pornhub_intro.wav',                 category: 'Memes',      emoji: '🟧'),
    SoundModel(id: 's74', name: 'Romantic',              file: 'romantic.wav',                       category: 'Music',      emoji: '❤️'),
    SoundModel(id: 's75', name: 'Shut Up',               file: 'shut_up.wav',                        category: 'Reactions',  emoji: '🤫'),

    SoundModel(id: 's76', name: 'Spit On That Thang',    file: 'spit_on_that_thang.wav',            category: 'Memes',      emoji: '🗣️'),
    SoundModel(id: 's77', name: 'Spongebob',             file: 'spongebob.wav',                      category: 'Cartoons',   emoji: '🧽'),
    SoundModel(id: 's78', name: 'W In The Chat Drake',   file: 'w_in_the_chat_drake.wav',           category: 'Memes',      emoji: '🏆'),
    SoundModel(id: 's79', name: 'What Are You Doing',    file: 'what_are_you_doing_step_bro.wav',   category: 'Memes',      emoji: '🤨'),
    SoundModel(id: 's80', name: 'Why Are You Running',   file: 'why_are_you_running.wav',           category: 'Memes',      emoji: '🏃'),

    SoundModel(id: 's81', name: 'Windows USB Sound',     file: 'windows_10_usb_sound.wav',          category: 'UI',         emoji: '💻'),

    // ── Effects ───────────────────────────────────────────────────────────
    SoundModel(id: 's82',  name: 'Construction Box',       file: 'construction_tool_box.wav',             category: 'Effects',  emoji: '🔨'),
    SoundModel(id: 's83',  name: 'Crumpled Paper',         file: 'crumpled_paper.wav',                    category: 'Effects',  emoji: '📄'),
    SoundModel(id: 's84',  name: 'Clinking Coins',         file: 'clinking_coins.wav',                    category: 'Effects',  emoji: '💰'),
    SoundModel(id: 's85',  name: 'Alarm Tone',             file: 'alarm_tone.wav',                        category: 'Effects',  emoji: '🚨'),
    SoundModel(id: 's86',  name: 'Martial Arts Punch',     file: 'martial_arts_fast_punch.wav',           category: 'Effects',  emoji: '🥊'),
    SoundModel(id: 's87',  name: 'Laser Thunder',          file: 'cinematic_laser_gun_thunder.wav',       category: 'Effects',  emoji: '⚡'),
    SoundModel(id: 's88',  name: 'Arrow Whoosh',           file: 'arrow_whoosh.wav',                      category: 'Effects',  emoji: '🏹'),
    SoundModel(id: 's89',  name: 'Air Woosh',              file: 'air_woosh.wav',                         category: 'Effects',  emoji: '💨'),

    // ── Gaming ────────────────────────────────────────────────────────────
    SoundModel(id: 's90',  name: 'Treasure Collect',       file: 'video_game_treasure.wav',               category: 'Gaming',   emoji: '💎'),
    SoundModel(id: 's91',  name: 'Coin Win',               file: 'winning_a_coin_video_game.wav',         category: 'Gaming',   emoji: '🪙'),
    SoundModel(id: 's92',  name: 'Retro Notification',     file: 'retro_game_notification.wav',           category: 'Gaming',   emoji: '🕹️'),

    // ── Animals ───────────────────────────────────────────────────────────
    SoundModel(id: 's93',  name: 'Cricket Screech',        file: 'single_cricket_screech.wav',            category: 'Animals',  emoji: '🦗'),
    SoundModel(id: 's94',  name: 'Lion Roar',              file: 'wild_lion_animal_roar.wav',             category: 'Animals',  emoji: '🦁'),
    SoundModel(id: 's95',  name: 'Horse Neigh',            file: 'scared_horse_neighing.wav',             category: 'Animals',  emoji: '🐴'),
    SoundModel(id: 's96',  name: 'Rooster Crow',           file: 'rooster_crowing_in_the_morning.wav',    category: 'Animals',  emoji: '🐓'),
    SoundModel(id: 's97',  name: 'Cockatoo Squawk',        file: 'cockatoo_bird_squawk.wav',              category: 'Animals',  emoji: '🦜'),
    SoundModel(id: 's98',  name: 'Fish Splash',            file: 'fish_moving_in_water.wav',              category: 'Animals',  emoji: '🐟'),
    SoundModel(id: 's99',  name: 'Beast Roar',             file: 'aggressive_beast_roar.wav',             category: 'Animals',  emoji: '👹'),

    // ── Cartoons ──────────────────────────────────────────────────────────
    SoundModel(id: 's100', name: 'No No No',               file: 'cartoon_girl_saying_no_no_no.wav',      category: 'Cartoons', emoji: '🙅'),
    SoundModel(id: 's101', name: 'Sad Party Horn',         file: 'cartoon_sad_party_horn.wav',            category: 'Cartoons', emoji: '🎺'),
    SoundModel(id: 's102', name: 'Clown Horn',             file: 'clown_horn_at_circus.wav',              category: 'Cartoons', emoji: '🤡'),
    SoundModel(id: 's103', name: 'Toy Whistle',            file: 'cartoon_toy_whistle.wav',               category: 'Cartoons', emoji: '🎵'),

    // ── Reactions ─────────────────────────────────────────────────────────
    SoundModel(id: 's104', name: 'Loud Snore',             file: 'man_strong_snore.wav',                  category: 'Reactions', emoji: '😴'),
    SoundModel(id: 's105', name: 'Gibberish Talk',         file: 'little_boy_gibberish_talk.wav',         category: 'Reactions', emoji: '🗣️'),
    SoundModel(id: 's106', name: 'Woman Coughing',         file: 'sick_woman_coughing.wav',               category: 'Reactions', emoji: '😷'),
    SoundModel(id: 's107', name: 'Throat Clear',           file: 'male_clearing_the_throat.wav',          category: 'Reactions', emoji: '🤧'),
    SoundModel(id: 's108', name: 'Man Coughing',           file: 'young_man_coughing.wav',                category: 'Reactions', emoji: '🤒'),
    SoundModel(id: 's109', name: 'Baby Sneeze',            file: 'little_baby_sneeze.wav',                category: 'Reactions', emoji: '🤧'),
    SoundModel(id: 's110', name: 'Crowd Applause',         file: 'small_crowd_laugh_and_applause.wav',    category: 'Reactions', emoji: '👏'),
    SoundModel(id: 's111', name: 'Man Sneeze',             file: 'sick_man_sneeze.wav',                   category: 'Reactions', emoji: '🤧'),
    SoundModel(id: 's112', name: 'Gasp',                   file: 'female_astonished_gasp.wav',            category: 'Reactions', emoji: '😱'),
    SoundModel(id: 's113', name: 'Crowd Laugh',            file: 'crowd_laugh.wav',                       category: 'Reactions', emoji: '😂'),

    // ── New batch ─────────────────────────────────────────────────────────────
    SoundModel(id: 's114', name: 'Air Horn',              file: 'airhorn.mp3',                           category: 'Memes',     emoji: '📯'),
    SoundModel(id: 's115', name: 'Angels Singing',        file: 'angels_singing.mp3',                    category: 'Music',     emoji: '😇'),
    SoundModel(id: 's116', name: 'Audience Awww',         file: 'audience_awwww.mp3',                    category: 'Reactions', emoji: '🥺'),
    SoundModel(id: 's117', name: 'Ba Dum Tss',            file: 'ba_dun_tss.mp3',                        category: 'Memes',     emoji: '🥁'),
    SoundModel(id: 's118', name: 'Big Explosion',         file: 'big_explosion.mp3',                     category: 'Effects',   emoji: '💥'),
    SoundModel(id: 's119', name: 'Cartoon Boing',         file: 'cartoon_boing.mp3',                     category: 'Cartoons',  emoji: '🌀'),
    SoundModel(id: 's120', name: 'Cartoon Dizzy',         file: 'cartoon_dizzy.mp3',                     category: 'Cartoons',  emoji: '💫'),
    SoundModel(id: 's121', name: 'Cartoon Running',       file: 'cartoon_running.mp3',                   category: 'Cartoons',  emoji: '🏃'),
    SoundModel(id: 's122', name: 'Cartoon Spring',        file: 'cartoon_spring.mp3',                    category: 'Cartoons',  emoji: '🪝'),
    SoundModel(id: 's123', name: 'Censored Beep',         file: 'censored_beep.mp3',                     category: 'Memes',     emoji: '🔇'),
    SoundModel(id: 's124', name: 'Clock Ticking',         file: 'clock_ticking.mp3',                     category: 'Effects',   emoji: '⏰'),
    SoundModel(id: 's125', name: 'Crickets Chirping',     file: 'crickets_chirping.mp3',                 category: 'Animals',   emoji: '🦗'),
    SoundModel(id: 's126', name: 'Crowd Booing',          file: 'crowd_booing.mp3',                      category: 'Reactions', emoji: '👎'),
    SoundModel(id: 's127', name: 'Disappointed Spongebob', file: 'disappointed_spongebob.mp3',           category: 'Cartoons',  emoji: '🧽'),
    SoundModel(id: 's128', name: 'Dramatic Boom',         file: 'dramatic_boom.mp3',                     category: 'Effects',   emoji: '🎭'),
    SoundModel(id: 's129', name: 'Dreaming',              file: 'dreaming.mp3',                          category: 'Music',     emoji: '💭'),
    SoundModel(id: 's130', name: 'Drum Roll',             file: 'drum_roll.mp3',                         category: 'Instruments', emoji: '🥁'),
    SoundModel(id: 's131', name: 'Dun Dun Duuun',         file: 'dun_dun_duuuun.mp3',                   category: 'Memes',     emoji: '😱'),
    SoundModel(id: 's132', name: 'FBI Open Up',           file: 'fbi_open_up.mp3',                       category: 'Memes',     emoji: '🚔'),
    SoundModel(id: 's133', name: 'Flashback',             file: 'flashback.mp3',                         category: 'Effects',   emoji: '✨'),
    SoundModel(id: 's134', name: 'Heartbeat',             file: 'heartbeat.mp3',                         category: 'Effects',   emoji: '❤️'),
    SoundModel(id: 's135', name: 'Heartbeat 2',           file: 'heartbeat_1.mp3',                       category: 'Effects',   emoji: '💗'),
    SoundModel(id: 's136', name: 'Kissing',               file: 'kissing.mp3',                           category: 'Reactions', emoji: '💋'),
    SoundModel(id: 's137', name: 'Nioce',                 file: 'nioce.mp3',                             category: 'Memes',     emoji: '👌'),
    SoundModel(id: 's138', name: 'Record Scratch',        file: 'record_scratch_wut.mp3',                category: 'Memes',     emoji: '📀'),
    SoundModel(id: 's139', name: 'Rubber Duck',           file: 'rubber_duck_sound.mp3',                 category: 'Memes',     emoji: '🦆'),
    SoundModel(id: 's140', name: 'Rubber Duckie',         file: 'rubber_duckie_quack.mp3',               category: 'Memes',     emoji: '🛁'),
    SoundModel(id: 's141', name: 'Sad Piano',             file: 'sad_piano.mp3',                         category: 'Music',     emoji: '🎹'),
    SoundModel(id: 's142', name: 'Slapping',              file: 'slapping.mp3',                          category: 'Effects',   emoji: '🤚'),
    SoundModel(id: 's143', name: 'Wah Wah',               file: 'wah_wah.mp3',                           category: 'Cartoons',  emoji: '😢'),
    SoundModel(id: 's144', name: 'Water Drip',            file: 'water_droplet_drip.mp3',                category: 'Effects',   emoji: '💧'),
    SoundModel(id: 's145', name: 'Windows XP Error',      file: 'windows_xp_error.mp3',                  category: 'UI',        emoji: '🖥️'),
    SoundModel(id: 's146', name: 'Windows XP Shutdown',   file: 'windows_xp_shutdown.mp3',               category: 'UI',        emoji: '💻'),
    SoundModel(id: 's147', name: 'Yeehaw',                file: 'yeehaww.mp3',                           category: 'Memes',     emoji: '🤠'),
    SoundModel(id: 's148', name: 'Morse Dot',                file: 'morse_dot.wav',                           category: 'Morse',     emoji: '⏺️'),
    SoundModel(id: 's149', name: 'Morse Dash',                file: 'morse_dash.wav',                           category: 'Morse',     emoji: '⏹️'),
  ]

  ;

  static List<String> get categories =>
      ['All', ...{...all.map((s) => s.category)}];
}