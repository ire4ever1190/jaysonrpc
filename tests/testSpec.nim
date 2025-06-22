## Test cases taken from the "Examples" section in the spec. Error messages are changed to match what we have (codes stay the same)
## Only missing invalid JSON requests since we deal with parsed JSON so that is a transport layer problem
## https://www.jsonrpc.org/specification#examples

import std/[unittest, json, strformat, macros, sugar, options]
import jaysonrpc

var rpc = Executor[string]()

rpc.on("subtract") do (minuend, subtrahend: int) -> int:
  return minuend - subtrahend


proc strOrNil(x: JsonNode): string =
  return if x != nil: $x else: ""

proc parseOrNil(x: string): JsonNode =
  if x == "": nil else: x.parseJson()

# Test case

proc checkJSON(a, b: JsonNode): bool =
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

template testCase(name: string, body: untyped) {.dirty.} =
  ## Creates a test case.
  ## Test case is a series of instructions for whats expected to be sent/recieved.
  ## Small DSL adds `->` (check send) and `<-` (check response) into the scope. Tests can
  ## be added on top
  test name:
    var resp: string
    proc `->`(msg: string) =
      let calls = rpc.getCalls(msg)
      let responses = collect:
        for call in calls:
          call()

      resp = calls.dump(responses).get()

    proc `->`(msg: JsonNode) {.used.} =
      -> $ msg

    proc `<-`(expected: string) =
      checkPoint resp
      checkPoint expected
      check checkJson(resp.parseJson(), expected.parseJson())

    proc `<-`(expected: JsonNode) {.used.} =
      <- $ expected

    body

testCase "RPC Call with positional parameters 1":
  -> %* {"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
  <- %* {"id": 1, "jsonrpc": "2.0", "result": 19}

testCase "RPC Call with positional parameters 2":
  -> %* {"jsonrpc": "2.0", "method": "subtract", "params": [23, 42], "id": 2}
  <- %* {"id": 2, "jsonrpc": "2.0", "result": -19}

testCase "RPC Call with named parameters 1":
  -> %* {"jsonrpc": "2.0", "method": "subtract", "params": {"subtrahend": 23, "minuend": 42}, "id": 3}
  <- %* {"id": 3, "jsonrpc": "2.0", "result": 19}

testCase "RPC call with named parameters 2":
  -> %* {"jsonrpc": "2.0", "method": "subtract", "params": {"minuend": 42, "subtrahend": 23}, "id": 4}
  <- %* {"id": 4, "jsonrpc": "2.0", "result": 19}

testCase "Notifications":
  -> %* {"jsonrpc": "2.0", "method": "update", "params": [1,2,3,4,5]}
  <- ""
  -> %* {"jsonrpc": "2.0", "method": "foobar"}
  <- ""

testCase "RPC call of non-existent method":
  -> %* {"jsonrpc": "2.0", "method": "foobar", "id": "1"}
  <- %* {"id": "1", "jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found: 'foobar'"}}

testCase "RPC call with invalid JSON":
  -> """{"jsonrpc": "2.0", "method": "foobar, "params": "bar", "baz]"""
  <- %* {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": nil}

testCase "RPC call with invalid request object":
  -> %* {"jsonrpc": "2.0", "method": 1, "params": "bar"}
  <- %* {"id": nil, "jsonrpc": "2.0", "error": {"code": -32600, "message": "Params must be an array/object of arguments"}}

testCase "RPC call batch, invalid JSON":
  -> """
    [
      {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
      {"jsonrpc": "2.0", "method"
    ]
  """
  <- %* {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": nil}

testCase "RPC call with an empty array":
  -> %* []
  <- %* {"id": nil, "jsonrpc": "2.0", "error": {"code": -32600, "message": "Batch calls must have at least 1 call"}}

testCase "RPC call with invalid batch (but not empty)":
  -> %* [1]
  <- %* [
      {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": nil}
    ]

testCase "RPC call with invalid batch":
  -> %* [1, 2, 3]
  <- %* [
    {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": nil},
    {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": nil},
    {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": nil}
  ]

testCase "RPC call batch":
  -> %* [
    {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
    {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]},
    {"jsonrpc": "2.0", "method": "subtract", "params": [42,23], "id": "2"},
    {"foo": "boo"},
    {"jsonrpc": "2.0", "method": "foo.get", "params": {"name": "myself"}, "id": "5"},
    {"jsonrpc": "2.0", "method": "get_data", "id": "9"}
  ]
  <- %* [
    {"jsonrpc": "2.0", "result": 7, "id": "1"},
    {"jsonrpc": "2.0", "result": 19, "id": "2"},
    {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": nil},
    {"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}, "id": "5"},
    {"jsonrpc": "2.0", "result": ["hello", 5], "id": "9"}
  ]

testCase "RPC call batch (all notifications)":
  -> %* [
    {"jsonrpc": "2.0", "method": "notify_sum", "params": [1,2,4]},
    {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]}
  ]
  <- ""
