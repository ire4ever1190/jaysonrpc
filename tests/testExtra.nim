import std/[
  unittest
]

import jaysonrpc
import ./utils

suite "Context parameter":
  test "Can pass a context parameter":
    var
      rpc = initExecutor[JsonNode, string]()
      val = ""
    rpc.on("foo") do (ctx: Context[string]):
      val = ctx.data

    rpc.notify "test", MethodDef[(), void](name: "foo"), ()
    check val == "test"

suite "Optional parameters":
  test "Void arguments are checked":
    var
      rpc = initExecutor[JsonNode, string]()
    rpc.on("foo") do (ctx: Context[string], bar: int): discard

    check not rpc.rawCall("test", MethodDef[(), void](name: "foo"), ()).passed

  test "Optional values are not required":
    var
      rpc = initExecutor[JsonNode, string]()
      val = ""
    rpc.on("foo") do (ctx: Context[string], foo: int, bar: Option[int]):
      val = "passed"

    rpc.notify "test", MethodDef[tuple[foo: int], void](name: "foo"), (foo: 1)
    check val == "passed"

suite "Return values":
  var
    rpc = initExecutor[JsonNode, string]()
  rpc.on("foo") do (ctx: Context[string], bar: int): discard
