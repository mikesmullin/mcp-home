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
