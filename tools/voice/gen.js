// 生成冷却提醒的内置语音。嗓音、句子顺序与文件命名必须与
// Modules/CooldownAlert.lua 的 AUDIO_TAG / buildItems / play 保持一致：
// 句子里的顺序 = 嗜血、爆发药水、升腾（= 图标横幅从左到右的顺序）。
// 用法：cd tools/voice && npm install && node gen.js
const fs = require('fs');
const path = require('path');
const { EdgeTTS } = require('node-edge-tts');

const OUT = path.join(__dirname, '..', '..', 'Media', 'voice');
const FORMAT = 'audio-24khz-48kbitrate-mono-mp3';

const SETS = [
  {
    dir: 'zh-CN',
    voice: 'zh-CN-XiaoyiNeural',
    joiner: '，',
    parts: { lust: '下一波嗜血', potion: '下一波爆发药水', asc: '下一波升腾' },
  },
  {
    dir: 'en-US',
    voice: 'en-US-AriaNeural',
    joiner: ', ',
    parts: {
      lust: 'Next pull Bloodlust',
      potion: 'Next pull Burst Potion',
      asc: 'Next pull Ascendance',
    },
  },
];

// 与 buildItems 的逆序遍历同序。mask 的 bit0..2 依次是 lust/potion/asc，
// 从 1 到 7 正好是七种非空组合，文件名 = 选中的 tag 用 '-' 连接。
const ORDER = ['lust', 'potion', 'asc'];

function combos() {
  const out = [];
  for (let mask = 1; mask < 8; mask++) {
    out.push(ORDER.filter((_, i) => mask & (1 << i)));
  }
  return out;
}

(async () => {
  for (const set of SETS) {
    const dir = path.join(OUT, set.dir);
    fs.mkdirSync(dir, { recursive: true });
    for (const tags of combos()) {
      const sentence = tags.map((t) => set.parts[t]).join(set.joiner);
      const key = tags.join('-');
      const file = path.join(dir, key + '.mp3');
      const tts = new EdgeTTS({ voice: set.voice, lang: set.dir, outputFormat: FORMAT });
      await tts.ttsPromise(sentence, file);
      const size = fs.statSync(file).size;
      console.log('OK ' + set.dir + '/' + key + '.mp3  ' + size + ' bytes  "' + sentence + '"');
    }
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
