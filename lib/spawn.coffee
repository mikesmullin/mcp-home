# Vendored from agl src/lib/spawn.mjs (not in agl-ai's export map).
import { spawn as _spawn } from 'child_process'

export spawn = (cmd, args = []) ->
  result =
    cmd: [cmd, args...].join ' '
    code: null
    stdout: ''
    stderr: ''
    promise: null
    proc: null
    kill: null
  proc = _spawn cmd, args, stdio: 'pipe'
  result.proc = proc
  result.kill = (signal = 'SIGTERM') ->
    try
      proc.kill signal
    catch e then null
  proc.stdout.on 'data', (d) -> result.stdout += d
  proc.stderr.on 'data', (d) -> result.stderr += d
  result.promise = new Promise (resolve, reject) ->
    proc.on 'close', (code) ->
      result.code = code
      resolve result
    proc.on 'error', reject
  result
