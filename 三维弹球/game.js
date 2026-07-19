/* 三维弹球 · SPACE PINBALL
 * 物理在桌面二维坐标系内模拟（x ∈ [-27,27]，y ∈ [0,88]，y 指向桌面远端），
 * 渲染时映射到三维：(x, 高度, -y)，整桌绕 X 轴倾斜。
 */
(function () {
'use strict';

// ── 错误上报（无头测试时通过 DOM 读取）──────────────────────────
function reportErr(msg) {
  var p = document.getElementById('err');
  if (!p) { p = document.createElement('pre'); p.id = 'err'; document.body.appendChild(p); }
  p.textContent += msg + '\n';
}
window.addEventListener('error', function (e) {
  reportErr((e.message || e.type) + ' @' + (e.filename || '') + ':' + (e.lineno || ''));
});
if (typeof THREE === 'undefined') { reportErr('three.min.js 未加载'); return; }

var Q = new URLSearchParams(location.search);
var SHOT = Q.get('shot'); // 截图调试模式

// ── 常量 ────────────────────────────────────────────────────────
var HW = 27;            // 桌面半宽
var ARC_Y = 61;         // 顶部圆弧圆心 y（半径 = HW，桌面最远处 y = 88）
var TOP_Y = ARC_Y + HW;
var BALL_R = 1.2;
var G = 78;             // 沿桌面的等效重力
var DAMP = 0.12;        // 速度衰减 /s
var VMAX = 130;
var DT = 1 / 240;       // 物理子步
var LANE_X = 22.5;      // 发射槽隔板
var LANE_C = (LANE_X + HW) / 2;   // 发射槽中线 24.75
var TILT = 0.12;        // 视觉倾角
var EXTRA_AT = 5000;    // 奖励弹球分数线

// ── 音效 ────────────────────────────────────────────────────────
var actx = null;
function initAudio() {
  if (SHOT || actx) return;
  try {
    var AC = window.AudioContext || window.webkitAudioContext;
    if (AC) actx = new AC();
  } catch (e) { /* 无音频环境 */ }
}
function tone(f0, f1, dur, type, vol, delay) {
  if (!actx) return;
  try {
    if (actx.state === 'suspended') actx.resume();
    var t0 = actx.currentTime + (delay || 0);
    var o = actx.createOscillator(), g = actx.createGain();
    o.type = type; o.frequency.setValueAtTime(f0, t0);
    o.frequency.exponentialRampToValueAtTime(Math.max(f1, 1), t0 + dur);
    g.gain.setValueAtTime(vol, t0);
    g.gain.exponentialRampToValueAtTime(0.001, t0 + dur);
    o.connect(g); g.connect(actx.destination);
    o.start(t0); o.stop(t0 + dur + 0.03);
  } catch (e) { /* 忽略 */ }
}
var sfx = {
  flip:   function () { tone(115, 62, 0.055, 'square', 0.18); },
  bump:   function () { tone(500 + Math.random() * 80, 190, 0.1, 'square', 0.25); tone(1500, 640, 0.06, 'sine', 0.1, 0.008); },
  target: function () { tone(960, 1240, 0.09, 'triangle', 0.22); },
  launch: function () { tone(140, 840, 0.28, 'sawtooth', 0.18); },
  sling:  function () { tone(260, 96, 0.07, 'square', 0.24); tone(1180, 520, 0.05, 'sine', 0.09, 0.006); },
  drain:  function () { tone(330, 52, 0.55, 'sawtooth', 0.22); },
  wall:   function (imp) { if (imp > 26) tone(200, 120, 0.04, 'triangle', Math.min(0.12, imp / 400)); },
  extra:  function () { [660, 880, 1320].forEach(function (f, i) { tone(f, f, 0.12, 'square', 0.16, i * 0.09); }); },
  bonus:  function () { [523, 659, 784, 1047].forEach(function (f, i) { tone(f, f, 0.1, 'square', 0.16, i * 0.07); }); }
};

// ── 物理世界 ────────────────────────────────────────────────────
var SEGS = [];
function addSeg(x1, y1, x2, y2, o) {
  o = o || {};
  var s = {
    x1: x1, y1: y1, x2: x2, y2: y2,
    e: o.e !== undefined ? o.e : 0.5,
    rad: o.rad !== undefined ? o.rad : 0.6,
    oneSided: !!o.oneSided,
    onHit: o.onHit || null,
    mesh: o.mesh !== false,
    h: o.h !== undefined ? o.h : 3.2,
    pad: o.pad !== undefined ? o.pad : 0.5,
    mat: o.mat || null
  };
  SEGS.push(s);
  return s;
}

var BUMPERS = [
  { x: -9.5, y: 67,   r: 2.7, color: 0x6ff3ff, last: -9, flash: 0 },
  { x:  9.5, y: 67,   r: 2.7, color: 0xff5fa2, last: -9, flash: 0 },
  { x:  0,   y: 56.5, r: 2.7, color: 0xffb84d, last: -9, flash: 0 }
];
var BUMPER_KICK = 58;

var TARGETS = [
  { y1: 39,   y2: 42.6 },
  { y1: 45.4, y2: 49 },
  { y1: 51.8, y2: 55.4 }
].map(function (t) { return { y1: t.y1, y2: t.y2, lit: false, last: -9, flash: 0, mesh: null }; });
var targetsResetAt = 0;

var FLIPPERS = [
  { px: -9.4, py: 12.6, rest: -0.52, up: 0.55, ang: -0.52, w: 0, pressed: false, len: 7.6, r: 1.05 },
  { px:  9.4, py: 12.6, rest: Math.PI + 0.52, up: Math.PI - 0.55, ang: Math.PI + 0.52, w: 0, pressed: false, len: 7.6, r: 1.05 }
];

var ball = { x: LANE_C, y: 5.8, vx: 0, vy: 0 };
var simT = 0;

// 外框
addSeg(-HW, 0, -HW, ARC_Y);
addSeg(HW, 0, HW, ARC_Y);
var ARC_N = 30;
for (var ai = 0; ai < ARC_N; ai++) {
  var a1 = Math.PI * ai / ARC_N, a2 = Math.PI * (ai + 1) / ARC_N;
  addSeg(HW * Math.cos(a1), ARC_Y + HW * Math.sin(a1),
         HW * Math.cos(a2), ARC_Y + HW * Math.sin(a2), { pad: 0.8 });
}
// 发射槽隔板 + 槽底
addSeg(LANE_X, 4, LANE_X, 62, { rad: 0.5 });
addSeg(LANE_X, 4, HW, 4, { e: 0.2 });
// 单向门：从场内落下时挡住，不许回槽；发射上行时穿过
var gateSeg = addSeg(LANE_X, 61.5, 26.5, 64, { oneSided: true, e: 0.25, rad: 0.25, h: 1.6 });
// 左右导轨（把球汇向弹板）
addSeg(-HW, 30, -10.1, 13.35, { e: 0.45 });
addSeg(LANE_X, 30, 10.1, 13.35, { e: 0.45 });
// 弹弓：导轨上的三角踢球器，击中发光面时把球踢回场内
var SLING_KICK = 46;
var SLINGS = [];
function addSling(P1, apex, P2, color) {
  var s = {
    p1: P1, apex: apex, p2: P2, color: color,
    cx: (P1.x + apex.x + P2.x) / 3, cy: (P1.y + apex.y + P2.y) / 3,
    last: -9, flash: 0, mat: null
  };
  function face(a, b) {
    var dx = b.x - a.x, dy = b.y - a.y, L = Math.hypot(dx, dy);
    var nx = -dy / L, ny = dx / L;
    // 法线取指向三角形外的一侧
    if (nx * (s.cx - (a.x + b.x) / 2) + ny * (s.cy - (a.y + b.y) / 2) > 0) { nx = -nx; ny = -ny; }
    addSeg(a.x, a.y, b.x, b.y, {
      e: 0.55, mesh: false,
      onHit: function (seg, imp) {
        if (imp < 4 || simT - s.last < 0.12) return;
        s.last = simT; s.flash = 1;
        ball.vx = nx * SLING_KICK + ball.vx * 0.25;
        ball.vy = ny * SLING_KICK + ball.vy * 0.25;
        addShake(0.35);
        addScore(50);
        sfx.sling();
      }
    });
  }
  face(P1, apex); face(apex, P2);
  addSeg(P2.x, P2.y, P1.x, P1.y, { e: 0.4, mesh: false }); // 底边贴导轨，防卡球
  SLINGS.push(s);
}
addSling({ x: -19.93, y: 22.93 }, { x: -14.76, y: 21.72 }, { x: -13.56, y: 16.56 }, 0x6ff3ff);
addSling({ x:  16.90, y: 22.32 }, { x:  12.14, y: 20.54 }, { x:  11.90, y: 15.46 }, 0xff5fa2);
// 左墙目标灯（物理段，网格另建）
TARGETS.forEach(function (t, i) {
  addSeg(-25.6, t.y1, -25.6, t.y2, {
    rad: 0.45, mesh: false,
    onHit: function () { hitTarget(i); }
  });
});

// ── 游戏状态 ────────────────────────────────────────────────────
var state = 'menu';   // menu | ready | play | drain | over
var score = 0, balls = 3, extraGiven = false, beatHi = false;
var hi = 0;
try { hi = parseInt(localStorage.getItem('3d-pinball-hi') || '0', 10) || 0; } catch (e) {}
var power = 0, pull = 0, charging = false;
var drainT = 0;
// 撞击时的桌体震动
var REDUCED_MOTION = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
var shake = 0;
function addShake(k) { if (!REDUCED_MOTION) shake = Math.min(1, shake + k); }

// ── DOM ─────────────────────────────────────────────────────────
var $ = function (id) { return document.getElementById(id); };
var scoreEl = $('scoreVal'), hiEl = $('hiVal'), ballsEl = $('ballsVal');
var powerEl = $('power'), powerFillEl = $('powerFill');
var menuEl = $('menu'), overEl = $('over');
var launchBtn = $('launchBtn');
var IS_TOUCH = window.matchMedia && matchMedia('(hover: none) and (pointer: coarse)').matches;
if (IS_TOUCH) document.body.classList.add('touch');

function updateHUD() {
  scoreEl.textContent = score;
  hiEl.textContent = hi;
  ballsEl.textContent = balls > 0 ? Array(balls + 1).join('●') : '—';
}
function toast(text, amber) {
  var d = document.createElement('div');
  d.className = 'toast' + (amber ? ' amber' : '');
  d.textContent = text;
  $('toasts').appendChild(d);
  setTimeout(function () { d.remove(); }, 1800);
}
function addScore(n) {
  score += n;
  if (!extraGiven && score >= EXTRA_AT) {
    extraGiven = true; balls++;
    toast('奖励弹球 +1');
    sfx.extra();
  }
  if (score > hi) { hi = score; beatHi = true; }
  updateHUD();
}
function hitTarget(i) {
  var t = TARGETS[i];
  if (simT - t.last < 0.3) return;
  t.last = simT; t.flash = 1;
  if (!t.lit) {
    t.lit = true;
    addScore(250);
    sfx.target();
    if (TARGETS.every(function (x) { return x.lit; })) {
      addScore(1000);
      toast('目标全部点亮 +1000', true);
      sfx.bonus();
      targetsResetAt = simT + 0.7;
    }
  } else {
    addScore(25);
  }
}

// ── 流程 ────────────────────────────────────────────────────────
function setLaunchBtn(show) {
  if (launchBtn) launchBtn.classList.toggle('show', !!show);
}
function toReady() {
  state = 'ready';
  power = 0; charging = false;
  ball.x = LANE_C; ball.y = 5.8; ball.vx = 0; ball.vy = 0;
  ballMesh.visible = true;
  setLaunchBtn(true);
}
function newGame() {
  score = 0; balls = 3; extraGiven = false; beatHi = false;
  TARGETS.forEach(function (t) { t.lit = false; t.flash = 0; });
  targetsResetAt = 0;
  menuEl.classList.add('hidden');
  overEl.classList.add('hidden');
  updateHUD();
  toReady();
}
function fire() {
  if (state !== 'ready') return;
  charging = false;
  state = 'play';
  setLaunchBtn(false);
  ball.vx = 0;
  ball.vy = 70 + 56 * power + (Math.random() * 3 - 1.5);
  sfx.launch();
}
function startDrain() {
  state = 'drain';
  drainT = 0;
  setLaunchBtn(false);
  addShake(0.3);
  sfx.drain();
}
function resolveDrain() {
  balls--;
  updateHUD();
  if (balls > 0) {
    if (balls === 1) toast('最后一颗弹球！', true);
    toReady();
  } else {
    gameOver();
  }
}
function gameOver() {
  state = 'over';
  ballMesh.visible = false;
  try { localStorage.setItem('3d-pinball-hi', String(hi)); } catch (e) {}
  $('finalScore').textContent = score;
  $('finalHi').textContent = '最高分 ' + hi;
  $('newRecord').style.display = beatHi && score > 0 ? 'inline-block' : 'none';
  overEl.classList.remove('hidden');
}

// ── 物理 ────────────────────────────────────────────────────────
function collideSeg(s) {
  var dx = s.x2 - s.x1, dy = s.y2 - s.y1;
  var L2 = dx * dx + dy * dy;
  var t = ((ball.x - s.x1) * dx + (ball.y - s.y1) * dy) / L2;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  var cx = s.x1 + t * dx, cy = s.y1 + t * dy;
  var nx = ball.x - cx, ny = ball.y - cy;
  var rr = BALL_R + s.rad;
  var d2 = nx * nx + ny * ny;
  if (d2 > rr * rr) return;
  var d = Math.sqrt(d2) || 1e-6;
  nx /= d; ny /= d;
  if (s.oneSided && (nx * -dy + ny * dx) < 0) return; // 只挡法线一侧
  ball.x = cx + nx * rr; ball.y = cy + ny * rr;
  var vn = ball.vx * nx + ball.vy * ny;
  if (vn < 0) {
    var e = vn < -3 ? s.e : 0; // 低速贴墙不弹跳
    var vtx = ball.vx - vn * nx, vty = ball.vy - vn * ny;
    ball.vx = vtx * 0.99 - vn * e * nx;
    ball.vy = vty * 0.99 - vn * e * ny;
    if (s.onHit) s.onHit(s, -vn); else sfx.wall(-vn);
  }
}
function collideBumper(bp) {
  var nx = ball.x - bp.x, ny = ball.y - bp.y;
  var rr = BALL_R + bp.r;
  var d2 = nx * nx + ny * ny;
  if (d2 > rr * rr) return;
  var d = Math.sqrt(d2) || 1e-6;
  nx /= d; ny /= d;
  ball.x = bp.x + nx * rr; ball.y = bp.y + ny * rr;
  var vn = ball.vx * nx + ball.vy * ny;
  var vtx = ball.vx - vn * nx, vty = ball.vy - vn * ny;
  ball.vx = nx * BUMPER_KICK + vtx * 0.3;
  ball.vy = ny * BUMPER_KICK + vty * 0.3;
  if (simT - bp.last > 0.09) {
    addScore(100);
    bp.flash = 1;
    addShake(0.45);
    sfx.bump();
  }
  bp.last = simT;
}
function collideFlipper(f) {
  var dirx = Math.cos(f.ang), diry = Math.sin(f.ang);
  var t = (ball.x - f.px) * dirx + (ball.y - f.py) * diry;
  t = t < 0 ? 0 : (t > f.len ? f.len : t);
  var cx = f.px + dirx * t, cy = f.py + diry * t;
  var nx = ball.x - cx, ny = ball.y - cy;
  var rr = BALL_R + f.r;
  var d2 = nx * nx + ny * ny;
  if (d2 > rr * rr) return;
  var d = Math.sqrt(d2) || 1e-6;
  nx /= d; ny /= d;
  ball.x = cx + nx * rr; ball.y = cy + ny * rr;
  // 接触点线速度 = ω × r
  var rx = cx - f.px, ry = cy - f.py;
  var ux = -f.w * ry, uy = f.w * rx;
  var rvx = ball.vx - ux, rvy = ball.vy - uy;
  var vn = rvx * nx + rvy * ny;
  if (vn < 0) {
    var e = vn < -3 ? 0.42 : 0;
    rvx -= (1 + e) * vn * nx;
    rvy -= (1 + e) * vn * ny;
    ball.vx = rvx + ux;
    ball.vy = rvy + uy;
  }
}
function updFlipper(f, dt) {
  var target = f.pressed ? f.up : f.rest;
  if (f.ang === target) { f.w = 0; return; }
  var dir = target > f.ang ? 1 : -1;
  var sp = f.pressed ? 26 : 15;
  var na = f.ang + dir * sp * dt;
  if ((dir > 0 && na > target) || (dir < 0 && na < target)) na = target;
  f.w = (na - f.ang) / dt;
  f.ang = na;
}
function step(dt) {
  simT += dt;
  FLIPPERS.forEach(function (f) { updFlipper(f, dt); });
  if (state !== 'play') return;

  ball.vy -= G * dt;
  var dampK = 1 - DAMP * dt;
  ball.vx *= dampK; ball.vy *= dampK;
  var sp = Math.hypot(ball.vx, ball.vy);
  if (sp > VMAX) { ball.vx *= VMAX / sp; ball.vy *= VMAX / sp; }
  ball.x += ball.vx * dt;
  ball.y += ball.vy * dt;

  for (var it = 0; it < 2; it++) {
    FLIPPERS.forEach(collideFlipper);
    SEGS.forEach(collideSeg);
    BUMPERS.forEach(collideBumper);
  }

  // 出界丢球 / 回到发射槽
  if (ball.y < 3 && ball.x < LANE_X) { startDrain(); return; }
  if (ball.x > LANE_X && ball.y < 6.6 && Math.abs(ball.vy) < 12) { toReady(); return; }
  // 兜底
  if (!isFinite(ball.x + ball.y + ball.vx + ball.vy)) { toReady(); return; }
  if (ball.y > TOP_Y + 4 || Math.abs(ball.x) > HW + 2) {
    ball.x = 0; ball.y = 50; ball.vx = Math.random() * 10 - 5; ball.vy = -10;
  }
}

// ── 三维场景 ────────────────────────────────────────────────────
var renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.outputEncoding = THREE.sRGBEncoding;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.15;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
document.body.insertBefore(renderer.domElement, document.body.firstChild);

var scene = new THREE.Scene();
scene.background = new THREE.Color(0x070912);
scene.fog = new THREE.FogExp2(0x070912, 0.002);

var camera = new THREE.PerspectiveCamera(44, window.innerWidth / window.innerHeight, 0.1, 600);
function fitCamera() {
  var aspect = window.innerWidth / window.innerHeight;
  var k = aspect < 0.6 ? Math.pow(0.6 / aspect, 0.85) : (aspect > 1.05 ? 0.86 : 1);
  camera.aspect = aspect;
  camera.position.set(0, 77 * k, 68 * k);
  camera.lookAt(0, 0, -32);
  camera.updateProjectionMatrix();
}

// 环境反射（金属球用）：小型发光房间烘焙
(function makeEnv() {
  var pm = new THREE.PMREMGenerator(renderer);
  var es = new THREE.Scene();
  es.background = new THREE.Color(0x0a0d22);
  function panel(color, x, y, z, w, h) {
    var m = new THREE.Mesh(new THREE.PlaneGeometry(w, h),
      new THREE.MeshBasicMaterial({ color: color, side: THREE.DoubleSide }));
    m.position.set(x, y, z); m.lookAt(0, 0, 0); es.add(m);
  }
  panel(0xffffff, 0, 10, 0, 14, 14);
  panel(0x3fd9ff, -10, 2, -5, 9, 16);
  panel(0xff5fa2, 10, 2, -5, 9, 16);
  panel(0x2233aa, 0, 1, 10, 16, 10);
  scene.environment = pm.fromScene(es, 0.08).texture;
  pm.dispose();
})();

// 灯光
scene.add(new THREE.HemisphereLight(0x93a7ff, 0x140b24, 0.5));
var key = new THREE.DirectionalLight(0xfff3e0, 1.05);
key.position.set(28, 95, 20);
key.castShadow = true;
key.shadow.mapSize.set(2048, 2048);
key.shadow.camera.left = -45; key.shadow.camera.right = 45;
key.shadow.camera.top = 40; key.shadow.camera.bottom = -100;
key.shadow.camera.near = 20; key.shadow.camera.far = 240;
key.shadow.bias = -0.0005;
scene.add(key);
key.target.position.set(0, 0, -44);
scene.add(key.target);

var tableGroup = new THREE.Group();
tableGroup.rotation.x = TILT;
scene.add(tableGroup);

var pCyan = new THREE.PointLight(0x3fd9ff, 0.6, 90, 2);
pCyan.position.set(-16, 15, -24);
tableGroup.add(pCyan);
var pRose = new THREE.PointLight(0xff5fa2, 0.6, 90, 2);
pRose.position.set(16, 15, -66);
tableGroup.add(pRose);

// 星空
(function stars() {
  var n = 420, arr = new Float32Array(n * 3);
  for (var i = 0; i < n; i++) {
    var r = 170 + Math.random() * 120;
    var th = Math.random() * Math.PI * 2;
    var ph = Math.acos(Math.random() * 1.7 - 0.7);
    arr[i * 3] = r * Math.sin(ph) * Math.cos(th);
    arr[i * 3 + 1] = Math.abs(r * Math.cos(ph)) - 20;
    arr[i * 3 + 2] = r * Math.sin(ph) * Math.sin(th) - 40;
  }
  var g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(arr, 3));
  scene.add(new THREE.Points(g, new THREE.PointsMaterial({
    color: 0x9fb4ff, size: 1.5, sizeAttenuation: true,
    transparent: true, opacity: 0.85, depthWrite: false
  })));
})();

// 桌面贴图（程序化绘制）
function makeDeckTexture() {
  var c = document.createElement('canvas');
  c.width = 540; c.height = 880;
  var g = c.getContext('2d');
  var px = function (x) { return (x + HW) * 10; };
  var py = function (y) { return (88 - y) * 10; };

  var grad = g.createLinearGradient(0, 0, 0, 880);
  grad.addColorStop(0, '#1d164f');
  grad.addColorStop(0.45, '#161b4c');
  grad.addColorStop(1, '#0e1233');
  g.fillStyle = grad;
  g.fillRect(0, 0, 540, 880);

  function blob(x, y, r, color) {
    var rg = g.createRadialGradient(x, y, 0, x, y, r);
    rg.addColorStop(0, color);
    rg.addColorStop(1, 'rgba(0,0,0,0)');
    g.fillStyle = rg;
    g.fillRect(x - r, y - r, r * 2, r * 2);
  }
  blob(px(-12), py(68), 130, 'rgba(120,80,255,.17)');
  blob(px(15), py(42), 150, 'rgba(40,170,255,.11)');
  blob(px(-7), py(24), 115, 'rgba(255,80,160,.09)');

  for (var i = 0; i < 180; i++) {
    g.fillStyle = 'rgba(195,212,255,' + (Math.random() * 0.5 + 0.12).toFixed(2) + ')';
    g.beginPath();
    g.arc(Math.random() * 540, Math.random() * 880, Math.random() * 1.5 + 0.3, 0, 7);
    g.fill();
  }

  // 缓冲柱底环
  BUMPERS.forEach(function (b) {
    var col = '#' + ('000000' + b.color.toString(16)).slice(-6);
    g.strokeStyle = col; g.globalAlpha = 0.4; g.lineWidth = 3;
    g.beginPath(); g.arc(px(b.x), py(b.y), 36, 0, 7); g.stroke();
    g.globalAlpha = 0.16; g.lineWidth = 8;
    g.beginPath(); g.arc(px(b.x), py(b.y), 46, 0, 7); g.stroke();
    g.globalAlpha = 1;
  });

  // 中央环饰
  g.strokeStyle = 'rgba(150,175,255,.16)'; g.lineWidth = 2;
  g.beginPath(); g.arc(px(0), py(44), 148, 0, 7); g.stroke();
  g.setLineDash([6, 10]);
  g.beginPath(); g.arc(px(0), py(44), 120, 0, 7); g.stroke();
  g.setLineDash([]);

  // 发射槽箭头
  g.strokeStyle = 'rgba(255,210,127,.75)'; g.lineWidth = 4; g.lineCap = 'round';
  for (var yy = 14; yy <= 34; yy += 6.5) {
    g.beginPath();
    g.moveTo(px(LANE_C) - 9, py(yy));
    g.lineTo(px(LANE_C), py(yy + 2.6));
    g.lineTo(px(LANE_C) + 9, py(yy));
    g.stroke();
  }

  // 目标灯区标记
  g.strokeStyle = 'rgba(111,243,255,.4)'; g.lineWidth = 2;
  TARGETS.forEach(function (t) {
    var midY = (t.y1 + t.y2) / 2;
    g.beginPath();
    g.moveTo(px(-23), py(midY));
    g.lineTo(px(-21), py(midY));
    g.stroke();
  });

  // 出球口阴影
  var dg = g.createRadialGradient(px(0), 880, 10, px(0), 880, 110);
  dg.addColorStop(0, 'rgba(2,3,10,.85)');
  dg.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = dg;
  g.fillRect(px(0) - 110, 880 - 110, 220, 110);

  // 铭牌文字
  g.textAlign = 'center';
  g.fillStyle = 'rgba(170,190,255,.28)';
  g.font = '700 30px "PingFang SC","Microsoft YaHei",sans-serif';
  g.fillText('三 维 弹 球', px(-2), py(27));
  g.fillStyle = 'rgba(150,175,255,.22)';
  g.font = '500 13px Menlo,monospace';
  g.fillText('S P A C E   P I N B A L L', px(-2), py(27) + 22);

  var tex = new THREE.CanvasTexture(c);
  tex.encoding = THREE.sRGBEncoding;
  tex.anisotropy = 8;
  return tex;
}

// 桌面
(function deck() {
  var shape = new THREE.Shape();
  shape.moveTo(-HW, 0);
  shape.lineTo(-HW, ARC_Y);
  shape.absarc(0, ARC_Y, HW, Math.PI, 0, true);
  shape.lineTo(HW, 0);
  shape.lineTo(-HW, 0);
  var geo = new THREE.ShapeGeometry(shape, 48);
  var pos = geo.attributes.position, uv = geo.attributes.uv;
  for (var i = 0; i < pos.count; i++) {
    uv.setXY(i, (pos.getX(i) + HW) / (2 * HW), pos.getY(i) / 88);
  }
  geo.rotateX(-Math.PI / 2);
  var mesh = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({
    map: makeDeckTexture(), roughness: 0.92, metalness: 0.05
  }));
  mesh.receiveShadow = true;
  tableGroup.add(mesh);
})();

// 墙体
var wallMat = new THREE.MeshStandardMaterial({
  color: 0x232a5e, roughness: 0.45, metalness: 0.25,
  emissive: 0x1b2470, emissiveIntensity: 0.3
});
var gateMat = new THREE.MeshStandardMaterial({
  color: 0x1a4a55, roughness: 0.4, metalness: 0.2,
  emissive: 0x6ff3ff, emissiveIntensity: 0.7
});
gateSeg.mat = gateMat;
gateSeg.h = 1.6;
SEGS.forEach(function (s) {
  if (!s.mesh) return;
  var dx = s.x2 - s.x1, dy = s.y2 - s.y1;
  var len = Math.hypot(dx, dy);
  var m = new THREE.Mesh(
    new THREE.BoxGeometry(len + s.pad, s.h, s.rad * 2),
    s.mat || wallMat
  );
  m.position.set((s.x1 + s.x2) / 2, s.h / 2, -(s.y1 + s.y2) / 2);
  m.rotation.y = Math.atan2(dy, dx);
  m.castShadow = true; m.receiveShadow = true;
  tableGroup.add(m);
});

// 缓冲柱
BUMPERS.forEach(function (bp) {
  var grp = new THREE.Group();
  grp.position.set(bp.x, 0, -bp.y);
  var body = new THREE.Mesh(
    new THREE.CylinderGeometry(bp.r, bp.r + 0.15, 1.7, 26),
    new THREE.MeshStandardMaterial({ color: 0x121737, roughness: 0.5, metalness: 0.3 })
  );
  body.position.y = 0.85;
  var ringMat = new THREE.MeshStandardMaterial({
    color: 0x101428, roughness: 0.35,
    emissive: bp.color, emissiveIntensity: 0.8
  });
  var ring = new THREE.Mesh(new THREE.TorusGeometry(bp.r - 0.15, 0.38, 12, 30), ringMat);
  ring.rotation.x = Math.PI / 2;
  ring.position.y = 1.9;
  var cap = new THREE.Mesh(
    new THREE.CylinderGeometry(1.5, bp.r - 0.4, 1.5, 26),
    new THREE.MeshStandardMaterial({ color: 0x1a2150, roughness: 0.4, metalness: 0.4 })
  );
  cap.position.y = 2.9;
  var capTopMat = new THREE.MeshStandardMaterial({
    color: 0x101428, emissive: bp.color, emissiveIntensity: 0.6, roughness: 0.4
  });
  var capTop = new THREE.Mesh(new THREE.CylinderGeometry(1.5, 1.5, 0.3, 26), capTopMat);
  capTop.position.y = 3.75;
  [body, ring, cap, capTop].forEach(function (m) { m.castShadow = true; grp.add(m); });
  tableGroup.add(grp);
  bp.grp = grp; bp.ringMat = ringMat; bp.capMat = capTopMat;
});

// 目标灯
TARGETS.forEach(function (t) {
  var midY = (t.y1 + t.y2) / 2, span = t.y2 - t.y1;
  var mat = new THREE.MeshStandardMaterial({
    color: 0x1a2150, roughness: 0.45,
    emissive: 0x39406e, emissiveIntensity: 0.5
  });
  var m = new THREE.Mesh(new THREE.BoxGeometry(1.1, 2.6, span + 0.3), mat);
  m.position.set(-25.7, 1.3, -midY);
  m.castShadow = true;
  tableGroup.add(m);
  t.mat = mat;
});

// 弹弓
SLINGS.forEach(function (s) {
  var shape = new THREE.Shape();
  shape.moveTo(s.p1.x, s.p1.y);
  shape.lineTo(s.apex.x, s.apex.y);
  shape.lineTo(s.p2.x, s.p2.y);
  shape.closePath();
  var geo = new THREE.ExtrudeGeometry(shape, {
    depth: 2.6, bevelEnabled: true,
    bevelThickness: 0.35, bevelSize: 0.3, bevelSegments: 2
  });
  geo.rotateX(-Math.PI / 2); // (x, 桌面y) → (x, 高度, -桌面y)
  var mat = new THREE.MeshStandardMaterial({
    color: 0x0d1130, roughness: 0.55, metalness: 0.15,
    emissive: s.color, emissiveIntensity: 0.85, envMapIntensity: 0.4
  });
  var m = new THREE.Mesh(geo, mat);
  m.castShadow = true; m.receiveShadow = true;
  tableGroup.add(m);
  s.mat = mat;
});

// 前挡板（遮住近端桌沿下的空隙）
(function apron() {
  var box = new THREE.Mesh(
    new THREE.BoxGeometry(2 * HW + 3.2, 3.4, 9),
    new THREE.MeshStandardMaterial({
      color: 0x080b22, roughness: 0.78, metalness: 0.1, envMapIntensity: 0.25
    })
  );
  box.position.set(0, -1.9, 4.55);
  box.receiveShadow = true;
  tableGroup.add(box);
  var strip = new THREE.Mesh(
    new THREE.BoxGeometry(2 * HW + 3.2, 0.2, 0.5),
    new THREE.MeshStandardMaterial({ color: 0x0a0e24, emissive: 0x6ff3ff, emissiveIntensity: 1.0 })
  );
  strip.position.set(0, 0.02, 0.3);
  tableGroup.add(strip);
})();

// 弹板
var flipMat = new THREE.MeshStandardMaterial({
  color: 0xff6a10, roughness: 0.42, metalness: 0.1,
  emissive: 0xe04a00, emissiveIntensity: 0.55, envMapIntensity: 0.3
});
FLIPPERS.forEach(function (f) {
  var geo = new THREE.CapsuleGeometry(f.r, f.len, 6, 16);
  geo.rotateZ(-Math.PI / 2);
  geo.translate(f.len / 2, 0, 0);
  var m = new THREE.Mesh(geo, flipMat);
  m.position.y = 1.2;
  m.castShadow = true;
  var grp = new THREE.Group();
  grp.position.set(f.px, 0, -f.py);
  grp.add(m);
  tableGroup.add(grp);
  f.grp = grp;
});

// 发射杆
var brassMat = new THREE.MeshStandardMaterial({ color: 0xc9a15a, roughness: 0.35, metalness: 0.8 });
var plungerHead = new THREE.Mesh(new THREE.CylinderGeometry(1.0, 1.0, 1.4, 20), brassMat);
plungerHead.geometry.rotateX(Math.PI / 2);
plungerHead.position.set(LANE_C, 1.2, -3.9);
plungerHead.castShadow = true;
tableGroup.add(plungerHead);
var plungerShaft = new THREE.Mesh(new THREE.CylinderGeometry(0.45, 0.45, 3.2, 14), brassMat);
plungerShaft.geometry.rotateX(Math.PI / 2);
plungerShaft.position.set(LANE_C, 1.2, -1.7);
tableGroup.add(plungerShaft);

// 弹球
var ballMesh = new THREE.Mesh(
  new THREE.SphereGeometry(BALL_R, 36, 24),
  new THREE.MeshStandardMaterial({
    color: 0xe8ecff, metalness: 0.95, roughness: 0.16, envMapIntensity: 1.3
  })
);
ballMesh.castShadow = true;
var ballGlow = new THREE.PointLight(0x8fd4ff, 0.5, 16, 2);
ballGlow.position.y = 2;
ballMesh.add(ballGlow);
tableGroup.add(ballMesh);

// 拖尾
var TRAIL_N = 14;
var trailGeo = new THREE.SphereGeometry(BALL_R * 0.62, 10, 8);
var trail = [];
for (var ti = 0; ti < TRAIL_N; ti++) {
  var tm = new THREE.Mesh(trailGeo, new THREE.MeshBasicMaterial({
    color: 0x9fd8ff, transparent: true, opacity: 0,
    blending: THREE.AdditiveBlending, depthWrite: false
  }));
  tm.visible = false;
  tableGroup.add(tm);
  trail.push(tm);
}
var trailPts = [], trailTick = 0;

// ── 输入 ────────────────────────────────────────────────────────
var keysDown = {};
var pointerSides = {};
function refreshFlipperInput() {
  var L = keysDown.ArrowLeft || keysDown.KeyZ || keysDown.KeyA;
  var R = keysDown.ArrowRight || keysDown.Slash || keysDown.KeyD;
  for (var id in pointerSides) {
    if (pointerSides[id] === 'L') L = true; else R = true;
  }
  var edgeL = L && !FLIPPERS[0].pressed, edgeR = R && !FLIPPERS[1].pressed;
  FLIPPERS[0].pressed = !!L;
  FLIPPERS[1].pressed = !!R;
  if ((edgeL || edgeR) && (state === 'ready' || state === 'play')) sfx.flip();
}
window.addEventListener('keydown', function (e) {
  if (e.repeat) { if (e.code === 'Space' || e.code.indexOf('Arrow') === 0) e.preventDefault(); return; }
  initAudio();
  if (state === 'menu' || state === 'over') {
    if (e.code === 'Enter' || e.code === 'Space' || e.code === 'KeyR') {
      e.preventDefault(); newGame();
    }
    return;
  }
  switch (e.code) {
    case 'ArrowLeft': case 'KeyZ': case 'KeyA':
    case 'ArrowRight': case 'Slash': case 'KeyD':
      e.preventDefault();
      keysDown[e.code] = true;
      refreshFlipperInput();
      break;
    case 'Space': case 'ArrowDown':
      e.preventDefault();
      if (state === 'ready') charging = true;
      break;
    case 'KeyR':
      newGame();
      break;
  }
});
window.addEventListener('keyup', function (e) {
  switch (e.code) {
    case 'ArrowLeft': case 'KeyZ': case 'KeyA':
    case 'ArrowRight': case 'Slash': case 'KeyD':
      keysDown[e.code] = false;
      refreshFlipperInput();
      break;
    case 'Space': case 'ArrowDown':
      if (charging) fire();
      break;
  }
});
window.addEventListener('blur', function () {
  keysDown = {}; pointerSides = {};
  refreshFlipperInput();
  if (charging) fire();
});
// 触屏 / 鼠标：左右半屏控制弹板
window.addEventListener('pointerdown', function (e) {
  initAudio();
  if (state === 'menu' || state === 'over') return;
  if (e.target.closest && e.target.closest('button')) return;
  pointerSides[e.pointerId] = e.clientX < window.innerWidth / 2 ? 'L' : 'R';
  refreshFlipperInput();
});
function releasePointer(e) {
  if (pointerSides[e.pointerId] !== undefined) {
    delete pointerSides[e.pointerId];
    refreshFlipperInput();
  }
}
window.addEventListener('pointerup', releasePointer);
window.addEventListener('pointercancel', releasePointer);
// 发射钮（触屏）
if (launchBtn) {
  launchBtn.addEventListener('pointerdown', function (e) {
    e.preventDefault(); e.stopPropagation();
    initAudio();
    if (state === 'ready') charging = true;
  });
  ['pointerup', 'pointercancel', 'pointerleave'].forEach(function (ev) {
    launchBtn.addEventListener(ev, function () { if (charging) fire(); });
  });
}
$('startBtn').addEventListener('click', function () { initAudio(); newGame(); });
$('againBtn').addEventListener('click', function () { initAudio(); newGame(); });
window.addEventListener('resize', function () {
  renderer.setSize(window.innerWidth, window.innerHeight);
  fitCamera();
});
window.addEventListener('contextmenu', function (e) { e.preventDefault(); });

// ── 主循环 ──────────────────────────────────────────────────────
var last = 0, acc = 0, viewW = 0, viewH = 0;
function frame(t) {
  requestAnimationFrame(frame);
  var dt = Math.min((t - last) / 1000 || 0, 0.033);
  last = t;

  // 视口尺寸自检（部分环境不派发 resize）
  if (viewW !== window.innerWidth || viewH !== window.innerHeight) {
    viewW = window.innerWidth; viewH = window.innerHeight;
    renderer.setSize(viewW, viewH);
    fitCamera();
  }

  // 蓄力
  if (charging && state === 'ready') {
    power = Math.min(1, power + dt / 1.15);
  } else if (state !== 'ready') {
    power = 0;
  }
  var targetPull = (state === 'ready' ? power : 0) * 2.2;
  pull += (targetPull - pull) * Math.min(1, dt * (charging ? 10 : 22));
  powerEl.classList.toggle('on', charging && state === 'ready');
  powerFillEl.style.height = (power * 100).toFixed(1) + '%';

  // 物理
  acc = Math.min(acc + dt, 0.05);
  while (acc >= DT) { step(DT); acc -= DT; }

  // 待发射：球钉在弹射杆顶
  if (state === 'ready' || state === 'menu') {
    ball.x = LANE_C; ball.y = 5.8 - pull;
    ball.vx = 0; ball.vy = 0;
  }
  plungerHead.position.z = -(3.9 - pull);
  plungerShaft.position.z = -(1.7 - pull * 0.6);
  plungerShaft.scale.y = 1 - pull * 0.16;

  // 丢球动画
  var sinkY = 0;
  if (state === 'drain') {
    drainT += dt;
    sinkY = -drainT * 9;
    if (drainT > 1.05) resolveDrain();
  }
  ballMesh.position.set(ball.x, BALL_R + sinkY, -ball.y);

  // 拖尾：高速时记录轨迹点，慢速/停摆时逐渐消散
  if (state === 'play' && Math.hypot(ball.vx, ball.vy) > 26) {
    if (++trailTick % 2 === 0) {
      trailPts.unshift({ x: ball.x, y: ball.y });
      if (trailPts.length > TRAIL_N) trailPts.pop();
    }
  } else if (trailPts.length) {
    trailPts.pop();
  }
  for (var tj = 0; tj < TRAIL_N; tj++) {
    var tmm = trail[tj], tp = trailPts[tj];
    if (!tp) { tmm.visible = false; continue; }
    var tk = 1 - tj / TRAIL_N;
    tmm.visible = true;
    tmm.position.set(tp.x, BALL_R, -tp.y);
    tmm.scale.setScalar(tk * 0.85 + 0.12);
    tmm.material.opacity = 0.5 * tk * tk;
  }

  // 桌体震动
  if (shake > 0.001) {
    shake *= Math.exp(-dt * 7);
    tableGroup.position.x = (Math.random() * 2 - 1) * shake * 0.5;
    tableGroup.position.z = (Math.random() * 2 - 1) * shake * 0.35;
  } else if (tableGroup.position.x !== 0) {
    tableGroup.position.set(0, 0, 0);
  }

  // 弹板 / 灯效
  FLIPPERS.forEach(function (f) { f.grp.rotation.y = f.ang; });
  BUMPERS.forEach(function (bp) {
    bp.flash = Math.max(0, bp.flash - dt * 3.2);
    var s = 1 + bp.flash * 0.14;
    bp.grp.scale.set(s, 1, s);
    bp.ringMat.emissiveIntensity = 0.8 + bp.flash * 2.4;
    bp.capMat.emissiveIntensity = 0.6 + bp.flash * 2.0;
  });
  SLINGS.forEach(function (s) {
    s.flash = Math.max(0, s.flash - dt * 3);
    s.mat.emissiveIntensity = 0.7 + s.flash * 2.4;
  });
  if (targetsResetAt && simT > targetsResetAt) {
    targetsResetAt = 0;
    TARGETS.forEach(function (tg) { tg.lit = false; });
  }
  TARGETS.forEach(function (tg) {
    tg.flash = Math.max(0, tg.flash - dt * 3);
    if (tg.lit) {
      tg.mat.emissive.setHex(0x6ff3ff);
      tg.mat.emissiveIntensity = 1.3 + tg.flash * 1.5;
    } else {
      tg.mat.emissive.setHex(0x39406e);
      tg.mat.emissiveIntensity = 0.5 + tg.flash * 2;
    }
  });

  renderer.render(scene, camera);
}

// ── 启动 ────────────────────────────────────────────────────────
fitCamera();
updateHUD();
if (SHOT === 'play') {
  newGame();
  score = 1250; updateHUD();
  state = 'play';
  ball.x = -4; ball.y = 46; ball.vx = 10; ball.vy = -16;
  TARGETS[0].lit = true;
} else if (SHOT === 'launch') {
  // 端到端物理验证：满力发射，应穿过单向门、绕弧顶入场并撞击得分
  newGame();
  state = 'play';
  ball.x = LANE_C; ball.y = 6; ball.vx = 0; ball.vy = 124;
} else if (SHOT === 'sim') {
  // 确定性物理自检：同步模拟 60 秒，结果写入 #err 供无头模式读取
  newGame();
  balls = 99;
  var rep = { fellBack: 0, drains: 0, maxY: 0, minX: 99, maxX: -99, exited: false, nan: false };
  var simV = parseFloat(Q.get('v')) || 124;
  var relaunch = function () {
    state = 'play';
    ball.x = LANE_C; ball.y = 6; ball.vx = 0; ball.vy = simV;
  };
  relaunch();
  for (var si = 0; si < 14400; si++) {
    var phase = si % 192; // 周期性拍打弹板
    FLIPPERS[0].pressed = FLIPPERS[1].pressed = phase < 40;
    step(DT);
    if (!isFinite(ball.x + ball.y + ball.vx + ball.vy)) { rep.nan = true; break; }
    if (ball.y > rep.maxY) rep.maxY = ball.y;
    if (ball.x < rep.minX) rep.minX = ball.x;
    if (ball.x > rep.maxX) rep.maxX = ball.x;
    if (ball.x < 10 && ball.y > 55) rep.exited = true;
    if (state === 'drain') { rep.drains++; relaunch(); }
    else if (state === 'ready') { rep.fellBack++; relaunch(); }
  }
  FLIPPERS[0].pressed = FLIPPERS[1].pressed = false;
  rep.score = score;
  rep.maxY = Math.round(rep.maxY * 10) / 10;
  rep.minX = Math.round(rep.minX * 10) / 10;
  rep.maxX = Math.round(rep.maxX * 10) / 10;
  reportErr('SIM ' + JSON.stringify(rep));
} else if (SHOT === 'ready') {
  newGame();
}
requestAnimationFrame(frame);

})();
