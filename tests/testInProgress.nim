import std/[unittest, json, strformat, macros, sugar, options]
import ./utils
import jaysonrpc

# TODO: Update the tests when I have some form on concurrency

var rpc = initExecutor[JsonNode]()

rpc.on("cancel") do (id: int, ctx: Context):
  ## Cancels a request
  ctx.cancel(%id)

rpc.on("someFunc") do (ctx: Context) -> bool:
  ## Returns if a request has been cancelled or not
  return ctx.isCancelled()

testCase "Test not cancelled by default":
  check rpc.inProgress() == 0
  -> %* {"jsonrpc": "2.0", "method": "someFunc", "id": 4}
  <- %* {"id": 4, "jsonrpc": "2.0", "result": false}
  check rpc.inProgress() == 0

suite "Context is not included in parameter count":
  testCase "Positional args":
    -> %* {"jsonrpc": "2.0", "method": "cancel", "params": [1], "id": 2}
    <- %* {"id": 2, "jsonrpc": "2.0", "result": nil}

  testCase "Named args":
    -> %* {"jsonrpc": "2.0", "method": "cancel", "params": {"id": 1}, "id": 2}
    <- %* {"id": 2, "jsonrpc": "2.0", "result": nil}

testCase "Nothing gets registered for notifications":
  let calls = rpc.getCalls($ %* {"jsonrpc": "2.0", "method": "someFunc"})
  check rpc.inProgress == 0

testCase "Check function is registered in the inProgress asap":
  let calls = rpc.getCalls($ %* {"jsonrpc": "2.0", "method": "someFunc", "id": 1})
  check rpc.inProgress() == 1
  # Don't call just yet, but call a cancellation
  -> %* {"jsonrpc": "2.0", "method": "cancel", "params": [1], "id": 2}
  <- %* {"id": 2, "jsonrpc": "2.0", "result": nil}
  # It should've cancelled the call before we ran it
  check rpc.inProgress() == 0

  # Now the call should know that is has been cancelled
  let responses = collect:
    for call in calls:
      call()

  resp = calls.dump(responses)
  check resp.get().parseJson()["result"].bval
