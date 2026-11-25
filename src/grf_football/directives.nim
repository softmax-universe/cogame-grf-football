## Directives: the order a seat plays for one 240-tick decision turn, its
## strict parser, and the view-coordinate transform every policy sees the world
## through.
##
## Two hard rules live here and are pinned by tests/test_directives.nim:
##
## 1. **Every recorded string is truncated on RUNE boundaries, never bytes.**
##    A byte-truncated multi-byte character is exactly the bug that makes
##    replay bytes render in a browser but fail a strict parser.
## 2. **Parsing is strict.** Replies must match the documented JSON schema with
##    exactly one cog entry for the seat's own shirt, valid enums, and finite
##    in-pitch numeric target coordinates. Optional fields keep their documented
##    defaults when omitted, but invalid values, unknown fields, and legacy
##    shapes are rejected rather than silently repaired.

import
  std/[json, math, strutils, unicode],
  sim

# --------------------------------------------------------------------------
# View coordinates: metres from the centre spot, x toward blue's goal. The
# ONLY coordinates a policy ever sees or sends.
# --------------------------------------------------------------------------

const
  ViewHalfW* = 42.0
  ViewHalfH* = 27.0
  GoalHalfWidth* = 4.0

proc viewX*(x: int32): float {.inline.} =
  float(int(x) - int(CentreX)) / 1_000_000.0

proc viewY*(y: int32): float {.inline.} =
  float(int(y) - int(CentreY)) / 1_000_000.0

proc worldXOfView*(v: float): int32 {.inline.} =
  int32(int(CentreX) + int(round(clamp(v, -ViewHalfW, ViewHalfW) * 1_000_000.0)))

proc worldYOfView*(v: float): int32 {.inline.} =
  int32(int(CentreY) + int(round(clamp(v, -ViewHalfH, ViewHalfH) * 1_000_000.0)))

proc round1*(value: float): float {.inline.} =
  ## One decimal, the precision every number in the seat view carries.
  round(value * 10.0) / 10.0

proc metresPerSecond*(umPerTick: int32): float {.inline.} =
  float(umPerTick) * float(TargetFps) / 1_000_000.0

# --------------------------------------------------------------------------
# Rune-boundary truncation
# --------------------------------------------------------------------------

proc clipRunes*(text: string, maxRunes: int): string =
  ## Truncates on a RUNE boundary. Slicing a `string` by byte index on any path
  ## to the replay is forbidden.
  result = text.strip()
  var clean = newStringOfCap(result.len)
  for rune in result.runes:
    # Control characters would corrupt a replay chat record and a JSON line.
    if int32(rune) >= 32 or int32(rune) == 9:
      clean.add($rune)
  result = clean
  if maxRunes <= 0:
    return ""
  if result.runeLen <= maxRunes:
    return
  result = result.runeSubStr(0, maxRunes - 1) & "\u2026"

# --------------------------------------------------------------------------
# Cog ids
# --------------------------------------------------------------------------

proc cogIndexOfId*(id: string): int =
  ## Strict `RED-1`..`RED-11` / `BLUE-1`..`BLUE-11` (case-insensitive team
  ## prefix, single `-`, no leading zero). -1 when the token names no shirt.
  let text = id.strip().toUpperAscii()
  let cut = text.find('-')
  if cut <= 0 or cut == text.high:
    return -1
  let
    prefix = text[0 ..< cut]
    digits = text[cut + 1 .. ^1]
  if digits.len == 0 or digits.len > 2 or digits[0] == '0':
    return -1
  for ch in digits:
    if ch notin {'0' .. '9'}:
      return -1
  let shirt = parseInt(digits)
  if shirt < 1 or shirt > CogsPerTeam:
    return -1
  case prefix
  of "RED": cogOfShirt(Red, shirt)
  of "BLUE": cogOfShirt(Blue, shirt)
  else: -1

# --------------------------------------------------------------------------
# Strict enum parsers
# --------------------------------------------------------------------------

proc parseRole(text: string, value: var Role): bool =
  case text.strip().toLowerAscii()
  of "striker": value = roleStriker; true
  of "winger": value = roleWinger; true
  of "playmaker": value = rolePlaymaker; true
  of "anchor": value = roleAnchor; true
  else: false

proc parseIntent(text: string, value: var Intent): bool =
  case text.strip().toLowerAscii()
  of "press": value = inPress; true
  of "hold_shape": value = inHoldShape; true
  of "make_run": value = inMakeRun; true
  of "support": value = inSupport; true
  of "drop_deep": value = inDropDeep; true
  of "carry": value = inCarry; true
  of "switch_play": value = inSwitchPlay; true
  of "shadow": value = inShadow; true
  else: false

proc parseOnBall(text: string, value: var OnBall): bool =
  case text.strip().toLowerAscii()
  of "shoot": value = obShoot; true
  of "pass_short": value = obPassShort; true
  of "pass_long": value = obPassLong; true
  of "pass_high": value = obPassHigh; true
  of "dribble": value = obDribble; true
  of "hold": value = obHold; true
  else: false

proc parseSprint(text: string, value: var SprintMode): bool =
  case text.strip().toLowerAscii()
  of "auto": value = spAuto; true
  of "always": value = spAlways; true
  of "never": value = spNever; true
  else: false

proc parseTackle(text: string, value: var TackleMode): bool =
  case text.strip().toLowerAscii()
  of "auto": value = tkAuto; true
  of "never": value = tkNever; true
  else: false

# --------------------------------------------------------------------------
# Directive construction and serialization
# --------------------------------------------------------------------------

proc emptyDirective*(seat: int): Directive =
  result.source = dsScripted
  result.half = 1
  result.cog = CogOrder(
    role: SeatRole[clamp(seat, 0, SeatCount - 1)],
    intent: inSupport,
    targetX: CentreX, targetY: CentreY,
    onBall: obPassShort, passTo: -1,
    sprint: spAuto, tackle: tkAuto, say: "")

proc directiveJson*(seat: int, directive: Directive): JsonNode =
  ## The `directive` replay chat record. Capped at MaxDirectiveRecordRunes by
  ## the caller (`capRecord` below).
  let
    index = cogOfSeat(seat)
    order = directive.cog
  var cogs = newJArray()
  cogs.add(%*{
    "id": cogId(index),
    "role": roleText(order.role),
    "intent": intentText(order.intent),
    "target": [round1(viewX(order.targetX)), round1(viewY(order.targetY))],
    "on_ball": onBallText(order.onBall),
    "pass_to": (if order.passTo >= 0: %cogId(int(order.passTo))
                else: newJNull()),
    "sprint": sprintText(order.sprint),
    "tackle": tackleText(order.tackle),
    "say": order.say
  })
  %*{
    "k": "directive",
    "turn": directive.turn,
    "half": directive.half,
    "seat": seat,
    "id": cogId(index),
    "team": teamText(teamOfSeat(seat)),
    "source": sourceText(directive.source),
    "latency_ms": directive.latencyMs,
    "note": directive.note,
    "cogs": cogs
  }

proc clipJsonStrings(node: JsonNode, budget: int): JsonNode =
  ## A copy of `node` with every STRING VALUE clipped to `budget` runes. Keys
  ## are untouched, so the shape a reader matches on survives.
  case node.kind
  of JString:
    result = %clipRunes(node.getStr(), budget)
  of JArray:
    result = newJArray()
    for item in node:
      result.add(clipJsonStrings(item, budget))
  of JObject:
    result = newJObject()
    for key, value in node:
      result[key] = clipJsonStrings(value, budget)
  else:
    result = node

proc capRecord*(text: string): string =
  ## Every replay chat record is capped at MaxDirectiveRecordRunes runes, on a
  ## rune boundary.
  ##
  ## The cap is on the SERIALIZED record, and JSON escaping is what makes that
  ## non-obvious: a `"` or a `\` inside a note or a say costs two runes on the
  ## wire. Blindly clipping the serialized text would cut the object mid-key:
  ## still valid UTF-8 on a rune boundary, but no longer JSON — and
  ## `broadcast.applyRecord` would silently drop the feed line while
  ## `tools/replay_summary.py` skipped the record, so phase 60 would
  ## under-count exactly the LLM directives it is there to verify.
  ##
  ## So an over-long record is shrunk STRUCTURALLY: parse it, clip its string
  ## values to a halving budget until the serialization fits, and only fall
  ## back to the blind rune clip when the text is not a JSON object at all.
  if text.runeLen <= MaxDirectiveRecordRunes:
    return clipRunes(text, MaxDirectiveRecordRunes)
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return clipRunes(text, MaxDirectiveRecordRunes)
  if node.kind != JObject:
    return clipRunes(text, MaxDirectiveRecordRunes)
  var budget = MaxNoteRunes
  while budget > 0:
    budget = budget div 2
    let shrunk = $clipJsonStrings(node, budget)
    if shrunk.runeLen <= MaxDirectiveRecordRunes:
      return shrunk
  clipRunes(text, MaxDirectiveRecordRunes)

# --------------------------------------------------------------------------
# Strict directive parser
# --------------------------------------------------------------------------

proc finiteNumberOf(node: JsonNode, value: var float): bool =
  ## Accepts only a finite JSON number (never numeric strings).
  if node.isNil:
    return false
  case node.kind
  of JInt:
    value = float(node.getInt())
    true
  of JFloat:
    let v = node.getFloat()
    if v != v or v == Inf or v == NegInf:
      return false
    value = v
    true
  else:
    false

proc parseDirective*(
  sim: SimServer,
  seat: int,
  payload: JsonNode,
  turn: int
): tuple[directive: Directive, ok: bool, error: string] =
  ## Validates one reply into a legal directive. Rejects unknown keys, legacy
  ## shapes, unmatched shirt ids, invalid enums, and missing or out-of-pitch
  ## targets. Optional fields (`note`, `role`, `pass_to`, `sprint`, `tackle`,
  ## `say`) keep their documented defaults when omitted or null.
  template reject(msg: string): untyped =
    return (Directive(), false, msg)

  if payload.isNil or payload.kind != JObject:
    reject("directive must be a JSON object")
  for key, _ in payload:
    if key notin ["note", "cogs"]:
      reject("unexpected top-level field: " & key)

  var note = ""
  if payload.hasKey("note") and payload["note"].kind != JNull:
    if payload["note"].kind != JString:
      reject("note must be a string")
    note = clipRunes(payload["note"].getStr(), MaxNoteRunes)

  if not payload.hasKey("cogs") or payload["cogs"].kind != JArray:
    reject("cogs must be an array")
  let cogsNode = payload["cogs"]
  if cogsNode.len != 1:
    reject("cogs must contain exactly one entry")
  let body = cogsNode[0]
  if body.kind != JObject:
    reject("cogs[0] must be an object")
  for key, _ in body:
    if key notin ["id", "role", "intent", "target", "on_ball", "pass_to",
        "sprint", "tackle", "say"]:
      reject("unexpected cog field: " & key)

  let index = cogOfSeat(seat)
  if not body.hasKey("id") or body["id"].kind != JString:
    reject("cogs[0].id must be a string")
  if cogIndexOfId(body["id"].getStr()) != index:
    reject("cogs[0].id must match " & cogId(index))

  var order = CogOrder(
    role: SeatRole[seat],
    passTo: -1'i32,
    sprint: spAuto,
    tackle: tkAuto,
    say: ""
  )

  if body.hasKey("role") and body["role"].kind != JNull:
    if body["role"].kind != JString or
        not parseRole(body["role"].getStr(), order.role):
      reject("invalid role")

  if not body.hasKey("intent") or body["intent"].kind != JString or
      not parseIntent(body["intent"].getStr(), order.intent):
    reject("invalid or missing intent")

  if not body.hasKey("target") or body["target"].kind != JArray or
      body["target"].len != 2:
    reject("target must be a [x, y] array")
  var vx, vy = 0.0
  if not finiteNumberOf(body["target"][0], vx) or
      not finiteNumberOf(body["target"][1], vy):
    reject("target coordinates must be finite numbers")
  if vx < -ViewHalfW or vx > ViewHalfW or vy < -ViewHalfH or vy > ViewHalfH:
    reject("target coordinates out of pitch bounds")
  order.targetX = worldXOfView(vx)
  order.targetY = worldYOfView(vy)

  if not body.hasKey("on_ball") or body["on_ball"].kind != JString or
      not parseOnBall(body["on_ball"].getStr(), order.onBall):
    reject("invalid or missing on_ball")

  if body.hasKey("pass_to") and body["pass_to"].kind != JNull:
    if body["pass_to"].kind != JString:
      reject("pass_to must be a teammate id string or null")
    let mate = cogIndexOfId(body["pass_to"].getStr())
    if mate < 0 or mate == index or teamOfCog(mate) != teamOfSeat(seat):
      reject("pass_to must name a teammate shirt")
    order.passTo = int32(mate)

  if body.hasKey("sprint") and body["sprint"].kind != JNull:
    if body["sprint"].kind != JString or
        not parseSprint(body["sprint"].getStr(), order.sprint):
      reject("invalid sprint mode")

  if body.hasKey("tackle") and body["tackle"].kind != JNull:
    if body["tackle"].kind != JString or
        not parseTackle(body["tackle"].getStr(), order.tackle):
      reject("invalid tackle mode")

  if body.hasKey("say") and body["say"].kind != JNull:
    if body["say"].kind != JString:
      reject("say must be a string")
    order.say = clipRunes(body["say"].getStr(), MaxSayRunes)

  var directive = Directive(
    turn: int32(turn),
    half: sim.half,
    source: dsLlm,
    note: note,
    cog: order
  )
  (directive, true, "")
