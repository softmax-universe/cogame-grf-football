import grf_football/prompts
## The decision loop: ONE parallel batch of eight per turn, one bounded retry,
## the scripted fallback, the budget guard, and the per-turn wall clock.

import std/[json, monotimes, os, strutils, times]
import lib/helpers
import grf_football/server

type Recorder = ref object
  calls: seq[int]          ## entries per batch call
  timeouts: seq[int]
  seats: seq[seq[int]]

proc goodReplyFor(seat: int): string =
  """{"note":"press and support","cogs":[{"id":"""" &
    cogId(cogOfSeat(seat)) &
    """","intent":"press","target":[4,2],"on_ball":"pass_short","sprint":"auto","tackle":"auto","say":"on him"}]}"""

proc replyingBatch(rec: Recorder, body = ""): BatchFn =
  result = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    rec.calls.add(calls.len)
    rec.timeouts.add(timeoutSeconds)
    var seats: seq[int]
    for call in calls:
      seats.add(call.seat)
      let text = if body.len > 0: body else: goodReplyFor(call.seat)
      result.add BatchReply(seat: call.seat, ok: true, text: text)
    rec.seats.add(seats)

proc failingBatch(rec: Recorder, error: string): BatchFn =
  result = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    rec.calls.add(calls.len)
    rec.timeouts.add(timeoutSeconds)
    var seats: seq[int]
    for call in calls:
      seats.add(call.seat)
      result.add BatchReply(seat: call.seat, ok: false, error: error)
    rec.seats.add(seats)

proc llmEngine(batch: BatchFn): TurnEngine =
  result = newTurnEngine(nil, batch, PromptSelection())
  for seat in 0 ..< SeatCount:
    result.policies[seat] = SeatPolicy(kind: pkLlm, prompt: "play well",
      label: "test", connected: true)

proc oneBatchOfEightPerTurn() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let engine = llmEngine(replyingBatch(rec))
  let outcome = engine.turn(sim, 0, 0)
  doAssert not outcome.failed, "valid LLM replies must succeed"
  doAssert rec.calls.len == 1,
    "all eight seats go out as ONE batch, got " & $rec.calls.len & " calls"
  doAssert rec.calls[0] == SeatCount,
    "the single batch carries all eight seats, got " & $rec.calls[0]
  var seen: array[SeatCount, bool]
  for seat in rec.seats[0]:
    seen[seat] = true
  for seat in 0 ..< SeatCount:
    doAssert seen[seat], "seat " & $seat & " was not in the batch"
    doAssert sim.hasDirective[seat]
    doAssert sim.activeDirective[seat].source == dsLlm
    doAssert sim.seatStats[seat].llmTurns == 1
  report "all eight seats' calls go out as ONE parallel batch per turn"

proc timeoutRetriesOnceThenFailsUnscored() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let engine = llmEngine(failingBatch(rec, "Operation timed out after 6000 ms"))
  let outcome = engine.turn(sim, 1, 0)
  doAssert outcome.failed, "two timeouts must fail the turn without fake moves"
  doAssert outcome.cause == "timeout"
  doAssert outcome.isInfra
  doAssert rec.calls.len == 2,
    "a failure retries EXACTLY once, got " & $rec.calls.len & " attempts"
  doAssert rec.calls[1] == SeatCount, "the retry is one batch too"
  for seat in 0 ..< SeatCount:
    doAssert not sim.hasDirective[seat],
      "failed LLM seat must not receive a synthesized directive"
    doAssert sim.seatStats[seat].fallbackTurns == 0
  var timeouts = 0
  var fallbackDirectives = 0
  for record in engine.records:
    let node = parseJson(record)
    if node{"k"}.getStr == "fallback":
      doAssert node{"cause"}.getStr == "timeout",
        "a curl deadline reads as `timeout`, got " & node{"cause"}.getStr
      inc timeouts
    elif node{"k"}.getStr == "directive" and node{"source"}.getStr == "fallback":
      inc fallbackDirectives
  doAssert timeouts == 2 * SeatCount,
    "one fallback record per failed attempt per seat, got " & $timeouts
  doAssert fallbackDirectives == 0, "no synthesized fallback directive may be emitted"
  report "a timeout retries exactly once, then fails with zero synthesized control"

proc parseFailureRetriesAndFails() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let engine = llmEngine(replyingBatch(rec, "I am not going to answer."))
  let outcome = engine.turn(sim, 2, 0)
  doAssert outcome.failed
  doAssert outcome.cause == "parse_error"
  doAssert not outcome.isInfra
  doAssert rec.calls.len == 2, "unparseable text retries once"
  for seat in 0 ..< SeatCount:
    doAssert not sim.hasDirective[seat]
  var causes: seq[string]
  for record in engine.records:
    let node = parseJson(record)
    if node{"k"}.getStr == "fallback":
      causes.add(node{"cause"}.getStr)
  doAssert "parse_error" in causes, "the cause names the parse failure"
  report "an unparseable reply retries once and then fails without fake moves"

proc wrongShirtIdAndProseRejected() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let badReply = """{"note":"ok","cogs":[{"id":"BLUE-11","intent":"press","target":[0,0],"on_ball":"hold"}]}"""
  let engine = llmEngine(replyingBatch(rec, badReply))
  let outcome = engine.turn(sim, 3, 0)
  doAssert outcome.failed
  doAssert outcome.cause == "parse_error"
  doAssert not outcome.isInfra
  doAssert rec.calls.len == 2, "wrong shirt id retries once"
  for seat in 0 ..< SeatCount:
    doAssert not sim.hasDirective[seat]
  var sawIdError = false
  for record in engine.records:
    let node = parseJson(record)
    if node{"k"}.getStr == "fallback" and "id must match" in node{"detail"}.getStr:
      sawIdError = true
  doAssert sawIdError, "fallback detail records the exact shirt-id mismatch"
  report "a wrong shirt id is rejected and recorded with the exact reason"

proc registrationRejectsInvalidScriptedAndConflict() =
  let prev = SeatPolicy(kind: pkScripted, baseline: "zonal", label: "zonal")
  let badScripted = registrationOf(
    """{"type":"register","prompt":"","scripted":"typo","policy":"x"}""", 0, prev)
  doAssert not badScripted.ok, "unknown scripted baseline must be rejected"
  let conflict = registrationOf(
    """{"type":"register","prompt":"attack","scripted":"zonal","policy":"x"}""", 0, prev)
  doAssert not conflict.ok, "setting both prompt and scripted must be rejected"
  let goodZonal = registrationOf(
    """{"type":"register","prompt":"","scripted":"zonal","policy":"z"}""", 0, prev)
  doAssert goodZonal.ok and goodZonal.policy.kind == pkScripted and
    goodZonal.policy.baseline == "zonal"
  let goodLlm = registrationOf(
    """{"type":"register","prompt":"play wide","scripted":null,"policy":"p"}""", 0, prev)
  doAssert goodLlm.ok and goodLlm.policy.kind == pkLlm
  report "registration rejects unknown scripted baselines and conflicting configs"

proc noCredentialsFailsWithoutBlocking() =
  var sim = playing(testConfig())
  let engine = newTurnEngine(nil, nil, PromptSelection())     ## no client, no transport
  for seat in 0 ..< SeatCount:
    engine.policies[seat] = SeatPolicy(kind: pkLlm, prompt: "x",
      label: "x", connected: true)
  let started = getMonoTime()
  let outcome = engine.turn(sim, 0, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds
  doAssert elapsed < 2000,
    "with no credentials the turn must fail fast, took " & $elapsed & " ms"
  doAssert outcome.failed
  doAssert outcome.cause == "no_credentials"
  doAssert outcome.isInfra
  var sawNoCredentials = false
  for record in engine.records:
    let node = parseJson(record)
    if node{"k"}.getStr == "fallback" and
        node{"cause"}.getStr == "no_credentials":
      sawNoCredentials = true
  doAssert sawNoCredentials, "the record names `no_credentials`"
  for seat in 0 ..< SeatCount:
    doAssert not sim.hasDirective[seat],
      "missing credentials must not synthesize a directive"
  report "a seat with no credentials fails fast with no_credentials and zero fake moves"

proc budgetGuardFailsLlmSeats() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let engine = llmEngine(replyingBatch(rec))
  # Two more turns no longer fit inside the wall-clock budget.
  let outcome = engine.turn(sim, 20, sim.config.wallClockBudgetSeconds - 5)
  doAssert outcome.failed
  doAssert outcome.cause == "budget_guard"
  doAssert outcome.isInfra
  doAssert engine.llmOff, "the budget guard switches the LLM off"
  doAssert engine.guardTurn == 20
  doAssert rec.calls.len == 0, "no batch is issued once the guard has fired"
  var sawGuard = false
  for record in engine.records:
    let node = parseJson(record)
    if node{"k"}.getStr == "budget_guard":
      sawGuard = true
      doAssert node{"turn"}.getInt == 20
  doAssert sawGuard, "a budget_guard record names the turn it fired"
  for seat in 0 ..< SeatCount:
    doAssert not sim.hasDirective[seat]
  report "the budget guard fires and aborts without synthesizing idle control"

proc turnStaysInsideItsBudget() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let engine = llmEngine(replyingBatch(rec))
  let started = getMonoTime()
  for turn in 0 ..< 4:
    let outcome = engine.turn(sim, turn, 0)
    doAssert not outcome.failed
  let elapsed = (getMonoTime() - started).inMilliseconds
  doAssert elapsed < int64(4 * sim.config.turnBudgetMs),
    "four turns must stay inside four turn budgets, took " & $elapsed & " ms"
  for t in rec.timeouts:
    doAssert t >= 1, "curly's whole-second floor is respected"
    doAssert t <= (sim.config.attempt1Ms div 1000),
      "an attempt is never given more than its allowance"
  report "a turn's wall clock never exceeds turnBudgetMs"

proc failureDeclarationShape() =
  ## The lobby no-show declaration the platform runner polls for.
  let path = tempPath("player-failure.json")
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & path)
  declarePlayerFailure(3, "slot 3 never joined")
  doAssert fileExists(path), "the declaration is written"
  let node = parseJson(readFile(path))
  doAssert node{"failed_policy_index"}.getInt == 3
  doAssert node{"message"}.getStr.len > 0
  removeFile(path)
  delEnv("COGAME_PLAYER_FAILURE_URI")
  report "declarePlayerFailure writes the shape the runner polls for"

when isMainModule:
  echo "test_engine"
  oneBatchOfEightPerTurn()
  timeoutRetriesOnceThenFailsUnscored()
  parseFailureRetriesAndFails()
  wrongShirtIdAndProseRejected()
  registrationRejectsInvalidScriptedAndConflict()
  noCredentialsFailsWithoutBlocking()
  budgetGuardFailsLlmSeats()
  turnStaysInsideItsBudget()
  failureDeclarationShape()
  echo "test_engine ok"
