import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:studio_core/app/arcade_stage.dart';
import 'package:studio_core/app/game_api.dart';
import 'package:studio_core/app/services/audio.dart';
import 'package:studio_core/app/studio_ui.dart';
import 'package:studio_core/core/arcade.dart';
import 'package:studio_core/core/game_rules.dart';
import 'package:studio_core/core/rng.dart';
import 'package:studio_core/core/strings.dart';

import 'shot_engine.dart';
import 'shot_view.dart';

/// İki kişilik 8 top bilardo (bilgisayara ya da çevrimiçi rakibe karşı).
///
/// Kurallar (popüler 8 top oyunlarındaki gibi): 15 top üçgende, 8 ortada.
/// Açılıştan sonra ilk faulsüz sokuş oyuncunun grubunu (düz 1-7 / çizgili
/// 9-15) belirler. Önce kendi grubuna değmek gerekir; grubunu bitiren 8'e
/// oynar. Beyazı sokmak, hiçbir topa değmemek ya da önce yanlış topa değmek
/// fauldür: sıra rakibe geçer ve rakip beyazı istediği yere koyar (elde top).
/// 8'i grubu bitmeden ya da faulle sokan kaybeder; kurallara uygun sokan
/// kazanır. Açılışta giren 8 yerine konur. Çevrimiçi masada atış saati var.
///
/// Çevrimiçi eşitleme: atışı yapan cihaz atışı kendi masasında çözer, sonucu
/// tek hamlede gönderir: "S:<vx>|<vy>|<beyaz x>|<beyaz y>|<ilk değilen>|
/// <cebe girenler>|<son dizilim>". Karşı cihaz beyazı aynı yere koyup aynı
/// hızla atışı canlandırır, sonra gönderenin (2 basamağa yuvarlanmış) son
/// dizilimine oturur; iki cihaz kuralları aynı verilerle uyguladığı için masa
/// ve maç durumu her atıştan sonra birebir aynıdır. Süresi dolan oyuncunun
/// cihazı "T:" gönderir (faul).
class PoolShot {
  final double vx, vy, cx, cy;
  final int first;
  final List<int> ids;
  final String layout;
  const PoolShot(this.vx, this.vy, this.cx, this.cy, this.first, this.ids, this.layout);

  int get potted => ids.where((i) => i != 0).length;
  bool get scratch => ids.contains(0);
  PoolOutcome get outcome => PoolOutcome(first, ids);

  String encode() => 'S:$vx|$vy|$cx|$cy|$first|${ids.join(',')}|$layout';

  static PoolShot? decode(String m) {
    if (!m.startsWith('S:')) return null;
    final p = m.substring(2).split('|');
    if (p.length != 7) return null;
    final vx = double.tryParse(p[0]), vy = double.tryParse(p[1]);
    final cx = double.tryParse(p[2]), cy = double.tryParse(p[3]);
    final first = int.tryParse(p[4]);
    if (vx == null || vy == null || cx == null || cy == null || first == null) return null;
    if (!vx.isFinite || !vy.isFinite || !cx.isFinite || !cy.isFinite) return null;
    final ids = <int>[];
    if (p[5].isNotEmpty) {
      for (final t in p[5].split(',')) {
        final v = int.tryParse(t);
        if (v == null || v < 0 || v > 15) return null;
        ids.add(v);
      }
    }
    return PoolShot(vx, vy, cx, cy, first, ids, p[6]);
  }
}

/// Süre doldu hamlesi.
const kPoolTimeout = 'T:';

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
    if (x == null || y == null || !x.isFinite || !y.isFinite) return false;
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

/// Topun grubu: 0 düz (1-7), 1 çizgili (9-15), -1 beyaz ya da 8.
int poolGroupOf(int id) => id <= 0 || id == 8 ? -1 : (id < 8 ? 0 : 1);

/// 15 topluk üçgen: tepe ön noktada, 8 ortada, arka köşelerde bir düz bir
/// çizgili; diğerleri bölüm tohumuyla karışık (iki cihazda aynı).
void rackPool(List<Disc> balls, int seed) {
  final r = SeededRandom(mixSeed([seed, 0x8B8]));
  final solids = [1, 2, 3, 4, 5, 6, 7], stripes = [9, 10, 11, 12, 13, 14, 15];
  r.shuffle(solids);
  r.shuffle(stripes);
  final order = List<int>.filled(15, 0);
  order[4] = 8;
  final flip = r.chance(0.5);
  order[10] = flip ? solids.removeLast() : stripes.removeLast();
  order[14] = flip ? stripes.removeLast() : solids.removeLast();
  final rest = [...solids, ...stripes];
  r.shuffle(rest);
  var k = 0;
  for (var i = 0; i < 15; i++) {
    if (order[i] == 0) order[i] = rest[k++];
  }
  balls
    ..clear()
    ..add(Disc(500, 1250, kPoolR, 1, 0));
  var i = 0;
  for (var row = 0; row < 5; row++) {
    for (var c = 0; c <= row; c++) {
      balls.add(Disc(500 + (c - row / 2) * (kPoolR * 2 + 1), 560 - row * (kPoolR * 1.75), kPoolR, 1, order[i++]));
    }
  }
}

bool _free(List<Disc> balls, Disc me, double x, double y) {
  for (final b in balls) {
    if (identical(b, me) || !b.live) continue;
    if ((b.x - x) * (b.x - x) + (b.y - y) * (b.y - y) < (kPoolR * 2 + 2) * (kPoolR * 2 + 2)) return false;
  }
  return x >= kTable.l + kPoolR && x <= kTable.r - kPoolR && y >= kTable.t + kPoolR && y <= kTable.b - kPoolR;
}

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
    if (_free(balls, c, c.x, c.y)) break;
    c.x = 220 + (k * 97) % 560;
  }
}

/// Açılışta giren 8 ön noktaya (doluysa biraz aşağısına) konur.
void respotEight(List<Disc> balls) {
  final e = balls.firstWhere((b) => b.id == 8);
  e
    ..live = true
    ..vx = 0
    ..vy = 0
    ..x = 500;
  for (var y = 560.0; y < 1400; y += 44) {
    e.y = y;
    if (_free(balls, e, e.x, e.y)) return;
  }
}

/// Atışın hızı: istaka açısı ve gücünden (tek oyunculu bilardoyla aynı).
(double, double) poolVelocity(double angle, double power) {
  final sp = 3 + power * 37;
  return (math.cos(angle) * sp, math.sin(angle) * sp);
}

/// Bir atışın sonucu: beyazın ilk değdiği top (0: hiçbiri) ve sırayla cebe
/// girenler (0 = beyaz).
class PoolOutcome {
  final int first;
  final List<int> ids;
  const PoolOutcome(this.first, this.ids);
  bool get scratch => ids.contains(0);
}

/// Atışı baştan sona çöz (canlandırmasız).
PoolOutcome resolvePoolShot(List<Disc> balls, double vx, double vy) {
  balls[0]
    ..vx = vx
    ..vy = vy;
  var first = 0;
  final ids = <int>[];
  for (var t = 0; t < kPoolMaxSteps; t++) {
    final moving = PoolSim.stepTable(balls, (b) => ids.add(b.id), (a, b) {
      if (first != 0) return;
      if (a.id == 0) {
        first = b.id;
      } else if (b.id == 0) {
        first = a.id;
      }
    });
    if (!moving) break;
  }
  for (final b in balls) {
    b
      ..vx = 0
      ..vy = 0;
  }
  return PoolOutcome(first, ids);
}

/// Maç durumu (iki cihazda aynı): sıra, gruplar, elde top, kazanan.
class PoolScore {
  int turn = 0;

  /// Koltuk 0'ın grubu (-1: masa açık).
  int group0 = -1;
  int winner = -1;
  bool ballInHand = false;
  bool broken = false;

  /// Son atışın ekranda gösterilecek kısa sonucu.
  String last = '';

  PoolScore copy() => PoolScore()
    ..turn = turn
    ..group0 = group0
    ..winner = winner
    ..ballInHand = ballInHand
    ..broken = broken;

  int groupOf(int seat) => group0 < 0 ? -1 : (seat == 0 ? group0 : 1 - group0);

  static int left(List<Disc> balls, int g) => balls.where((b) => b.live && poolGroupOf(b.id) == g).length;

  /// Koltuğun kendi grubundan soktuğu top sayısı (grubu yoksa 0).
  int potted(List<Disc> balls, int seat) {
    final g = groupOf(seat);
    return g < 0 ? 0 : 7 - left(balls, g);
  }

  /// Koltuk 8'e mi oynuyor (grubu bitti)?
  bool onEight(List<Disc> balls, int seat) {
    final g = groupOf(seat);
    return g >= 0 && left(balls, g) == 0;
  }

  /// Bu topa önce değmek kurallara uygun mu?
  bool legalFirst(List<Disc> balls, int seat, int id) {
    if (id <= 0) return false;
    final g = groupOf(seat);
    if (g < 0) return id != 8;
    if (left(balls, g) == 0) return id == 8;
    return poolGroupOf(id) == g;
  }

  /// Atış sonrası kurallar. [balls]: atış sonrası masa; beyazın ve (açılışta)
  /// 8'in yeniden yerleştirilmesi burada yapılır.
  void apply(int shooter, PoolOutcome o, List<Disc> balls) {
    if (winner >= 0) return;
    final other = 1 - shooter;
    final breakShot = !broken;
    broken = true;
    final g = groupOf(shooter);
    final ownNow = g < 0 ? 0 : o.ids.where((id) => poolGroupOf(id) == g).length;
    final wasOnEight = g >= 0 && left(balls, g) + ownNow == 0;
    var foul = o.scratch || o.first == 0;
    if (!foul) {
      if (g < 0) {
        foul = o.first == 8;
      } else if (wasOnEight) {
        foul = o.first != 8;
      } else {
        foul = poolGroupOf(o.first) != g;
      }
    }
    if (o.ids.contains(8)) {
      if (breakShot) {
        respotEight(balls);
      } else {
        winner = wasOnEight && !foul ? shooter : other;
        last = '8!';
        if (!balls[0].live) respotCue(balls);
        return;
      }
    }
    if (g < 0 && !breakShot && !foul) {
      final firstObj = o.ids.firstWhere((id) => poolGroupOf(id) >= 0, orElse: () => 0);
      if (firstObj != 0) {
        final fg = poolGroupOf(firstObj);
        group0 = shooter == 0 ? fg : 1 - fg;
      }
    }
    final g2 = groupOf(shooter);
    final goodPot = g2 < 0 ? o.ids.any((id) => poolGroupOf(id) >= 0) : o.ids.any((id) => poolGroupOf(id) == g2);
    if (!balls[0].live) respotCue(balls);
    if (foul) {
      turn = other;
      ballInHand = true;
      last = 'FOUL';
    } else {
      ballInHand = false;
      turn = goodPot ? shooter : other;
      final n = o.ids.where((id) => id != 0).length;
      last = n > 1 ? 'x$n!' : (n == 1 ? 'IN!' : '');
    }
  }

  /// Atış saati doldu: faul, sıra ve elde top rakibe.
  void timeout(int shooter) {
    if (winner >= 0 || turn != shooter) return;
    turn = 1 - shooter;
    ballInHand = true;
    last = 'FOUL';
  }
}

/// Bilgisayar rakibi: kurallara uygun topları ve cepleri dener, birkaç
/// atışı masada çözüp en iyisini seçer; elde top varsa beyazı da yerleştirir.
/// [d] 1..10: yüksek zorlukta daha az sapma. Döner: (vx, vy, beyaz x, beyaz y).
(double, double, double, double) poolBotShot(List<Disc> balls, PoolScore m, int seat, int d, SeededRandom r) {
  final cue = balls[0];
  final spots = <(double, double)>[(cue.x, cue.y)];
  if (m.ballInHand) {
    for (final b in balls.skip(1)) {
      if (!b.live || !m.legalFirst(balls, seat, b.id)) continue;
      for (final pk in kPockets) {
        final dx = b.x - pk[0], dy = b.y - pk[1];
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist < 1) continue;
        final x = b.x + dx / dist * 170, y = b.y + dy / dist * 170;
        if (_free(balls, cue, x, y)) spots.add((x, y));
      }
      if (spots.length >= 3) break;
    }
  }
  final before = m.potted(balls, seat);
  var bestScore = -1e9;
  var best = (-math.pi / 2, 0.6, cue.x, cue.y);
  for (final sp in spots) {
    final cands = <(double, double)>[]; // açı, maliyet
    for (final b in balls.skip(1)) {
      if (!b.live || !m.legalFirst(balls, seat, b.id)) continue;
      for (final pk in kPockets) {
        final dx = pk[0] - b.x, dy = pk[1] - b.y;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist < 1) continue;
        final gx = b.x - dx / dist * kPoolR * 2, gy = b.y - dy / dist * kPoolR * 2;
        final ax = gx - sp.$1, ay = gy - sp.$2;
        final al = math.sqrt(ax * ax + ay * ay);
        if (al < 1) continue;
        final cut = math.acos(((ax * dx + ay * dy) / (al * dist)).clamp(-1.0, 1.0));
        if (cut > 1.3) continue;
        cands.add((math.atan2(ay, ax), cut * 400 + dist + al * 0.5));
      }
    }
    if (cands.isEmpty) {
      // Doğrudan en yakın kurallı topa vur (güvenli oyun).
      Disc? near;
      var nd = 1e18;
      for (final b in balls.skip(1)) {
        if (!b.live || !m.legalFirst(balls, seat, b.id)) continue;
        final dd = (b.x - sp.$1) * (b.x - sp.$1) + (b.y - sp.$2) * (b.y - sp.$2);
        if (dd < nd) {
          nd = dd;
          near = b;
        }
      }
      if (near != null) cands.add((math.atan2(near.y - sp.$2, near.x - sp.$1), 0.0));
    }
    cands.sort((a, b) => a.$2.compareTo(b.$2));
    for (final c in cands.take(4)) {
      for (final pw in const [0.45, 0.65, 0.9]) {
        final copy = [for (final b in balls) b.copy()];
        copy[0]
          ..x = sp.$1
          ..y = sp.$2
          ..live = true;
        final v = poolVelocity(c.$1, pw);
        final o = resolvePoolShot(copy, v.$1, v.$2);
        final m2 = m.copy();
        m2.apply(seat, o, copy);
        var s = 6.0 * (m2.potted(copy, seat) - before) - pw;
        if (m2.winner == seat) s += 1000;
        if (m2.winner == 1 - seat) s -= 1000;
        if (m2.winner < 0 && m2.turn == seat) s += 30;
        if (m2.ballInHand && m2.turn != seat) s -= 40;
        if (s > bestScore) {
          bestScore = s;
          best = (c.$1, pw, sp.$1, sp.$2);
        }
      }
    }
  }
  final dd = d < 1 ? 1 : (d > 10 ? 10 : d);
  final noise = (11 - dd) * 0.011;
  final angle = best.$1 + (r.nextDouble() - r.nextDouble()) * noise;
  final power = clampD(best.$2 + (r.nextDouble() - 0.5) * noise, 0.2, 1.0);
  final v = poolVelocity(angle, power);
  return (v.$1, v.$2, best.$3, best.$4);
}

const _tYou = ['Sen', 'You', 'Du', 'Tú', 'Vous', 'أنت', 'تو', 'את/ה', 'آپ', 'Вы', 'Ви', 'Ty', 'Ty', 'Tu', 'Te', 'Εσύ', 'Tu', 'Você', 'Jij', 'Du', 'Du', 'Du', 'Sinä', 'あなた', '나', '你', 'आप', 'আপনি', 'Kamu', 'Anda', 'คุณ', 'Bạn', 'Ikaw'];
const _tRival = ['Rakip', 'Rival', 'Gegner', 'Rival', 'Rival', 'الخصم', 'حریف', 'יריב', 'حریف', 'Соперник', 'Суперник', 'Rywal', 'Soupeř', 'Rival', 'Ellenfél', 'Αντίπαλος', 'Rivale', 'Rival', 'Tegenstander', 'Motståndare', 'Modstander', 'Motstander', 'Vastustaja', '相手', '상대', '对手', 'प्रतिद्वंद्वी', 'প্রতিদ্বন্দ্বী', 'Lawan', 'Lawan', 'คู่แข่ง', 'Đối thủ', 'Kalaban'];
const _tYourTurn = ['Senin sıran', 'Your turn', 'Du bist dran', 'Tu turno', 'À vous', 'دورك', 'نوبت توست', 'תורך', 'آپ کی باری', 'Ваш ход', 'Ваш хід', 'Twój ruch', 'Jsi na tahu', 'Rândul tău', 'Te jössz', 'Σειρά σου', 'Tocca a te', 'Sua vez', 'Jouw beurt', 'Din tur', 'Din tur', 'Din tur', 'Sinun vuorosi', 'あなたの番', '내 차례', '轮到你了', 'आपकी बारी', 'তোমার পালা', 'Giliranmu', 'Giliran anda', 'ตาของคุณ', 'Lượt của bạn', 'Iyong turno'];
const _tRivalTurn = ['Rakibin sırası', 'Rival’s turn', 'Gegner ist dran', 'Turno del rival', 'Tour de l’adversaire', 'دور الخصم', 'نوبت حریف', 'תור היריב', 'حریف کی باری', 'Ход соперника', 'Хід суперника', 'Ruch rywala', 'Na tahu je soupeř', 'Rândul adversarului', 'Az ellenfél jön', 'Σειρά του αντιπάλου', 'Tocca all’avversario', 'Vez do rival', 'Beurt van tegenstander', 'Motståndarens tur', 'Modstanderens tur', 'Motstanderens tur', 'Vastustajan vuoro', '相手の番', '상대 차례', '对手回合', 'प्रतिद्वंद्वी की बारी', 'প্রতিদ্বন্দ্বীর পালা', 'Giliran lawan', 'Giliran lawan', 'ตาของคู่แข่ง', 'Lượt đối thủ', 'Turno ng kalaban'];

const _tBallInHand = ['Elde top: beyazı sürükleyip yerleştir', 'Ball in hand: drag the cue ball', 'Ball in Hand: weiße Kugel ziehen', 'Bola en mano: arrastra la blanca', 'Bille en main : déplacez la blanche', 'الكرة في اليد: اسحب الكرة البيضاء', 'توپ در دست: توپ سفید را بکشید', 'כדור ביד: גררו את הכדור הלבן', 'گیند ہاتھ میں: سفید گیند گھسیٹیں', 'Шар в руке: перетащите биток', 'Куля в руці: перетягніть биток', 'Bila z ręki: przeciągnij białą', 'Koule v ruce: přetáhněte bílou', 'Bila în mână: trage bila albă', 'Kézben a golyó: húzd a fehéret', 'Μπάλα στο χέρι: σύρε τη λευκή', 'Palla in mano: trascina la bianca', 'Bola na mão: arraste a branca', 'Bal in hand: sleep de witte bal', 'Fri boll: dra den vita bollen', 'Fri bold: træk den hvide kugle', 'Ball i hånd: dra den hvite kula', 'Pallo kädessä: vedä valkoista', '手球：白球をドラッグして置く', '프리볼: 흰 공을 끌어 놓으세요', '自由球：拖动白球摆放', 'हाथ में गेंद: सफ़ेद गेंद खींचें', 'হাতে বল: সাদা বল টেনে রাখো', 'Bola di tangan: seret bola putih', 'Bola di tangan: seret bola putih', 'ฟรีบอล: ลากลูกขาวไปวาง', 'Bóng trong tay: kéo bi trắng', 'Bola sa kamay: i-drag ang puting bola'];

/// Çevrimiçi atış saati (sn).
const kPoolShotSeconds = 30;

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
  final Stopwatch _clock = Stopwatch()..start();

  late final int me;
  late final int opp;
  MatchLink? get link => widget.ctx.match;
  bool _remoteOpp = false;

  // canlandırma
  bool _animating = false;
  int _steps = 0;
  int _shooter = 0;
  int _first = 0;
  final List<int> _ids = [];
  PoolShot? _incoming;
  bool _botBusy = false;
  bool _done = false;
  double _cx = 500, _cy = 1250;

  // nişan / elde top
  Offset? _press;
  bool _placing = false;
  int _shots = 0;

  // atış saati
  int _moves = 0;
  int _turnKey = -1;
  int _turnAt = 0;

  String get lang => widget.ctx.lang;
  bool get _timed => link != null && _remoteOpp;

  @override
  void initState() {
    super.initState();
    sim = PoolSim(widget.level);
    rackPool(sim.balls, widget.level.meta.seed);
    palette = ArcadePalette(widget.ctx.pieceColors, widget.ctx.background, widget.ctx.colorBlind, widget.ctx.reducedMotion);
    final l = link;
    me = l?.mySeat ?? 0;
    opp = me == 0 ? 1 : 0;
    _remoteOpp = l != null && widget.ctx.role(opp) == SeatRole.remote;
    _botRng = SeededRandom(mixSeed([widget.level.meta.seed, 0xB111]));
    _ticker = createTicker(_onFrame)..start();
    if (l != null) {
      // Maça geri dönüş: hamleler sırayla uygulanır (canlandırmasız).
      for (final (seat, mv) in l.history) {
        _applyQuiet(seat, mv);
      }
      _sub = l.moves.listen((e) {
        if (e.$1 == opp) _queue.add(e.$2);
      });
    }
  }

  void _applyQuiet(int seat, String mv) {
    if (mv == kPoolTimeout) {
      match.timeout(seat);
      return;
    }
    final s = PoolShot.decode(mv);
    if (s != null && applyPoolLayout(sim.balls, s.layout)) match.apply(seat, s.outcome, sim.balls);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _sub?.cancel();
    super.dispose();
  }

  bool get _oppIsBot => !_remoteOpp || (link?.dropped.contains(opp) ?? false);

  int get _now => _clock.elapsedMilliseconds;

  /// Atış saatinde kalan süre (ms).
  int get _timeLeft => kPoolShotSeconds * 1000 - (_now - _turnAt);

  void _onFrame(Duration _) {
    if (!mounted) return;
    if (sim.flashTicks > 0) sim.flashTicks--;
    if (_animating) {
      _steps++;
      final moving = PoolSim.stepTable(sim.balls, (b) {
        _ids.add(b.id);
        if (b.id != 0) widget.ctx.sfx(Sfx.clear);
      }, (a, b) {
        if (_first != 0) return;
        if (a.id == 0) {
          _first = b.id;
        } else if (b.id == 0) {
          _first = a.id;
        }
      });
      if (!moving || _steps >= kPoolMaxSteps) _shotDone();
      setState(() {});
      return;
    }
    if (_done) return;
    if (match.winner >= 0) return _finish();
    final key = _moves * 2 + match.turn;
    if (key != _turnKey) {
      _turnKey = key;
      _turnAt = _now;
    }
    if (match.turn == me) {
      if (_timed && _timeLeft <= 0) {
        // Süre doldu: faul, sıra rakibe.
        _press = null;
        _placing = false;
        unawaited(link!.send(kPoolTimeout).catchError((Object _) {}));
        match.timeout(me);
        _moves++;
        sim.say('FOUL');
        widget.ctx.sfx(Sfx.error);
      }
      if (_timed) setState(() {});
      return;
    }
    if (_queue.isNotEmpty && _remoteOpp) {
      final mv = _queue.removeAt(0);
      if (mv == kPoolTimeout) {
        match.timeout(opp);
        _moves++;
        sim.say('FOUL');
        setState(() {});
        return;
      }
      final s = PoolShot.decode(mv);
      if (s != null) _start(opp, s.vx, s.vy, s.cx, s.cy, incoming: s);
    } else if (_oppIsBot && !_botBusy) {
      _botBusy = true;
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted || _done || _animating || match.turn != opp) {
          _botBusy = false;
          return;
        }
        final v = poolBotShot(sim.balls, match, opp, widget.level.difficulty, _botRng);
        _botBusy = false;
        _start(opp, v.$1, v.$2, v.$3, v.$4);
      });
    }
    if (_timed) setState(() {});
  }

  void _start(int shooter, double vx, double vy, double cx, double cy, {PoolShot? incoming}) {
    _shooter = shooter;
    _moves++;
    _first = 0;
    _ids.clear();
    _steps = 0;
    _incoming = incoming;
    _cx = cx;
    _cy = cy;
    sim.balls[0]
      ..x = cx
      ..y = cy
      ..live = true
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
    PoolOutcome o;
    if (inc != null) {
      // Rakibin cihazındaki sonuç geçerlidir: masa onun dizilimine oturur.
      applyPoolLayout(sim.balls, inc.layout);
      o = inc.outcome;
    } else {
      o = PoolOutcome(_first, List<int>.of(_ids));
      final layout = poolLayout(sim.balls);
      applyPoolLayout(sim.balls, layout);
      if (_shooter == me && _remoteOpp) {
        final msg = PoolShot(_lastVx, _lastVy, _cx, _cy, o.first, o.ids, layout).encode();
        unawaited(link!.send(msg).catchError((Object _) {}));
      }
    }
    match.apply(_shooter, o, sim.balls);
    if (match.last.isNotEmpty) sim.say(match.last);
    widget.ctx.sfx(match.last == 'FOUL' ? Sfx.error : (o.ids.any((i) => i != 0) ? Sfx.combo : Sfx.tap));
  }

  double _lastVx = 0, _lastVy = 0;

  bool get _canAct => !_animating && !_done && match.turn == me && match.winner < 0;

  void _shoot() {
    if (!_canAct) return;
    final v = poolVelocity(sim.aimAngle, sim.aimPower);
    _lastVx = v.$1;
    _lastVy = v.$2;
    _shots++;
    final cue = sim.balls[0];
    _start(me, v.$1, v.$2, cue.x, cue.y);
  }

  void _finish() {
    if (_done) return;
    _done = true;
    final w = match.winner;
    final won = w == me;
    final mine = match.potted(sim.balls, me), theirs = match.potted(sim.balls, opp);
    final l = link;
    if (l != null) unawaited(l.finish(w, iWon: won).catchError((Object _) {}));
    final og = match.groupOf(opp);
    final oppLeft = og < 0 ? 7 : PoolScore.left(sim.balls, og);
    Future.delayed(const Duration(milliseconds: 1100), () {
      if (!mounted) return;
      widget.ctx.sfx(won ? Sfx.win : Sfx.lose);
      widget.ctx.finish(RoundResult(
        won: won,
        score: mine * 100 + (won ? 500 : 0),
        stars: !won ? 0 : (oppLeft >= 5 ? 3 : (oppLeft >= 2 ? 2 : 1)),
        moves: _shots,
        gameStats: {'balls_potted': mine, 'shots_taken': _shots, if (won) 'racks_cleared': 1},
        headline: won ? null : '${Strings.pick(_tYou, lang)} $mine — ${Strings.pick(_tRival, lang)} $theirs',
      ));
    });
  }

  void _panStart(Offset p) {
    if (!_canAct) return;
    final cue = sim.balls[0];
    _placing = match.ballInHand && (p - Offset(cue.x, cue.y)).distance < 80;
    _press = p;
  }

  void _panUpdate(Offset p) {
    final s = _press;
    if (s == null || !_canAct) return;
    if (_placing) {
      final cue = sim.balls[0];
      final x = clampD(p.dx, kTable.l + kPoolR, kTable.r - kPoolR), y = clampD(p.dy, kTable.t + kPoolR, kTable.b - kPoolR);
      if (_free(sim.balls, cue, x, y)) {
        setState(() {
          cue
            ..x = x
            ..y = y;
        });
      }
      return;
    }
    setState(() => sim.dragAim(p.dx - s.dx, p.dy - s.dy));
  }

  void _panEnd() {
    final s = _press;
    final placing = _placing;
    _press = null;
    _placing = false;
    if (s == null || placing) return;
    if (sim.aimPower > 0.05) _shoot();
  }

  @override
  Widget build(BuildContext context) {
    final myTurn = match.turn == me;
    final hand = myTurn && match.ballInHand && !_animating && !_done;
    final head = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Flexible(child: _chip(me, Strings.pick(_tYou, lang), myTurn)),
        Expanded(
          child: Text(
            Strings.pick(hand ? _tBallInHand : (myTurn ? _tYourTurn : _tRivalTurn), lang),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          ),
        ),
        Flexible(child: _chip(opp, widget.ctx.match != null ? widget.ctx.seatName(opp) : Strings.pick(_tRival, lang), !myTurn)),
      ]),
    );
    final timeFrac = _timed && !_animating && !_done ? (_timeLeft / (kPoolShotSeconds * 1000)).clamp(0.0, 1.0) : 0.0;
    // Onaylı tasarımın degrade zemini; masa çizimi kendi sanatını korur.
    return StudioBackdrop(
      child: Column(children: [
        head,
        if (_timed)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 6,
                child: Align(
                  alignment: myTurn ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
                  child: FractionallySizedBox(
                    widthFactor: timeFrac.toDouble(),
                    heightFactor: 1,
                    child: ColoredBox(color: timeFrac < 0.33 ? const Color(0xFFE63946) : const Color(0xFF52B788)),
                  ),
                ),
              ),
            ),
          ),
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
                onPanCancel: () {
                  _press = null;
                  _placing = false;
                },
                child: CustomPaint(painter: _PoolPainter(sim, palette, myTurn && !_animating && !_done, hand, _now)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  /// Oyuncu hapı: ad, grubunun simgesi (düz / çizgili / 8) ve soktuğu top.
  Widget _chip(int seat, String name, bool active) {
    final g = match.groupOf(seat);
    final icon = g < 0 ? -1 : (match.onEight(sim.balls, seat) ? 8 : (g == 0 ? 1 : 9));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF2E9E62) : Colors.black.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: active ? Colors.white.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon >= 0) ...[
          SizedBox(width: 18, height: 18, child: CustomPaint(painter: _BallIcon(icon))),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text('$name ${match.potted(sim.balls, seat)}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        ),
      ]),
    );
  }
}

class _BallIcon extends CustomPainter {
  final int id;
  _BallIcon(this.id);

  @override
  void paint(Canvas canvas, Size size) =>
      paintPoolBall(canvas, size.center(Offset.zero), size.shortestSide / 2, id, shadow: false);

  @override
  bool shouldRepaint(covariant _BallIcon old) => old.id != id;
}

class _PoolPainter extends CustomPainter {
  final PoolSim sim;
  final ArcadePalette palette;
  final bool aim;
  final bool hand;
  final int now;
  _PoolPainter(this.sim, this.palette, this.aim, this.hand, this.now);

  @override
  void paint(Canvas canvas, Size size) {
    // Sıra rakipteyken istaka gösterilmez.
    final phase = sim.phase;
    if (!aim) sim.phase = 1;
    paintShot(canvas, sim, palette, 0);
    sim.phase = phase;
    if (hand) {
      // Elde top: beyazın çevresinde nabız gibi atan halka.
      final cue = sim.balls[0];
      final k = (math.sin(now / 180) + 1) / 2;
      canvas.drawCircle(
          Offset(cue.x, cue.y),
          kPoolR + 10 + k * 8,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..color = const Color(0xFFFFD166).withValues(alpha: 0.5 + 0.5 * k));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
