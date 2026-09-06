#!/usr/bin/env bun
# House MCP: lights, Pixel Clock, media, apps, activity commands.
# Model-facing names are unprefixed (Angela mcp entry prefix: false).
import yaml from 'js-yaml'
import { existsSync, readdirSync, readFileSync } from 'fs'
import { runMcpStdioServer, textResult } from './shared/mcp-stdio.mjs'
import { spawn } from './lib/spawn.coffee'
import { clamp, forceInt } from './lib/validate.coffee'
import {
  alarm__create, alarm__list, alarm__update, alarm__delete
  alarm__show, alarm__snooze
  timer__create, timer__dismiss, timer__show
} from '/workspace/agl-common/lib/tool/adb.coffee'
import { desk_light, pc_light_color } from '/workspace/agl-common/lib/tool/home.coffee'

ACTIVITY_DIR = process.env.ADA_ACTIVITY_DIR or '/workspace/mari/activity'

# Ambient mic transcript (perception-voice append-only log, one utterance per
# line: `Sun, Sep 6 @ 4:09p | text`). Append-only, so 1-based line numbers
# are stable cursors. Env override for tests.
TRANSCRIPT_PATH = process.env.EAVESDROP_TRANSCRIPT or '/workspace/perception-voice/tmp/convos.md'
MONTHS = { Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5, Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11 }

# `Sun, Sep 6 @ 4:09p` -> ISO-8601 (local year guess; rolls back a year when
# the result lands in the future). Falls back to the raw prefix when odd.
parseLogTs = (prefix) ->
  m = String(prefix or '').match /^(\w{3}), (\w{3}) (\d{1,2}) @ (\d{1,2}):(\d{2})([ap])$/
  return prefix unless m and MONTHS[m[2]]?
  h = parseInt(m[4], 10) % 12
  h += 12 if m[6] is 'p'
  now = new Date()
  d = new Date now.getFullYear(), MONTHS[m[2]], parseInt(m[3], 10), h, parseInt(m[5], 10)
  d.setFullYear d.getFullYear() - 1 if d.getTime() > now.getTime() + 86400000
  d.toISOString()

splitLogLine = (line) ->
  idx = line.indexOf ' | '
  if idx < 0
    { prefix: '', levelDb: null, content: line }
  else
    prefix = line[0...idx]
    rest = line[idx + 3..]
    m = rest.match /^P95 (-?\d+)dB \| (.*)$/
    if m
      { prefix: prefix, levelDb: parseInt(m[1], 10), content: m[2] }
    else
      { prefix: prefix, levelDb: null, content: rest }

mcpFn = (fn) ->
  description: fn.description or fn.name or 'tool'
  inputSchema:
    type: 'object'
    properties: fn.parameters or {}
    required: fn.required or []
  handler: (args) ->
    out = await fn {}, args or {}
    textResult String(out ? '')

# Create then bring Clock to the matching tab. Deterministic: the model does
# not need a second tool call (and should not "remember" to open it).
mcpFnCreateAndShow = (createFn, showFn, page) ->
  extra = " After creating, automatically opens the Clock #{page} page on the phone."
  description: (createFn.description or createFn.name or 'tool') + extra
  inputSchema:
    type: 'object'
    properties: createFn.parameters or {}
    required: createFn.required or []
  handler: (args) ->
    out = await createFn {}, args or {}
    text = String(out ? '')
    if /^Failed/i.test text
      return textResult text
    shown = await showFn {}, {}
    textResult "#{text} #{String(shown ? '')}"

loadActivities = ->
  apps = {}
  commands = {}
  return { apps, commands } unless existsSync ACTIVITY_DIR
  for f in readdirSync ACTIVITY_DIR
    continue unless f.endsWith('.yml') or f.endsWith('.yaml')
    try
      doc = yaml.load readFileSync("#{ACTIVITY_DIR}/#{f}", 'utf8')
    catch e then continue
    continue unless doc?.name
    if doc.shell_aliases
      for target in Object.values doc.shell_aliases
        apps[target] = if doc.shell_prefix then "#{doc.shell_prefix} #{target}" else target
    if doc.commands
      for own key, val of doc.commands
        shell = if typeof val is 'string' then val else val?.shell
        commands["#{doc.name}.#{key}"] = shell if typeof shell is 'string'
  { apps, commands }

activities = loadActivities()

runCmd = (cmd, args) ->
  try
    child = spawn cmd, args.map(String)
    await child.promise
    { ok: child.code is 0, out: (child.stdout + child.stderr).trim().slice(0, 200) }
  catch e
    { ok: false, out: "#{cmd}: #{e.message}" }

shellTool = (shellLine, timeoutMs = 10000) ->
  try
    child = spawn 'bash', ['-c', shellLine]
    timeout = new Promise (r) -> setTimeout (-> r 'TIMEOUT'), timeoutMs
    result = await Promise.race [child.promise, timeout]
    return "started (still running): #{shellLine}" if result is 'TIMEOUT'
    if child.code is 0
      "ok: #{shellLine}#{if child.stdout then " — #{child.stdout.trim().slice 0, 200}" else ''}"
    else
      "failed (exit #{child.code}): #{shellLine} — #{(child.stderr or child.stdout).trim().slice 0, 200}"
  catch e
    "failed: #{shellLine} — #{e.message}"

pickPlayer = ->
  res = await runCmd 'playerctl', ['-l']
  return null unless res.ok and res.out
  players = res.out.split('\n').filter Boolean
  paused = null
  for p in players
    st = await runCmd 'playerctl', ['-p', p, 'status']
    continue unless st.ok
    status = st.out.trim()
    return p if status is 'Playing'
    paused ?= p if status is 'Paused'
  paused ? players[0] ? null

appNames = Object.keys activities.apps
cmdIds = Object.keys activities.commands
cmdListing = cmdIds.map((id) -> "#{id}: #{activities.commands[id]}").join '\n'

tools =
  desk_light: mcpFn desk_light
  pc_light_color: mcpFn pc_light_color
  alarm__create: mcpFnCreateAndShow alarm__create, alarm__show, 'alarms'
  alarm__list: mcpFn alarm__list
  alarm__update: mcpFn alarm__update
  alarm__delete: mcpFn alarm__delete
  alarm__show: mcpFn alarm__show
  alarm__snooze: mcpFn alarm__snooze
  timer__create: mcpFnCreateAndShow timer__create, timer__show, 'timers'
  timer__dismiss: mcpFn timer__dismiss
  timer__show: mcpFn timer__show

  media_control:
    description: 'control the currently playing media (music or video in the browser or ' +
      'any media player: pause, play, skip tracks) and/or set the system ' +
      'output volume — the equivalent of the keyboard media keys.'
    inputSchema:
      type: 'object'
      properties:
        action:
          type: 'string'
          enum: ['play', 'pause', 'play-pause', 'next', 'previous', 'stop']
          description: 'transport action for the active media player. omit when only changing volume.'
        volume:
          type: 'integer'
          description: 'set system output volume as a percent, 0-100. omit when only controlling playback.'
    handler: ({ action, volume }) ->
      parts = []
      if action
        player = await pickPlayer()
        if player
          res = await runCmd 'playerctl', ['-p', player, action]
          who = player.replace /\..*$/, ''
          parts.push if res.ok then "media #{action} ok (#{who})." \
                      else "media #{action} failed (#{res.out})."
        else
          parts.push 'no media player is running.'
      if volume?
        v = clamp forceInt(volume, 0), 0, 100
        res = await runCmd 'wpctl', ['set-volume', '@DEFAULT_AUDIO_SINK@', "#{v}%"]
        parts.push if res.ok then "system volume set to #{v} percent." \
                    else "volume change failed (#{res.out})."
      textResult parts.join(' ') or 'no media action requested (specify action and/or volume).'

  current_time:
    description: 'get the current local date, time, and timezone'
    inputSchema: { type: 'object', properties: {} }
    handler: ->
      now = new Date()
      tz = Intl.DateTimeFormat().resolvedOptions().timeZone
      local = now.toLocaleString 'en-US',
        weekday: 'long', year: 'numeric', month: 'long', day: 'numeric'
        hour: 'numeric', minute: '2-digit', second: '2-digit', timeZoneName: 'short'
      textResult "#{local} (timezone #{tz}; ISO #{now.toISOString()})"

  tail_eavesdrop_transcript:
    description: 'eavesdrop on the room: read the ambient microphone transcript ' +
      '(everything heard around here, addressed to Ada or not) from the newest end, like tail(1). ' +
      'Omit `before` to get the last `limit` utterances. Pass `before` = `next_before` from the ' +
      'previous call to get the previous page (strictly older). Messages in each page run ' +
      'oldest-to-newest. Repeat until `has_older` is false. ' +
      'Each message carries its timestamp plus a P95 loudness tag (`level_db`, windowed-RMS in dBFS, 0 = full scale) ' +
      'recorded with it: higher (closer to zero) means nearer/louder, which helps tell who was speaking, ' +
      'while the timestamp orders utterances in time. Older lines may have `level_db` null (recorded before tagging). ' +
      'Use when Mike references something said earlier that was never spoken to you. ' +
      'Read-only; it does not search. Message ids are 1-based line numbers, stable while the log is append-only.'
    inputSchema:
      type: 'object'
      properties:
        limit:
          type: 'integer'
          default: 100
          minimum: 1
          maximum: 200
          description: 'page size, capped server-side at 200. First call returns the newest `limit` utterances.'
        before:
          type: 'string'
          description: 'return `limit` utterances strictly older than this message id. Omit to tail.'
    handler: ({ limit, before }) ->
      unless existsSync TRANSCRIPT_PATH
        return textResult "transcript unavailable (no log at #{TRANSCRIPT_PATH})", true
      lim = parseInt limit, 10
      lim = 100 unless lim >= 1
      lim = Math.min 200, lim
      raw = readFileSync TRANSCRIPT_PATH, 'utf8'
      lines = raw.split('\n').filter (l) -> l.trim().length > 0
      total = lines.length
      end = total
      if before?
        cursor = parseInt String(before), 10
        unless cursor >= 1
          return textResult "invalid before cursor #{JSON.stringify before} (want a message id from a previous call)", true
        end = Math.min cursor - 1, total
      start = Math.max 0, end - lim
      msgs = lines[start...end].map (line, i) ->
        { prefix, content, levelDb } = splitLogLine line
        id: String(start + i + 1), timestamp: parseLogTs(prefix), level_db: levelDb, role: 'user', speaker: 'ambient', content: content
      textResult JSON.stringify({
        messages: msgs
        oldest_id: if msgs.length then msgs[0].id else null
        newest_id: if msgs.length then msgs[msgs.length - 1].id else null
        has_older: start > 0
        next_before: if msgs.length then msgs[0].id else null
      }, null, 2)

  run_application:
    description: 'launch a desktop application by its program name (as found on PATH), ' +
      'e.g. audacity, discord, zen-browser. Use the plain lowercase binary ' +
      'name, a single word.' +
      (if appNames.length then " Known favorites: #{appNames.join ', '}." else '')
    inputSchema:
      type: 'object'
      properties:
        app:
          type: 'string'
          description: 'program name: one word, lowercase, no spaces or paths'
      required: ['app']
    handler: ({ app }) ->
      name = String(app ? '').trim()
      unless /^[A-Za-z0-9._+-]{1,64}$/.test name
        return textResult "refused: \"#{name}\" is not a plain program name (one word, no spaces or paths)", true
      res = await runCmd "#{process.env.HOME}/launch.sh", [name]
      textResult if res.ok then "launched #{name}." else "failed to launch #{name} (#{res.out})"

  # Same script mari's arch activity binds to hotkey S (~/.config/mari/activity/arch.yml).
  shutdown:
    description: 'shut down this home PC. Runs ~/shutdown.sh: turns off the desk light, then poweroffs the machine. ' +
      'Only when Mike explicitly asked to shut down, power off, or turn off this computer — never as a side effect.'
    inputSchema: { type: 'object', properties: {} }
    handler: ->
      script = "#{process.env.HOME}/shutdown.sh"
      unless existsSync script
        return textResult "shutdown script missing: #{script}", true
      try
        child = spawn script, []
        # Do not wait for poweroff (or the desk-light agent ahead of it). Catch
        # immediate spawn/exec failures, then return so Ada can speak.
        early = await Promise.race [
          child.promise
          new Promise (r) -> setTimeout (-> r 'TIMEOUT'), 1500
        ]
        if early is 'TIMEOUT'
          return textResult 'shutdown started: desk light off, then this PC will power off.'
        if child.code is 0
          return textResult 'shutdown script finished; the PC should be powering off.'
        err = (child.stderr or child.stdout).trim().slice 0, 200
        textResult "shutdown failed (exit #{child.code}): #{err}", true
      catch e
        textResult "failed to start shutdown: #{e.message}", true

if cmdIds.length
  tools.run_activity_command =
    description: 'run one of my predefined activity commands (home automation, work laptop, sessions). ' +
      "Available commands (id: shell):\n#{cmdListing}"
    inputSchema:
      type: 'object'
      properties:
        id:
          type: 'string'
          enum: cmdIds
          description: 'the command id to run'
      required: ['id']
    handler: ({ id }) ->
      line = activities.commands[id]
      return textResult "unknown command: #{id}", true unless line
      textResult await shellTool line, 10000

await runMcpStdioServer
  name: 'home'
  version: '0.1.0'
  tools: tools
