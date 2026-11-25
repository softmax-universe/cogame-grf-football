## Strict directive parsing, single-object JSON/fence extraction, and the
## RUNE-BOUNDARY truncation discipline.

import std/[json, strutils, unicode]
import lib/helpers
import grf_football/prompts

proc parse(sim: SimServer, seat: int, text: string):
    tuple[directive: Directive, ok: bool, error: string] =
  let payload = extractJsonObject(text)
  sim.parseDirective(seat, payload, 0)

proc mustRejectJson(text: string, label: string) =
  var raised = false
  try:
    discard extractJsonObject(text)
  except GrfFootballError:
    raised = true
  doAssert raised, "extractJsonObject must reject " & label

proc mustRejectDirective(sim: SimServer, seat: int, text: string, label: string) =
  let payload = extractJsonObject(text)
  let res = sim.parseDirective(seat, payload, 0)
  doAssert not res.ok, "parseDirective must reject " & label
  doAssert res.error.len > 0, "rejection must carry a reason for " & label

proc bareAndSingleFenceParse() =
  var sim = playing(testConfig())
  let bare = "  {\"note\":\"ok\",\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"press\"," &
    "\"target\":[3,4],\"on_ball\":\"pass_short\"}]}  "
  let a = parse(sim, 2, bare)
  doAssert a.ok, "bare JSON object parses: " & a.error
  doAssert a.directive.cog.intent == inPress
  doAssert a.directive.cog.role == SeatRole[2], "omitted role keeps seat default"
  doAssert a.directive.cog.sprint == spAuto, "omitted sprint keeps default"
  doAssert a.directive.cog.tackle == tkAuto, "omitted tackle keeps default"
  doAssert a.directive.cog.passTo == -1, "omitted pass_to keeps null default"

  let jsonFenced = "```json\n{\"note\":\"ok\",\"cogs\":[{\"id\":\"RED-9\"," &
    "\"intent\":\"press\",\"target\":[3,4],\"on_ball\":\"shoot\"}]}\n```"
  let b = parse(sim, 2, jsonFenced)
  doAssert b.ok, "json-tagged fence parses: " & b.error
  doAssert b.directive.cog.onBall == obShoot

  let plainFenced = "```\n{\"cogs\":[{\"intent\":\"shadow\"," &
    "\"target\":[1,1],\"on_ball\":null}]}\n```"
  let c = parse(sim, 2, plainFenced)
  doAssert c.ok, "plain fence with omitted id and null on_ball parses: " & c.error
  doAssert c.directive.cog.intent == inShadow
  doAssert c.directive.cog.onBall == obPassShort, "null on_ball defaults to pass_short"
  doAssert c.directive.note == "", "omitted note defaults to empty"

  let minimal = "{\"cogs\":[{\"intent\":\"hold_shape\",\"target\":[0,0]}]}"
  let d = parse(sim, 2, minimal)
  doAssert d.ok, "omitted id and on_ball parse cleanly: " & d.error
  doAssert d.directive.cog.intent == inHoldShape
  doAssert d.directive.cog.onBall == obPassShort, "omitted on_ball defaults to pass_short"
  report "bare JSON and single plain/json outer fences parse with optional defaults"

proc proseAndExtraObjectsRejected() =
  const ValidObj = "{\"note\":\"ok\",\"cogs\":[{\"id\":\"RED-9\"," &
    "\"intent\":\"shadow\",\"target\":[1,1],\"on_ball\":\"hold\"}]}"
  mustRejectJson("Sure! Here is my order:\n" & ValidObj, "prose prefix")
  mustRejectJson(ValidObj & "\nGood luck!", "prose suffix")
  mustRejectJson("Here:\n```json\n" & ValidObj & "\n```", "prose before fence")
  mustRejectJson("```json\n" & ValidObj & "\n```\nThanks!", "prose after fence")
  mustRejectJson(ValidObj & "\n" & ValidObj, "two bare JSON objects")
  mustRejectJson("```json\n" & ValidObj & "\n```\n```json\n" & ValidObj & "\n```",
    "two fenced blocks")
  mustRejectJson("```python\n" & ValidObj & "\n```", "non-json fence tag")
  mustRejectJson("```json\n" & ValidObj, "unterminated fence")
  mustRejectJson("[" & ValidObj & "]", "top-level JSON array")
  mustRejectJson("   ", "empty response")
  report "surrounding prose, extra objects, and bad fences are rejected"

proc legacyShapesAndAliasesRejected() =
  var sim = playing(testConfig())
  mustRejectDirective(sim, 2,
    "{\"note\":\"n\",\"cogs\":{\"id\":\"RED-9\",\"intent\":\"carry\"," &
    "\"target\":[0,0],\"on_ball\":\"dribble\"}}",
    "bare cogs object")
  mustRejectDirective(sim, 2,
    "{\"note\":\"n\",\"cogs\":{\"RED-9\":{\"intent\":\"support\"," &
    "\"target\":[0,0],\"on_ball\":\"pass_short\"}}}",
    "id-keyed cogs map")
  mustRejectDirective(sim, 2,
    "{\"note\":\"n\",\"cog\":[{\"id\":\"RED-9\",\"intent\":\"carry\"," &
    "\"target\":[0,0],\"on_ball\":\"dribble\"}]}",
    "legacy cog field alias")
  mustRejectDirective(sim, 2,
    "{\"note\":\"n\",\"extra\":1,\"cogs\":[{\"id\":\"RED-9\"," &
    "\"intent\":\"carry\",\"target\":[0,0],\"on_ball\":\"dribble\"}]}",
    "unknown top-level key")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"carry\",\"target\":[0,0]," &
    "\"on_ball\":\"dribble\",\"bonus\":true}]}",
    "unknown cog key")
  report "legacy cogs shapes, cog alias, and unknown keys are rejected"

proc targetValidationStrict() =
  var sim = playing(testConfig())
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"make_run\"," &
    "\"target\":[\"12.5\",\"-3\"],\"on_ball\":\"shoot\"}]}",
    "numeric strings in target")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"make_run\"," &
    "\"target\":{\"x\":12.5,\"y\":-3},\"on_ball\":\"shoot\"}]}",
    "object target {x, y}")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"make_run\"," &
    "\"target\":[9999,-9999],\"on_ball\":\"shoot\"}]}",
    "out-of-pitch target")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"make_run\"," &
    "\"target\":[0,0,1],\"on_ball\":\"shoot\"}]}",
    "3-element target array")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"make_run\"," &
    "\"on_ball\":\"shoot\"}]}",
    "missing target")
  let ok = parse(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"make_run\"," &
    "\"target\":[12.5,-3],\"on_ball\":\"shoot\"}]}")
  doAssert ok.ok
  doAssert ok.directive.cog.targetX == worldXOfView(12.5)
  doAssert ok.directive.cog.targetY == worldYOfView(-3.0)
  report "target requires finite in-pitch [x, y] numbers"

proc unknownEnumsRejected() =
  var sim = playing(testConfig())
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"teleport\"," &
    "\"target\":[0,0],\"on_ball\":\"pass_short\"}]}",
    "unknown intent")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"role\":\"goalkeeper\"," &
    "\"intent\":\"press\",\"target\":[0,0],\"on_ball\":\"pass_short\"}]}",
    "unknown role")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"press\"," &
    "\"target\":[0,0],\"on_ball\":\"bicycle_kick\"}]}",
    "unknown on_ball")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"press\"," &
    "\"target\":[0,0],\"on_ball\":\"pass_short\",\"sprint\":\"maybe\"}]}",
    "unknown sprint")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"press\"," &
    "\"target\":[0,0],\"on_ball\":\"pass_short\",\"tackle\":\"perhaps\"}]}",
    "unknown tackle")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"target\":[0,0],\"on_ball\":\"pass_short\"}]}",
    "missing intent")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"press\",\"target\":[0,0],\"on_ball\":42}]}",
    "non-string on_ball")
  report "unknown or invalid enums and missing required intent are rejected"

proc passToAndIdValidationStrict() =
  var sim = playing(testConfig())
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"support\",\"target\":[0,0]," &
    "\"on_ball\":\"pass_short\",\"pass_to\":\"BLUE-4\"}]}",
    "pass_to naming an opponent")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"support\",\"target\":[0,0]," &
    "\"on_ball\":\"pass_short\",\"pass_to\":\"RED-9\"}]}",
    "pass_to naming self")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"BLUE-11\",\"intent\":\"drop_deep\",\"target\":[0,0]," &
    "\"on_ball\":\"hold\"}]}",
    "unmatched shirt id")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED9\",\"intent\":\"drop_deep\",\"target\":[0,0]," &
    "\"on_ball\":\"hold\"}]}",
    "missing hyphen in shirt id")
  mustRejectDirective(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"press\",\"target\":[0,0]," &
    "\"on_ball\":\"hold\"},{\"id\":\"RED-10\",\"intent\":\"carry\"," &
    "\"target\":[0,0],\"on_ball\":\"dribble\"}]}",
    "extra cog entry")
  mustRejectDirective(sim, 2,
    "{\"note\":\"nothing\",\"cogs\":[]}",
    "empty cogs array")

  let mate = parse(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"support\",\"target\":[0,0]," &
    "\"on_ball\":\"pass_short\",\"pass_to\":\"red-10\"}]}")
  doAssert mate.ok
  doAssert mate.directive.cog.passTo == int32(cogOfShirt(Red, 10))
  report "id, pass_to, and cogs arity are strictly validated"

proc runeTruncationOnTheBoundary() =
  var note = ""
  for _ in 0 ..< (MaxNoteRunes - 1):
    note.add("a")
  note.add("\xF0\x9F\x8F\x86")     ## U+1F3C6 TROPHY, four bytes
  note.add("tail that must go")
  let clipped = clipRunes(note, MaxNoteRunes)
  doAssert clipped.runeLen <= MaxNoteRunes,
    "the clip respects the rune cap, got " & $clipped.runeLen
  doAssert isValidUtf8(clipped), "the clip is valid UTF-8"
  doAssert clipped.validateUtf8() == -1, "std/unicode agrees it is valid UTF-8"
  var emojiOnly = ""
  for _ in 0 ..< 400:
    emojiOnly.add("\xF0\x9F\x8F\x86")
  let clippedEmoji = clipRunes(emojiOnly, MaxSayRunes)
  doAssert clippedEmoji.runeLen <= MaxSayRunes
  doAssert isValidUtf8(clippedEmoji)
  report "truncation lands on rune boundaries, emoji included"

proc recordsStayUnderTheCap() =
  var sim = playing(testConfig())
  var d = sim.zonalDirective(2, 5)
  d.note = clipRunes(repeat("\"quoted\\ ", 60), MaxNoteRunes)
  d.cog.say = clipRunes(repeat("\"say\\ ", 40), MaxSayRunes)
  let record = capRecord($directiveJson(2, d))
  doAssert record.runeLen <= MaxDirectiveRecordRunes,
    "a directive record is capped at 900 runes, got " & $record.runeLen
  doAssert isValidUtf8(record)
  let node = parseJson(record)
  doAssert node.kind == JObject and node{"k"}.getStr == "directive",
    "an over-long record is shrunk STRUCTURALLY and stays parseable"
  report "a directive record is capped at 900 runes and stays parseable JSON"

proc invalidOnBallDiagnosticIncludesBoundedValue() =
  var sim = playing(testConfig())
  let strBad = parse(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"press\"," &
    "\"target\":[0,0],\"on_ball\":\"bicycle_kick\"}]}")
  doAssert not strBad.ok
  doAssert strBad.error == "invalid on_ball: \"bicycle_kick\"",
    "unexpected invalid on_ball string diagnostic: " & strBad.error

  let emptyBad = parse(sim, 2,
    "{\"cogs\":[{\"intent\":\"press\",\"target\":[0,0],\"on_ball\":\"\"}]}")
  doAssert not emptyBad.ok
  doAssert emptyBad.error == "invalid on_ball: \"\"",
    "unexpected empty on_ball diagnostic: " & emptyBad.error

  let intBad = parse(sim, 2,
    "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"press\"," &
    "\"target\":[0,0],\"on_ball\":42}]}")
  doAssert not intBad.ok
  doAssert intBad.error == "invalid on_ball: 42",
    "unexpected non-string on_ball diagnostic: " & intBad.error

  let longVal = repeat("x", MaxInvalidOnBallRunes + 40)
  let longBad = parse(sim, 2,
    "{\"cogs\":[{\"intent\":\"press\",\"target\":[0,0],\"on_ball\":\"" &
    longVal & "\"}]}")
  doAssert not longBad.ok
  doAssert longBad.error.startsWith("invalid on_ball: \""),
    "long invalid on_ball diagnostic prefix mismatch: " & longBad.error
  let longPayload = longBad.error["invalid on_ball: ".len .. ^1]
  doAssert longPayload.runeLen <= MaxInvalidOnBallRunes,
    "invalid on_ball diagnostic value exceeded rune bound: " & $longPayload.runeLen
  doAssert longPayload.endsWith("\u2026"),
    "over-long invalid on_ball diagnostic must end with ellipsis"
  doAssert isValidUtf8(longBad.error)

  let emojiVal = repeat("\xF0\x9F\x8F\x86", MaxInvalidOnBallRunes + 20)
  let emojiBad = parse(sim, 2,
    "{\"cogs\":[{\"intent\":\"press\",\"target\":[0,0],\"on_ball\":\"" &
    emojiVal & "\"}]}")
  doAssert not emojiBad.ok
  let emojiPayload = emojiBad.error["invalid on_ball: ".len .. ^1]
  doAssert emojiPayload.runeLen <= MaxInvalidOnBallRunes,
    "emoji invalid on_ball diagnostic exceeded rune bound: " & $emojiPayload.runeLen
  doAssert emojiBad.error.validateUtf8() == -1,
    "emoji invalid on_ball diagnostic must stay valid UTF-8"
  report "invalid on_ball diagnostic reports the actual value with a rune-safe length bound"

proc systemMessageMinimumExampleParses() =
  var sim = playing(testConfig())
  let msg = systemMessage(PromptSelection(variant: pvCanonical))
  doAssert "shoot|pass_short" notin msg, "systemMessage must not show pseudo-JSON pipe schema"
  doAssert "(optional)" notin msg, "systemMessage must not show pseudo-JSON (optional) strings"
  doAssert "[x,y]" notin msg, "systemMessage must not show pseudo-JSON [x,y] target"
  var exampleLine = ""
  for line in msg.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("{") and trimmed.endsWith("}"):
      exampleLine = trimmed
      break
  doAssert exampleLine.len > 0, "systemMessage must include a single-line minimum legal JSON reply"
  for seat in 0 ..< SeatCount:
    let res = parse(sim, seat, exampleLine)
    doAssert res.ok, "systemMessage minimum JSON reply must parse for seat " & $seat & ": " & res.error
  for capability in ["press", "hold_shape", "make_run", "support", "drop_deep",
      "carry", "switch_play", "shadow", "shoot", "pass_short", "pass_long",
      "pass_high", "dribble", "hold", "pass_to", "sprint", "tackle", "role",
      "say", "note"]:
    doAssert capability in msg, "systemMessage must keep capability selectable: " & capability
  report "systemMessage embeds a legal minimum JSON reply that parses for every seat"

when isMainModule:
  echo "test_directives"
  bareAndSingleFenceParse()
  proseAndExtraObjectsRejected()
  legacyShapesAndAliasesRejected()
  targetValidationStrict()
  unknownEnumsRejected()
  invalidOnBallDiagnosticIncludesBoundedValue()
  systemMessageMinimumExampleParses()
  passToAndIdValidationStrict()
  runeTruncationOnTheBoundary()
  recordsStayUnderTheCap()
  echo "test_directives ok"
