import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:studio_core/app/arcade_stage.dart';
import 'package:studio_core/app/play_kit.dart';
import 'package:studio_core/app/services/audio.dart';
import 'package:studio_core/core/arcade.dart';
import 'shot_engine.dart';

/// Procedural vector art for the aim & shoot sports (no sprites needed).
Paint _p(int c) => Paint()..color = Color(c);

Paint _stroke(int c, double w) => Paint()
  ..color = Color(c)
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round;

void _bg(Canvas c, int top, int bottom) {
  c.drawRect(
    const Rect.fromLTWH(0, 0, kWorldW, kWorldH),
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(top), Color(bottom)],
      ).createShader(const Rect.fromLTWH(0, 0, kWorldW, kWorldH)),
  );
}

void _ball(Canvas c, double x, double y, double r, int color, {bool shine = true}) {
  c.drawCircle(Offset(x + r * 0.15, y + r * 0.25), r, _p(0x44000000));
  c.drawCircle(Offset(x, y), r, _p(color));
  if (shine) c.drawCircle(Offset(x - r * 0.35, y - r * 0.35), r * 0.3, _p(0x88FFFFFF));
}

void _dashedAim(Canvas c, double x, double y, double a, double len, int color) {
  final paint = _stroke(color, 8);
  for (var d = 30.0; d < len; d += 34) {
    final e = math.min(d + 18, len);
    c.drawLine(Offset(x + math.cos(a) * d, y + math.sin(a) * d), Offset(x + math.cos(a) * e, y + math.sin(a) * e), paint);
  }
  final tip = Offset(x + math.cos(a) * len, y + math.sin(a) * len);
  final path = Path()
    ..moveTo(tip.dx + math.cos(a) * 26, tip.dy + math.sin(a) * 26)
    ..lineTo(tip.dx + math.cos(a + 2.5) * 22, tip.dy + math.sin(a + 2.5) * 22)
    ..lineTo(tip.dx + math.cos(a - 2.5) * 22, tip.dy + math.sin(a - 2.5) * 22)
    ..close();
  c.drawPath(path, _p(color));
}

void _powerBar(Canvas c, double power) {
  const r = Rect.fromLTWH(40, 1480, 260, 30);
  c.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(15)), _p(0x88000000));
  final col = Color.lerp(const Color(0xFF52B788), const Color(0xFFE63946), power)!;
  c.drawRRect(
    RRect.fromRectAndRadius(Rect.fromLTWH(r.left, r.top, r.width * power.clamp(0.0, 1.0), r.height), const Radius.circular(15)),
    Paint()..color = col,
  );
}

void _flash(Canvas c, ShotSim s) {
  if (s.flashTicks <= 0 || s.flash.isEmpty) return;
  final a = (s.flashTicks / 70).clamp(0.0, 1.0);
  paintText(c, s.flash, const Offset(500, 160), 84, Colors.white.withValues(alpha: a));
}

void paintShot(Canvas c, ArcadeSim sim, ArcadePalette p, double t) {
  final s = sim as ShotSim;
  switch (s) {
    case GolfSim g:
      _golf(c, g, t);
    case PoolSim q:
      _pool(c, q);
    case BowlingSim b:
      _bowling(c, b);
    case HoopSim h:
      _hoop(c, h);
    case ArcherySim a:
      _archery(c, a);
    case DartsSim d:
      _darts(c, d);
    case PenaltySim k:
      _penalty(c, k, t);
    default:
      break;
  }
  if (s.phase == 0 && !s.usesReticle && s is! PenaltySim) _powerBar(c, s.aimPower);
  _flash(c, s);
}

// golf --------------------------------------------------------------------------
void _golf(Canvas c, GolfSim g, double t) {
  _bg(c, 0xFF2D6A4F, 0xFF1B4332);
  final h = g.hole;
  final area = Rect.fromLTRB(kGolfArea.l, kGolfArea.t, kGolfArea.r, kGolfArea.b);
  c.drawRRect(RRect.fromRectAndRadius(area.inflate(14), const Radius.circular(30)), _p(0xFF6B4226));
  c.drawRRect(RRect.fromRectAndRadius(area, const Radius.circular(24)), _p(0xFF52B788));
  // mowing stripes
  for (var y = kGolfArea.t; y < kGolfArea.b; y += 120) {
    c.drawRect(Rect.fromLTWH(kGolfArea.l, y, kGolfArea.r - kGolfArea.l, 60), _p(0x1474C69D));
  }
  for (final z in h.sand) {
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(z.l, z.t, z.r, z.b), const Radius.circular(40)), _p(0xFFE9D8A6));
  }
  for (final z in h.water) {
    final r = RRect.fromRectAndRadius(Rect.fromLTRB(z.l, z.t, z.r, z.b), const Radius.circular(36));
    c.drawRRect(r, _p(0xFF0096C7));
    final wave = 6 * math.sin(t * 3);
    c.drawLine(Offset(z.l + 30, (z.t + z.b) / 2 + wave), Offset(z.r - 30, (z.t + z.b) / 2 - wave), _stroke(0x88FFFFFF, 5));
  }
  for (final w in h.walls) {
    final r = Rect.fromLTRB(w.l, w.t, w.r, w.b);
    c.drawRRect(RRect.fromRectAndRadius(r.translate(0, 8), const Radius.circular(8)), _p(0x55000000));
    c.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(8)), _p(0xFF8D6E63));
  }
  final m = g.moverAt(g.ticks);
  if (m != null) {
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(m.l, m.t, m.r, m.b), const Radius.circular(8)), _p(0xFFFFB703));
  }
  // cup + flag
  c.drawCircle(Offset(h.hx, h.hy), kCupR, _p(0xFF081C15));
  c.drawLine(Offset(h.hx, h.hy), Offset(h.hx, h.hy - 120), _stroke(0xFFFFFFFF, 6));
  final flag = Path()
    ..moveTo(h.hx, h.hy - 120)
    ..lineTo(h.hx + 70 + 6 * math.sin(t * 5), h.hy - 100)
    ..lineTo(h.hx, h.hy - 80)
    ..close();
  c.drawPath(flag, _p(0xFFE63946));
  // tee
  c.drawCircle(Offset(h.sx, h.sy), 22, _p(0x33FFFFFF));
  if (g.phase == 0) _dashedAim(c, g.ball.x, g.ball.y, g.aimAngle, 70 + g.aimPower * 260, 0xDDFFFFFF);
  _ball(c, g.ball.x, g.ball.y, kGolfBallR, 0xFFFFFFFF);
  paintText(c, 'PAR ${h.par}', const Offset(860, 1500), 40, Colors.white);
}

// pool --------------------------------------------------------------------------
const _poolColors = [
  0xFFFFFFFF, 0xFFFFD60A, 0xFF1D4ED8, 0xFFE63946, 0xFF7B2CBF, 0xFFF77F00, 0xFF2A9D8F,
  0xFF9D0208, 0xFF111111, 0xFFFFD60A, 0xFF1D4ED8, 0xFFE63946, 0xFF7B2CBF, 0xFFF77F00, 0xFF2A9D8F, 0xFF9D0208,
];

void _pool(Canvas c, PoolSim s) {
  _bg(c, 0xFF2B2D42, 0xFF1A1B2E);
  final felt = Rect.fromLTRB(kTable.l, kTable.t, kTable.r, kTable.b);
  c.drawRRect(RRect.fromRectAndRadius(felt.inflate(46), const Radius.circular(40)), _p(0xFF5C3A21));
  c.drawRRect(RRect.fromRectAndRadius(felt.inflate(20), const Radius.circular(20)), _p(0xFF1B5E20));
  c.drawRect(felt, _p(0xFF2E7D32));
  c.drawLine(Offset(kTable.l, 1150), Offset(kTable.r, 1150), _stroke(0x33FFFFFF, 3));
  for (final pk in kPockets) {
    c.drawCircle(Offset(pk[0], pk[1]), kPocketR, _p(0xFF0B0B0B));
  }
  final cue = s.balls[0];
  if (s.phase == 0 && cue.live) {
    _dashedAim(c, cue.x, cue.y, s.aimAngle, 120 + s.aimPower * 420, 0x99FFFFFF);
    // cue stick behind the ball
    final back = 60 + s.aimPower * 90;
    final a = s.aimAngle;
    c.drawLine(
      Offset(cue.x - math.cos(a) * back, cue.y - math.sin(a) * back),
      Offset(cue.x - math.cos(a) * (back + 420), cue.y - math.sin(a) * (back + 420)),
      _stroke(0xFFD4A373, 16),
    );
  }
  for (final b in s.balls) {
    if (!b.live) continue;
    final col = _poolColors[b.id % _poolColors.length];
    _ball(c, b.x, b.y, kPoolR, col);
    if (b.id > 8) c.drawCircle(Offset(b.x, b.y), kPoolR * 0.55, _p(0xFFFFFFFF));
    if (b.id > 0) paintText(c, '${b.id}', Offset(b.x, b.y), 18, b.id > 8 ? Colors.black : Colors.white);
  }
}

// bowling -----------------------------------------------------------------------
void _bowling(Canvas c, BowlingSim s) {
  _bg(c, 0xFF14213D, 0xFF000814);
  c.drawRect(const Rect.fromLTRB(kLaneL - 60, 80, kLaneR + 60, kWorldH), _p(0xFF22223B));
  c.drawRect(const Rect.fromLTRB(kLaneL, 80, kLaneR, kWorldH), _p(0xFFD4A373));
  for (var x = kLaneL + 24; x < kLaneR; x += 24) {
    c.drawLine(Offset(x, 80), Offset(x, kWorldH), _stroke(0x22000000, 2));
  }
  // arrows on the lane
  for (var i = -2; i <= 2; i++) {
    final x = 500 + i * 40.0, y = 1100 - i.abs() * 30.0;
    final path = Path()
      ..moveTo(x, y)
      ..lineTo(x - 10, y + 26)
      ..lineTo(x + 10, y + 26)
      ..close();
    c.drawPath(path, _p(0xFF6D4C41));
  }
  c.drawLine(const Offset(kLaneL, kFoulY - 40), const Offset(kLaneR, kFoulY - 40), _stroke(0xFFE63946, 4));
  if (s.bumpers > 0) {
    c.drawRect(const Rect.fromLTRB(kLaneL - 14, 80, kLaneL, kWorldH), _p(0xFFFFB703));
    c.drawRect(const Rect.fromLTRB(kLaneR, 80, kLaneR + 14, kWorldH), _p(0xFFFFB703));
  }
  for (final q in s.pins) {
    if (!q.live) continue;
    final moved = (q.x - q.ox).abs() + (q.y - q.oy).abs() > 10;
    c.drawCircle(Offset(q.x + 3, q.y + 5), kPinR, _p(0x55000000));
    c.drawCircle(Offset(q.x, q.y), kPinR, _p(moved ? 0xFFBDBDBD : 0xFFFFFFFF));
    c.drawCircle(Offset(q.x, q.y), kPinR * 0.45, _p(0xFFE63946));
  }
  if (s.phase == 0) _dashedAim(c, s.ball.x, s.ball.y, s.aimAngle, 120 + s.aimPower * 260, 0xCCFFFFFF);
  _ball(c, s.ball.x, s.ball.y, kBowlR, 0xFF3A0CA3);
  c.drawCircle(Offset(s.ball.x - 8, s.ball.y - 6), 4, _p(0xFF000000));
  c.drawCircle(Offset(s.ball.x + 6, s.ball.y - 9), 4, _p(0xFF000000));
  // scorecard
  paintText(c, '${s.gameScore}', const Offset(160, 260), 90, Colors.white);
  paintText(c, '/ ${s.target}', const Offset(160, 340), 44, Colors.white70);
  for (var f = 0; f < s.frames; f++) {
    final x = 830.0, y = 200.0 + f * 52;
    c.drawRect(Rect.fromLTWH(x - 70, y - 22, 140, 44), _p(f == s.frame ? 0x66FFB703 : 0x33FFFFFF));
    paintText(c, '${f + 1}', Offset(x - 50, y), 24, Colors.white70);
  }
}

// basketball --------------------------------------------------------------------
void _hoop(Canvas c, HoopSim s) {
  _bg(c, 0xFF1D3557, 0xFF457B9D);
  // crowd dots
  for (var i = 0; i < 60; i++) {
    c.drawCircle(Offset((i * 97) % 1000 + 20.0, 120 + (i * 53) % 260.0), 14, _p(i.isEven ? 0x33FFFFFF : 0x22FFD166));
  }
  c.drawRect(const Rect.fromLTRB(0, kFloorY, kWorldW, kWorldH), _p(0xFFC08552));
  for (var x = 0.0; x < kWorldW; x += 90) {
    c.drawLine(Offset(x, kFloorY), Offset(x, kWorldH), _stroke(0x33000000, 3));
  }
  final hx = s.hxAt(s.ticks);
  // pole, board, rim and net
  c.drawRect(Rect.fromLTRB(hx + kRimHalf + 60, s.hy - 120, hx + kRimHalf + 84, kFloorY), _p(0xFF6C757D));
  c.drawRect(Rect.fromLTRB(hx + kRimHalf + 26, s.hy - 200, hx + kRimHalf + 40, s.hy + 30), _p(0xFFF8F9FA));
  c.drawRect(Rect.fromLTRB(hx + kRimHalf + 26, s.hy - 120, hx + kRimHalf + 40, s.hy - 20), _stroke(0xFFE63946, 4));
  final net = Path()
    ..moveTo(hx - kRimHalf, s.hy)
    ..lineTo(hx - kRimHalf * 0.6, s.hy + 90)
    ..lineTo(hx + kRimHalf * 0.6, s.hy + 90)
    ..lineTo(hx + kRimHalf, s.hy);
  c.drawPath(net, _stroke(0xCCFFFFFF, 4));
  for (var i = -2; i <= 2; i++) {
    c.drawLine(Offset(hx + i * 18.0, s.hy), Offset(hx + i * 11.0, s.hy + 90), _stroke(0x88FFFFFF, 3));
  }
  // shooter spot
  c.drawOval(Rect.fromCenter(center: Offset(s.sx, kFloorY - 6), width: 120, height: 24), _p(0x44000000));
  if (s.phase == 0) {
    // short preview of the arc
    final sp = 12 + s.aimPower * 30;
    var x = s.bx, y = s.by, vx = math.cos(s.aimAngle) * sp, vy = math.sin(s.aimAngle) * sp;
    for (var k = 0; k < 14; k++) {
      for (var j = 0; j < 2; j++) {
        vy += 0.55;
        x += vx;
        y += vy;
      }
      c.drawCircle(Offset(x, y), 8 - k * 0.4, _p(0xAAFFFFFF));
    }
  }
  _ball(c, s.bx, s.by, kHoopR, 0xFFF77F00, shine: false);
  final seam = _stroke(0xFF3D1E00, 3);
  c.drawLine(Offset(s.bx - kHoopR, s.by), Offset(s.bx + kHoopR, s.by), seam);
  c.drawLine(Offset(s.bx, s.by - kHoopR), Offset(s.bx, s.by + kHoopR), seam);
  // rim in front of the ball
  c.drawLine(Offset(hx - kRimHalf, s.hy), Offset(hx + kRimHalf, s.hy), _stroke(0xFFE63946, 10));
}

// archery -----------------------------------------------------------------------
void _archery(Canvas c, ArcherySim s) {
  _bg(c, 0xFF8ECAE6, 0xFFA7C957);
  c.drawRect(const Rect.fromLTRB(0, 980, kWorldW, kWorldH), _p(0xFF6A994E));
  final cx = s.cxAt(s.ticks);
  // stand
  c.drawLine(Offset(cx - 120, s.cy + s.radius + 200), Offset(cx, s.cy), _stroke(0xFF7F5539, 16));
  c.drawLine(Offset(cx + 120, s.cy + s.radius + 200), Offset(cx, s.cy), _stroke(0xFF7F5539, 16));
  const cols = [0xFFFFFFFF, 0xFFFFFFFF, 0xFF222222, 0xFF222222, 0xFF0077B6, 0xFF0077B6, 0xFFE63946, 0xFFE63946, 0xFFFFD60A, 0xFFFFD60A];
  for (var i = 0; i < 10; i++) {
    final r = s.radius * (10 - i) / 10;
    c.drawCircle(Offset(cx, s.cy), r, _p(cols[i]));
    c.drawCircle(Offset(cx, s.cy), r, _stroke(0x55000000, 2));
  }
  c.drawCircle(Offset(cx, s.cy), s.radius / 20, _stroke(0xFF000000, 2));
  // landed arrows (stored relative to the moving target)
  for (final m in s.marks) {
    final x = m.length > 2 ? cx + m[2] : m[0];
    c.drawCircle(Offset(x, m[1]), 9, _p(0xFF3D1E00));
    c.drawCircle(Offset(x, m[1]), 4, _p(0xFFFFFFFF));
  }
  // wind flag
  final w = s.wind;
  c.drawLine(const Offset(120, 980), const Offset(120, 780), _stroke(0xFF6C757D, 8));
  final flag = Path()
    ..moveTo(120, 790)
    ..lineTo(120 + w * 60, 815)
    ..lineTo(120, 840)
    ..close();
  c.drawPath(flag, _p(0xFFE63946));
  paintText(c, 'WIND ${w.abs().toStringAsFixed(1)} ${w > 0.05 ? '→' : (w < -0.05 ? '←' : '')}', const Offset(160, 1030), 34, Colors.white);
  _reticle(c, s, 0xFFE63946);
  // bow at the bottom
  c.drawArc(const Rect.fromLTWH(380, 1260, 240, 320), math.pi * 1.1, math.pi * 0.8, false, _stroke(0xFF7F5539, 14));
  final pull = s.holding ? math.min(1.0, s.holdTicks / 20) : 0.0;
  c.drawLine(const Offset(410, 1340), Offset(500, 1340 + pull * 60), _stroke(0xFFFFFFFF, 3));
  c.drawLine(const Offset(590, 1340), Offset(500, 1340 + pull * 60), _stroke(0xFFFFFFFF, 3));
  if (s.phase == 1) {
    final k = (s.phaseTicks / s.flightTicks).clamp(0.0, 1.0);
    final ax = 500 + (s.hitX - 500) * k, ay = 1340 + (s.hitY - 1340) * k;
    c.drawCircle(Offset(ax, ay), 14 * (1 - k * 0.6), _p(0xFF3D1E00));
  }
}

void _reticle(Canvas c, ShotSim s, int color) {
  if (!s.holding) {
    c.drawCircle(Offset(s.baseX, s.baseY), 26, _stroke(0x66FFFFFF, 3));
    return;
  }
  final o = Offset(s.retX, s.retY);
  final paint = _stroke(color, 5);
  c.drawCircle(o, 30, paint);
  c.drawLine(o.translate(-48, 0), o.translate(-14, 0), paint);
  c.drawLine(o.translate(48, 0), o.translate(14, 0), paint);
  c.drawLine(o.translate(0, -48), o.translate(0, -14), paint);
  c.drawLine(o.translate(0, 48), o.translate(0, 14), paint);
}

// darts -------------------------------------------------------------------------
void _darts(Canvas c, DartsSim s) {
  _bg(c, 0xFF283618, 0xFF1B1B1B);
  const o = Offset(DartsSim.cx, DartsSim.cy);
  c.drawCircle(o, DartsSim.rBoard + 70, _p(0xFF111111));
  for (var i = 0; i < 20; i++) {
    final a0 = (i * 18 - 9 - 90) * math.pi / 180, sweep = 18 * math.pi / 180;
    final dark = i.isEven;
    void ring(double r0, double r1, int col) {
      final path = Path()
        ..addArc(Rect.fromCircle(center: o, radius: r1), a0, sweep)
        ..arcTo(Rect.fromCircle(center: o, radius: r0), a0 + sweep, -sweep, false)
        ..close();
      c.drawPath(path, _p(col));
    }

    ring(28, 175, dark ? 0xFF1B1B1B : 0xFFF1E3C6);
    ring(175, 189, dark ? 0xFFD62828 : 0xFF2A9D8F);
    ring(189, 286, dark ? 0xFF1B1B1B : 0xFFF1E3C6);
    ring(286, 300, dark ? 0xFFD62828 : 0xFF2A9D8F);
    final la = (i * 18 - 90) * math.pi / 180;
    paintText(c, '${kDartSectors[i]}', o.translate(math.cos(la) * 335, math.sin(la) * 335), 30, Colors.white);
  }
  c.drawCircle(o, 28, _p(0xFF2A9D8F));
  c.drawCircle(o, 11, _p(0xFFD62828));
  for (final m in s.marks) {
    c.drawCircle(Offset(m[0], m[1]), 8, _p(0xFF0077B6));
    c.drawCircle(Offset(m[0], m[1]), 3, _p(0xFFFFFFFF));
  }
  _reticle(c, s, 0xFFFFD60A);
  // score panel
  c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(300, 1150, 400, 170), const Radius.circular(24)), _p(0xCC000000));
  paintText(c, '${s.remaining}', const Offset(500, 1215), 90, Colors.white);
  paintText(c, s.doubleOut ? 'DOUBLE OUT' : 'TO GO', const Offset(500, 1290), 28, Colors.white70);
  for (var k = 0; k < 3; k++) {
    c.drawCircle(Offset(440 + k * 60.0, 1380), 14, _p(k < 3 - s.dartInTurn ? 0xFFFFD60A : 0x44FFFFFF));
  }
  if (s.phase == 1) {
    final k = (s.phaseTicks / s.flightTicks).clamp(0.0, 1.0);
    c.drawCircle(Offset(500 + (s.hitX - 500) * k, 1500 + (s.hitY - 1500) * k), 12 * (1 - k * 0.5), _p(0xFF0077B6));
  }
}

// penalty -----------------------------------------------------------------------
void _penalty(Canvas c, PenaltySim s, double t) {
  _bg(c, 0xFF0B132B, 0xFF1C2541);
  // stands & lights
  for (var i = 0; i < 70; i++) {
    c.drawCircle(Offset((i * 71) % 1000 + 10.0, 60 + (i * 37) % 240.0), 10, _p(i % 3 == 0 ? 0x55FFD166 : 0x33FFFFFF));
  }
  c.drawRect(const Rect.fromLTRB(0, 340, kWorldW, kWorldH), _p(0xFF2D6A4F));
  for (var y = 340.0; y < kWorldH; y += 140) {
    c.drawRect(Rect.fromLTWH(0, y, kWorldW, 70), _p(0x1474C69D));
  }
  // goal: net, posts, crossbar
  c.drawRect(const Rect.fromLTRB(kGoalL, kGoalT, kGoalR, kGoalB), _p(0x22FFFFFF));
  for (var x = kGoalL; x <= kGoalR; x += 30) {
    c.drawLine(Offset(x, kGoalT), Offset(x, kGoalB), _stroke(0x44FFFFFF, 2));
  }
  for (var y = kGoalT; y <= kGoalB; y += 30) {
    c.drawLine(Offset(kGoalL, y), Offset(kGoalR, y), _stroke(0x44FFFFFF, 2));
  }
  c.drawLine(const Offset(kGoalL, kGoalB), const Offset(kGoalL, kGoalT), _stroke(0xFFFFFFFF, 14));
  c.drawLine(const Offset(kGoalR, kGoalB), const Offset(kGoalR, kGoalT), _stroke(0xFFFFFFFF, 14));
  c.drawLine(const Offset(kGoalL, kGoalT), const Offset(kGoalR, kGoalT), _stroke(0xFFFFFFFF, 14));
  c.drawLine(const Offset(0, kGoalB), const Offset(kWorldW, kGoalB), _stroke(0xAAFFFFFF, 6));
  // keeper
  final kc = s.shooting ? 0xFFF77F00 : 0xFF00B4D8;
  final body = Rect.fromCenter(center: Offset(s.kx, s.ky), width: 70, height: 120);
  c.drawRRect(RRect.fromRectAndRadius(body, const Radius.circular(30)), _p(kc));
  c.drawCircle(Offset(s.kx, s.ky - 80), 30, _p(0xFFFFD7BA));
  final reach = s.phase == 1 ? 1.0 : 0.6;
  c.drawLine(Offset(s.kx - 30, s.ky - 40), Offset(s.kx - 95 * reach, s.ky - 70), _stroke(kc, 18));
  c.drawLine(Offset(s.kx + 30, s.ky - 40), Offset(s.kx + 95 * reach, s.ky - 70), _stroke(kc, 18));
  c.drawCircle(Offset(s.kx - 95 * reach, s.ky - 70), 16, _p(0xFF52B788));
  c.drawCircle(Offset(s.kx + 95 * reach, s.ky - 70), 16, _p(0xFF52B788));
  // spot + ball
  c.drawOval(Rect.fromCenter(center: const Offset(500, 1320), width: 70, height: 20), _p(0x88FFFFFF));
  final k = s.phase == 1 ? (s.phaseTicks / s.flyT).clamp(0.0, 1.0) : 0.0;
  final br = 34 * (1 - k * 0.55);
  _ball(c, s.ballX, s.ballY, br, 0xFFFFFFFF);
  c.drawCircle(Offset(s.ballX, s.ballY), br * 0.35, _p(0xFF222222));
  if (!s.shooting && s.phase == 0) {
    // rival run-up
    final ry = 1500 - s.runUp * 3.0;
    c.drawCircle(Offset(470, ry), 34, _p(0xFFE63946));
    paintText(c, '${50 - s.runUp > 0 ? ((50 - s.runUp) / 17).ceil() : ''}', const Offset(500, 260), 60, Colors.white);
  }
  if (s.shooting) _reticle(c, s, 0xFFFFD60A);
  // shoot-out dots
  final n = math.min(14, math.max(5, math.max(s.myRes.length, s.cpuRes.length)));
  for (var i = 0; i < n; i++) {
    final a = i < s.myRes.length ? (s.myRes[i] ? 0xFF52B788 : 0xFFE63946) : 0x44FFFFFF;
    final b = i < s.cpuRes.length ? (s.cpuRes[i] ? 0xFFE63946 : 0xFF52B788) : 0x44FFFFFF;
    c.drawCircle(Offset(60 + i * 40.0, 1480), 15, _p(a));
    c.drawCircle(Offset(60 + i * 40.0, 1530), 15, _p(b));
  }
  if (s.superKeeper > 0 && !s.shooting) {
    c.drawCircle(Offset(s.kx, s.ky - 40), 150, _stroke(0x66FFD60A, 6));
  }
  paintText(c, s.shooting ? 'SHOOT' : 'SAVE', const Offset(820, 1500), 48, Colors.white);
}

Sfx? shotSound(ArcadeSim sim) => switch ((sim as ShotSim).lastEvent) {
      1 => Sfx.tap,
      2 => Sfx.place,
      3 => Sfx.combo,
      4 => Sfx.error,
      5 => Sfx.clear,
      _ => null,
    };
