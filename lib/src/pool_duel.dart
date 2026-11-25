import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:studio_core/app/game_api.dart';
import 'package:studio_core/app/services/audio.dart';
import 'package:studio_core/core/arcade.dart';
import 'package:studio_core/core/game_rules.dart';
import 'package:studio_core/core/rng.dart';
import 'package:studio_core/core/strings.dart';

import 'shot_engine.dart';
import 'shot_view.dart';

/// İki kişilik bilardo: aynı masada sırayla atış. Cebe top sokan (beyazı
/// sokmadan) yeniden atar; masa bitince çok top sokan kazanır.
///
/// Çevrimiçi eşitleme: atışı yapan cihaz atışı kendi masasında çözer, sonucu
/// tek hamlede gönderir: "S:<vx>|<vy>|<sokulan>|<faul>|<son dizilim>". Karşı
/// cihaz aynı hızla atışı canlandırır, sonra gönderenin (2 basamağa
/// yuvarlanmış) son dizilimine oturur; gönderen de aynı yuvarlanmış dizilime
/// oturduğu için iki masa her atıştan sonra birebir aynıdır.
class PoolShot {
  final double vx, vy;
  final int potted;
  final bool foul;
  final String layout;
  const PoolShot(this.vx, this.vy, this.potted, this.foul, this.layout);

  String encode() => 'S:$vx|$vy|$potted|${foul ? 1 : 0}|$layout';

  static PoolShot? decode(String m) {
    if (!m.startsWith('S:')) return null;
    final p = m.substring(2).split('|');
    if (p.length != 5) return null;
    final vx = double.tryParse(p[0]), vy = double.tryParse(p[1]), n = int.tryParse(p[2]);
    if (vx == null || vy == null || n == null || !vx.isFinite || !vy.isFinite) return null;
    return PoolShot(vx, vy, n, p[3] == '1', p[4]);
  }
}

/// Masanın kısa yazımı: "x,y,canlı;…" (top sırasıyla, 2 basamak).
String poolLayout(List<Disc> balls) =>
    [for (final b in balls) '${b.x.toStringAsFixed(2)},${b.y.toStringAsFixed(2)},${b.live ? 1 : 0}'].join(';');

/// Yazılı dizilimi masaya uygula (hızlar sıfırlanır). Bozuksa false.
bool applyPoolLayout(List<Disc> balls, String layout) {
  final parts = layout.split(';');
  if (parts.length != balls.length) return false;
  final parsed = <(double, double, bool)>[];
  for (final p in parts) {
    final f = p.split(',');
    if (f.length != 3) return false;
    final x = double.tryParse(f[0]), y = double.tryParse(f[1]);
    if (x == null || y == null) return false;
    parsed.add((x, y, f[2] == '1'));
  }
  for (var i = 0; i < balls.length; i++) {
    final b = balls[i];
    b
      ..x = parsed[i].$1
      ..y = parsed[i].$2
      ..live = parsed[i].$3
      ..vx = 0
      ..vy = 0;
  }
  return true;
}

/// Bir atışın en çok adım sayısı (iki cihazda aynı).
const kPoolMaxSteps = 1200;

/// Faulden sonra beyaz top başlangıç noktasına (diğer toplardan uzağa) konur.
void respotCue(List<Disc> balls) {
  final c = balls[0];
  c
    ..live = true
    ..vx = 0
    ..vy = 0
    ..x = 500
    ..y = 1250;
  for (var k = 0; k < 20; k++) {
    if (balls.skip(1).every((b) => !b.live || math.pow(b.x - c.x, 2) + math.pow(b.y - c.y, 2) > 45 * 45)) break;
    c.x = 220 + (k * 97) % 560;
  }
}

/// Atışın hızı: istaka açısı ve gücünden (tek oyunculu bilardoyla aynı).
(double, double) poolVelocity(double angle, double power) {
  final sp = 3 + power * 37;
  return (math.cos(angle) * sp, math.sin(angle) * sp);
}

/// Atışı baştan sona çöz (canlandırmasız). Döner: (sokulan, faul).
(int, bool) resolvePoolShot(List<Disc> balls, double vx, double vy) {
  balls[0]
    ..vx = vx
    ..vy = vy;
  var potted = 0;
  var foul = false;
  for (var t = 0; t < kPoolMaxSteps; t++) {
    final moving = PoolSim.stepTable(balls, (b) {
      if (b.id == 0) {
        foul = true;
      } else {
        potted++;
      }
    });
    if (!moving) break;
  }
  for (final b in balls) {
    b
      ..vx = 0
      ..vy = 0;
  }
  if (foul) respotCue(balls);
  return (potted, foul);
}

/// Bilgisayar rakibi: cebe girecek topları seçip birkaç adayı dener.
/// [d] 1..10: yüksek zorlukta daha az sapma.
(double, double) poolBotShot(List<Disc> balls, int d, SeededRandom r) {
  final cue = balls[0];
  final cands = <(double, double, double)>[]; // açı, maliyet, mesafe
  for (final b in balls.skip(1)) {
    if (!b.live) continue;
    for (final pk in kPockets) {
      final dx = pk[0] - b.x, dy = pk[1] - b.y;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < 1) continue;
      final gx = b.x - dx / dist * kPoolR * 2, gy = b.y - dy / dist * kPoolR * 2;
      final ax = gx - cue.x, ay = gy - cue.y;
      final al = math.sqrt(ax * ax + ay * ay);
      if (al < 1) continue;
      final cut = math.acos(((ax * dx + ay * dy) / (al * dist)).clamp(-1.0, 1.0));
      if (cut > 1.3) continue;
      cands.add((math.atan2(ay, ax), cut * 400 + dist + al * 0.5, al + dist));
    }
  }
  cands.sort((a, b) => a.$2.compareTo(b.$2));
  var bestScore = -1e9;
  var best = (0.0, 0.0);
  for (final c in cands.take(6)) {
    for (final pw in const [0.4, 0.62, 0.85]) {
      final copy = [for (final b in balls) b.copy()];
      final v = poolVelocity(c.$1, pw);
      final (n, foul) = resolvePoolShot(copy, v.$1, v.$2);
      final s = n * 10 - (foul ? 25 : 0) - pw;
      if (s > bestScore) {
        bestScore = s;
        best = (c.$1, pw);
      }
    }
  }
  if (cands.isEmpty) {
    // Doğrudan en yakın topa vur.
    Disc? near;
    var nd = 1e18;
    for (final b in balls.skip(1)) {
      if (!b.live) continue;
      final dd = math.pow(b.x - cue.x, 2) + math.pow(b.y - cue.y, 2);
      if (dd < nd) {
        nd = dd.toDouble();
        near = b;
      }
    }
    best = near == null ? (-math.pi / 2, 0.6) : (math.atan2(near.y - cue.y, near.x - cue.x), 0.6);
  }
  final dd = d < 1 ? 1 : (d > 10 ? 10 : d);
  final noise = (11 - dd) * 0.011;
  final angle = best.$1 + (r.nextDouble() - r.nextDouble()) * noise;
  final power = clampD(best.$2 + (r.nextDouble() - 0.5) * noise, 0.2, 1.0);
  return poolVelocity(angle, power);
}

/// Maç durumu: puanlar ve sıra (masa toplarıyla birlikte iki cihazda aynı).
class PoolScore {
  final List<int> score = [0, 0];
  int turn = 0;

  /// Atıştan sonra: sokup faul yapmayan yeniden atar.
  void apply(int shooter, int potted, bool foul) {
    score[shooter] += potted;
    turn = potted > 0 && !foul ? shooter : 1 - shooter;
  }
}

const _tYou = ['Sen', 'You', 'Du', 'Tú', 'Vous', 'أنت', 'تو', 'את/ה', 'آپ', 'Вы', 'Ви', 'Ty', 'Ty', 'Tu', 'Te', 'Εσύ', 'Tu', 'Você', 'Jij', 'Du', 'Du', 'Du', 'Sinä', 'あなた', '나', '你', 'आप', 'আপনি', 'Kamu', 'Anda', 'คุณ', 'Bạn', 'Ikaw'];
const _tRival = ['Rakip', 'Rival', 'Gegner', 'Rival', 'Rival', 'الخصم', 'حریف', 'יריב', 'حریف', 'Соперник', 'Суперник', 'Rywal', 'Soupeř', 'Rival', 'Ellenfél', 'Αντίπαλος', 'Rivale', 'Rival', 'Tegenstander', 'Motståndare', 'Modstander', 'Motstander', 'Vastustaja', '相手', '상대', '对手', 'प्रतिद्वंद्वी', 'প্রতিদ্বন্দ্বী', 'Lawan', 'Lawan', 'คู่แข่ง', 'Đối thủ', 'Kalaban'];
const _tYourTurn = ['Senin sıran', 'Your turn', 'Du bist dran', 'Tu turno', 'À vous', 'دورك', 'نوبت توست', 'תורך', 'آپ کی باری', 'Ваш ход', 'Ваш хід', 'Twój ruch', 'Jsi na tahu', 'Rândul tău', 'Te jössz', 'Σειρά σου', 'Tocca a te', 'Sua vez', 'Jouw beurt', 'Din tur', 'Din tur', 'Din tur', 'Sinun vuorosi', 'あなたの番', '내 차례', '轮到你了', 'आपकी बारी', 'তোমার পালা', 'Giliranmu', 'Giliran anda', 'ตาของคุณ', 'Lượt của bạn', 'Iyong turno'];
const _tRivalTurn = ['Rakibin sırası', 'Rival’s turn', 'Gegner ist dran', 'Turno del rival', 'Tour de l’adversaire', 'دور الخصم', 'نوبت حریف', 'תור היריב', 'حریف کی باری', 'Ход соперника', 'Хід суперника', 'Ruch rywala', 'Na tahu je soupeř', 'Rândul adversarului', 'Az ellenfél jön', 'Σειρά του αντιπάλου', 'Tocca all’avversario', 'Vez do rival', 'Beurt van tegenstander', 'Motståndarens tur', 'Modstanderens tur', 'Motstanderens tur', 'Vastustajan vuoro', '相手の番', '상대 차례', '对手回合', 'प्रतिद्वंद्वी की बारी', 'প্রতিদ্বন্দ্বীর পালা', 'Giliran lawan', 'Giliran lawan', 'ตาของคู่แข่ง', 'Lượt đối thủ', 'Turno ng kalaban'];

/// İki kişilik bilardo ekranı: bilgisayara karşı ya da çevrimiçi rakibe karşı.
class PoolDuelView extends StatefulWidget {
  final PlayContext ctx;
  final ShotLevel level;
  const PoolDuelView({super.key, required this.ctx, required this.level});

  @override
  State<PoolDuelView> createState() => _PoolDuelViewState();
}

class _PoolDuelViewState extends State<PoolDuelView> with SingleTickerProviderStateMixin {
  late final PoolSim sim;
  final PoolScore match = PoolScore();
  late final ArcadePalette palette;
  late final Ticker _ticker;
  late final SeededRandom _botRng;
  StreamSubscription<(int, String)>? _sub;
  final List<String> _queue = [];

  late final int me;
  late final int opp;
  MatchLink? get link => widget.ctx.match;
  bool _remoteOpp = false;

  // canlandırma
  bool _animating = false;
  int _steps = 0;
  int _shooter = 0;
  int _potted = 0;
  bool _foul = false;
  PoolShot? _incoming;
  bool _botBusy = false;
  bool _done = false;

  // nişan
  Offset? _press;
  int _shots = 0;

  String get lang => widget.ctx.lang;

  @override
  void initState() {
    super.initState();
    sim = PoolSim(widget.level);
    palette = ArcadePalette(widget.ctx.pieceColors, widget.ctx.background, widget.ctx.colorBlind, widget.ctx.reducedMotion);
    final l = link;
    me = l?.mySeat ?? 0;
    opp = me == 0 ? 1 : 0;
    _remoteOpp = l != null && widget.ctx.role(opp) == SeatRole.remote;
    _botRng = SeededRandom(mixSeed([widget.level.meta.seed, 0xB111]));
    _ticker = createTicker(_onFrame)..start();
    if (l != null) {
      // Maça geri dönüş: atışlar sırayla uygulanır (canlandırmasız).
      for (final (seat, mv) in l.history) {
        final s = PoolShot.decode(mv);
        if (s != null && applyPoolLayout(sim.balls, s.layout)) match.apply(seat, s.potted, s.foul);
      }
      _sub = l.moves.listen((e) {
        if (e.$1 == opp) _queue.add(e.$2);
      });
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _sub?.cancel();
    super.dispose();
  }

  bool get _oppIsBot => !_remoteOpp || (link?.dropped.contains(opp) ?? false);
  int get _left => sim.balls.skip(1).where((b) => b.live).length;

  void _onFrame(Duration _) {
    if (!mounted) return;
    if (sim.flashTicks > 0) sim.flashTicks--;
    if (_animating) {
      _steps++;
      final moving = PoolSim.stepTable(sim.balls, (b) {
        if (b.id == 0) {
          _foul = true;
        } else {
          _potted++;
        }
      });
      if (!moving || _steps >= kPoolMaxSteps) _shotDone();
      setState(() {});
      return;
    }
    if (_done) return;
    if (_left == 0) return _finish();
    if (match.turn == opp) {
      if (_queue.isNotEmpty && _remoteOpp) {
        final s = PoolShot.decode(_queue.removeAt(0));
        if (s != null) _start(opp, s.vx, s.vy, incoming: s);
      } else if (_oppIsBot && !_botBusy) {
        _botBusy = true;
        Future.delayed(const Duration(milliseconds: 700), () {
          if (!mounted || _done || _animating || match.turn != opp) {
            _botBusy = false;
            return;
          }
          final v = poolBotShot(sim.balls, widget.level.difficulty, _botRng);
          _botBusy = false;
          _start(opp, v.$1, v.$2);
        });
      }
    }
  }

  void _start(int shooter, double vx, double vy, {PoolShot? incoming}) {
    _shooter = shooter;
    _potted = 0;
    _foul = false;
    _steps = 0;
    _incoming = incoming;
    sim.balls[0]
      ..vx = vx
      ..vy = vy;
    sim.phase = 1;
    _animating = true;
    widget.ctx.sfx(Sfx.place);
  }

  void _shotDone() {
    _animating = false;
    sim.phase = 0;
    for (final b in sim.balls) {
      b
        ..vx = 0
        ..vy = 0;
    }
    final inc = _incoming;
    int potted;
    bool foul;
    if (inc != null) {
      // Rakibin cihazındaki sonuç geçerlidir: masa onun dizilimine oturur.
      if (!applyPoolLayout(sim.balls, inc.layout) && _foul) respotCue(sim.balls);
      potted = inc.potted;
      foul = inc.foul;
    } else {
      if (_foul) respotCue(sim.balls);
      potted = _potted;
      foul = _foul;
      final layout = poolLayout(sim.balls);
      applyPoolLayout(sim.balls, layout);
      if (_shooter == me && _remoteOpp) {
        unawaited(link!.send(PoolShot(_lastVx, _lastVy, potted, foul, layout).encode()).catchError((Object _) {}));
      }
    }
    if (potted > 0) sim.say(potted > 1 ? 'x$potted!' : 'IN!');
    if (foul) sim.say('FOUL');
    widget.ctx.sfx(foul ? Sfx.error : (potted > 0 ? Sfx.clear : Sfx.tap));
    match.apply(_shooter, potted, foul);
  }

  double _lastVx = 0, _lastVy = 0;

  void _shoot() {
    if (_animating || _done || match.turn != me) return;
    final v = poolVelocity(sim.aimAngle, sim.aimPower);
    _lastVx = v.$1;
    _lastVy = v.$2;
    _shots++;
    _start(me, v.$1, v.$2);
  }

  void _finish() {
    if (_done) return;
    _done = true;
    final mine = match.score[me], theirs = match.score[opp];
    final l = link;
    if (l != null) {
      final w = mine > theirs ? me : (mine < theirs ? opp : -1);
      unawaited(l.finish(w, iWon: w == me).catchError((Object _) {}));
    }
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      final won = mine >= theirs;
      widget.ctx.sfx(won ? Sfx.win : Sfx.lose);
      widget.ctx.finish(RoundResult(
        won: won,
        score: mine * 100,
        stars: !won ? 0 : (mine - theirs >= 4 ? 3 : (mine > theirs ? 2 : 1)),
        moves: _shots,
        gameStats: {'balls_potted': mine, 'shots_taken': _shots, if (won) 'racks_cleared': 1},
        headline: won ? null : '${Strings.pick(_tYou, lang)} $mine — ${Strings.pick(_tRival, lang)} $theirs',
      ));
    });
  }

  void _panStart(Offset p) {
    if (_animating || _done || match.turn != me) return;
    _press = p;
  }

  void _panUpdate(Offset p) {
    final s = _press;
    if (s == null) return;
    setState(() => sim.dragAim(p.dx - s.dx, p.dy - s.dy));
  }

  void _panEnd() {
    final s = _press;
    _press = null;
    if (s == null) return;
    if (sim.aimPower > 0.05) _shoot();
  }

  @override
  Widget build(BuildContext context) {
    final myTurn = match.turn == me;
    final head = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        _chip('${Strings.pick(_tYou, lang)} ${match.score[me]}', myTurn),
        const Spacer(),
        Text(Strings.pick(myTurn ? _tYourTurn : _tRivalTurn, lang), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        const Spacer(),
        _chip('${widget.ctx.match != null ? widget.ctx.seatName(opp) : Strings.pick(_tRival, lang)} ${match.score[opp]}', !myTurn),
      ]),
    );
    return ColoredBox(
      color: const Color(0xFF1A1B2E),
      child: Column(children: [
        head,
        Expanded(
          child: FittedBox(
            child: SizedBox(
              width: kWorldW,
              height: kWorldH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => _panStart(d.localPosition),
                onPanUpdate: (d) => _panUpdate(d.localPosition),
                onPanEnd: (_) => _panEnd(),
                onPanCancel: () => _press = null,
                child: CustomPaint(painter: _PoolPainter(sim, palette, myTurn && !_animating)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _chip(String text, bool active) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF52B788) : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
      );
}

class _PoolPainter extends CustomPainter {
  final PoolSim sim;
  final ArcadePalette palette;
  final bool aim;
  _PoolPainter(this.sim, this.palette, this.aim);

  @override
  void paint(Canvas canvas, Size size) {
    // Sıra rakipteyken istaka gösterilmez.
    final phase = sim.phase;
    if (!aim) sim.phase = 1;
    paintShot(canvas, sim, palette, 0);
    sim.phase = phase;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
