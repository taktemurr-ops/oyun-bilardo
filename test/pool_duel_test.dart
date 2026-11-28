import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oyun_bilardo/oyun_bilardo.dart';
import 'package:studio_core/app/game_api.dart';
import 'package:studio_core/core/game_rules.dart';
import 'package:studio_core/core/level_plan.dart';
import 'package:studio_core/core/rng.dart';
import 'package:studio_core/app/studio_ui.dart';

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

  List<Disc> rack(int n) {
    final b = <Disc>[];
    rackPool(b, level(n).meta.seed);
    return b;
  }

  test('8 top dizilimi: 15 top, 8 ortada, arka köşelerde bir düz bir çizgili', () {
    final b = rack(3);
    expect(b.length, 16);
    expect(b[0].id, 0);
    expect({for (final x in b.skip(1)) x.id}, {for (var i = 1; i <= 15; i++) i});
    expect(b[5].id, 8);
    expect({poolGroupOf(b[11].id), poolGroupOf(b[15].id)}, {0, 1});
    expect(poolLayout(rack(3)), poolLayout(b));
  });

  test('aynı atış aynı masada aynı sonucu verir (deterministik fizik)', () {
    for (final n in [1, 9, 33, 77]) {
      final a = rack(n), b = rack(n);
      final ra = resolvePoolShot(a, 1.5, -38.25), rb = resolvePoolShot(b, 1.5, -38.25);
      expect(rb.first, ra.first);
      expect(rb.ids, ra.ids);
      expect(ra.first, isNot(0));
      expect(poolLayout(b), poolLayout(a));
    }
  });

  test('atış hamlesi yazılır ve okunur', () {
    final balls = rack(4);
    final s = PoolShot(12.345678901234, -7.5, 480.5, 1200.25, 9, const [3, 0], poolLayout(balls));
    final d = PoolShot.decode(s.encode())!;
    expect(d.vx, s.vx);
    expect(d.vy, s.vy);
    expect(d.cx, 480.5);
    expect(d.cy, 1200.25);
    expect(d.first, 9);
    expect(d.ids, [3, 0]);
    expect(d.potted, 1);
    expect(d.scratch, isTrue);
    final copy = rack(4);
    expect(applyPoolLayout(copy, d.layout), isTrue);
    expect(poolLayout(copy), poolLayout(balls));
    expect(PoolShot.decode(PoolShot(1, 2, 3, 4, 0, const [], 'x').encode())!.ids, isEmpty);
    expect(PoolShot.decode('S:x|1|2|0|'), isNull);
    expect(PoolShot.decode('S:1|1|1|1|1|99|a'), isNull);
    expect(PoolShot.decode('çöp'), isNull);
  });

  group('8 top kuralları', () {
    List<Disc> table(List<int> ids) => [
          Disc(500, 1250, kPoolR, 1, 0),
          for (var i = 0; i < ids.length; i++) Disc(200 + i * 45.0, 700, kPoolR, 1, ids[i]),
        ];
    void pot(List<Disc> b, List<int> ids) {
      for (final x in b) {
        if (ids.contains(x.id)) x.live = false;
      }
    }

    test('beyaz cebe: faul, sıra ve elde top rakibe, beyaz masaya döner', () {
      final b = table([1, 2, 8, 9]);
      final m = PoolScore()..broken = true;
      pot(b, [0]);
      m.apply(0, const PoolOutcome(1, [0]), b);
      expect(m.turn, 1);
      expect(m.ballInHand, isTrue);
      expect(m.last, 'FOUL');
      expect(b[0].live, isTrue);
    });

    test('açılıştan sonra ilk sokuş grubu belirler; sokan yeniden atar', () {
      final b = table([1, 2, 8, 9, 10]);
      final m = PoolScore()..broken = true;
      pot(b, [10]);
      m.apply(1, const PoolOutcome(9, [10]), b);
      expect(m.groupOf(1), 1);
      expect(m.groupOf(0), 0);
      expect(m.turn, 1);
      expect(m.ballInHand, isFalse);
    });

    test('önce rakibin topuna değmek fauldür', () {
      final b = table([1, 2, 8, 9, 10]);
      final m = PoolScore()
        ..broken = true
        ..group0 = 0;
      m.apply(0, const PoolOutcome(9, []), b);
      expect(m.turn, 1);
      expect(m.ballInHand, isTrue);
    });

    test('8 erken girerse atan kaybeder, grup bitince girerse kazanır', () {
      final b = table([1, 8, 9]);
      final m = PoolScore()
        ..broken = true
        ..group0 = 0;
      pot(b, [8]);
      m.apply(0, const PoolOutcome(1, [8]), b);
      expect(m.winner, 1);

      final c = table([8, 9]);
      final n = PoolScore()
        ..broken = true
        ..group0 = 0;
      expect(n.onEight(c, 0), isTrue);
      expect(n.legalFirst(c, 0, 8), isTrue);
      expect(n.legalFirst(c, 0, 9), isFalse);
      pot(c, [8]);
      n.apply(0, const PoolOutcome(8, [8]), c);
      expect(n.winner, 0);
    });

    test('açılışta giren 8 yerine konur, maç sürer', () {
      final b = rack(2);
      final m = PoolScore();
      pot(b, [8]);
      m.apply(0, const PoolOutcome(5, [8]), b);
      expect(m.winner, -1);
      expect(b.firstWhere((x) => x.id == 8).live, isTrue);
    });

    test('süre dolunca faul', () {
      final m = PoolScore()..broken = true;
      m.timeout(1);
      expect(m.turn, 0);
      m.timeout(0);
      expect(m.turn, 1);
      expect(m.ballInHand, isTrue);
    });
  });

  test('iki cihaz bütün maç boyunca aynı masada ve aynı durumda kalır; maç biter', () {
    for (final n in [2, 15, 40]) {
      final dev = [rack(n), rack(n)];
      final score = [PoolScore(), PoolScore()];
      final rng = SeededRandom(n);
      var shots = 0;
      while (score[0].winner < 0 && shots < 500) {
        final shooter = score[0].turn;
        // Atan cihaz çözer, yuvarlanmış dizilimi yayınlar.
        final v = poolBotShot(dev[shooter], score[shooter], shooter, 10, rng);
        dev[shooter][0]
          ..x = v.$3
          ..y = v.$4
          ..live = true;
        final o = resolvePoolShot(dev[shooter], v.$1, v.$2);
        final layout = poolLayout(dev[shooter]);
        final msg = PoolShot(v.$1, v.$2, v.$3, v.$4, o.first, o.ids, layout).encode();
        applyPoolLayout(dev[shooter], layout);
        score[shooter].apply(shooter, o, dev[shooter]);
        // Karşı cihaz aynı atışı oynatır, sonra dizilime oturur.
        final other = 1 - shooter;
        final got = PoolShot.decode(msg)!;
        dev[other][0]
          ..x = got.cx
          ..y = got.cy
          ..live = true;
        resolvePoolShot(dev[other], got.vx, got.vy);
        applyPoolLayout(dev[other], got.layout);
        score[other].apply(shooter, got.outcome, dev[other]);
        expect(poolLayout(dev[other]), poolLayout(dev[shooter]));
        expect(score[other].turn, score[shooter].turn);
        expect(score[other].group0, score[shooter].group0);
        expect(score[other].ballInHand, score[shooter].ballInHand);
        shots++;
      }
      expect(shots, greaterThan(0));
      expect(score[0].winner, isNot(-1), reason: 'bölüm $n: $shots atışta bitmedi');
      expect(score[1].winner, score[0].winner);
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
    // Onaylı tasarım: degrade zemin ve koyu yarı saydam oyuncu hapları.
    expect(find.descendant(of: find.byType(PoolDuelView), matching: find.byType(StudioBackdrop)), findsOneWidget);
    for (final e in find.descendant(of: find.byType(PoolDuelView), matching: find.byType(RichText)).evaluate()) {
      final c = (e.widget as RichText).text.style?.color;
      if (c != null) expect(c.computeLuminance(), greaterThan(0.5));
    }
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
    final balls = <Disc>[];
    rackPool(balls, gl.puzzle.meta.seed);
    final o = resolvePoolShot(balls, 0.5, -38);
    link.ctrl.add((0, PoolShot(0.5, -38, 500, 1250, o.first, o.ids, poolLayout(balls)).encode()));
    for (var i = 0; i < 1300; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
