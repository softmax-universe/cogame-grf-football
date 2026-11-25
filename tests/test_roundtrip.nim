## Public host + player round-trip tests over real HTTP/WebSocket:
## 1. Regular bare JSON & markdown-fenced JSON (with optional fields omitted) ->
##    model-produced actions execute and produce a genuine scored completion.
## 2. Invalid / ambiguous model object (two JSON objects) ->
##    recorded parse_error failure, unfinished episode terminated unscored with
##    no results.json / no numeric scores, zero synthesized fallback directives.
## 3. Provider / transport failure (HTTP 503) ->
##    recorded transport_error failure, unfinished episode terminated unscored
##    with no results.json / no numeric scores, zero synthesized control.
## 4. Missing credentials ->
##    recorded no_credentials failure, unfinished episode terminated unscored
##    with no results.json / no numeric scores, zero synthesized control.

import
  std/[atomics, json, locks, net, options, os, strutils],
  bitworld/runtime,
  mummy,
  whisky,
  lib/helpers,
  grf_football/server

const
  SpriteClientChat = 0x81'u8
  SpriteClientReady = 0x85'u8

type
  MockMode = enum
    mmValidBareAndFence
    mmAmbiguousObject
    mmInvalidOnBallTackle
    mmProviderFailure

  MockServerArgs = object
    server: ptr Server
    port: int

  PlayerThreadArgs = object
    url: string
    registration: string
    connectDelayMs: int

var
  mockLock: Lock
  mockMode: MockMode
  mockCallCount: Atomic[int]
  mockLastSlot: string

initLock(mockLock)

proc freePort(): int =
  let sock = newSocket()
  defer: sock.close()
  sock.bindAddr(Port(0), "127.0.0.1")
  int(sock.getLocalAddr()[1])

proc chatPacket(text: string): string =
  result = newString(3 + text.len)
  result[0] = char(SpriteClientChat)
  result[1] = char(text.len and 0xff)
  result[2] = char((text.len shr 8) and 0xff)
  for i, ch in text:
    result[3 + i] = ch

proc readyPacket(): string =
  result = newString(1)
  result[0] = char(SpriteClientReady)

proc mockLlmHandler(request: Request) =
  if request.path != "/v1/messages" or request.httpMethod != "POST":
    request.respond(404, emptyHttpHeaders(), "not found")
    return
  let n = mockCallCount.fetchAdd(1)
  var mode: MockMode
  {.gcsafe.}:
    withLock mockLock:
      mode = mockMode
      mockLastSlot = request.headers["X-Coworld-Player-Slot"]
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  case mode
  of mmValidBareAndFence:
    let text =
      if n == 0:
        # Bare JSON using explicit off-ball tackle="auto" with optional metadata omitted
        # and on_ball explicitly null (defaults to pass_short).
        """{"cogs":[{"intent":"press","target":[4,2],"on_ball":null,"tackle":"auto"}]}"""
      else:
        # Single json-tagged markdown fence with optional fields and tackle="never".
        "```json\n" &
        """{"note":"turn 1 fenced","cogs":[{"id":"RED-10","intent":"support","target":[8,-3],"on_ball":"shoot","tackle":"never","say":"push up"}]}""" &
        "\n```"
    let body = $(%*{
      "id": "msg_test_" & $n,
      "type": "message",
      "role": "assistant",
      "model": "anthropic/claude-haiku-4.5",
      "stop_reason": "end_turn",
      "content": [{"type": "text", "text": text}]
    })
    request.respond(200, headers, body)
  of mmAmbiguousObject:
    # Ambiguous response: two JSON objects concatenated.
    let text =
      """{"note":"first","cogs":[{"id":"RED-10","intent":"press","target":[0,0],"on_ball":"hold"}]}""" &
      "\n" &
      """{"note":"second","cogs":[{"id":"RED-10","intent":"support","target":[5,5],"on_ball":"pass_short"}]}"""
    let body = $(%*{
      "id": "msg_ambig_" & $n,
      "type": "message",
      "role": "assistant",
      "model": "anthropic/claude-haiku-4.5",
      "stop_reason": "end_turn",
      "content": [{"type": "text", "text": text}]
    })
    request.respond(200, headers, body)
  of mmInvalidOnBallTackle:
    # Misplaced tackle in on_ball must be strictly rejected with GamePlayerFailure.
    let text =
      """{"note":"press","cogs":[{"id":"RED-10","intent":"press","target":[0,0],"on_ball":"tackle"}]}"""
    let body = $(%*{
      "id": "msg_tackle_" & $n,
      "type": "message",
      "role": "assistant",
      "model": "anthropic/claude-haiku-4.5",
      "stop_reason": "end_turn",
      "content": [{"type": "text", "text": text}]
    })
    request.respond(200, headers, body)
  of mmProviderFailure:
    request.respond(503, headers, """{"error":"provider unavailable"}""")

proc mockServerThreadProc(args: MockServerArgs) {.thread.} =
  args.server[].serve(Port(args.port), "127.0.0.1")

proc playerThreadProc(args: PlayerThreadArgs) {.thread.} =
  if args.connectDelayMs > 0:
    sleep(args.connectDelayMs)
  var socket: whisky.WebSocket
  var connected = false
  for _ in 0 ..< 80:
    try:
      socket = whisky.newWebSocket(args.url)
      connected = true
      break
    except CatchableError:
      sleep(50)
  if not connected:
    return
  try:
    socket.send(chatPacket(args.registration), whisky.BinaryMessage)
    var reSent = false
    while true:
      let msg = socket.receiveMessage(60_000)
      if msg.isNone:
        break
      if not reSent:
        reSent = true
        socket.send(chatPacket(args.registration), whisky.BinaryMessage)
      socket.send(readyPacket(), whisky.BinaryMessage)
  except CatchableError:
    discard
  try:
    socket.close()
  except CatchableError:
    discard

proc roundtripConfig(): GameConfig =
  result = testConfig(maxTicks = 480)
  result.halfTicks = 240
  result.turnTicks = 240
  result.turnSpacingMs = 0
  result.startWaitTicks = 4
  result.gameOverTicks = 4
  result.fastMode = true
  result.slots = @[]
  for i in 0 ..< SeatCount:
    result.slots.add PlayerSlotConfig(
      name: "seat-" & $i,
      token: "tok-" & $i,
      team: teamOfSeat(i),
      hasTeam: true
    )

proc verifyReplayHashChain(replayPath: string):
    tuple[fallbacks: seq[JsonNode], directives: seq[JsonNode], stops: seq[JsonNode], resultNode: JsonNode] =
  let data = loadReplay(replayPath)
  var cfg = defaultGameConfig()
  cfg.update(data.configJson)
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  var player = initReplayPlayer(data)
  player.mismatchQuit = false
  while player.hashIndex < data.hashes.len and
      sim.tickCount < player.replayMaxTick():
    player.stepReplay(sim)
    doAssert not player.hashValidationFailed,
      "replay hash diverged at tick " & $player.hashMismatchTick
  for chat in data.chats:
    try:
      let node = parseJson(chat.message)
      if node.kind != JObject:
        continue
      case node{"k"}.getStr
      of "fallback": result.fallbacks.add(node)
      of "directive": result.directives.add(node)
      of "stop": result.stops.add(node)
      of "result": result.resultNode = node{"results"}
      else: discard
    except CatchableError:
      discard

proc runEpisode(
  label: string,
  useMockSidecar: bool,
  mode: MockMode,
  lobbyJoinTimeoutTicks = DefaultLobbyJoinTimeoutTicks,
  lastSeatDelayMs = 0
): tuple[
  resultsPath, failurePath, replayPath: string,
  mockCalls: int,
  lastSlot: string
] =
  let
    resultsPath = tempPath("rt-" & label & "-results.json")
    failurePath = tempPath("rt-" & label & "-failure.json")
    replayPath = tempPath("rt-" & label & ".replay")
  for p in [resultsPath, failurePath, replayPath]:
    if fileExists(p): removeFile(p)

  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & failurePath)
  delEnv("ANTHROPIC_API_KEY")
  delEnv("ANTHROPIC_API_KEY_URI")
  delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
  delEnv("AWS_BEARER_TOKEN_BEDROCK")

  var mockServer: Server
  var mockThread: Thread[MockServerArgs]
  if useMockSidecar:
    let mockPort = freePort()
    mockCallCount.store(0)
    withLock mockLock:
      mockMode = mode
      mockLastSlot = ""
    mockServer = newServer(mockLlmHandler, workerThreads = 2)
    createThread(mockThread, mockServerThreadProc,
      MockServerArgs(server: addr mockServer, port: mockPort))
    mockServer.waitUntilReady()
    putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:" & $mockPort)
  else:
    delEnv("COWORLD_LLM_ENDPOINT")

  let gamePort = freePort()
  var playerThreads: array[SeatCount, Thread[PlayerThreadArgs]]
  for seat in 0 ..< SeatCount:
    let reg =
      if seat == 0:
        $(%*{"type": "register", "prompt": "Play smart football",
             "scripted": newJNull(), "policy": "grf-football-model"})
      else:
        $(%*{"type": "register", "prompt": "",
             "scripted": "zonal", "policy": "zonal"})
    createThread(playerThreads[seat], playerThreadProc, PlayerThreadArgs(
      url: "ws://127.0.0.1:" & $gamePort & "/player?slot=" & $seat & "&token=tok-" & $seat,
      registration: reg,
      connectDelayMs: (if seat == SeatCount - 1: lastSeatDelayMs else: 0)
    ))

  var rt = RuntimeConfig(
    host: "127.0.0.1",
    port: gamePort,
    resultsUri: "file://" & resultsPath,
    replayUri: "file://" & replayPath
  )
  var cfg = roundtripConfig()
  cfg.lobbyJoinTimeoutTicks = lobbyJoinTimeoutTicks
  runServerLoop(
    host = "127.0.0.1",
    port = gamePort,
    initialConfig = cfg,
    saveReplayPath = replayPath,
    loadReplayPath = "",
    saveScoresPath = "",
    runtimeConfig = rt
  )

  for seat in 0 ..< SeatCount:
    joinThread(playerThreads[seat])

  if useMockSidecar:
    mockServer.close()
    joinThread(mockThread)

  delEnv("COWORLD_LLM_ENDPOINT")
  delEnv("COGAME_PLAYER_FAILURE_URI")

  var slotSeen = ""
  withLock mockLock:
    slotSeen = mockLastSlot
  result = (resultsPath, failurePath, replayPath, mockCallCount.load(), slotSeen)

proc validBareAndFencedRoundtrip() =
  let ep = runEpisode("valid", useMockSidecar = true, mmValidBareAndFence)
  doAssert ep.mockCalls >= 2,
    "native model player must invoke the sidecar on both turns, got " & $ep.mockCalls
  doAssert ep.lastSlot == "0",
    "sidecar requests must carry X-Coworld-Player-Slot=0, got " & ep.lastSlot
  doAssert not fileExists(ep.failurePath),
    "valid LLM episode must not report player_failure.json"
  doAssert fileExists(ep.resultsPath),
    "completed episode must write results.json"
  let results = parseJson(readFile(ep.resultsPath))
  doAssert results["reason"].getStr == "complete"
  doAssert results["endRule"].getStr == "full_time"
  doAssert results["llmTurns"][0].getInt >= 2,
    "model-produced action must execute on seat 0, got " & $results["llmTurns"][0].getInt
  doAssert results["fallbackTurns"][0].getInt == 0
  doAssert results["scores"].len == SeatCount
  var sum = 0.0
  for v in results["scores"]:
    sum += v.getFloat
  doAssert sum > 3.999 and sum < 4.001, "completed game scores sum to 4.000"
  let rep = verifyReplayHashChain(ep.replayPath)
  var seat0Llm = 0
  for d in rep.directives:
    if d{"seat"}.getInt == 0 and d{"source"}.getStr == "llm":
      inc seat0Llm
    doAssert d{"source"}.getStr != "fallback"
  doAssert seat0Llm >= 2, "replay must record seat 0 llm directives"
  for p in [ep.resultsPath, ep.failurePath, ep.replayPath]:
    if fileExists(p): removeFile(p)
  report "host+player round-trip executes bare JSON and fenced JSON model directives to a scored completion"

proc ambiguousObjectTerminatesUnscored() =
  let ep = runEpisode("ambiguous", useMockSidecar = true, mmAmbiguousObject)
  doAssert ep.mockCalls == 1,
    "ambiguous reply fails on its sole request, got " & $ep.mockCalls
  doAssert not fileExists(ep.resultsPath),
    "invalid/ambiguous model failure must NOT write results.json or numeric scores"
  doAssert fileExists(ep.failurePath),
    "invalid/ambiguous model failure must write player_failure.json"
  let failure = parseJson(readFile(ep.failurePath))
  doAssert failure["failed_policy_index"].getInt == 0
  doAssert "parse_error" in failure["message"].getStr,
    "failure message must attribute parse_error, got " & failure["message"].getStr
  let rep = verifyReplayHashChain(ep.replayPath)
  doAssert rep.fallbacks.len == 1,
    "the rejected request must be recorded, got " & $rep.fallbacks.len
  for fb in rep.fallbacks:
    doAssert fb{"cause"}.getStr == "parse_error"
  for d in rep.directives:
    doAssert d{"source"}.getStr != "fallback",
      "zero synthesized fallback directives may be written"
  doAssert rep.stops.len == 1 and rep.stops[0]{"reason"}.getStr == "fault"
  doAssert not rep.resultNode.isNil
  doAssert rep.resultNode["reason"].getStr == "fault"
  doAssert not rep.resultNode.hasKey("scores"),
    "replay result record for fault must not carry numeric scores"
  doAssert not rep.resultNode.hasKey("win"),
    "replay result record for fault must not carry win booleans"
  for p in [ep.resultsPath, ep.failurePath, ep.replayPath]:
    if fileExists(p): removeFile(p)
  report "host+player round-trip terminates unscored on ambiguous model object with no numeric results"

proc misplacedOnBallTackleTerminatesUnscored() =
  let ep = runEpisode("onball-tackle", useMockSidecar = true, mmInvalidOnBallTackle)
  doAssert ep.mockCalls == 1,
    "misplaced on_ball=tackle fails on its sole request, got " & $ep.mockCalls
  doAssert not fileExists(ep.resultsPath),
    "misplaced on_ball=tackle must NOT write results.json or numeric scores"
  doAssert fileExists(ep.failurePath),
    "misplaced on_ball=tackle must write player_failure.json"
  let failure = parseJson(readFile(ep.failurePath))
  doAssert failure["failed_policy_index"].getInt == 0
  doAssert failure["message"].getStr == "parse_error: invalid on_ball: \"tackle\"",
    "unexpected failure message: " & failure["message"].getStr
  let rep = verifyReplayHashChain(ep.replayPath)
  doAssert rep.fallbacks.len == 1
  doAssert rep.fallbacks[0]{"cause"}.getStr == "parse_error"
  doAssert rep.fallbacks[0]{"detail"}.getStr == "invalid on_ball: \"tackle\""
  for d in rep.directives:
    doAssert d{"source"}.getStr != "fallback",
      "zero synthesized fallback directives may be written"
  doAssert rep.stops.len == 1 and rep.stops[0]{"reason"}.getStr == "fault"
  doAssert not rep.resultNode.isNil
  doAssert rep.resultNode["reason"].getStr == "fault"
  doAssert not rep.resultNode.hasKey("scores")
  doAssert not rep.resultNode.hasKey("win")
  for p in [ep.resultsPath, ep.failurePath, ep.replayPath]:
    if fileExists(p): removeFile(p)
  report "host+player round-trip rejects misplaced on_ball=tackle with official GamePlayerFailure"

proc providerFailureTerminatesUnscored() =
  let ep = runEpisode("provider", useMockSidecar = true, mmProviderFailure)
  doAssert ep.mockCalls == 1,
    "provider 503 fails on its sole request, got " & $ep.mockCalls
  doAssert not fileExists(ep.resultsPath),
    "provider failure must NOT write results.json or numeric scores"
  doAssert fileExists(ep.failurePath),
    "provider failure must write player_failure.json"
  let failure = parseJson(readFile(ep.failurePath))
  doAssert failure["failed_policy_index"].getInt == 0
  doAssert "transport_error" in failure["message"].getStr,
    "failure message must attribute transport_error, got " & failure["message"].getStr
  let rep = verifyReplayHashChain(ep.replayPath)
  doAssert rep.fallbacks.len == 1
  for fb in rep.fallbacks:
    doAssert fb{"cause"}.getStr == "transport_error"
  for d in rep.directives:
    doAssert d{"source"}.getStr != "fallback"
  doAssert rep.stops.len == 1 and rep.stops[0]{"reason"}.getStr == "fault"
  doAssert not rep.resultNode.isNil
  doAssert rep.resultNode["reason"].getStr == "fault"
  doAssert not rep.resultNode.hasKey("scores")
  doAssert not rep.resultNode.hasKey("win")
  for p in [ep.resultsPath, ep.failurePath, ep.replayPath]:
    if fileExists(p): removeFile(p)
  report "host+player round-trip terminates unscored on provider failure with no numeric results"

proc missingCredentialsTerminatesUnscored() =
  let ep = runEpisode("nocreds", useMockSidecar = false, mmProviderFailure)
  doAssert not fileExists(ep.resultsPath),
    "missing credentials must NOT write results.json or numeric scores"
  doAssert fileExists(ep.failurePath),
    "missing credentials must write player_failure.json"
  let failure = parseJson(readFile(ep.failurePath))
  doAssert failure["failed_policy_index"].getInt == 0
  doAssert "no_credentials" in failure["message"].getStr,
    "failure message must attribute no_credentials, got " & failure["message"].getStr
  let rep = verifyReplayHashChain(ep.replayPath)
  doAssert rep.fallbacks.len == 1 and rep.fallbacks[0]{"cause"}.getStr == "no_credentials"
  for d in rep.directives:
    doAssert d{"source"}.getStr != "fallback"
  doAssert rep.stops.len == 1 and rep.stops[0]{"reason"}.getStr == "fault"
  doAssert not rep.resultNode.isNil
  doAssert rep.resultNode["reason"].getStr == "fault"
  doAssert not rep.resultNode.hasKey("scores")
  doAssert not rep.resultNode.hasKey("win")
  for p in [ep.resultsPath, ep.failurePath, ep.replayPath]:
    if fileExists(p): removeFile(p)
  report "host+player round-trip terminates unscored on missing credentials with no numeric results"

proc delayedJoinDoesNotFastForwardLobbyTimeout() =
  ## With fastMode=true, early seats sending Ready must not fast-forward
  ## lobbyWaitTimer while waiting for a late seat to connect.
  ## 12 ticks at 24 Hz is ~500 ms; a 200 ms delay on seat 7 must succeed.
  let ep = runEpisode(
    "delayed-join",
    useMockSidecar = true,
    mmValidBareAndFence,
    lobbyJoinTimeoutTicks = 12,
    lastSeatDelayMs = 200
  )
  doAssert not fileExists(ep.failurePath),
    "late seat within real 24 Hz lobby window must not trigger lobby join timeout"
  doAssert fileExists(ep.resultsPath),
    "episode with delayed seat must complete and write results.json"
  let results = parseJson(readFile(ep.resultsPath))
  doAssert results["reason"].getStr == "complete"
  doAssert results["endRule"].getStr == "full_time"
  discard verifyReplayHashChain(ep.replayPath)
  for p in [ep.resultsPath, ep.failurePath, ep.replayPath]:
    if fileExists(p): removeFile(p)
  report "fastMode does not fast-forward lobby join timeout while waiting for late seats"

when isMainModule:
  echo "test_roundtrip"
  validBareAndFencedRoundtrip()
  delayedJoinDoesNotFastForwardLobbyTimeout()
  ambiguousObjectTerminatesUnscored()
  misplacedOnBallTackleTerminatesUnscored()
  providerFailureTerminatesUnscored()
  missingCredentialsTerminatesUnscored()
  echo "test_roundtrip ok"
