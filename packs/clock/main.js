// Hyacinth clock pack — herbarium specimen card.
//
// Two tickers: the big clock numerals (HH:MM, updated each second so the
// minute boundary is crisp) and the date marginalia (roman + prose,
// recomputed each tick but only re-rendered when the day actually changes).
// No requestAnimationFrame, no work between updates — the M11 powersave
// CPU appreciates it.

const clockEl = document.getElementById('clock');
const romanEl = document.getElementById('date-roman');
const proseEl = document.getElementById('date-prose');

const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

const ROMAN_MONTHS = [
  'I', 'II', 'III', 'IV', 'V', 'VI',
  'VII', 'VIII', 'IX', 'X', 'XI', 'XII',
];

// Convert an integer (1..3999) to a roman-numeral string. Used for the day
// and the year. Standard subtractive notation.
function toRoman(n) {
  const table = [
    [1000, 'M'], [900, 'CM'], [500, 'D'], [400, 'CD'],
    [100, 'C'],  [90, 'XC'],  [50, 'L'],  [40, 'XL'],
    [10, 'X'],   [9, 'IX'],   [5, 'V'],   [4, 'IV'],
    [1, 'I'],
  ];
  let out = '';
  for (const [v, s] of table) {
    while (n >= v) { out += s; n -= v; }
  }
  return out;
}

// English ordinal: 1 → "first", 2 → "second", ... falls back to "Nth"
// for the rare days the spelled-out form would get long.
function ordinal(n) {
  const words = [
    null, 'first', 'second', 'third', 'fourth', 'fifth',
    'sixth', 'seventh', 'eighth', 'ninth', 'tenth',
    'eleventh', 'twelfth', 'thirteenth', 'fourteenth', 'fifteenth',
    'sixteenth', 'seventeenth', 'eighteenth', 'nineteenth', 'twentieth',
    'twenty-first', 'twenty-second', 'twenty-third', 'twenty-fourth',
    'twenty-fifth', 'twenty-sixth', 'twenty-seventh', 'twenty-eighth',
    'twenty-ninth', 'thirtieth', 'thirty-first',
  ];
  return words[n] || `${n}th`;
}

function pad(n) {
  return String(n).padStart(2, '0');
}

let lastDateKey = '';

function tick() {
  const now = new Date();

  // Big clock — always update so the minute flip is sharp.
  if (clockEl) {
    clockEl.textContent = pad(now.getHours()) + ':' + pad(now.getMinutes());
  }

  // Date marginalia — only re-render when the day changes.
  const dateKey = `${now.getFullYear()}-${now.getMonth()}-${now.getDate()}`;
  if (dateKey !== lastDateKey) {
    lastDateKey = dateKey;
    const day = now.getDate();
    const month = now.getMonth();
    const year = now.getFullYear();

    if (romanEl) {
      // e.g. "VIII · IV · MMXXVI"
      romanEl.textContent = `${toRoman(day)} · ${ROMAN_MONTHS[month]} · ${toRoman(year)}`;
    }
    if (proseEl) {
      // e.g. "the eighth of April"
      proseEl.textContent = `the ${ordinal(day)} of ${MONTHS[month]}`;
    }
  }
}

tick();
setInterval(tick, 1000);

// ----- Battery marginalia (M15.2) -----
//
// Android System WebView is Blink and still ships navigator.getBattery(),
// even though Firefox/Safari dropped it on fingerprinting grounds. We use
// it directly — no polling, just the levelchange/chargingchange events —
// and hide the readout entirely when the API is missing (e.g. a `pnpm dev`
// desktop preview in Firefox) so the clock face renders unchanged.
const batteryEl = document.getElementById('battery');
const batteryLevelEl = document.getElementById('battery-level');
const batteryChargingEl = document.getElementById('battery-charging');

async function initBattery() {
  if (!('getBattery' in navigator)) {
    if (batteryEl) batteryEl.style.display = 'none';
    return;
  }

  const battery = await navigator.getBattery();

  function render() {
    if (batteryLevelEl) {
      batteryLevelEl.textContent = Math.round(battery.level * 100) + '%';
    }
    if (batteryChargingEl) {
      // `⚡` reads too modern against the herbarium voice; use a bracketed
      // italic annotation that matches the Cormorant Garamond marginalia.
      batteryChargingEl.textContent = battery.charging ? '[charging]' : '';
    }
  }

  render();
  battery.addEventListener('levelchange', render);
  battery.addEventListener('chargingchange', render);
}

initBattery();
