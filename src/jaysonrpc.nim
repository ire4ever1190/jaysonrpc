import std/[
  critbits,
  json,
  jsonutils,
  options,
  typetraits,
  strformat,
  macros,
  wrapnils,
  sugar
]

type
  Executor*[R] = object
    ## Executor stores all the functions and handles calling them.
    ## Transport is handled separately.
    # Return type is generic to allow for async/sync executors
    handlers: CritBitTree[proc (data: JsonNode): R]

  MethodDef[T: proc] = object
    ## This is a definition of a method. Used to enforce a spec
    ## or for calling a pre-defined method.
    ## This has the benefit of being able to share defintions between server and client
    ## for type safe calling (don't worry, we have helpers)
    name: string

  ID* = distinct JsonNode
    ## ID of a request

  Request* = object
    ## A request sent to the server
    jsonrpc = "2.0"
      ## Version, only 2.0 is implemented
    id*: Option[JsonNode]
      ## ID of the request. If missing then its a notification
    meth*: string
      ## Method getting called
    params*: JsonNode
      ## Either an array of positional params or an object of named params

  Error* = object
    ## Error object. Can store extra metadata in `data` that is understood by the handler
    code*: RPCErrorCode
      ## Code relating to the error
    message*: string
      ## Message providing a human description of the message
    data*: JsonNode
      ## Extra metadata to store about the message


  Response* = object
    ## Response sent back to the caller.
    ## Is possible that it contains an error
    jsonrpc = "2.0"
    id: Option[JsonNode]
    case passed: bool ## Whether the call failed or not
    of true:
      result: JsonNode
        ## Result from the call
    of false:
      error: Error
        ## Error that occured from the call

  RPCErrorCode = distinct int
    ## Error codes for JSONRPC. Stored as distinct int instead of enum
    ## so that it can be extended

  RPCError = object of CatchableError
    ## Exception to throw about an error
    code: RPCErrorCode

const
  InvalidRequest = RPCErrorCode(-32600)
  InvalidParams = RPCErrorCode(-32602)

func fromJsonHook*(request: out Request, data: JsonNode) =
  ## Hook for parsing the JSON
  # Perform some validation
  let id = option(data{"id"})
  if id.map(x => x.kind notin {JInt, JString, JNull}).get(true):
    raise (ref RPCError)(code: InvalidRequest, msg: "`id` must be one int, string, or null")
  if data["params"].kind notin {JArray, JObject}
    raise (ref RPCError)(code: InvalidRequest, msg: "Params must be an array/object of arguments")

  request = Request(
      jsonrpc: data["jsonrpc"].str,
      id: id,
      meth: data["method"].str,
      params: data["params"]
  )

func isNotification*(x: Request): bool =
  ## Checks if a request is a notification
  x.id.isNone()

func failed(req: Request, code: RPCErrorCode, msg: string, data: JsonNode = newJNull()): Response =
  ## Constructs an error in response to a request.
  ## Expects the request to not be a notification
  return Response(
    id: req.id,
    passed: false,
    error: Error(
      code: code,
      message: msg,
      data: data
    )
  )


proc createNamedTuple(prc: NimNode): NimNode =
  ## Takes in the NimNode for a proc type and returns a named tuple to
  ## parse the parameters.
  ## Tuple has default values set
  let
    typ = prc.getTypeImpl()
    params = typ[0][1 .. ^1]
  # First we need to construct the type
  let tupleType = nnkTupleTy.newTree()
  for param in params:
    # We need to desym the params
    tupleType &= newIdentDefs(ident param[0].strVal, param[1])


  # Then construct it
  return newCall("default", tupleType)

  # Then assign the defaults (TODO)

proc positionalParams(data: JsonNode, args: var tuple) =
  ## Parses positional params from the object

  # Do some checks
  if data.kind != JArray:
    raise (ref RPCError)(code: InvalidRequest, msg: "Positional params must be an array")
  elif data.len != args.tupleLen:
    raise (ref RPCError)(code: InvalidParams, msg: "Expected {args.tupleLen} parameters but got {data.len}")

  # Parse each field
  var i = 0
  for field in args.fields:
    field.fromJson(data[i])
    i += 1

proc namedParams(data: JsonNode, args: var tuple, allowedMissing: static seq[string]) =
  ## Parses named params from the object
  if data.kind != JObject:
    raise (ref RPCError)(code: InvalidRequest, msg: "Named params must be an object")

  for name, field in args.fieldPairs:
    if name notin data and name notin allowedMissing:
      const fieldName = name
      raise (ref RPCError)(code: InvalidParams, msg: fmt"Missing expected argument: '{fieldName}'")

    field.fromJson(data[name])

macro call*(prc: proc, args: tuple): untyped =
  ## Calls a proc using arguments from `tuple`
  runnableExamples:
    proc foo(a, b: int): int = a + b

    assert foo.call((1, 2)) == 3
  result = newCall(prc)
  for arg in args.getTypeImpl():
    result &= nnkDotExpr.newTree(args, ident arg[0].strVal)


proc parseArgs(data: JsonNode, args: var tuple) =
  ## Parses the arguments from `data` into `args`. Handles
  ## both positional and named args
  case data.kind
  of JArray:
    data.positionalParams(args)
  of JObject:
    data.namedParams(args, @["test"])
  else:
    assert false, "Expected either an array of positional params or object of named params"

macro wrapRPC(handler: proc, into: typedesc): proc =
  ## Wraps a proc so that it matches `into`. Performs the conversion
  ## of the passed JSON into whats expected for the handler
  let tupleVal = handler.createNamedTuple()
  return quote do:
    proc (data: JsonNode): JsonNode =
      var args = `tupleVal`
      data.parseArgs(args)
      return `handler`.call(args).toJson()

proc add*[R](exec: var Executor[R], meth: string, handler: proc) =
  ## Adds a method into the executor. Overwrites a method if it already exists
  exec.handlers[meth] = wrapRPC(handler, R)

proc add*[T](exec: var Executor, def: MethodDef[T], handler: T) =
  ## Adds a method into the executor. Enforces the method implements a
  ## a signature
  exec.add(def.name, handler)

proc call*[R](exec: var Executor[R], request: Request): R =
  ## Handles a method
  let meth = request.meth
  if meth notin exec.handlers:
    raise (ref KeyError)(msg: fmt"{meth} not registered in executor") # TODO: Convert to RPC error
  exec.handlers[request.meth](request.params)

proc call*[R](exec: var Executor[R], request: JsonNode): R =
  ## Handle a request that is still in JSON

export critbits
