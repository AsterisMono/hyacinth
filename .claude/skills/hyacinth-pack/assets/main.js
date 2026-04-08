// Hello-bag starter — ticks the clock once per second.
// Replace this whole file when you have a real pack idea; the only thing
// the kiosk requires of main.js is that it doesn't crash on load.

const clock = document.getElementById('clock');

function pad(n) {
  return String(n).padStart(2, '0');
}

function tick() {
  if (!clock) return;
  const now = new Date();
  clock.textContent = pad(now.getHours()) + ':' + pad(now.getMinutes());
}

tick();
setInterval(tick, 1000);
