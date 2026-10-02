"use strict";

const SKILL_BY_SPELL_ID = new Map([
  [117014, "elementalBlast"],
  [61882, "earthquake"],
]);

function validateRotationEvents(events) {
  if (!Array.isArray(events)) throw new Error("rotation: rotationCastEvents must be an array");
  for (const [index, event] of events.entries()) {
    if (!event || event.type !== "cast" || !SKILL_BY_SPELL_ID.has(event.spellId) ||
        !Number.isFinite(event.t) || event.t < 0) {
      throw new Error("rotation: invalid rotation event at index " + index +
        ": type=" + String(event?.type) + ", spellId=" + String(event?.spellId) +
        ", time=" + String(event?.t));
    }
  }
}

function assignRotationEvents(events, waves) {
  validateRotationEvents(events);
  if (!Array.isArray(waves)) throw new Error("rotation: waves must be an array");
  return events.map(event => {
    for (let i = waves.length - 1; i >= 0; i--) {
      const wave = waves[i];
      if (wave && Number.isFinite(wave.castStart) && Number.isFinite(wave.castEnd) &&
          event.t >= wave.castStart && event.t <= wave.castEnd) return i;
    }
    return -1;
  });
}

function summarizeRotation(waveCount, events, assignments) {
  validateRotationEvents(events);
  if (!Number.isInteger(waveCount) || waveCount < 1) {
    throw new Error("rotation: invalid assignment input");
  }
  if (!Array.isArray(assignments) || assignments.length !== events.length) {
    throw new Error("rotation: unassigned rotation cast");
  }
  const usage = Array.from({ length: waveCount }, () => ({ elementalBlast: 0, earthquake: 0 }));
  events.forEach((event, i) => {
    const wave = assignments[i];
    if (!Number.isInteger(wave) || wave < 0 || wave >= waveCount) {
      throw new Error("rotation: unassigned rotation cast at " + event.t);
    }
    usage[wave][SKILL_BY_SPELL_ID.get(event.spellId)] += 1;
  });
  return usage;
}

function ratioTenths(usage) {
  const total = usage.elementalBlast + usage.earthquake;
  if (total === 0) return null;
  const elementalBlast = Math.floor(usage.elementalBlast / total * 10 + 0.5);
  return { elementalBlast, earthquake: 10 - elementalBlast };
}

function buildRatioPack(usage) {
  if (!Array.isArray(usage)) throw new Error("rotation: ratio usage must be an array");
  return usage.map((row, index) => {
    if (!row || !Number.isSafeInteger(row.elementalBlast) || row.elementalBlast < 0 ||
        !Number.isSafeInteger(row.earthquake) || row.earthquake < 0) {
      throw new Error("rotation: ratio usage at index " + index + " must contain nonnegative safe integers");
    }
    return row.elementalBlast.toString(36) + "." + row.earthquake.toString(36);
  }).join(",");
}

function buildRatioPackLine(usage, routeKey) {
  const line = "/npt importratiopack " + routeKey + " " + buildRatioPack(usage);
  if (line.length > 255) throw new Error("rotation: ratio pack command exceeds 255 characters");
  return line;
}

module.exports = { assignRotationEvents, summarizeRotation, ratioTenths, buildRatioPack, buildRatioPackLine };
