// 生成横幅图标的两张自带白底贴图：圆形遮罩 + 圆环辉光。
// 白底 + 运行时 SetVertexColor 染色：换主题色不需要重新生成资产。
// 确定性输出（无随机、无时间戳），重跑结果逐字节一致。
// 用法：node tools/media/gen-glow.js（零依赖，只用 Node 内置模块）
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const OUT = path.join(__dirname, '..', '..', 'Media');
const SIZE = 128;
const CENTER = (SIZE - 1) / 2; // 像素中心落在 63.5，四角对称

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const smoothstep = (t) => t * t * (3 - 2 * t);
const dist = (x, y) => Math.hypot(x - CENTER, y - CENTER);
const byte = (v) => Math.round(clamp01(v) * 255);

// 不透明白色圆盘，半径 62，边缘 1.5px smoothstep 过渡带。
function circleMask(x, y) {
  const a = smoothstep(clamp01((62 + 0.75 - dist(x, y)) / 1.5));
  return [255, 255, 255, byte(a)];
}

// 圆环（内 46 外 52，各 1px AA）alpha 1；外辉光 52 处 0.45 平滑落到 64 处 0；
// r<46 全透明。辉光与圆环取 max，交界处才不会出现亮度台阶。
function ringGlow(x, y) {
  const d = dist(x, y);
  if (d < 46) return [255, 255, 255, 0];
  const ring = smoothstep(clamp01(d - 46)) * smoothstep(clamp01(52 - d));
  const glow = d < 52 ? 0.45 : 0.45 * smoothstep(clamp01((64 - d) / 12));
  return [255, 255, 255, byte(Math.max(ring, glow))];
}

// ---- 手写 PNG 编码器：signature + IHDR + IDAT + IEND，每块带 CRC32 ----

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function encodePng(pixelFn) {
  // 原始扫描线：每行以 filter 字节 0（None）开头，后接 RGBA 字节。
  const raw = Buffer.alloc(SIZE * (SIZE * 4 + 1));
  let o = 0;
  for (let y = 0; y < SIZE; y++) {
    raw[o++] = 0;
    for (let x = 0; x < SIZE; x++) {
      for (const v of pixelFn(x, y)) raw[o++] = v;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(SIZE, 0);
  ihdr.writeUInt32BE(SIZE, 4);
  ihdr[8] = 8; // 位深 8
  ihdr[9] = 6; // 颜色类型 RGBA
  // 10-12 字节保持 0：deflate 压缩、标准 filter、非隔行。
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

fs.mkdirSync(OUT, { recursive: true });
const targets = [
  ['circle_mask.png', circleMask],
  ['ring_glow.png', ringGlow],
];
for (const [name, fn] of targets) {
  const file = path.join(OUT, name);
  fs.writeFileSync(file, encodePng(fn));
  console.log('wrote', file);
}
