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
  -> %* {"jsonrpc": "2.0", "method": "someFunc", "id": 4}
  <- %* {"id": 4, "jsonrpc": "2.0", "result": false}

testCase "Function is registered when parsed":
  let calls = rpc.getCalls($ %* {"jsonrpc": "2.0", "method": "someFunc", "id": 1})
  # Don't call just yet, but call a cancellation
  -> %* {"jsonrpc": "2.0", "method": "cancel", "params": [1], "id": 2}
  # Now the call should know that is has been cancelled
  let responses = collect:
    for call in calls:
      call()

  resp = calls.dump(responses)
  check resp.get().parseJson()["result"].bval
