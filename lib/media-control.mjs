// Firefox/Zen global player and other MPRIS clients via playerctl.
// Independent of which browser tab is focused. Always returns a snapshot.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const fmtPlayer = (name) => String(name || '').replace(/\..*$/, '');
const parseDurationUs = (us) => {
  const n = Number(us);
  return Number.isFinite(n) && n > 0 ? n / 1e6 : null;
};
const clampPct = (n) => {
  let v = Number.parseInt(n, 10);
  if (!Number.isInteger(v)) v = 0;
  return Math.min(100, Math.max(0, v));
};

export function createMediaControl(runCmd, opts = {}) {
  const waitMs = opts.waitMs ?? 80;
  const tries = opts.tries ?? 12;

  const pickPlayer = async () => {
    const res = await runCmd('playerctl', ['-l']);
    if (!res.ok || !res.out) return null;
    const players = res.out.split('\n').filter(Boolean);
    let paused = null;
    for (const p of players) {
      const st = await runCmd('playerctl', ['-p', p, 'status']);
      if (!st.ok) continue;
      const status = st.out.trim();
      if (status === 'Playing') return p;
      if (status === 'Paused' && !paused) paused = p;
    }
    return paused ?? players[0] ?? null;
  };

  const meta = async (player, args) => {
    const res = await runCmd('playerctl', ['-p', player, ...args]);
    return res.ok ? res.out.trim() : '';
  };

  const systemVolume = async () => {
    const res = await runCmd('wpctl', ['get-volume', '@DEFAULT_AUDIO_SINK@']);
    if (!res.ok) return null;
    const m = res.out.match(/Volume:\s+([0-9.]+)/);
    return m ? Math.round(Number(m[1]) * 100) : null;
  };

  const snapshot = async (player) => {
    if (!player) {
      return { player: null, status: 'none', note: 'no MPRIS media player is running (Zen global player / Spotify / etc.)' };
    }
    const status = (await meta(player, ['status'])) || 'unknown';
    const artist = await meta(player, ['metadata', 'xesam:artist']);
    const title = await meta(player, ['metadata', 'xesam:title']);
    const album = await meta(player, ['metadata', 'xesam:album']);
    const url = await meta(player, ['metadata', 'xesam:url']);
    const length = parseDurationUs(await meta(player, ['metadata', 'mpris:length']));
    const posRaw = await meta(player, ['position']);
    const position = posRaw !== '' && Number.isFinite(Number(posRaw)) ? Number(posRaw) : null;
    const volRaw = await meta(player, ['volume']);
    const playerVolume = volRaw !== '' && Number.isFinite(Number(volRaw)) ? Math.round(Number(volRaw) * 100) : null;
    const fraction = length > 0 && position != null ? position / length : null;
    return {
      player: fmtPlayer(player), playerId: player, status,
      artist: artist || null, title: title || null, album: album || null, url: url || null,
      positionSeconds: position, durationSeconds: length, fraction,
      playerVolumePercent: playerVolume, systemVolumePercent: await systemVolume(),
    };
  };

  const waitUntil = async (player, pred) => {
    let last = null;
    for (let i = 0; i < tries; i++) {
      last = await snapshot(player);
      if (pred(last)) return last;
      await sleep(waitMs);
    }
    return last;
  };

  const report = (extra, snap) => {
    if (!snap?.player) return [extra, snap?.note || 'no media player.'].filter(Boolean).join(' ');
    const dur = snap.durationSeconds != null ? snap.durationSeconds.toFixed(1) : '?';
    const pos = snap.positionSeconds != null ? snap.positionSeconds.toFixed(1) : '?';
    const pct = snap.fraction != null ? `${(snap.fraction * 100).toFixed(1)}%` : '?';
    const who = [snap.artist, snap.title].filter(Boolean).join(' — ') || '(title unknown)';
    return [
      extra,
      `player=${snap.player} status=${snap.status} track=${who}`,
      `position=${pos}s/${dur}s (${pct}) playerVolume=${snap.playerVolumePercent ?? '?'}% systemVolume=${snap.systemVolumePercent ?? '?'}%`,
    ].filter(Boolean).join(' ');
  };

  return {
    handle: async (args = {}) => {
      const action = args.action;
      const hasSeek = args.positionSeconds != null || args.positionFraction != null || args.seekBySeconds != null;
      const player = await pickPlayer();
      const before = await snapshot(player);
      const notes = [];

      if (!player && (action || hasSeek || args.playerVolume != null)) {
        return report('no media player is running.', before);
      }

      if (action && action !== 'status') {
        const res = await runCmd('playerctl', ['-p', player, action]);
        if (!res.ok) return report(`media ${action} failed (${res.out}).`, await snapshot(player));
        const want = action === 'pause' || action === 'stop' ? (s) => s.status === 'Paused' || s.status === 'Stopped'
          : action === 'play' ? (s) => s.status === 'Playing'
          : action === 'next' || action === 'previous' ? (s) => (s.title && s.title !== before.title)
            || (s.positionSeconds != null && before.positionSeconds != null && Math.abs(s.positionSeconds - before.positionSeconds) > 0.5)
          : () => true;
        const snap = await waitUntil(player, want);
        notes.push(want(snap)
          ? `media ${action} ok (${fmtPlayer(player)}).`
          : `media ${action} sent but not verified (status=${snap.status}, track=${snap.title}).`);
      }

      if (hasSeek) {
        const length = before.durationSeconds;
        let target = null;
        if (args.positionFraction != null) {
          const frac = Number(args.positionFraction);
          if (!(Number.isFinite(frac) && frac >= 0 && frac <= 1)) notes.push('positionFraction must be 0..1.');
          else if (!(length > 0)) notes.push('cannot seek by fraction: duration unknown.');
          else target = frac * length;
        } else if (args.positionSeconds != null) {
          const sec = Number(args.positionSeconds);
          if (!(Number.isFinite(sec) && sec >= 0)) notes.push('positionSeconds must be >= 0.');
          else target = sec;
        } else {
          const delta = Number(args.seekBySeconds);
          if (!Number.isFinite(delta)) notes.push('seekBySeconds must be a number.');
          else if (before.positionSeconds != null) target = Math.max(0, before.positionSeconds + delta);
          else notes.push('cannot relative-seek: current position unknown.');
        }
        if (target != null) {
          if (length > 0) target = Math.min(target, length);
          const res = await runCmd('playerctl', ['-p', player, 'position', String(target)]);
          const snap = await waitUntil(player, (s) => s.positionSeconds != null && Math.abs(s.positionSeconds - target) <= 1.5);
          if (res.ok && snap.positionSeconds != null && Math.abs(snap.positionSeconds - target) <= 1.5) {
            notes.push(`seek ok to ${snap.positionSeconds.toFixed(1)}s (requested ${target.toFixed(1)}s).`);
          } else {
            notes.push(`seek to ${target.toFixed(1)}s not verified (observed ${snap.positionSeconds ?? 'unknown'}s).`);
          }
        }
      }

      if (args.playerVolume != null) {
        const v = clampPct(args.playerVolume);
        const res = await runCmd('playerctl', ['-p', player, 'volume', String(v / 100)]);
        const snap = await waitUntil(player, (s) => s.playerVolumePercent != null && Math.abs(s.playerVolumePercent - v) <= 2);
        notes.push(res.ok && snap.playerVolumePercent != null && Math.abs(snap.playerVolumePercent - v) <= 2
          ? `player volume ${snap.playerVolumePercent} percent.`
          : `player volume change not verified (${res.out || snap.playerVolumePercent}).`);
      }

      if (args.volume != null) {
        const v = clampPct(args.volume);
        const res = await runCmd('wpctl', ['set-volume', '@DEFAULT_AUDIO_SINK@', `${v}%`]);
        const snap = await snapshot(player);
        if (res.ok && snap.systemVolumePercent != null && Math.abs(snap.systemVolumePercent - v) <= 2) {
          notes.push(`system volume ${snap.systemVolumePercent} percent.`);
        } else if (res.ok) notes.push(`system volume set to ${v} percent (readback ${snap.systemVolumePercent ?? 'unknown'}).`);
        else notes.push(`system volume change failed (${res.out}).`);
      }

      const after = await snapshot(player);
      return report(notes.join(' ') || 'status only — no transport change.', after);
    },
  };
}
