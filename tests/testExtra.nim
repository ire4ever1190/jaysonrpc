import std/[
  unittest,
  sets
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

test "Exceptions are caught":
  var
    rpc = initExecutor[JsonNode, string]()
    val = ""
  rpc.on("foo") do (ctx: Context[string]):
    assert false

  echo  rpc.rawCall("foo", MethodDef[(), void](name: "foo"), ())
  check not rpc.rawCall("foo", MethodDef[(), void](name: "foo"), ()).passed

suite "Return values":
  var
    rpc = initExecutor[JsonNode, string]()
  rpc.on("foo") do (ctx: Context[string], bar: int): discard

suite "Names function":
  test "Single call returns one name":
    let rpc = initExecutor[JsonNode, void]()

    let calls = rpc.getCalls("""{"jsonrpc": "2.0", "method": "singleMethod", "id": 1}""")
    check calls.names() == toHashSet(["singleMethod"])

  test "Batch call returns multiple names":
    let rpc = initExecutor[JsonNode, void]()

    let calls = rpc.getCalls("""[
      {"jsonrpc": "2.0", "method": "method1", "id": 1},
      {"jsonrpc": "2.0", "method": "method2", "id": 2},
      {"jsonrpc": "2.0", "method": "method3", "id": 3}
    ]""")
    check calls.names() == toHashSet(["method1", "method2", "method3"])
