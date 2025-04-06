## Test cases taken from the "Examples" section in the spec. Error messages are changed to match what we have (codes stay the same)
## Only missing invalid JSON requests since we deal with parsed JSON so that is a transport layer problem
## https://www.jsonrpc.org/specification#examples

import std/[unittest, json, strformat, macros]
import jaysonrpc

var rpc = Executor[JsonNode]()

rpc.on("subtract") do (minuend, subtrahend: int) -> int:
  return minuend - subtrahend


proc strOrNil(x: JsonNode): string =
  return if x != nil: $x else: ""

proc parseOrNil(x: string): JsonNode =
  if x == "": nil else: x.parseJson()

# Test case

macro generateTestCases() =
  ## Generate test cases for std/unittest so this is easier to use
  result = newStmtList()

  let cases: seq[tuple[name: string, req, resp: JsonNode]] = @[
    (
      "RPC Call with positional parameters 1",
      %* {"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1},
      %* {"jsonrpc": "2.0", "result": 19, "id": 1}
    ),
    (
      "RPC Call with positional parameters 2",
      %* {"jsonrpc": "2.0", "method": "subtract", "params": [23, 42], "id": 2},
      %* {"jsonrpc": "2.0", "result": -19, "id": 2}
    ),
    (
      "RPC Call with named parameters 1",
      %* {"jsonrpc": "2.0", "method": "subtract", "params": {"subtrahend": 23, "minuend": 42}, "id": 3},
      %* {"jsonrpc": "2.0", "result": 19, "id": 3}
    ),
    (
      "RPC call with named parameters 2",
      %* {"jsonrpc": "2.0", "method": "subtract", "params": {"minuend": 42, "subtrahend": 23}, "id": 4},
      %* {"jsonrpc": "2.0", "result": 19, "id": 4}
    ),
    (
      "Notification 1",
      %* {"jsonrpc": "2.0", "method": "update", "params": [1,2,3,4,5]},
      nil # Notifications don't send anything back
    ),
    (
      "Notification 2",
      %* {"jsonrpc": "2.0", "method": "foobar"},
      nil # Is an error, but notifications send nothing back
    ),
    (
      "RPC call of non-existent method",
      %* {"jsonrpc": "2.0", "method": "foobar", "id": "1"},
      %* {"id": "1", "jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found: 'foobar'"}}
    ),
    # We take in pre-parsed JSON, so can't actually get invalid JSON.
    # Transports must handle this error
    # "RPC call with invalid JSON"
    (
      "RPC call with invalid request object",
      %* {"jsonrpc": "2.0", "method": 1, "params": "bar"},
      %* {"id": nil, "jsonrpc": "2.0", "error": {"code": -32600, "message": "Params must be an array/object of arguments"}}
    ),
    # Same for batch calls, we deal with pre-parsed JSON
    # "RPCC call Batch, invalid JSON"
    (
      "RPC call with an empty array",
      %* [],
      %* {"id": nil, "jsonrpc": "2.0", "error": {"code": -32600, "message": "Batch calls must have at least 1 call"}}
    ),
    (
      "RPC call with invalid batch (but not empty)",
      %* [1],
      %* [
        {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": nil}
      ]
    ),
    (
      "RPC call with invalid batch",
      %* [1, 2, 3],
      %* [
        {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": nil},
        {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": nil},
        {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": nil}
      ]
    ),
    (
      "RPC call batch",
      %* [
        {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
        {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]},
        {"jsonrpc": "2.0", "method": "subtract", "params": [42,23], "id": "2"},
        {"foo": "boo"},
        {"jsonrpc": "2.0", "method": "foo.get", "params": {"name": "myself"}, "id": "5"},
        {"jsonrpc": "2.0", "method": "get_data", "id": "9"}
      ],
      %* [
        {"jsonrpc": "2.0", "result": 7, "id": "1"},
        {"jsonrpc": "2.0", "result": 19, "id": "2"},
        {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": nil},
        {"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}, "id": "5"},
        {"jsonrpc": "2.0", "result": ["hello", 5], "id": "9"}
      ]
    ),
    (
      "RPC call batch (all notifications)",
      %* [
        {"jsonrpc": "2.0", "method": "notify_sum", "params": [1,2,4]},
        {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]}
      ],
      nil # Nothing is returned for all notification batches
    )
  ]

  for (name, sent, recv) in cases:
    # Convert to string, quote converts it into JsonNodeObj
    let
      strSent = strOrNil sent
      strRecv = strOrNil recv
    result.add quote do:
      test `name`:
        let
          res = rpc.call(`strSent`.parseOrNil()).strOrNil()
          expected = strOrNil `strRecv`.parseOrNil()
        check res == expected

generateTestCases()
