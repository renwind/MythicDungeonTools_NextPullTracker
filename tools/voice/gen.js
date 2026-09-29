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
    prefix: '下一波',
    names: { lust: '嗜血', potion: '爆发药水', asc: '升腾' },
    join: (arr) => arr.join('加'),
  },
  {
    dir: 'en-US',
    voice: 'en-US-AriaNeural',
    prefix: 'Next pull: ',
    names: {
      lust: 'Bloodlust',
      potion: 'Burst Potion',
      asc: 'Ascendance',
    },
    join: (arr) =>
      arr.length === 1 ? arr[0] : arr.slice(0, -1).join(', ') + ' and ' + arr[arr.length - 1],
  },
];

// 与 buildItems 的逆序遍历同序。mask 的 bit0..2 依次是 lust/potion/asc，
// 从 1 到 7 正好是七种非空组合，文件名 = 选中的 tag 用 '-' 连接。
const ORDER = ['lust', 'potion', 'asc'];

// v4 独立成句的语音（设计 v4）：不参与上面的组合 ORDER/mask 逻辑，
// 键 = CooldownLust 直接传给 CooldownAlert.play 的 audioKey，一句一个文件。
const PHRASES = {
  'zh-CN': {
    'lust-ready': '嗜血好了',
    'lust-sated-soon': '精疲力尽快结束，下一波可用嗜血',
  },
  'en-US': {
    'lust-ready': 'Bloodlust ready.',
    'lust-sated-soon': 'Exhaustion ends soon. Bloodlust usable next pull.',
  },
};

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
      const sentence = set.prefix + set.join(tags.map((t) => set.names[t]));
      const key = tags.join('-');
      const file = path.join(dir, key + '.mp3');
      const tts = new EdgeTTS({ voice: set.voice, lang: set.dir, outputFormat: FORMAT });
      await tts.ttsPromise(sentence, file);
      const size = fs.statSync(file).size;
      console.log('OK ' + set.dir + '/' + key + '.mp3  ' + size + ' bytes  "' + sentence + '"');
    }
    // v4 独立句：文件名 = PHRASES 的键，与 CooldownLust 传给 play() 的 audioKey 一致。
    const phrases = PHRASES[set.dir] || {};
    for (const key of Object.keys(phrases)) {
      const sentence = phrases[key];
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
