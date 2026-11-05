'use strict';
// Explicit order; all assets are local and independent of GitHub API availability.
const screenshots = [
  ['input', 'Input — simulated 16×16 analog module'],
  ['output', 'Output — simulated hardware controls'],
  ['headphones-speakers', 'Speaker and headphone outputs — simulator'],
  ['mixer', 'Low-latency mixers — simulator'],
  ['input-routing', 'Input routing — simulator'],
  ['output-routing', 'Output routing — simulator'],
  ['device-settings', 'Device settings — simulator'],
  ['system-setup', 'System setup — simulator'],
  ['appearance-light', 'Light appearance — simulator'],
  ['usb-connection', 'USB connection — up to 96 kHz'],
  ['maestro-help', 'Built-in Maestro Help'],
  ['input-micpre', '8MicPre controls — simulator'],
  ['micpre-help', 'Microphone preamp help'],
  ['update-available', 'Sparkle update available'],
  ['update-current', 'Sparkle up to date'],
].map(([name, caption]) => ({src: `screenshots/${name}.png`, caption}));
const hero = document.getElementById('heroShot');
const box = document.getElementById('lightbox');
const large = document.getElementById('large');
const closeButton = document.getElementById('close');
const previous = document.getElementById('prev');
const next = document.getElementById('next');
const caption = document.getElementById('gallery-caption');
let index = 0, returnFocus, previousOverflow;
let background = [];
function show() {
  const item = screenshots[index];
  large.alt = item.caption;
  caption.textContent = item.caption;
  large.src = item.src;
  document.getElementById('count').textContent = `${index + 1} / ${screenshots.length}`;
}
large.onerror = () => { caption.textContent = `${screenshots[index].caption} — image unavailable`; };
function openGallery() {
  if (box.classList.contains('open')) return;
  returnFocus = document.activeElement;
  previousOverflow = document.body.style.overflow;
  background = [...document.body.children].filter(el => el !== box && el.tagName !== 'SCRIPT').map(el => [el, el.inert]);
  background.forEach(([el]) => { el.inert = true; });
  index = 0;
  show();
  box.classList.add('open');
  box.setAttribute('aria-hidden', 'false');
  document.body.style.overflow = 'hidden';
  closeButton.focus();
}
function closeGallery() {
  box.classList.remove('open');
  box.setAttribute('aria-hidden', 'true');
  document.body.style.overflow = previousOverflow;
  background.forEach(([el, inert]) => { el.inert = inert; });
  returnFocus?.focus();
}
function move(step) { index = (index + step + screenshots.length) % screenshots.length; show(); }
hero.setAttribute('role', 'button');
hero.setAttribute('tabindex', '0');
hero.setAttribute('aria-label', 'View all 15 Maestro screenshots');
hero.setAttribute('aria-haspopup', 'dialog');
hero.onclick = openGallery;
hero.onkeydown = event => {
  if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); openGallery(); }
};
closeButton.onclick = closeGallery;
previous.onclick = () => move(-1);
next.onclick = () => move(1);
box.onclick = event => { if (event.target === box) closeGallery(); };
box.onkeydown = event => {
  if (event.key === 'Escape') closeGallery();
  if (event.key === 'ArrowRight') move(1);
  if (event.key === 'ArrowLeft') move(-1);
  if (event.key === 'Tab') {
    const controls = [closeButton, previous, next];
    const current = controls.indexOf(document.activeElement);
    event.preventDefault();
    controls[(current + (event.shiftKey ? 2 : 1)) % controls.length].focus();
  }
};
const preview = document.createElement('img');
preview.src = screenshots[0].src;
preview.alt = screenshots[0].caption;
preview.onerror = () => { hero.textContent = 'View Maestro screenshots'; };
const hint = document.createElement('span');
hint.className = 'hint';
hint.textContent = 'View all 15 screenshots ↗';
hero.replaceChildren(preview, hint);
