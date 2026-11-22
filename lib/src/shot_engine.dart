import 'dart:math' as math;

import 'package:studio_core/core/arcade.dart';
import 'package:studio_core/core/level_plan.dart';
import 'package:studio_core/core/rng.dart';

/// Turn-based "aim & shoot" sports on the shared arcade framework:
/// mini golf, pool, bowling, basketball, archery, darts and penalties.
///
/// Every level is a sequence of *rounds* (a hole, a rack, a bowling game,
/// a shooting challenge, a darts leg, a shoot-out). A round's layout is a
/// pure function of (level seed, round index, difficulty), so a failed
/// round can be retried with the same layout. Failing a round costs a life;
/// the campaign is won when every round is completed.
enum ShotKind { golf, billiards, bowling, basketball, archery, darts, penalty }

class ShotLevel {
  final ArcadeMeta meta;
  final ShotKind kind;
  final int difficulty;
  final int rounds; // campaign rounds (0 = unlimited)
  final int theme;
  const ShotLevel(this.meta, this.kind, this.difficulty, this.rounds, this.theme);
}

ShotLevel generateShot(ShotKind kind, LevelSpec spec) {
  final m = ArcadeMeta.of(spec);
  final d = spec.difficulty.clamp(1, 10);
  var rounds = 1;
  if (kind == ShotKind.golf && d >= 7) rounds = 2;
  if (!m.goal) rounds = 0;
  return ShotLevel(m, kind, d, rounds, spec.theme % 4);
}

/// Axis aligned rectangle used for walls and zones.
class Box {
  double l, t, r, b;
  Box(this.l, this.t, this.r, this.b);
  bool contains(double x, double y) => x >= l && x <= r && y >= t && y <= b;
  Box inflate(double k) => Box(l - k, t - k, r + k, b + k);
  Box copy() => Box(l, t, r, b);
}

/// A moving disc (ball / pin).
class Disc {
  double x, y, vx = 0, vy = 0;
  final double r, m;
  final double ox, oy;
  final int id;
  bool live = true;
  Disc(this.x, this.y, this.r, this.m, this.id)
      : ox = x,
        oy = y;
  Disc copy() => Disc(x, y, r, m, id)
    ..vx = vx
    ..vy = vy
    ..live = live;
  double get speed => math.sqrt(vx * vx + vy * vy);
}

/// Board darts sector order clockwise from the top.
const kDartSectors = [20, 1, 18, 4, 13, 6, 10, 15, 2, 17, 3, 19, 7, 16, 8, 11, 14, 9, 12, 5];

abstract class ShotSim extends ArcadeSim {
  final ShotLevel level;
  int round = 0; // rounds completed
  int phase = 0; // 0 aim, 1 in flight
  int phaseTicks = 0;
  int shots = 0; // total shots / throws
  int lastEvent = 0; // 1 shot, 2 good, 3 great, 4 miss, 5 round done
  String flash = '';
  int flashTicks = 0;

  // aiming (drag kinds)
  bool aiming = false;
  double pressX = -1, pressY = -1, curX = -1, curY = -1;
  double aimAngle = -math.pi / 2, aimPower = 0.6;

  // reticle (archery, darts, penalty shooting)
  bool holding = false;
  double baseX = 500, baseY = 700;
  int holdTicks = 0;

  /// Autopilot scratch (never read by the game rules).
  final List<ArcadeInput> botQueue = [];

  factory ShotSim(ShotLevel l) => switch (l.kind) {
        ShotKind.golf => GolfSim(l),
        ShotKind.billiards => PoolSim(l),
        ShotKind.bowling => BowlingSim(l),
        ShotKind.basketball => HoopSim(l),
        ShotKind.archery => ArcherySim(l),
        ShotKind.darts => DartsSim(l),
        ShotKind.penalty => PenaltySim(l),
      };

  ShotSim.base(this.level) : super(level.meta, lives: 3) {
    setupRound();
  }

  /// Difficulty used for the current round (endless ramps up).
  int get rd => (level.difficulty + (level.rounds == 0 ? round ~/ 2 : 0)).clamp(1, 10);

  int get roundSeed => mixSeed([meta.seed, 9001, round]);

  /// Creates the layout of the current round (and resets it).
  void setupRound();

  /// 0..1 progress of the running round.
  double get roundProgress;

  bool get usesReticle => false;

  /// Drag vector -> aim. Default: pull back like a slingshot.
  void dragAim(double dx, double dy) {
    final vx = -dx, vy = -dy;
    final len = math.sqrt(vx * vx + vy * vy);
    if (len < 4) return;
    aimAngle = math.atan2(vy, vx);
    aimPower = (len / 350).clamp(0.0, 1.0);
  }

  /// Called with an input before aiming starts (e.g. bowling position).
  bool preAim(ArcadeInput i) => false;

  void fire();

  /// One tick of the shot in flight; returns true when it has resolved.
  bool flight();

  /// Reticle sway offset for the current hold.
  (double, double) sway() {
    final a = swayAmp();
    final t = holdTicks.toDouble();
    final ph = (roundSeed % 628) / 100.0;
    return (a * math.sin(t * 0.071 + ph) + a * 0.4 * math.sin(t * 0.19 + 1.3 * ph),
        a * 0.8 * math.cos(t * 0.057 + ph * 0.7) + a * 0.3 * math.sin(t * 0.23));
  }

  double swayAmp() => 0;

  double get retX => clampD(baseX + sway().$1, 0, kWorldW);
  double get retY => clampD(baseY + sway().$2, 0, kWorldH);

  @override
  void update(ArcadeInput input) {
    lastEvent = 0;
    phaseTicks++;
    if (flashTicks > 0) flashTicks--;
    if (phase == 1) {
      if (flight()) {
        phase = 0;
        phaseTicks = 0;
      }
      return;
    }
    if (usesReticle) {
      _reticle(input);
    } else {
      _drag(input);
    }
  }

  void _drag(ArcadeInput i) {
    if (!aiming && preAim(i)) return;
    if (i.down && i.hasPointer) {
      if (!aiming) {
        aiming = true;
        pressX = i.x;
        pressY = i.y;
      }
      curX = i.x;
      curY = i.y;
      dragAim(curX - pressX, curY - pressY);
      return;
    }
    if (aiming && !i.down) {
      aiming = false;
      final len = math.sqrt(math.pow(curX - pressX, 2) + math.pow(curY - pressY, 2));
      if (len > 25 && aimPower > 0.05) _doFire();
      return;
    }
    // keyboard
    if (i.dirX != 0) aimAngle += i.dirX * 0.02;
    if (i.dirY != 0) aimPower = clampD(aimPower - i.dirY * 0.012, 0.1, 1);
    clampAim();
    if (i.tap && !i.hasPointer) _doFire();
  }

  void clampAim() {}

  void _reticle(ArcadeInput i) {
    if (i.down) {
      if (!holding) {
        holding = true;
        holdTicks = 0;
      }
      holdTicks++;
      if (i.hasPointer) {
        baseX = i.x;
        baseY = i.y;
      }
    }
    if (i.dirX != 0 || i.dirY != 0) {
      baseX = clampD(baseX + i.dirX * 6, 0, kWorldW);
      baseY = clampD(baseY + i.dirY * 6, 0, kWorldH);
    }
    if (holding && !i.down) {
      holding = false;
      if (holdTicks >= 6) _doFire();
      holdTicks = 0;
    }
  }

  void _doFire() {
    shots++;
    lastEvent = 1;
    fire();
    phase = 1;
    phaseTicks = 0;
  }

  void say(String s) {
    flash = s;
    flashTicks = 70;
  }

  /// The running round was completed.
  void roundDone() {
    round++;
    lastEvent = 5;
    if (level.rounds > 0 && round >= level.rounds) {
      win();
      return;
    }
    setupRound();
  }

  /// The running round failed: costs a life (zen: just restart it).
  void roundFailed() {
    lastEvent = 4;
    if (meta.zen) {
      setupRound();
      return;
    }
    shield = 0;
    hit();
  }

  @override
  void onLifeLost() {
    phase = 0;
    aiming = false;
    holding = false;
    setupRound();
  }

  @override
  double get progress =>
      level.rounds > 0 ? ((round + roundProgress.clamp(0.0, 1.0)) / level.rounds).clamp(0.0, 1.0) : 0;

  /// 1..3 quality of the current play (kind specific).
  int get quality => 3;

  @override
  int get stars => won ? math.min(lifeStars(this, 3), quality) : 0;
}

// ---------------------------------------------------------------------------
// Disc physics shared by golf, pool and bowling.

class DiscWorld {
  final List<Disc> discs;
  final List<Box> walls;
  final Box bounds;
  double restitution;
  DiscWorld(this.discs, this.walls, this.bounds, {this.restitution = 0.8});

  static void collideBox(Disc d, Box w, double e) {
    final cx = clampD(d.x, w.l, w.r), cy = clampD(d.y, w.t, w.b);
    var nx = d.x - cx, ny = d.y - cy;
    var dist = math.sqrt(nx * nx + ny * ny);
    if (dist >= d.r) return;
    if (dist < 1e-6) {
      // centre inside: push out along the shallowest side
      final dl = d.x - w.l, dr = w.r - d.x, dt = d.y - w.t, db = w.b - d.y;
      final mn = math.min(math.min(dl, dr), math.min(dt, db));
      if (mn == dl) {
        nx = -1;
        ny = 0;
      } else if (mn == dr) {
        nx = 1;
        ny = 0;
      } else if (mn == dt) {
        nx = 0;
        ny = -1;
      } else {
        nx = 0;
        ny = 1;
      }
      dist = 0;
    } else {
      nx /= dist;
      ny /= dist;
    }
    final pen = d.r - dist;
    d.x += nx * pen;
    d.y += ny * pen;
    final vn = d.vx * nx + d.vy * ny;
    if (vn < 0) {
      d.vx -= (1 + e) * vn * nx;
      d.vy -= (1 + e) * vn * ny;
    }
  }

  static void collideBounds(Disc d, Box b, double e) {
    if (d.x - d.r < b.l) {
      d.x = b.l + d.r;
      d.vx = d.vx.abs() * e;
    } else if (d.x + d.r > b.r) {
      d.x = b.r - d.r;
      d.vx = -d.vx.abs() * e;
    }
    if (d.y - d.r < b.t) {
      d.y = b.t + d.r;
      d.vy = d.vy.abs() * e;
    } else if (d.y + d.r > b.b) {
      d.y = b.b - d.r;
      d.vy = -d.vy.abs() * e;
    }
  }

  static bool collidePair(Disc a, Disc b, double e) {
    final dx = b.x - a.x, dy = b.y - a.y;
    final rr = a.r + b.r;
    final d2 = dx * dx + dy * dy;
    if (d2 >= rr * rr || d2 < 1e-9) return false;
    final dist = math.sqrt(d2);
    final nx = dx / dist, ny = dy / dist;
    final pen = rr - dist;
    final ta = b.m / (a.m + b.m), tb = a.m / (a.m + b.m);
    a.x -= nx * pen * ta;
    a.y -= ny * pen * ta;
    b.x += nx * pen * tb;
    b.y += ny * pen * tb;
    final rv = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny;
    if (rv > 0) return true;
    final j = -(1 + e) * rv / (1 / a.m + 1 / b.m);
    a.vx -= j * nx / a.m;
    a.vy -= j * ny / a.m;
    b.vx += j * nx / b.m;
    b.vy += j * ny / b.m;
    return true;
  }
}

// ---------------------------------------------------------------------------
// Mini golf

class GolfHole {
  final double sx, sy, hx, hy;
  final List<Box> walls;
  final List<Box> sand, water;
  final Box? mover; // slides horizontally
  final double moverAmp, moverSpeed;
  final int par;
  final int limit;
  GolfHole(this.sx, this.sy, this.hx, this.hy, this.walls, this.sand, this.water, this.mover, this.moverAmp,
      this.moverSpeed, this.par, this.limit);
}

const double kGolfBallR = 14, kCupR = 24;
final kGolfArea = Box(60, 160, 940, 1540);

bool _segBox(double x0, double y0, double x1, double y1, Box b) {
  for (var i = 0; i <= 40; i++) {
    final t = i / 40;
    if (b.contains(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)) return true;
  }
  return false;
}

GolfHole makeGolfHole(int seed, int d) {
  final r = SeededRandom(seed);
  final hx = 180.0 + r.nextDouble() * 640, hy = 260.0 + r.nextDouble() * 160;
  final sx = 200.0 + r.nextDouble() * 600, sy = 1400.0 - r.nextDouble() * 60;
  final walls = <Box>[];
  final n = (1 + d ~/ 2).clamp(1, 5);
  // horizontal bars with guaranteed gaps
  for (var i = 0; i < n; i++) {
    final y = 520.0 + (i + 0.5) * (760 / n) + r.nextDouble() * 60 - 30;
    final w = 260.0 + r.nextDouble() * (220 + d * 12);
    final fromLeft = r.chance(0.5);
    final x0 = fromLeft ? kGolfArea.l : kGolfArea.r - w;
    walls.add(Box(x0, y, x0 + w, y + 26));
    if (d >= 6 && r.chance(0.4)) {
      // a short post in the remaining gap
      final gx = fromLeft ? x0 + w + 120 + r.nextDouble() * 120 : x0 - 150 - r.nextDouble() * 120;
      walls.add(Box(gx, y - 50, gx + 26, y + 76));
    }
  }
  final sand = <Box>[], water = <Box>[];
  bool free(Box b) =>
      !b.inflate(60).contains(hx, hy) &&
      !b.inflate(70).contains(sx, sy) &&
      walls.every((w) => !(b.l < w.r + 30 && b.r > w.l - 30 && b.t < w.b + 30 && b.b > w.t - 30));
  for (var k = 0; k < 40 && sand.length < (d >= 2 ? 1 + d ~/ 5 : 0); k++) {
    final x = 120 + r.nextDouble() * 600, y = 300 + r.nextDouble() * 1000;
    final b = Box(x, y, x + 140 + r.nextDouble() * 80, y + 90 + r.nextDouble() * 50);
    if (free(b)) sand.add(b);
  }
  for (var k = 0; k < 40 && water.length < (d >= 4 ? 1 + (d >= 8 ? 1 : 0) : 0); k++) {
    final x = 120 + r.nextDouble() * 600, y = 360 + r.nextDouble() * 900;
    final b = Box(x, y, x + 150 + r.nextDouble() * 90, y + 80 + r.nextDouble() * 40);
    if (free(b) && sand.every((s) => !(b.l < s.r && b.r > s.l && b.t < s.b && b.b > s.t))) water.add(b);
  }
  Box? mover;
  var amp = 0.0, spd = 0.0;
  if (d >= 5) {
    final y = 380 + r.nextDouble() * 80;
    mover = Box(450, y + (hy > 340 ? 140 : 120), 550, y + (hy > 340 ? 162 : 142));
    amp = 220 + r.nextDouble() * 120;
    spd = 0.012 + d * 0.0015;
  }
  var par = 2;
  for (final w in [...walls, ...water]) {
    if (_segBox(sx, sy, hx, hy, w.inflate(kGolfBallR))) {
      par = 3;
      break;
    }
  }
  if (walls.length >= 4) par++;
  final slack = d <= 3 ? 3 : 2;
  return GolfHole(sx, sy, hx, hy, walls, sand, water, mover, amp, spd, par, par + slack);
}

class GolfSim extends ShotSim {
  late GolfHole hole;
  late Disc ball;
  int strokes = 0;
  double restX = 0, restY = 0;
  int holesDone = 0, holeInOne = 0, underPar = 0, waterHits = 0;
  int lastStrokes = 0, lastPar = 0;
  GolfSim(super.l) : super.base();

  @override
  void setupRound() {
    hole = makeGolfHole(roundSeed, rd);
    ball = Disc(hole.sx, hole.sy, kGolfBallR, 1, 0);
    restX = hole.sx;
    restY = hole.sy;
    strokes = 0;
    aimAngle = math.atan2(hole.hy - hole.sy, hole.hx - hole.sx);
    aimPower = 0.6;
  }

  Box? moverAt(int t) {
    final m = hole.mover;
    if (m == null) return null;
    final off = hole.moverAmp * math.sin(t * hole.moverSpeed);
    return Box(m.l + off, m.t, m.r + off, m.b);
  }

  @override
  double get roundProgress => 0;

  @override
  String get goalText => '${round + 1}${level.rounds > 0 ? '/${level.rounds}' : ''} • $strokes/${hole.limit} (par ${hole.par})';

  @override
  void fire() {
    strokes++;
    final sp = 4 + aimPower * 30;
    ball.vx = math.cos(aimAngle) * sp;
    ball.vy = math.sin(aimAngle) * sp;
  }

  /// One tick of golf physics; returns 0 rolling, 1 holed, 2 water, 3 stopped.
  static int stepBall(GolfHole h, Disc b, Box? mover) {
    for (var s = 0; s < 3; s++) {
      b.x += b.vx / 3;
      b.y += b.vy / 3;
      for (final w in h.walls) {
        DiscWorld.collideBox(b, w, 0.75);
      }
      if (mover != null) DiscWorld.collideBox(b, mover, 0.9);
      DiscWorld.collideBounds(b, kGolfArea, 0.75);
      final dx = b.x - h.hx, dy = b.y - h.hy;
      if (dx * dx + dy * dy < kCupR * kCupR && b.speed < 21) return 1;
    }
    var f = 0.982;
    for (final z in h.sand) {
      if (z.contains(b.x, b.y)) f = 0.9;
    }
    b.vx *= f;
    b.vy *= f;
    for (final z in h.water) {
      if (z.contains(b.x, b.y)) return 2;
    }
    final sp = b.speed;
    if (sp < 0.25) {
      b.vx = 0;
      b.vy = 0;
      return 3;
    }
    // gentle pull into the cup edge
    final dx = h.hx - b.x, dy = h.hy - b.y;
    final dd = math.sqrt(dx * dx + dy * dy);
    if (dd < kCupR * 1.8 && sp < 6) {
      b.vx += dx / dd * 0.25;
      b.vy += dy / dd * 0.25;
    }
    return 0;
  }

  @override
  bool flight() {
    final res = stepBall(hole, ball, moverAt(ticks));
    if (res == 0) {
      if (phaseTicks > 900) {
        ball.vx = 0;
        ball.vy = 0;
      } else {
        return false;
      }
    }
    if (res == 1) {
      holesDone++;
      if (strokes == 1) holeInOne++;
      if (strokes < hole.par) underPar++;
      lastStrokes = strokes;
      lastPar = hole.par;
      score += math.max(1, hole.limit - strokes + 1) * 100 + (strokes == 1 ? 500 : 0);
      say(strokes == 1
          ? 'HOLE IN ONE!'
          : strokes < hole.par
              ? 'BIRDIE!'
              : strokes == hole.par
                  ? 'PAR'
                  : '+${strokes - hole.par}');
      lastEvent = strokes <= hole.par ? 3 : 2;
      roundDone();
      return true;
    }
    if (res == 2) {
      waterHits++;
      strokes++;
      say('SPLASH +1');
      ball = Disc(restX, restY, kGolfBallR, 1, 0);
      lastEvent = 4;
    } else {
      restX = ball.x;
      restY = ball.y;
    }
    if (strokes >= hole.limit && !meta.zen) {
      say('X');
      roundFailed();
    }
    return true;
  }

  @override
  int get quality => lastStrokes <= lastPar ? 3 : (lastStrokes <= lastPar + 1 ? 2 : 1);

  @override
  bool useBooster() {
    // Mulligan: give a stroke back.
    if (over || strokes == 0) return false;
    strokes--;
    return true;
  }

  @override
  Map<String, int> get stats => {
        'shots_taken': shots,
        'holes_completed': holesDone,
        'hole_in_one': holeInOne,
        'under_par': underPar,
      };
}

// ---------------------------------------------------------------------------
// Pool (8 ball style rack clearing)

final kTable = Box(120, 260, 880, 1460);
const double kPoolR = 20, kPocketR = 38;
const kPockets = [
  [120.0, 260.0],
  [880.0, 260.0],
  [120.0, 860.0],
  [880.0, 860.0],
  [120.0, 1460.0],
  [880.0, 1460.0],
];

class PoolSim extends ShotSim {
  final List<Disc> balls = []; // [0] = cue
  int budget = 0, used = 0;
  int potted = 0, racks = 0, scratches = 0, bestRun = 0, run = 0;
  int pottedThisShot = 0;
  bool scratched = false;
  int target = 0, pottedRack = 0;
  PoolSim(super.l) : super.base();

  @override
  void setupRound() {
    final r = SeededRandom(roundSeed);
    final d = rd;
    balls.clear();
    balls.add(Disc(500, 1250, kPoolR, 1, 0));
    final n = (2 + d).clamp(3, 12);
    if (n >= 6 && r.chance(0.5)) {
      // triangle rack
      var id = 1;
      for (var row = 0; row < 5 && id <= n; row++) {
        for (var k = 0; k <= row && id <= n; k++) {
          balls.add(Disc(500 + (k - row / 2) * (kPoolR * 2 + 1), 560 - row * (kPoolR * 1.75), kPoolR, 1, id++));
        }
      }
    } else {
      var id = 1;
      var tries = 0;
      while (id <= n && tries++ < 500) {
        final x = 190 + r.nextDouble() * 620, y = 330 + r.nextDouble() * 760;
        var ok = true;
        for (final b in balls) {
          if ((b.x - x) * (b.x - x) + (b.y - y) * (b.y - y) < 80 * 80) ok = false;
        }
        for (final p in kPockets) {
          if ((p[0] - x) * (p[0] - x) + (p[1] - y) * (p[1] - y) < 90 * 90) ok = false;
        }
        if (ok) balls.add(Disc(x, y, kPoolR, 1, id++));
      }
    }
    target = balls.length - 1;
    pottedRack = 0;
    used = 0;
    budget = target + (d <= 3 ? 5 : (d <= 7 ? 4 : 3));
    aimAngle = -math.pi / 2;
    aimPower = 0.6;
  }

  @override
  double get roundProgress => target == 0 ? 1 : pottedRack / target;

  @override
  String get goalText => '$pottedRack/$target • ${budget - used}';

  @override
  void fire() {
    used++;
    pottedThisShot = 0;
    scratched = false;
    final sp = 3 + aimPower * 37;
    balls[0].vx = math.cos(aimAngle) * sp;
    balls[0].vy = math.sin(aimAngle) * sp;
  }

  /// Physics tick; returns true while anything moves. Pots are reported via [onPot].
  static bool stepTable(List<Disc> bs, void Function(Disc) onPot) {
    for (var s = 0; s < 2; s++) {
      for (final b in bs) {
        if (!b.live) continue;
        b.x += b.vx / 2;
        b.y += b.vy / 2;
      }
      for (var i = 0; i < bs.length; i++) {
        final a = bs[i];
        if (!a.live) continue;
        for (var j = i + 1; j < bs.length; j++) {
          final b = bs[j];
          if (b.live) DiscWorld.collidePair(a, b, 0.95);
        }
      }
      for (final b in bs) {
        if (!b.live) continue;
        for (final p in kPockets) {
          final dx = b.x - p[0], dy = b.y - p[1];
          if (dx * dx + dy * dy < kPocketR * kPocketR) {
            b.live = false;
            b.vx = 0;
            b.vy = 0;
            onPot(b);
            break;
          }
        }
        if (b.live) DiscWorld.collideBounds(b, kTable, 0.8);
      }
    }
    var moving = false;
    for (final b in bs) {
      if (!b.live) continue;
      b.vx *= 0.986;
      b.vy *= 0.986;
      if (b.speed < 0.08) {
        b.vx = 0;
        b.vy = 0;
      } else {
        moving = true;
      }
    }
    return moving;
  }

  @override
  bool flight() {
    final moving = stepTable(balls, (b) {
      if (b.id == 0) {
        scratched = true;
      } else {
        pottedThisShot++;
        pottedRack++;
        potted++;
        score += 100;
      }
    });
    if (moving && phaseTicks < 1200) return false;
    if (pottedThisShot > 0) {
      run += pottedThisShot;
      bestRun = math.max(bestRun, run);
      say(pottedThisShot > 1 ? 'x$pottedThisShot!' : 'IN!');
      lastEvent = pottedThisShot > 1 ? 3 : 2;
    } else {
      run = 0;
    }
    if (scratched) {
      scratches++;
      score = math.max(0, score - 50);
      say('FOUL');
      final c = balls[0];
      c.live = true;
      c.x = 500;
      c.y = 1250;
      // nudge out of other balls
      for (var k = 0; k < 20; k++) {
        if (balls.skip(1).every((b) => !b.live || math.pow(b.x - c.x, 2) + math.pow(b.y - c.y, 2) > 45 * 45)) break;
        c.x = 220 + (k * 97) % 560;
      }
    }
    if (pottedRack >= target) {
      racks++;
      score += (budget - used) * 50;
      roundDone();
      return true;
    }
    if (used >= budget && !meta.zen) roundFailed();
    return true;
  }

  @override
  int get quality => scratches == 0 ? 3 : (scratches <= 2 ? 2 : 1);

  @override
  bool useBooster() {
    if (over) return false;
    budget += 2;
    return true;
  }

  @override
  Map<String, int> get stats => {
        'shots_taken': shots,
        'balls_potted': potted,
        'racks_cleared': racks,
        'best_run': bestRun,
      };
}

// ---------------------------------------------------------------------------
// Bowling

const double kLaneL = 380, kLaneR = 620, kFoulY = 1440, kHeadPinY = 360;
const double kBowlR = 28, kPinR = 12;

List<Disc> rackPins() {
  final pins = <Disc>[];
  var id = 1;
  for (var row = 0; row < 4; row++) {
    for (var k = 0; k <= row; k++) {
      pins.add(Disc(500 + (k - row / 2) * 62, kHeadPinY - row * 54, kPinR, 1, id++));
    }
  }
  return pins;
}

class BowlingSim extends ShotSim {
  int frames = 0, target = 0;
  final List<int> rolls = [];
  List<Disc> pins = rackPins();
  late Disc ball;
  double ballX = 500;
  int frame = 0, rollInFrame = 0;
  int strikes = 0, spares = 0, knocked = 0, gamesWon = 0;
  int lastDown = 0;
  bool inGutter = false;
  BowlingSim(super.l) : super.base();

  @override
  void setupRound() {
    final d = rd;
    frames = (3 + d ~/ 2).clamp(3, 10);
    target = frames * (6 + d);
    rolls.clear();
    cur.clear();
    standing = 10;
    frame = 0;
    rollInFrame = 0;
    pins = rackPins();
    ball = Disc(ballX, kFoulY, kBowlR, 5, 0);
    aimAngle = -math.pi / 2;
    aimPower = 0.8;
  }

  static int scoreOf(List<int> rolls, int frames) {
    var s = 0, i = 0;
    for (var f = 0; f < frames && i < rolls.length; f++) {
      final last = f == frames - 1;
      if (rolls[i] == 10) {
        s += 10 + (i + 1 < rolls.length ? rolls[i + 1] : 0) + (i + 2 < rolls.length ? rolls[i + 2] : 0);
        i += last ? 3 : 1;
      } else if (i + 1 < rolls.length && rolls[i] + rolls[i + 1] == 10) {
        s += 10 + (i + 2 < rolls.length ? rolls[i + 2] : 0);
        i += last ? 3 : 2;
      } else {
        s += rolls[i] + (i + 1 < rolls.length ? rolls[i + 1] : 0);
        i += 2;
      }
    }
    return s;
  }

  int get gameScore => scoreOf(rolls, frames);

  @override
  double get roundProgress => target == 0 ? 0 : gameScore / target;

  @override
  String get goalText => '${math.min(frame + 1, frames)}/$frames • $gameScore/$target';

  @override
  bool preAim(ArcadeInput i) {
    if (i.down && i.hasPointer && i.y > kFoulY - 40) {
      ballX = clampD(i.x, kLaneL + kBowlR, kLaneR - kBowlR);
      ball.x = ballX;
      return true;
    }
    return false;
  }

  @override
  void clampAim() {
    aimAngle = clampD(aimAngle, -math.pi / 2 - 0.22, -math.pi / 2 + 0.22);
  }

  @override
  void dragAim(double dx, double dy) {
    super.dragAim(dx, dy);
    clampAim();
  }

  @override
  void fire() {
    final sp = 14 + aimPower * 16;
    ball = Disc(ballX, kFoulY, kBowlR, 5, 0)
      ..vx = math.cos(aimAngle) * sp
      ..vy = math.sin(aimAngle) * sp;
    inGutter = false;
  }

  /// Returns true while anything moves.
  static bool stepLane(Disc ball, List<Disc> pins, bool Function() gutter, void Function() setGutter,
      {bool bumpers = false}) {
    for (var s = 0; s < 3; s++) {
      if (ball.live) {
        ball.x += ball.vx / 3;
        ball.y += ball.vy / 3;
        if (bumpers) {
          if (ball.x < kLaneL + kBowlR) {
            ball.x = kLaneL + kBowlR;
            ball.vx = ball.vx.abs() * 0.6;
          } else if (ball.x > kLaneR - kBowlR) {
            ball.x = kLaneR - kBowlR;
            ball.vx = -ball.vx.abs() * 0.6;
          }
        }
        if (!gutter() && (ball.x < kLaneL || ball.x > kLaneR)) {
          setGutter();
          ball.vx = 0;
        }
      }
      for (final p in pins) {
        if (!p.live) continue;
        p.x += p.vx / 3;
        p.y += p.vy / 3;
      }
      if (!gutter() && ball.live) {
        for (final p in pins) {
          if (p.live) DiscWorld.collidePair(ball, p, 0.7);
        }
      }
      for (var i = 0; i < pins.length; i++) {
        if (!pins[i].live) continue;
        for (var j = i + 1; j < pins.length; j++) {
          if (pins[j].live) DiscWorld.collidePair(pins[i], pins[j], 0.75);
        }
      }
    }
    if (ball.y < 120) ball.live = false;
    var moving = ball.live;
    for (final p in pins) {
      if (!p.live) continue;
      p.vx *= 0.93;
      p.vy *= 0.93;
      if (p.x < kLaneL - 20 || p.x > kLaneR + 20 || p.y < 100) p.live = false;
      if (p.speed > 0.1) moving = true;
    }
    return moving;
  }

  static int countDown(List<Disc> pins) {
    var n = 0;
    for (final p in pins) {
      if (!p.live || (p.x - p.ox).abs() + (p.y - p.oy).abs() > 10) n++;
    }
    return n;
  }

  int standing = 10;
  final List<int> cur = [];

  @override
  bool flight() {
    final moving = stepLane(ball, pins, () => inGutter, () => inGutter = true, bumpers: bumpers > 0);
    if (moving && phaseTicks < 500) return false;
    bumpers = 0;
    final down = countDown(pins) - (10 - standing);
    lastDown = down;
    knocked += down;
    rolls.add(down);
    cur.add(down);
    score += down * 10;
    standing -= down;
    final last = frame == frames - 1;
    var frameOver = false, rerack = false, gameOver = false;
    if (down == 10) {
      strikes++;
      score += 100;
      say('STRIKE!');
      lastEvent = 3;
    } else if (standing == 0) {
      spares++;
      score += 50;
      say('SPARE!');
      lastEvent = 2;
    } else if (inGutter) {
      say('GUTTER');
      lastEvent = 4;
    } else {
      say('$down');
    }
    if (!last) {
      if (standing == 0 || cur.length == 2) frameOver = true;
    } else {
      if (cur.length == 3) {
        gameOver = true;
      } else if (cur.length == 2 && cur[0] < 10 && cur[0] + cur[1] < 10) {
        gameOver = true;
      } else if (standing == 0) {
        rerack = true;
      }
    }
    if (frameOver) {
      frame++;
      cur.clear();
      rerack = true;
    }
    if (rerack) {
      pins = rackPins();
      standing = 10;
    } else {
      _clearFallen();
    }
    ball = Disc(ballX, kFoulY, kBowlR, 5, 0);
    if (gameOver) {
      if (gameScore >= target) {
        gamesWon++;
        roundDone();
      } else if (meta.zen) {
        setupRound();
      } else {
        roundFailed();
      }
    } else if (!meta.zen && gameScore + _maxRemaining() < target) {
      roundFailed();
    }
    return true;
  }

  int _maxRemaining() => (frames - frame) * 30;

  void _clearFallen() {
    for (final p in pins) {
      if ((p.x - p.ox).abs() + (p.y - p.oy).abs() > 10) p.live = false;
      p.vx = 0;
      p.vy = 0;
      if (p.live) {
        p.x = p.ox;
        p.y = p.oy;
      }
    }
  }

  @override
  int get quality => gameScore >= target * 1.4 ? 3 : (gameScore >= target * 1.15 ? 2 : 1);

  @override
  bool useBooster() {
    // Bumpers for the next roll: lane guards keep the ball out of the gutter.
    if (over || phase == 1) return false;
    bumpers = 1;
    return true;
  }

  int bumpers = 0;

  @override
  Map<String, int> get stats => {
        'shots_taken': shots,
        'strikes': strikes,
        'spares': spares,
        'pins_knocked': knocked,
      };
}

// ---------------------------------------------------------------------------
// Basketball (side view)

const double kFloorY = 1460, kHoopR = 30, kRimHalf = 46, kRimR = 7;

class HoopSim extends ShotSim {
  double bx = 0, by = 0, vx = 0, vy = 0;
  double sx = 300, sy = 1250; // shooter spot
  double hx0 = 760, hy = 620, amp = 0, hspd = 0;
  int need = 3, attempts = 6, made = 0, taken = 0;
  int baskets = 0, swishes = 0, streak = 0, bestStreak = 0;
  bool touched = false, scored = false;
  int bounces = 0;
  HoopSim(super.l) : super.base();

  double hxAt(int t) => hx0 + amp * math.sin(t * hspd);

  @override
  void setupRound() {
    final r = SeededRandom(roundSeed);
    final d = rd;
    need = (3 + d ~/ 2).clamp(3, 8);
    attempts = need + (d <= 3 ? 4 : (d <= 7 ? 3 : 2));
    made = 0;
    taken = 0;
    hy = 560.0 + r.nextDouble() * 140;
    hx0 = 740.0 + r.nextDouble() * 60;
    amp = d >= 4 ? 40.0 + d * 12 : 0;
    hspd = d >= 4 ? 0.012 + d * 0.0016 : 0;
    _newSpot();
    aimAngle = -math.pi / 3;
    aimPower = 0.6;
  }

  void _newSpot() {
    final r = SeededRandom(mixSeed([roundSeed, taken, 77]));
    sx = 140.0 + r.nextDouble() * 360;
    sy = 1180.0 + r.nextDouble() * 140;
    bx = sx;
    by = sy;
    vx = 0;
    vy = 0;
  }

  @override
  void dragAim(double dx, double dy) {
    // flick toward the hoop
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 4) return;
    aimAngle = math.atan2(dy, dx);
    aimPower = (len / 450).clamp(0.0, 1.0);
  }

  @override
  double get roundProgress => made / need;

  @override
  String get goalText => '$made/$need • ${attempts - taken}';

  @override
  void fire() {
    taken++;
    final sp = 12 + aimPower * 30;
    vx = math.cos(aimAngle) * sp;
    vy = math.sin(aimAngle) * sp;
    touched = false;
    scored = false;
    bounces = 0;
  }

  /// One tick; returns 0 flying, 1 scored now, 2 dead ball.
  static int stepHoop(_HoopBall b, double hx, double hy) {
    for (var s = 0; s < 3; s++) {
      final py = b.y;
      b.vy += 0.55 / 3;
      b.x += b.vx / 3;
      b.y += b.vy / 3;
      // rims
      for (final rx in [hx - kRimHalf, hx + kRimHalf]) {
        final dx = b.x - rx, dy = b.y - hy;
        final rr = kHoopR + kRimR;
        final d2 = dx * dx + dy * dy;
        if (d2 < rr * rr && d2 > 1e-9) {
          final dist = math.sqrt(d2);
          final nx = dx / dist, ny = dy / dist;
          b.x = rx + nx * rr;
          b.y = hy + ny * rr;
          final vn = b.vx * nx + b.vy * ny;
          if (vn < 0) {
            b.vx -= 1.6 * vn * nx;
            b.vy -= 1.6 * vn * ny;
          }
          b.touched = true;
        }
      }
      // backboard: vertical segment right of the hoop
      final bbx = hx + kRimHalf + 26;
      if (b.y > hy - 200 && b.y < hy + 30 && (b.x + kHoopR > bbx) && b.x < bbx + 10 && b.vx > 0) {
        b.x = bbx - kHoopR;
        b.vx = -b.vx * 0.6;
        b.touched = true;
      }
      // through the hoop: centre crosses rim height going down inside
      if (!b.scored && b.vy > 0 && py < hy && b.y >= hy && (b.x - hx).abs() < kRimHalf - 6) {
        b.scored = true;
        return 1;
      }
      if (b.y + kHoopR > kFloorY) {
        b.y = kFloorY - kHoopR;
        b.vy = -b.vy * 0.55;
        b.vx *= 0.8;
        b.bounces++;
      }
    }
    if (b.bounces >= 2 || b.x < -80 || b.x > kWorldW + 80) return 2;
    return 0;
  }

  @override
  bool flight() {
    final b = _HoopBall(bx, by, vx, vy)
      ..touched = touched
      ..scored = scored
      ..bounces = bounces;
    final res = stepHoop(b, hxAt(ticks), hy);
    bx = b.x;
    by = b.y;
    vx = b.vx;
    vy = b.vy;
    touched = b.touched;
    scored = b.scored;
    bounces = b.bounces;
    if (res == 1) {
      made++;
      baskets++;
      streak++;
      bestStreak = math.max(bestStreak, streak);
      final swish = !touched;
      if (swish) swishes++;
      score += 100 + (swish ? 50 : 0) + streak * 10;
      say(swish ? 'SWISH!' : 'SCORE!');
      lastEvent = swish ? 3 : 2;
    }
    if (res == 2 || phaseTicks > 400) {
      if (!scored) {
        streak = 0;
        say('MISS');
        lastEvent = 4;
      }
      if (made >= need) {
        score += (attempts - taken) * 60;
        roundDone();
      } else if (!meta.zen && attempts - taken < need - made) {
        roundFailed();
      } else {
        _newSpot();
      }
      return true;
    }
    return false;
  }

  @override
  int get quality => taken - made <= 1 ? 3 : (taken - made <= 2 ? 2 : 1);

  @override
  bool useBooster() {
    if (over) return false;
    attempts += 2;
    return true;
  }

  @override
  Map<String, int> get stats => {
        'shots_taken': shots,
        'baskets': baskets,
        'swishes': swishes,
        'best_streak': bestStreak,
      };
}

class _HoopBall {
  double x, y, vx, vy;
  bool touched = false, scored = false;
  int bounces = 0;
  _HoopBall(this.x, this.y, this.vx, this.vy);
}

// ---------------------------------------------------------------------------
// Archery & darts: hold to aim (the reticle sways), release to shoot.

abstract class ThrowSim extends ShotSim {
  double hitX = 0, hitY = 0;
  double fromX = 500, fromY = 1500;
  bool shown = false;
  final List<List<double>> marks = []; // landed shots of this round
  ThrowSim(super.l) : super.base();

  @override
  bool get usesReticle => true;

  /// Constant drift applied to the shot (gravity / wind).
  (double, double) drift();

  int get flightTicks => 22;

  @override
  void fire() {
    final (dx, dy) = drift();
    hitX = retX + dx;
    hitY = retY + dy;
  }

  @override
  bool flight() {
    if (phaseTicks < flightTicks) return false;
    marks.add([hitX, hitY]);
    land(hitX, hitY);
    return true;
  }

  void land(double x, double y);
}

class ArcherySim extends ThrowSim {
  double cx0 = 500, cy = 640, radius = 240, wind = 0, moveAmp = 0, moveSpd = 0;
  int arrows = 6, shot = 0, need = 40, points = 0;
  int bulls = 0, arrowsTotal = 0, tens = 0;
  ArcherySim(super.l);

  double cxAt(int t) => cx0 + moveAmp * math.sin(t * moveSpd);

  @override
  void setupRound() {
    final r = SeededRandom(roundSeed);
    final d = rd;
    radius = 260.0 - d * 9;
    arrows = 6;
    need = 6 * (4 + d ~/ 2) + (d >= 8 ? 4 : 0);
    shot = 0;
    points = 0;
    marks.clear();
    wind = d >= 2 ? (r.nextDouble() * 2 - 1) * (0.6 + d * 0.25) : 0;
    moveAmp = d >= 6 ? 60.0 + d * 10 : 0;
    moveSpd = d >= 6 ? 0.02 + d * 0.002 : 0;
    cx0 = 500;
    cy = 620.0 + r.nextDouble() * 60;
    baseX = 500;
    baseY = cy + 40;
  }

  @override
  double swayAmp() => 7 + rd * 1.6 + math.max(0, holdTicks - 150) * 0.25;

  @override
  (double, double) drift() => (wind * 22, 36.0 + rd * 2);

  @override
  int get flightTicks => 26;

  @override
  void land(double x, double y) {
    shot++;
    arrowsTotal++;
    final cx = cxAt(ticks);
    final dist = math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
    final ring = dist >= radius ? 0 : 10 - (dist / (radius / 10)).floor();
    marks.last.add(x - cx);
    points += ring;
    score += ring * 10;
    if (ring == 10) {
      tens++;
      if (dist < radius / 20) bulls++;
      say(dist < radius / 20 ? 'X!' : '10!');
      lastEvent = 3;
    } else if (ring >= 7) {
      say('$ring');
      lastEvent = 2;
    } else {
      say(ring == 0 ? 'MISS' : '$ring');
      lastEvent = 4;
    }
    if (points >= need && shot >= arrows) {
      roundDone();
    } else if (shot >= arrows) {
      if (points >= need) {
        roundDone();
      } else if (meta.zen) {
        setupRound();
      } else {
        roundFailed();
      }
    }
  }

  @override
  double get roundProgress => points / need;

  @override
  String get goalText => '$points/$need • ${arrows - shot}';

  @override
  int get quality => points >= need + 8 ? 3 : (points >= need + 3 ? 2 : 1);

  @override
  bool useBooster() {
    // Focus: next shot without sway.
    if (over) return false;
    focus = 1;
    return true;
  }

  int focus = 0;

  @override
  (double, double) sway() {
    if (focus > 0) return (0, 0);
    return super.sway();
  }

  @override
  void fire() {
    super.fire();
    focus = 0;
  }

  @override
  Map<String, int> get stats => {
        'shots_taken': shots,
        'arrows': arrowsTotal,
        'tens': tens,
        'bullseyes': bulls,
      };
}

class DartsSim extends ThrowSim {
  static const double cx = 500, cy = 700, rBoard = 300;
  int start = 101, remaining = 101, turnStart = 101, dartInTurn = 0, darts = 0, limit = 15;
  bool doubleOut = false;
  int legs = 0, triples = 0, bulls = 0, thrown = 0, best = 0;
  int lastPts = 0;
  DartsSim(super.l);

  @override
  void setupRound() {
    final d = rd;
    start = d <= 2 ? 101 : (d <= 5 ? 201 : (d <= 8 ? 301 : 501));
    remaining = start;
    turnStart = start;
    dartInTurn = 0;
    darts = 0;
    doubleOut = d >= 7;
    limit = (start / 20).ceil() + (d <= 4 ? 9 : 7);
    marks.clear();
    baseX = cx;
    baseY = cy;
  }

  @override
  double swayAmp() => 4 + rd * 1.2 + math.max(0, holdTicks - 150) * 0.2;

  @override
  (double, double) drift() => (0, 18);

  /// Points and multiplier for a board position.
  static (int, int) scoreAt(double x, double y) {
    final dx = x - cx, dy = y - cy;
    final r = math.sqrt(dx * dx + dy * dy);
    if (r <= 11) return (50, 2);
    if (r <= 28) return (25, 1);
    if (r > rBoard) return (0, 0);
    var ang = math.atan2(dx, -dy) * 180 / math.pi; // 0 = up, clockwise
    if (ang < 0) ang += 360;
    final idx = ((ang + 9) % 360 ~/ 18);
    final base = kDartSectors[idx];
    if (r >= 175 && r <= 189) return (base * 3, 3);
    if (r >= 286) return (base * 2, 2);
    return (base, 1);
  }

  /// Centre of a sector ring: mult 1 inner single, 3 triple, 2 double.
  static (double, double) aimPoint(int sector, int mult) {
    if (sector == 25) return (cx, cy);
    if (sector == 50) return (cx, cy);
    final idx = kDartSectors.indexOf(sector);
    final ang = idx * 18 * math.pi / 180;
    final r = mult == 3 ? 182.0 : (mult == 2 ? 293.0 : 120.0);
    return (cx + math.sin(ang) * r, cy - math.cos(ang) * r);
  }

  @override
  void land(double x, double y) {
    darts++;
    thrown++;
    dartInTurn++;
    final (pts, mult) = scoreAt(x, y);
    lastPts = pts;
    if (mult == 3) triples++;
    if (pts == 50) bulls++;
    final after = remaining - pts;
    final bust = after < 0 || (doubleOut && (after == 1 || (after == 0 && mult != 2)));
    if (bust) {
      remaining = turnStart;
      dartInTurn = 3;
      say('BUST');
      lastEvent = 4;
    } else {
      remaining = after;
      score += pts;
      say(pts == 0 ? 'MISS' : (mult == 3 ? 'T${pts ~/ 3}' : (mult == 2 && pts != 50 ? 'D${pts ~/ 2}' : '$pts')));
      lastEvent = pts >= 40 ? 3 : (pts > 0 ? 2 : 4);
    }
    if (dartInTurn >= 3) {
      best = math.max(best, turnStart - remaining);
      dartInTurn = 0;
      turnStart = remaining;
      marks.clear();
    }
    if (remaining == 0) {
      legs++;
      score += (limit - darts) * 30 + 200;
      say('GAME SHOT!');
      lastEvent = 3;
      roundDone();
      return;
    }
    if (darts >= limit) {
      if (meta.zen) {
        setupRound();
      } else {
        roundFailed();
      }
    }
  }

  @override
  double get roundProgress => (start - remaining) / start;

  @override
  String get goalText => '$remaining • ${limit - darts}';

  @override
  int get quality => darts <= limit - 4 ? 3 : (darts <= limit - 2 ? 2 : 1);

  @override
  bool useBooster() {
    if (over) return false;
    limit += 3;
    return true;
  }

  @override
  Map<String, int> get stats => {
        'darts_thrown': thrown,
        'legs_won': legs,
        'triples': triples,
        'bullseyes': bulls,
      };
}

// ---------------------------------------------------------------------------
// Penalty shoot-out: shoot (aim with the reticle) and save (move the keeper).

const double kGoalL = 200, kGoalR = 800, kGoalT = 420, kGoalB = 700;

class PenaltySim extends ShotSim {
  int kick = 0; // kicks taken in the shoot-out (both teams)
  int myGoals = 0, cpuGoals = 0, myKicks = 0, cpuKicks = 0;
  bool shooting = true; // player's turn to shoot
  // keeper (always drawn on the goal line)
  double kx = 500, ky = 640, ktx = 500, kty = 640;
  // ball flight
  double ballX = 500, ballY = 1300, tgtX = 500, tgtY = 560, flyT = 30;
  int runUp = 0;
  int kickPhase = 0; // save turn: 0 run-up, 1 flying
  double guessX = 500, guessY = 600; // cpu keeper plan
  int goals = 0, saves = 0, shootouts = 0;
  final List<bool> myRes = [], cpuRes = [];
  int superKeeper = 0;
  PenaltySim(super.l) : super.base();

  @override
  bool get usesReticle => shooting;

  @override
  void setupRound() {
    kick = 0;
    myGoals = 0;
    cpuGoals = 0;
    myKicks = 0;
    cpuKicks = 0;
    shooting = true;
    myRes.clear();
    cpuRes.clear();
    _prepare();
  }

  SeededRandom get _kr => SeededRandom(mixSeed([roundSeed, kick, 4242]));

  void _prepare() {
    kx = 500;
    ky = 640;
    ktx = 500;
    kty = 640;
    ballX = 500;
    ballY = 1300;
    runUp = 0;
    kickPhase = 0;
    baseX = 500;
    baseY = 560;
    final r = _kr;
    if (shooting) {
      // cpu keeper commits to a side (better keepers read the shot more often)
      final side = r.nextInt(3); // 0 left, 1 middle, 2 right
      guessX = side == 0 ? 330 : (side == 1 ? 500 : 670);
      guessY = 560 + r.nextDouble() * 100;
    } else {
      final d = rd;
      final onTarget = r.chance(0.86 + d * 0.012);
      final corner = r.nextDouble();
      final sideX = r.chance(0.5) ? -1 : 1;
      tgtX = 500 + sideX * (onTarget ? 60 + corner * 220 : 330 + corner * 40);
      tgtY = onTarget ? 470 + r.nextDouble() * 200 : 380 + r.nextDouble() * 20;
      flyT = (44 - d * 1.8).clamp(26, 44);
    }
  }

  @override
  double swayAmp() => 8 + rd * 1.4 + math.max(0, holdTicks - 120) * 0.3;

  @override
  double get roundProgress => 0;

  @override
  String get goalText => '$myGoals-$cpuGoals • ${math.min(myKicks + (shooting ? 1 : 0), 99)}';

  @override
  void fire() {
    tgtX = retX;
    tgtY = retY;
    flyT = 28;
    ballX = 500;
    ballY = 1300;
  }

  @override
  void update(ArcadeInput input) {
    if (!shooting && phase == 0) {
      // save turn: keeper follows the finger / keys, cpu runs up and shoots
      lastEvent = 0;
      phaseTicks++;
      if (flashTicks > 0) flashTicks--;
      _moveKeeperInput(input);
      runUp++;
      if (runUp >= 50) {
        phase = 1;
        phaseTicks = 0;
        shots++;
        lastEvent = 1;
      }
      _keeperStep(16);
      return;
    }
    if (!shooting && phase == 1) {
      _moveKeeperInput(input);
    }
    super.update(input);
  }

  void _moveKeeperInput(ArcadeInput i) {
    if (i.down && i.hasPointer) {
      ktx = clampD(i.x, kGoalL, kGoalR);
      kty = clampD(i.y, kGoalT + 30, kGoalB - 30);
    }
    if (i.dirX != 0) ktx = clampD(ktx + i.dirX * 18, kGoalL, kGoalR);
    if (i.dirY != 0) kty = clampD(kty + i.dirY * 14, kGoalT + 30, kGoalB - 30);
  }

  void _keeperStep(double speed) {
    final dx = ktx - kx, dy = kty - ky;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d <= speed) {
      kx = ktx;
      ky = kty;
    } else {
      kx += dx / d * speed;
      ky += dy / d * speed;
    }
  }

  bool _covers(double x, double y) {
    final dx = (x - kx).abs(), dy = (y - ky).abs();
    final big = superKeeper > 0 && !shooting;
    return dx < (big ? 150 : 95) && dy < (big ? 120 : 80);
  }

  @override
  bool flight() {
    final t = (phaseTicks / flyT).clamp(0.0, 1.0);
    ballX = 500 + (tgtX - 500) * t;
    ballY = 1300 + (tgtY - 1300) * t - math.sin(t * math.pi) * 120;
    if (shooting) {
      // cpu keeper reacts after a short delay
      if (phaseTicks == 7) {
        final r = _kr;
        final read = r.chance(0.25 + rd * 0.05);
        ktx = read ? tgtX : guessX;
        kty = read ? tgtY : guessY;
      }
      if (phaseTicks > 7) _keeperStep(11 + rd * 0.6);
    } else {
      _keeperStep(17);
    }
    if (phaseTicks < flyT) return false;
    final inside = tgtX > kGoalL + 12 && tgtX < kGoalR - 12 && tgtY > kGoalT + 12 && tgtY < kGoalB;
    final saved = inside && _covers(tgtX, tgtY);
    final goal = inside && !saved;
    kick++;
    if (shooting) {
      myKicks++;
      myRes.add(goal);
      if (goal) {
        myGoals++;
        goals++;
        score += 100;
        say('GOAL!');
        lastEvent = 3;
      } else {
        say(saved ? 'SAVED' : 'MISS');
        lastEvent = 4;
      }
    } else {
      cpuKicks++;
      cpuRes.add(goal);
      superKeeper = 0;
      if (goal) {
        cpuGoals++;
        say('GOAL');
        lastEvent = 4;
      } else {
        if (saved) saves++;
        score += saved ? 100 : 30;
        say(saved ? 'SAVE!' : 'MISS!');
        lastEvent = saved ? 3 : 2;
      }
    }
    shooting = !shooting;
    if (_decided()) {
      if (myGoals > cpuGoals) {
        shootouts++;
        score += 300;
        roundDone();
      } else {
        roundFailed();
      }
    } else {
      _prepare();
    }
    return true;
  }

  bool _decided() {
    if (myKicks <= 5 && cpuKicks <= 5 && !(myKicks == 5 && cpuKicks == 5)) {
      final myLeft = 5 - myKicks, cpuLeft = 5 - cpuKicks;
      if (myGoals + myLeft < cpuGoals) return true;
      if (cpuGoals + cpuLeft < myGoals) return true;
      return false;
    }
    // sudden death after equal kicks
    return myKicks == cpuKicks && myGoals != cpuGoals;
  }

  @override
  int get quality => cpuGoals <= 1 ? 3 : (myGoals - cpuGoals >= 2 ? 2 : 1);

  @override
  bool useBooster() {
    // Super keeper: covers much more of the goal for the next save.
    if (over || superKeeper > 0) return false;
    superKeeper = 1;
    return true;
  }

  @override
  Map<String, int> get stats => {
        'goals_scored': goals,
        'saves': saves,
        'shootouts_won': shootouts,
        'shots_taken': shots,
      };
}

// ---------------------------------------------------------------------------
// Autopilot (level validation + demo). Searches shots with the same physics.

const double _padX = 500, _padY = 800;

/// The aim the game will actually read from quantized pointer positions.
(double, double, int, int) _realizePull(double a, double p, {double scale = 350, bool forward = false}) {
  final s = forward ? 1.0 : -1.0;
  final cx = (_padX + s * math.cos(a) * p * scale).roundToDouble();
  final cy = ((forward ? 1000.0 : _padY) + s * math.sin(a) * p * scale).roundToDouble();
  final dx = cx - _padX, dy = cy - (forward ? 1000.0 : _padY);
  final vx = forward ? dx : -dx, vy = forward ? dy : -dy;
  final len = math.sqrt(vx * vx + vy * vy);
  return (math.atan2(vy, vx), (len / scale).clamp(0.0, 1.0), cx.toInt(), cy.toInt());
}

void _queueDrag(ShotSim s, int cx, int cy, {bool forward = false}) {
  final py = forward ? 1000.0 : _padY;
  s.botQueue
    ..add(ArcadeInput(down: true, x: _padX, y: py))
    ..add(ArcadeInput(down: true, x: cx.toDouble(), y: cy.toDouble()))
    ..add(ArcadeInput(down: false, x: cx.toDouble(), y: cy.toDouble()));
}

ArcadeInput shotBot(ArcadeSim sim) {
  final s = sim as ShotSim;
  if (s.botQueue.isNotEmpty) return s.botQueue.removeAt(0);
  if (s is PenaltySim) return _penaltyBot(s);
  if (s.phase == 1) return ArcadeInput.idle;
  if (s is ThrowSim) return _throwBot(s);
  if (s.aiming) return ArcadeInput(down: false, x: s.curX, y: s.curY);
  switch (s) {
    case GolfSim g:
      _golfPlan(g);
    case PoolSim p:
      _poolPlan(p);
    case BowlingSim b:
      _bowlPlan(b);
    case HoopSim h:
      _hoopPlan(h);
    default:
      break;
  }
  return s.botQueue.isNotEmpty ? s.botQueue.removeAt(0) : ArcadeInput.idle;
}

// golf ------------------------------------------------------------------
final Expando<List<double>> _golfField = Expando();
final Expando<int> _golfFieldKey = Expando();

List<double> _field(GolfSim g) {
  final key = g.roundSeed ^ (g.rd << 20);
  if (_golfFieldKey[g] == key) return _golfField[g]!;
  const cs = 20.0;
  final w = (kWorldW / cs).ceil(), h = (kWorldH / cs).ceil();
  final cost = List<double>.filled(w * h, 1);
  final blocked = List<bool>.filled(w * h, false);
  for (var j = 0; j < h; j++) {
    for (var i = 0; i < w; i++) {
      final x = (i + 0.5) * cs, y = (j + 0.5) * cs;
      if (!kGolfArea.inflate(-kGolfBallR).contains(x, y)) blocked[j * w + i] = true;
      for (final b in g.hole.walls) {
        if (b.inflate(kGolfBallR + 4).contains(x, y)) blocked[j * w + i] = true;
      }
      for (final b in g.hole.water) {
        if (b.inflate(6).contains(x, y)) blocked[j * w + i] = true;
      }
      for (final b in g.hole.sand) {
        if (b.contains(x, y)) cost[j * w + i] = 3;
      }
    }
  }
  final dist = List<double>.filled(w * h, 1e9);
  final gi = (g.hole.hx / cs).floor(), gj = (g.hole.hy / cs).floor();
  dist[gj * w + gi] = 0;
  // simple Dijkstra with a bucketed queue (costs are small)
  final open = <int>[gj * w + gi];
  while (open.isNotEmpty) {
    var bi = 0;
    for (var k = 1; k < open.length; k++) {
      if (dist[open[k]] < dist[open[bi]]) bi = k;
    }
    final c = open.removeAt(bi);
    final ci = c % w, cj = c ~/ w;
    for (final (di, dj, step) in const [(1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0), (1, 1, 1.414), (1, -1, 1.414), (-1, 1, 1.414), (-1, -1, 1.414)]) {
      final ni = ci + di, nj = cj + dj;
      if (ni < 0 || nj < 0 || ni >= w || nj >= h) continue;
      final n = nj * w + ni;
      if (blocked[n]) continue;
      final nd = dist[c] + step * cost[n];
      if (nd < dist[n]) {
        if (dist[n] >= 1e9) open.add(n);
        dist[n] = nd;
      }
    }
  }
  _golfField[g] = dist;
  _golfFieldKey[g] = key;
  return dist;
}

double _fieldAt(List<double> f, double x, double y) {
  const cs = 20.0;
  final w = (kWorldW / cs).ceil();
  final i = (x / cs).floor().clamp(0, w - 1), j = (y / cs).floor().clamp(0, (kWorldH / cs).ceil() - 1);
  return f[j * w + i] * cs;
}

double _golfEval(GolfSim g, List<double> f, double a, double p) {
  final b = Disc(g.ball.x, g.ball.y, kGolfBallR, 1, 0);
  final sp = 4 + p * 30;
  b.vx = math.cos(a) * sp;
  b.vy = math.sin(a) * sp;
  var t = g.ticks + 4;
  for (var k = 0; k < 900; k++) {
    final r = GolfSim.stepBall(g.hole, b, g.moverAt(t++));
    if (r == 1) return -1000 + k * 0.01;
    if (r == 2) return 1e6;
    if (r == 3) break;
  }
  return _fieldAt(f, b.x, b.y) + p * 5;
}

void _golfPlan(GolfSim g) {
  final f = _field(g);
  var best = 1e18, ba = 0.0, bp = 0.5;
  for (var ai = 0; ai < 72; ai++) {
    for (var pi = 0; pi < 9; pi++) {
      final (a, p, _, _) = _realizePull(ai * math.pi * 2 / 72, 0.12 + pi * 0.11);
      final v = _golfEval(g, f, a, p);
      if (v < best) {
        best = v;
        ba = ai * math.pi * 2 / 72;
        bp = 0.12 + pi * 0.11;
      }
    }
  }
  if (best > -500) {
    // refine around the best shot
    final a0 = ba, p0 = bp;
    for (var da = -6; da <= 6; da++) {
      for (var dp = -5; dp <= 5; dp++) {
        final ca = a0 + da * 0.012, cp = (p0 + dp * 0.02).clamp(0.08, 1.0);
        final (a, p, _, _) = _realizePull(ca, cp);
        final v = _golfEval(g, f, a, p);
        if (v < best) {
          best = v;
          ba = ca;
          bp = cp;
        }
      }
    }
  }
  final (_, _, cx, cy) = _realizePull(ba, bp);
  _queueDrag(g, cx, cy);
}

// pool ------------------------------------------------------------------
bool _clearPath(List<Disc> balls, double x0, double y0, double x1, double y1, Set<int> ignore) {
  final dx = x1 - x0, dy = y1 - y0;
  final len2 = dx * dx + dy * dy;
  if (len2 < 1) return true;
  for (final b in balls) {
    if (!b.live || ignore.contains(b.id)) continue;
    final t = (((b.x - x0) * dx + (b.y - y0) * dy) / len2).clamp(0.0, 1.0);
    final px = x0 + dx * t - b.x, py = y0 + dy * t - b.y;
    if (px * px + py * py < (kPoolR * 2) * (kPoolR * 2)) return false;
  }
  return true;
}

double _poolEval(PoolSim s, double a, double p) {
  final bs = [for (final b in s.balls) b.copy()];
  final sp = 3 + p * 37;
  bs[0].vx = math.cos(a) * sp;
  bs[0].vy = math.sin(a) * sp;
  var pots = 0;
  var scratch = false;
  for (var k = 0; k < 1200; k++) {
    final moving = PoolSim.stepTable(bs, (b) {
      if (b.id == 0) {
        scratch = true;
      } else {
        pots++;
      }
    });
    if (!moving) break;
  }
  var v = pots * 1000.0 - (scratch ? 1500 : 0);
  // leave: distance from cue to the nearest remaining ball
  if (!scratch) {
    var near = 1e9;
    for (final b in bs.skip(1)) {
      if (!b.live) continue;
      near = math.min(near, math.sqrt(math.pow(b.x - bs[0].x, 2) + math.pow(b.y - bs[0].y, 2)));
    }
    if (near < 1e9) v -= near * 0.05;
  }
  return v;
}

void _poolPlan(PoolSim s) {
  final cue = s.balls[0];
  final cands = <(double, double)>[];
  for (final b in s.balls.skip(1)) {
    if (!b.live) continue;
    for (final pk in kPockets) {
      final px = pk[0], py = pk[1];
      final dx = px - b.x, dy = py - b.y;
      final dl = math.sqrt(dx * dx + dy * dy);
      final gx = b.x - dx / dl * kPoolR * 2, gy = b.y - dy / dl * kPoolR * 2;
      final ax = gx - cue.x, ay = gy - cue.y;
      final al = math.sqrt(ax * ax + ay * ay);
      if (al < 1) continue;
      final cut = (ax * dx + ay * dy) / (al * dl);
      if (cut < 0.3) continue;
      if (!_clearPath(s.balls, cue.x, cue.y, gx, gy, {0, b.id})) continue;
      if (!_clearPath(s.balls, b.x, b.y, px, py, {0, b.id})) continue;
      final a = math.atan2(ay, ax);
      for (final p in const [0.3, 0.5, 0.7, 0.95]) {
        cands.add((a, p));
      }
    }
  }
  if (cands.length < 8) {
    for (final b in s.balls.skip(1)) {
      if (!b.live) continue;
      final a = math.atan2(b.y - cue.y, b.x - cue.x);
      for (final da in const [-0.06, -0.03, 0.0, 0.03, 0.06]) {
        cands.add((a + da, 0.6));
        cands.add((a + da, 0.95));
      }
    }
  }
  var best = -1e18, ba = -math.pi / 2, bp = 0.6;
  for (final (ca, cp) in cands) {
    final (a, p, _, _) = _realizePull(ca, cp);
    final v = _poolEval(s, a, p);
    if (v > best) {
      best = v;
      ba = ca;
      bp = cp;
    }
  }
  final (_, _, cx, cy) = _realizePull(ba, bp);
  _queueDrag(s, cx, cy);
}

// bowling -----------------------------------------------------------------
int _bowlEval(BowlingSim s, double x, double a, double p) {
  final pins = [for (final q in s.pins) q.copy()];
  final sp = 14 + p * 16;
  final ball = Disc(x, kFoulY, kBowlR, 5, 0)
    ..vx = math.cos(a) * sp
    ..vy = math.sin(a) * sp;
  var gutter = false;
  for (var k = 0; k < 500; k++) {
    if (!BowlingSim.stepLane(ball, pins, () => gutter, () => gutter = true, bumpers: s.bumpers > 0)) break;
  }
  var n = 0;
  for (var i = 0; i < pins.length; i++) {
    final q = pins[i];
    if (s.pins[i].live && (!q.live || (q.x - q.ox).abs() + (q.y - q.oy).abs() > 10)) n++;
  }
  return n;
}

void _bowlPlan(BowlingSim s) {
  var best = -1, bx = 500.0, ba = -math.pi / 2, bp = 0.9;
  for (var xi = 0; xi < 9; xi++) {
    final x = 430.0 + xi * 17.5;
    for (var ai = -10; ai <= 10; ai++) {
      for (final pw in const [0.75, 1.0]) {
        final (a, p, _, _) = _realizePull(-math.pi / 2 + ai * 0.02, pw);
        final ac = clampD(a, -math.pi / 2 - 0.22, -math.pi / 2 + 0.22);
        final v = _bowlEval(s, x.roundToDouble(), ac, p);
        if (v > best) {
          best = v;
          bx = x;
          ba = -math.pi / 2 + ai * 0.02;
          bp = pw;
        }
      }
    }
  }
  s.botQueue
    ..add(ArcadeInput(down: true, x: bx.roundToDouble(), y: 1500))
    ..add(ArcadeInput(down: false, x: bx.roundToDouble(), y: 1500));
  final (_, _, cx, cy) = _realizePull(ba, bp);
  _queueDrag(s, cx, cy);
}

// basketball ----------------------------------------------------------------
double _hoopEval(HoopSim h, double a, double p) {
  final sp = 12 + p * 30;
  final b = _HoopBall(h.bx, h.by, math.cos(a) * sp, math.sin(a) * sp);
  var t = h.ticks + 4;
  var best = 1e9;
  for (var k = 0; k < 400; k++) {
    final hx = h.hxAt(t++);
    final r = HoopSim.stepHoop(b, hx, h.hy);
    if (r == 1) return b.touched ? -500 : -1000;
    if (r == 2) break;
    if (b.vy > 0) best = math.min(best, (b.x - hx).abs() + (b.y - h.hy).abs());
  }
  return best;
}

void _hoopPlan(HoopSim h) {
  var best = 1e18, ba = -1.0, bp = 0.6;
  for (var ai = 0; ai <= 50; ai++) {
    for (var pi = 0; pi <= 40; pi++) {
      final ca = -math.pi / 2 + 0.1 + ai * 0.025, cp = 0.15 + pi * 0.021;
      final (a, p, _, _) = _realizePull(ca, cp, scale: 450, forward: true);
      final v = _hoopEval(h, a, p);
      if (v < best) {
        best = v;
        ba = ca;
        bp = cp;
      }
    }
  }
  final (_, _, cx, cy) = _realizePull(ba, bp, scale: 450, forward: true);
  _queueDrag(h, cx, cy, forward: true);
}

// archery / darts --------------------------------------------------------------
(double, double) _dartTarget(DartsSim s) {
  final rem = s.remaining;
  final opts = <(int, int, int)>[]; // sector, mult, points
  for (var n = 1; n <= 20; n++) {
    opts.add((n, 1, n));
    opts.add((n, 2, n * 2));
    opts.add((n, 3, n * 3));
  }
  opts.add((25, 1, 25));
  opts.add((50, 2, 50));
  (int, int, int)? pick;
  var bestV = -1e9;
  for (final o in opts) {
    final left = rem - o.$3;
    if (left < 0) continue;
    if (s.doubleOut && (left == 1 || (left == 0 && o.$2 != 2))) continue;
    if (left == 0) {
      pick = o;
      break;
    }
    var v = o.$3.toDouble();
    if (s.doubleOut) {
      if (left <= 40 && left.isEven) v += 100;
      if (left == 50) v += 90;
    } else {
      if (left <= 20 || left == 25 || left == 50) v += 60;
    }
    if (o.$2 == 1 && o.$1 != 25) v -= 0; // singles are fine
    if (v > bestV) {
      bestV = v;
      pick = o;
    }
  }
  final o = pick ?? (20, 3, 60);
  if (o.$1 == 25) return (DartsSim.cx, DartsSim.cy - 20);
  if (o.$1 == 50) return (DartsSim.cx, DartsSim.cy);
  return DartsSim.aimPoint(o.$1, o.$2);
}

ArcadeInput _throwBot(ThrowSim s) {
  double gx, gy;
  final landT = s.ticks + 2 + s.flightTicks;
  if (s is ArcherySim) {
    gx = s.cxAt(landT);
    gy = s.cy;
  } else {
    (gx, gy) = _dartTarget(s as DartsSim);
  }
  final (dx, dy) = s.drift();
  if (s.holding && s.holdTicks >= 8) {
    return ArcadeInput(down: false, x: s.baseX, y: s.baseY);
  }
  final h = s.holding ? s.holdTicks : 0;
  // sway that will be used when firing after this tick's hold
  final save = s.holdTicks;
  s.holdTicks = h + 1;
  final (sx, sy) = s.sway();
  s.holdTicks = save;
  return ArcadeInput(down: true, x: clampD(gx - dx - sx, 0, kWorldW), y: clampD(gy - dy - sy, 0, kWorldH));
}

// penalty -------------------------------------------------------------------
ArcadeInput _penaltyBot(PenaltySim s) {
  if (!s.shooting) {
    if (s.phase == 1 && s.phaseTicks >= 3) {
      return ArcadeInput(down: true, x: s.tgtX.roundToDouble(), y: clampD(s.tgtY, kGoalT + 30, kGoalB - 30).roundToDouble());
    }
    return const ArcadeInput(down: true, x: 500, y: 600);
  }
  if (s.phase == 1) return ArcadeInput.idle;
  final gx = s.guessX >= 500 ? 290.0 : 710.0;
  const gy = 480.0;
  if (s.holding && s.holdTicks >= 8) return ArcadeInput(down: false, x: s.baseX, y: s.baseY);
  final h = s.holding ? s.holdTicks : 0;
  final save = s.holdTicks;
  s.holdTicks = h + 1;
  final (sx, sy) = s.sway();
  s.holdTicks = save;
  return ArcadeInput(down: true, x: (gx - sx).roundToDouble(), y: (gy - sy).roundToDouble());
}
