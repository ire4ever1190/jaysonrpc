import std/[unittest, jsonutils]
import jaysonrpc
import ./utils

const
  foo = MethodDef[(), void](name: "foo")
  close = MethodDef[tuple[name: string], void](name: "close")

template checkCall(call: untyped, expected: JsonNode) {.callsite.}=
  let correct = checkJson(call.toJson(), expected)
  checkpoint: "Actual: " & call.toJson().pretty()
  checkpoint: "Expected: " & expected.pretty()
  check correct

suite "Forming calls":
  test "Basic call":
    # We don't expect an ID, that gets set later
    checkCall foo.call(()), %* {"jsonrpc": "2.0", "method": "foo"}

  test "Basic notification":
    checkCall foo.notify(()), %* {"jsonrpc": "2.0", "method": "foo"}

  test "Passing arg":
    checkCall close.notify(("foo",)), %* {"jsonrpc": "2.0", "method": "close", "params": {"name": "foo"}}

  test "Named arg":
    checkCall close.notify((name: "foo")), %* {"jsonrpc": "2.0", "method": "close", "params": {"name": "foo"}}

  when false: # Default args implemented in the future
    test "Default args":
      checkCall hasDefault.notify(), %* {"jsonrpc": "2.0", "method": "close", "params": {"arg": "hello"}}
