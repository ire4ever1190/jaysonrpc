## Test cases taken from the "Examples" section in the spec. Error messages are changed to match what we have (codes stay the same)
## Only missing invalid JSON requests since we deal with parsed JSON so that is a transport layer problem
## https://www.jsonrpc.org/specification#examples

import std/[unittest, json, strformat, macros, sugar, options]
import jaysonrpc
import ./utils

var rpc = initExecutor[JsonNode, void]()

rpc.on("subtract") do (minuend, subtrahend: int) -> int:
  return minuend - subtrahend

rpc.on("no_args") do () -> int:
  9

rpc.on("get_data") do () -> (string, int):
  return ("hello", 5)

rpc.on("sum") do (a, b, c: int) -> int:
  return a + b + c

rpc.on("error") do ():
  raise (ref CatchableError)(msg: "Hello")

rpc.on("failedSpecial") do ():
  raise (ref RPCError)(code: RPCErrorCode(-32000), msg: "Failed at something specific")

var voidCalls = 0
rpc.on("void") do ():
  # Have some side effect to ensure we know this is getting called
  voidCalls += 1
  return

testCase "RPC Call with positional parameters 1":
  -> %* {"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
  <- %* {"id": 1, "jsonrpc": "2.0", "result": 19}

testCase "RPC Call with positional parameters 2":
  -> %* {"jsonrpc": "2.0", "method": "subtract", "params": [23, 42], "id": 2}
  <- %* {"id": 2, "jsonrpc": "2.0", "result": -19}

suite "RPC Call with named parameters":
  testCase "Check args in normal order":
    -> %* {"jsonrpc": "2.0", "method": "subtract", "params": {"subtrahend": 23, "minuend": 42}, "id": 3}
    <- %* {"id": 3, "jsonrpc": "2.0", "result": 19}

  testCase "Check args in different order":
    -> %* {"jsonrpc": "2.0", "method": "subtract", "params": {"minuend": 42, "subtrahend": 23}, "id": 4}
    <- %* {"id": 4, "jsonrpc": "2.0", "result": 19}

  testCase "Can't pass unknown args":
    -> %* {"jsonrpc": "2.0", "method": "subtract", "params": {"minuend": 42, "subtrahend": 23, "foo": 1}, "id": 4}
    <- %* {"id": 4, "jsonrpc": "2.0", "error": {"code": InvalidParams, "message": "Unknown argument: 'foo'"}}

testCase "RPC with with no parameters":
  -> %* {"jsonrpc": "2.0", "method": "no_args", "id": 4}
  <- %* {"id": 4, "jsonrpc": "2.0", "result": 9}

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
  <- %* {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Failed to parse JSON"}, "id": nil}

testCase "RPC call with invalid request object":
  -> %* {"jsonrpc": "2.0", "method": 1, "params": "bar", "id": 1}
  <- %* {"id": 1, "jsonrpc": "2.0", "error": {"code": -32600, "message": "Params must be an array/object of arguments"}}

testCase "RPC call batch, invalid JSON":
  -> """
    [
      {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
      {"jsonrpc": "2.0", "method"
    ]
  """
  <- %* {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Failed to parse JSON"}, "id": nil}

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
    {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Missing jsonrpc"}, "id": nil},
    {"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found: 'foo.get'"}, "id": "5"},
    {"jsonrpc": "2.0", "result": ["hello", 5], "id": "9"}
  ]

testCase "RPC call batch (all notifications)":
  -> %* [
    {"jsonrpc": "2.0", "method": "notify_sum", "params": [1,2,4]},
    {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]}
  ]
  <- ""

suite "Errors":
  testCase "If handler throws an error it is returned":
    -> %* {"jsonrpc": "2.0", "method": "error", "id": "1"}
    <- %* {"id": "1", "jsonrpc": "2.0", "error": {"code": -32603, "message": "Hello"}}

  testCase "If handler throws an error it is returned":
    -> %* {"jsonrpc": "2.0", "method": "failedSpecial", "id": "1"}
    <- %* {"id": "1", "jsonrpc": "2.0", "error": {"code": -32000, "message": "Failed at something specific"}}


testCase "Void returns null":
  let oldVoidCalls = voidCalls
  -> %* {"jsonrpc": "2.0", "method": "void", "id": "1"}
  <- %* {"id": "1", "jsonrpc": "2.0", "result": nil}
  check oldVoidCalls + 1 == voidCalls

suite "Error ID handling":
  testCase "Invalid params error preserves request ID":
    -> %* {"jsonrpc": "2.0", "method": "subtract", "params": {"minuend": 42}, "id": "test-123"}
    <- %* {"id": "test-123", "jsonrpc": "2.0", "error": {"code": -32602, "message": "Missing expected argument: 'subtrahend'"}}

  testCase "Missing jsonrpc field has null ID":
    -> %* {"method": "foobar", "id": "should-be-null"}
    <- %* {"id": nil, "jsonrpc": "2.0", "error": {"code": -32600, "message": "Missing jsonrpc"}}
