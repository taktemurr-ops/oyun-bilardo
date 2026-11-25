import 'package:studio_core/core/arcade.dart';
import 'package:studio_core/core/level_plan.dart';
import 'package:studio_core/core/missions.dart';
import 'package:studio_core/core/stats.dart';
import 'shot_engine.dart';

class PoolRules extends ArcadeRules<ShotLevel> {
  @override
  String get gameId => 'oyun-bilardo';

  @override
  List<String> get optionalMechanics => const [];

  /// İki kişilik: "Bilgisayara karşı" ve "Çevrimiçi masa" (sırayla atış).
  @override
  int get localPlayers => 2;

  @override
  List<GameStat> get gameStats => const [
        GameStat('balls_potted', 'Cebe giren top', 'Balls potted', scale: 300),
        GameStat('racks_cleared', 'Temizlenen masa', 'Racks cleared', scale: 30),
        GameStat('shots_taken', 'Yapılan atış', 'Shots taken', scale: 300),
        GameStat('best_run', 'En uzun seri', 'Best run', scale: 10),
      ];

  @override
  List<MissionTemplate> get missionTemplates => const [
        MissionTemplate('balls_potted', 'balls_potted', [75, 150, 300]),
        MissionTemplate('racks_cleared', 'racks_cleared', [3, 7, 15], coinReward: 80),
      ];

  @override
  ShotLevel generate(LevelSpec spec) => generateShot(ShotKind.billiards, spec);

  @override
  ArcadeMeta metaOf(ShotLevel l) => l.meta;

  @override
  ArcadeSim createSim(ShotLevel l) => ShotSim(l);

  @override
  ArcadeInput bot(ArcadeSim sim) => shotBot(sim);
}

ArcadeRules createRules() => PoolRules();
