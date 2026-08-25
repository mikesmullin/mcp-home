# Vendored from agl src/lib/validate.mjs (not in agl-ai's export map).

export forceInt = (n, def) ->
  parsed = Number.parseInt n
  if Number.isInteger parsed then parsed else def

export forceRx = (rx, val, def) ->
  if rx.test val then val else def

export clamp = (n, min, max) ->
  if n < min then min
  else if n > max then max
  else n
