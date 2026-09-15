import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMediaControl } from '../lib/media-control.mjs';

function mock(script) {
  const calls = [];
  const runCmd = async (cmd, args) => {
    calls.push([cmd, ...args]);
    const key = [cmd, ...args].join(' ');
    if (typeof script[key] === 'function') return script[key]();
    if (script[key] !== undefined) return { ok: true, out: String(script[key]) };
    return { ok: false, out: `unexpected ${key}` };
  };
  return { calls, media: createMediaControl(runCmd, { waitMs: 0, tries: 3 }) };
}

const playing = {
  'playerctl -l': 'firefox.instance_1_33',
  'playerctl -p firefox.instance_1_33 status': 'Playing',
  'playerctl -p firefox.instance_1_33 metadata xesam:artist': 'Kobaryo, Srezcat',
  'playerctl -p firefox.instance_1_33 metadata xesam:title': 'kawAIi (feat. Srezcat)',
  'playerctl -p firefox.instance_1_33 metadata xesam:album': 'kawAIi',
  'playerctl -p firefox.instance_1_33 metadata xesam:url': 'https://open.spotify.com/playlist/x',
  'playerctl -p firefox.instance_1_33 metadata mpris:length': '179000000',
  'playerctl -p firefox.instance_1_33 position': '40',
  'playerctl -p firefox.instance_1_33 volume': '1.0',
  'wpctl get-volume @DEFAULT_AUDIO_SINK@': 'Volume: 0.40',
};

test('status reads now-playing without transport', async () => {
  const { calls, media } = mock(playing);
  const text = await media.handle({});
  assert.match(text, /track=Kobaryo, Srezcat — kawAIi/);
  assert.match(text, /status=Playing/);
  assert.match(text, /position=40.0s\/179.0s/);
  assert.equal(calls.some((c) => c[0] === 'playerctl' && (c.includes('pause') || c[c.length - 1] === 'play')), false);
});

test('pause is verified; missing player is explicit', async () => {
  const state = { status: 'Playing' };
  const { media } = mock({
    ...playing,
    'playerctl -p firefox.instance_1_33 pause': () => { state.status = 'Paused'; return { ok: true, out: '' }; },
    'playerctl -p firefox.instance_1_33 status': () => ({ ok: true, out: state.status }),
  });
  assert.match(await media.handle({ action: 'pause' }), /media pause ok \(firefox\)[\s\S]*status=Paused/);
  const empty = mock({ 'playerctl -l': '' });
  assert.match(await empty.media.handle({ action: 'pause' }), /no media player/);
});

test('seek by fraction and player volume are verified', async () => {
  const pos = { n: 40 };
  const vol = { n: 1 };
  const { media } = mock({
    ...playing,
    'playerctl -p firefox.instance_1_33 position': () => ({ ok: true, out: String(pos.n) }),
    'playerctl -p firefox.instance_1_33 position 89.5': () => { pos.n = 89.5; return { ok: true, out: '' }; },
    'playerctl -p firefox.instance_1_33 volume': () => ({ ok: true, out: String(vol.n) }),
    'playerctl -p firefox.instance_1_33 volume 0.5': () => { vol.n = 0.5; return { ok: true, out: '' }; },
  });
  assert.match(await media.handle({ positionFraction: 0.5 }), /seek ok to 89.5s/);
  assert.match(await media.handle({ playerVolume: 50 }), /player volume 50 percent/);
});
