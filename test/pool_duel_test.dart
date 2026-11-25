import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oyun_bilardo/oyun_bilardo.dart';
import 'package:studio_core/app/game_api.dart';
import 'package:studio_core/core/game_rules.dart';
import 'package:studio_core/core/level_plan.dart';
import 'package:studio_core/core/rng.dart';

class FakeLink implements MatchLink {
  @override
  final int mySeat;
  @override
  final List<(int, String)> history;
  final StreamController<(int, String)> ctrl = StreamController.broadcast();
  final List<String> sent = [];
  @override
  final Set<int> dropped = {};
  int? winner;
  FakeLink(this.mySeat, {this.history = const []});
  @override
  int get seed => 5;
  @override
  List<String> get names => const ['A', 'B'];
  @override
  bool get isHost => mySeat == 0;
  @override
  Stream<(int, String)> get moves => ctrl.stream;
  @override
  Future<void> send(String move, {int? asSeat}) async => sent.add(move);
  @override
  Future<void> finish(int winner, {bool? iWon}) async => this.winner = winner;
}

PlayContext ctxFor(GeneratedLevel gl, List<RoundResult> out, {FakeLink? link}) => PlayContext(
      spec: gl.spec,
      generated: gl,
      resume: const {},
      pieceColors: const [Color(0xFF3E6FB0), Color(0xFFC8553D)],
      background: const [Color(0xFF203040), Color(0xFF304050)],
      colorBlind: false,
      reducedMotion: false,
      leftHanded: false,
      lang: 'tr',
      t: (k, [p = const {}]) => k,
      finish: out.add,
      saveResume: (_) {},
      requestHint: () async => true,
      requestBooster: () async => true,
      requestContinue: () async => false,
      sfx: (_) {},
      seats: link == null ? const [] : [for (var i = 0; i < 2; i++) i == link.mySeat ? SeatRole.local : SeatRole.remote],
      match: link,
    );

void main() {
  final rules = PoolRules();
  final planner = LevelPlanner(gameId: rules.gameId, optionalMechanics: rules.optionalMechanics);
  ShotLevel level(int n) => rules.build(planner.spec(n)).puzzle;

  test('iki kişilik: bilgisayara karşı ve çevrimiçi masa açık', () {
    expect(rules.localPlayers, 2);
  });

  test('aynı atış aynı masada aynı sonucu verir (deterministik fizik)', () {
    for (final n in [1, 9, 33, 77]) {
      final a = PoolSim(level(n)).balls, b = PoolSim(level(n)).balls;
      final ra = resolvePoolShot(a, 21.5, -30.25), rb = resolvePoolShot(b, 21.5, -30.25);
      expect(rb, ra);
      expect(poolLayout(b), poolLayout(a));
    }
  });

  test('atış hamlesi yazılır ve okunur', () {
    final balls = PoolSim(level(4)).balls;
    final s = PoolShot(12.345678901234, -7.5, 2, true, poolLayout(balls));
    final d = PoolShot.decode(s.encode())!;
    expect(d.vx, s.vx);
    expect(d.vy, s.vy);
    expect(d.potted, 2);
    expect(d.foul, isTrue);
    final copy = PoolSim(level(4)).balls;
    expect(applyPoolLayout(copy, d.layout), isTrue);
    expect(poolLayout(copy), poolLayout(balls));
    expect(PoolShot.decode('S:x|1|2|0|'), isNull);
    expect(PoolShot.decode('çöp'), isNull);
  });

  test('iki cihaz bütün maç boyunca aynı masada ve aynı puanda kalır', () {
    for (final n in [2, 15, 40]) {
      final dev = [PoolSim(level(n)).balls, PoolSim(level(n)).balls];
      final score = [PoolScore(), PoolScore()];
      final rng = SeededRandom(n);
      var shots = 0;
      while (dev[0].skip(1).any((b) => b.live) && shots < 400) {
        final shooter = score[0].turn;
        // Atan cihaz çözer, yuvarlanmış dizilimi yayınlar.
        final v = poolBotShot(dev[shooter], 6, rng);
        final (p, f) = resolvePoolShot(dev[shooter], v.$1, v.$2);
        final layout = poolLayout(dev[shooter]);
        final msg = PoolShot(v.$1, v.$2, p, f, layout).encode();
        applyPoolLayout(dev[shooter], layout);
        // Karşı cihaz aynı atışı oynatır, sonra dizilime oturur.
        final other = 1 - shooter;
        final got = PoolShot.decode(msg)!;
        resolvePoolShot(dev[other], got.vx, got.vy);
        applyPoolLayout(dev[other], got.layout);
        for (final s in score) {
          s.apply(shooter, got.potted, got.foul);
        }
        expect(poolLayout(dev[other]), poolLayout(dev[shooter]));
        shots++;
      }
      expect(shots, greaterThan(0));
      expect(score[1].score, score[0].score);
      expect(score[1].turn, score[0].turn);
      final left = dev[0].skip(1).where((b) => b.live).length;
      expect(score[0].score[0] + score[0].score[1], dev[0].length - 1 - left);
    }
  });

  testWidgets('bilgisayara karşı: bot oynar, ekran hata vermez', (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final gl = rules.build(planner.spec(3));
    final out = <RoundResult>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: bilardoConfig.buildPlay(ctxFor(gl, out)))));
    expect(find.byType(PoolDuelView), findsOneWidget);
    // Nişan al ve vur.
    final c = tester.getCenter(find.byType(CustomPaint).last);
    final g = await tester.startGesture(c);
    await g.moveBy(const Offset(0, 120));
    await g.up();
    for (var i = 0; i < 600 && out.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('çevrimiçi: rakibin atışı gelir, masa onun dizilimine oturur', (tester) async {
    final gl = rules.build(planner.run(GameModeId.online, 5, difficulty: 4));
    final link = FakeLink(1);
    final out = <RoundResult>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: bilardoConfig.buildPlay(ctxFor(gl, out, link: link)))));
    final balls = PoolSim(gl.puzzle).balls;
    final (p, f) = resolvePoolShot(balls, 0.5, -38);
    link.ctrl.add((0, PoolShot(0.5, -38, p, f, poolLayout(balls)).encode()));
    for (var i = 0; i < 1300; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
