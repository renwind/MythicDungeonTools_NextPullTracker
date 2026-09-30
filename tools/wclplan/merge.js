// 合波判据（2026-09-30 对 +22 纳洛拉克洞穴报告实测标定）：
//  (a) 本波窗口内 0 死亡 => 只 tag 没打，并入下一波；
//  (b) 与下一波窗口间隔 < gapSeconds => 实战未脱战，合并。
// 该报告三组合并间隔 0s/1s/5s，正常波间隔 >=10s，默认阈值 8s 有充足余量。
"use strict";

const DEFAULT_GAP_SECONDS = 8;

function mergePulls(windows, deathCounts, opts = {}) {
  if (!Array.isArray(windows) || !Array.isArray(deathCounts) || windows.length !== deathCounts.length) {
    throw new Error("merge: windows/deathCounts length mismatch");
  }
  const gap = opts.gapSeconds ?? DEFAULT_GAP_SECONDS;
  const groups = [];
  for (let i = 0; i < windows.length; i++) {
    const last = groups[groups.length - 1];
    const prev = i - 1;
    const joinPrevious = last && (
      deathCounts[prev] === 0 ||
      (windows[prev].end !== null && windows[i].start !== null &&
        windows[i].start - windows[prev].end < gap)
    );
    if (joinPrevious) last.push(i + 1);
    else groups.push([i + 1]);
  }
  return groups;
}

module.exports = { mergePulls, DEFAULT_GAP_SECONDS };
