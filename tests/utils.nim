import std/[json, sugar, jsonutils, json]

import jaysonrpc

proc checkJSON*(a, b: JsonNode): bool =
  ## Checks if two JSON objects are the same.
  ## Ignores field order
  if a.kind != b.kind: return false
  case a.kind
  of JNull: return true
  of JBool, JInt, JFloat, Jstring, JArray: return a == b
  of JObject:
    for field, val in a:
      if b[field] != val:
        return false
    for field, val in b:
      if a[field] != val:
        return false
    return true

proc checkJSON*(a, b: string): bool =
  ## Checks two json strings (parses them first)
  checkJSON(a.parseJson(), b.parseJson())

proc strOrNil*(x: JsonNode): string =
  return if x != nil: $x else: ""

proc parseOrNil*(x: string): JsonNode =
  if x == "": nil else: x.parseJson()

proc notify*[R, C, A, T](rpc: Executor[R, C], ctx: C, meth: MethodDef[A, T], args: A) =
  ## Sends notification
  let calls = rpc.getCalls($ meth.notify(args).toJson(), ctx)
  let responses = collect:
    for call in calls:
      call()

  discard calls.dump(responses)

var id = 0
proc rawCall*[R, C, A, T](rpc: Executor[R, C], ctx: C, meth: MethodDef[A, T], args: A): Response =
  ## Performs a call and returns the value
  var call = meth.call(args)
  call.id = id
  inc id

  let calls = rpc.getCalls($ meth.notify(args).toJson(), ctx)
  let responses = collect:
    for call in calls:
      call()

  let resp = calls.dump(responses)
  if resp.isSome():
    result.fromJson(resp.get().parseJson())

template testCase*(name: string, body: untyped) {.dirty.} =
  ## Creates a test case.
  ## Test case is a series of instructions for whats expected to be sent/recieved.
  ## Small DSL adds `->` (check send) and `<-` (check response) into the scope. Tests can
  ## be added on top
  test name:
    var resp: Option[string]
    proc `->`(msg: string) =
      let calls = rpc.getCalls(msg)
      let responses = collect:
        for call in calls:
          call()

      resp = calls.dump(responses)

    proc `->`(msg: JsonNode) {.used.} =
      -> $ msg

    proc `<-`(expected: string) =
      checkPoint $resp
      checkPoint expected
      if expected == "":
        check resp.isNone()
      else:
        check resp.isSome()
        if resp.isNone(): return
        check checkJson(resp.get().parseJson(), expected.parseJson())

    proc `<-`(expected: JsonNode) {.used.} =
      <- $ expected

    body
