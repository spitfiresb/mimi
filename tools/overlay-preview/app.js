const $ = (id) => document.getElementById(id);
const defaults = {
  background: '#242424', textColor: '#f2f2f2', opacity: 82, blur: 20,
  border: 8, shadow: 26, radius: 14, font: 14, padX: 16, padY: 12,
  width: 460, volatile: 44, motion: true,
};
const presets = {
  current: defaults,
  glass: { ...defaults, background: '#202820', opacity: 56, blur: 28, border: 18, radius: 20, padX: 18, padY: 14, shadow: 20 },
  ink: { ...defaults, background: '#1b1e1a', opacity: 100, blur: 0, border: 0, radius: 12, shadow: 16, volatile: 56 },
  light: { ...defaults, background: '#f3f3ed', textColor: '#262b24', opacity: 76, blur: 24, border: 35, radius: 18, shadow: 15, volatile: 52 },
};
const storageKey = 'mimi-overlay-studio-v1';
const sampleDefault = 'We should move the release to Friday and give ourselves a little more time to get the details right.';
let theme = { ...defaults }, sample = sampleDefault, preset = 'current', backdrop = 'dusk';
try {
  const saved = JSON.parse(localStorage.getItem(storageKey) || 'null');
  if (saved?.version === 1) {
    for (const key of Object.keys(defaults)) {
      if (typeof saved.theme?.[key] === typeof defaults[key]) theme[key] = saved.theme[key];
    }
    if (typeof saved.sample === 'string') sample = saved.sample;
    if (Object.hasOwn(presets, saved.preset) || saved.preset === 'custom') preset = saved.preset;
    if (['dusk', 'paper', 'night', 'color'].includes(saved.backdrop)) backdrop = saved.backdrop;
  }
} catch { /* Storage may be unavailable; the playground still works. */ }

const states = [
  { name: 'Idle', description: 'The overlay stays hidden while idle and during microphone startup. It appears only when recording is ready.', mic: 'Mic off', hidden: true },
  { name: 'Ready', description: 'Audio is ready. This is the cue to start speaking.', mic: 'Mic on', volatile: 'Speak now', pulse: true },
  { name: 'Listening', description: 'Committed words are bright. The latest words stay dim until the recognizer confirms them.', mic: 'Mic on', transcript: true, pulse: true },
  { name: 'Hands-free', description: 'Recording continues after the second tap. Fn finishes the dictation.', mic: 'Mic on', transcript: true, locked: true, pulse: true },
  { name: 'Transcribing', description: 'The microphone is off. The last preview dims while the final transcript finishes.', mic: 'Mic off', processing: true },
  { name: 'Cleaning up', description: 'Optional cleanup streams its result into the same panel. Cleanup is off by default in Mimi.', mic: 'Mic off', cleaned: true },
  { name: 'Finished', description: 'With cleanup enabled, the final sentence settles briefly before hiding. With cleanup off, Mimi pastes and hides directly.', mic: 'Mic off', cleaned: true },
  { name: 'Error', description: 'Startup failure closes the microphone and leaves a retry message.', mic: 'Mic off', volatile: 'Microphone unavailable — release and try again' },
];
const waveform = '<svg viewBox="0 0 20 20"><path d="M2 8v4m4-7v10m4-13v16m4-13v10m4-7v4"/></svg>';
const lock = '<svg viewBox="0 0 20 20"><rect x="4.5" y="8.5" width="11" height="9" rx="2"/><path d="M6.5 8V5.5a3.5 3.5 0 0 1 7 0V8m-3.5 4v2"/></svg>';
let selected = 2, playing = false, timer;

states.forEach((state, i) => {
  const button = document.createElement('button');
  button.className = 'state-button';
  button.innerHTML = `<span class="index">${String(i + 1).padStart(2, '0')}</span><span>${state.name}</span><span class="state-dot"></span>`;
  button.onclick = () => { stopPlayback(); selectState(i); };
  $('states').append(button);
});

const controls = [
  ['opacity', 'Opacity', 0, 100, '%', 'surface'],
  ['blur', 'Blur', 0, 50, 'px', 'surface'],
  ['border', 'Edge highlight', 0, 60, '%', 'surface'],
  ['shadow', 'Shadow', 0, 70, '%', 'surface'],
  ['radius', 'Corner radius', 0, 36, 'px', 'shape'],
  ['width', 'Maximum width', 260, 680, 'px', 'shape'],
  ['padX', 'Horizontal padding', 8, 32, 'px', 'shape'],
  ['padY', 'Vertical padding', 6, 28, 'px', 'shape'],
  ['font', 'Text size', 11, 22, 'px', 'shape'],
  ['volatile', 'Unconfirmed text', 15, 85, '%', 'shape'],
];
for (const [key, name, min, max, unit, group] of controls) {
  const row = document.createElement('div');
  row.innerHTML = `<label class="slider-label" for="${key}">${name}<output id="${key}-value" for="${key}"></output></label><input type="range" id="${key}" min="${min}" max="${max}" step="1">`;
  $(group + '-controls').append(row);
  // Clamp old/edited local settings to the supported design range.
  theme[key] = Math.max(min, Math.min(max, Number.isFinite(theme[key]) ? theme[key] : defaults[key]));
  $(key).oninput = () => {
    theme[key] = Number($(key).value); preset = 'custom'; sync(); save();
  };
}
for (const key of ['background', 'textColor']) {
  if (!/^#[\da-f]{6}$/i.test(theme[key])) theme[key] = defaults[key];
  $(key).oninput = () => { theme[key] = $(key).value; preset = 'custom'; sync(); save(); };
}
for (const key of ['motion']) {
  $(key).onchange = () => { theme[key] = $(key).checked; preset = 'custom'; sync(); save(); };
}
$('sample').value = sample;
$('sample').oninput = () => { sample = $('sample').value; render(); save(); };
$('preset').onchange = () => {
  preset = $('preset').value;
  if (presets[preset]) theme = { ...presets[preset] };
  sync(); save();
};
$('backdrop').onchange = () => { backdrop = $('backdrop').value; sync(); save(); };
$('reset').onclick = () => { theme = { ...defaults }; preset = 'current'; sync(); save(); };

function sync() {
  for (const [key, , , , unit] of controls) {
    $(key).value = theme[key]; $(key + '-value').textContent = `${theme[key]}${unit}`;
  }
  for (const key of ['background', 'textColor']) $(key).value = theme[key];
  for (const key of ['motion']) $(key).checked = theme[key];
  $('preset').value = preset;
  $('backdrop').value = backdrop;
  $('stage').className = 'stage ' + backdrop;
  const variables = {
    surface: theme.background, text: theme.textColor, opacity: theme.opacity / 100,
    blur: theme.blur + 'px', radius: theme.radius + 'px', border: theme.border / 100,
    shadow: theme.shadow / 100, font: theme.font + 'px', 'pad-x': theme.padX + 'px',
    'pad-y': theme.padY + 'px', 'max-width': theme.width + 'px', volatile: theme.volatile / 100,
  };
  for (const [key, value] of Object.entries(variables)) $('overlay').style.setProperty('--' + key, value);
  render();
}
function selectState(index) {
  selected = Math.max(0, Math.min(states.length - 1, index));
  [...$('states').children].forEach((button, i) => button.setAttribute('aria-pressed', String(i === selected)));
  const state = states[selected];
  $('state-name').textContent = $('detail-title').textContent = state.name;
  $('detail-description').textContent = state.description;
  $('state-number').textContent = `${String(selected + 1).padStart(2, '0')} / ${states.length}`;
  $('mic-state').textContent = state.mic;
  render();
}
function render() {
  const state = states[selected];
  let committed = '', volatile = state.volatile || '';
  if (state.transcript) {
    const words = sample.trim().split(/\s+/).filter(Boolean);
    const split = Math.max(0, words.length - 5);
    committed = words.slice(0, split).join(' ');
    volatile = (committed ? ' ' : '') + words.slice(split).join(' ');
  } else if (state.processing) volatile = sample || 'Transcribing…';
  else if (state.cleaned) committed = sample;
  $('committed').textContent = committed;
  $('volatile-text').textContent = volatile;
  $('glyph').innerHTML = state.locked ? lock : waveform;
  $('glyph').classList.toggle('pulse', Boolean(state.pulse && theme.motion));
  $('overlay').classList.toggle('hidden', Boolean(state.hidden));
  requestAnimationFrame(updateDimensions);
}
function updateDimensions() {
  const rect = $('overlay').getBoundingClientRect();
  $('dimensions').textContent = states[selected].hidden ? 'Overlay hidden' : `${Math.round(rect.width)} × ${Math.round(rect.height)} px`;
}
new ResizeObserver(updateDimensions).observe($('overlay'));
function save() {
  try {
    localStorage.setItem(storageKey, JSON.stringify({ version: 1, theme, sample, preset, backdrop }));
    $('save-note').textContent = 'Saved in this browser. Export to keep a design file.';
  } catch { $('save-note').textContent = 'Browser storage unavailable. Export to keep your changes.'; }
}
function stopPlayback() {
  playing = false; clearTimeout(timer); $('play').textContent = '▶ Play sequence';
}
$('play').onclick = () => {
  if (playing) { stopPlayback(); return; }
  playing = true; $('play').textContent = 'Ⅱ Pause sequence';
  // A hands-free dictation: two taps, listening, finalization, optional cleanup.
  const sequence = [[0, 750], [1, 650], [3, 3500], [4, 1000], [5, 1200], [6, 650], [0, 0]];
  let step = 0;
  function next() {
    const [index, duration] = sequence[step++]; selectState(index);
    if (step === sequence.length) { stopPlayback(); return; }
    timer = setTimeout(next, duration);
  }
  next();
};
document.addEventListener('keydown', (event) => {
  if (event.target.closest('input,select,textarea,button') || event.metaKey || event.ctrlKey || event.altKey) return;
  if (['ArrowUp', 'ArrowDown'].includes(event.key)) {
    event.preventDefault(); stopPlayback(); selectState(selected + (event.key === 'ArrowDown' ? 1 : -1));
  } else if (event.code === 'Space') { event.preventDefault(); $('play').click(); }
});
document.addEventListener('visibilitychange', () => { if (document.hidden) stopPlayback(); });
$('export').onclick = () => {
  const design = { version: 1, target: 'Mimi native overlay', source: 'Browser approximation; verify native material in AppKit', theme, sample };
  const url = URL.createObjectURL(new Blob([JSON.stringify(design, null, 2) + '\n'], { type: 'application/json' }));
  const link = document.createElement('a'); link.href = url; link.download = 'mimi-overlay-design.json'; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  $('save-note').textContent = 'Design exported. Mimi’s running appearance is unchanged.';
};
sync(); selectState(selected);
