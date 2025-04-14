import std/[
  critbits,
  json,
  jsonutils,
  options,
  typetraits,
  strformat,
  macros,
  wrapnils,
  sugar,
  streams,
  asyncdispatch
]

# TODO: Expose methods for parsing a request, can be handy for adding middlewares
# TODO: Some kind of context maybe?

type
  Executor*[R] = object
    ## Executor stores all the functions and handles calling them.
    ## Transport is handled separately.
    # TODO: Add generic parameter for context
    # Return type is generic to allow for async/sync executors
    handlers: CritBitTree[proc (data: JsonNode): R]

  SyncExecutor = Executor[string]
    ## Synchronous RPC call executor. Not exactly useful, but I use it for tests

  AsyncExecutor = Executor[Future[string]]

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
    jsonrpc = "2.0" # TODO: Remove?
      ## Version, only 2.0 is implemented
    id*: Option[JsonNode]
      ## ID of the request. If missing then its a notification
    meth*: string
      ## Method getting called
    params*: JsonNode # Type it better maybe? Easier for middlewares
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
    id*: JsonNode
      ## A response always has an ID since notifications have nothing sent back
    case passed*: bool ## Whether the call failed or not
    of true:
      result*: JsonNode
        ## Result from the call
    of false:
      error*: Error
        ## Error that occured from the call

  RPCErrorCode = distinct int
    ## Error codes for JSONRPC. Stored as distinct int instead of enum
    ## so that it can be extended

  RPCError = object of CatchableError
    ## Exception to throw about an error
    code*: RPCErrorCode
      ## Corresponding error code defined in the spec
    id*: JsonNode
      ## Request that the failure occured in.
      ## "If there was an error in detecting the id in the Request object (e.g. Parse error/Invalid Request), it MUST be Null."

const
  InvalidRequest* = RPCErrorCode(-32600)
    ## Request object was invalid
  InvalidParams* = RPCErrorCode(-32602)
    ## Parameters passed were invalid
  MethodNotFound* = RPCErrorCode(-32601)
    ## Executor couldn't find the method
  ParseError* = RPCErrorCode(-32700)
    ## Error when trying to parse incoming JSON

proc `%`*(code: RPCErrorCode): JsonNode {.borrow.}
proc `$`*(code: RPCErrorCode): string {.borrow.}


func fromJsonHook*(request: out Request, data: JsonNode) =
  ## Hook for parsing the JSON
  # Perform some validation
  let id = option(data{"id"})
  if id.map(x => x.kind notin {JInt, JString, JNull}).get(false):
    raise (ref RPCError)(id: newJNull(), code: InvalidRequest, msg: "`id` must be one int, string, or null")

  # "This member MAY be omitted"
  let params = option(data{"params"})
  if params.map(x => x.kind notin {JArray, JObject}).get(false):
    raise (ref RPCError)(id: id.get(newJNull()), code: InvalidRequest, msg: "Params must be an array/object of arguments")

  request = Request(
      jsonrpc: data["jsonrpc"].str,
      id: id,
      meth: data["method"].str,
      params: params.get(newJArray())
  )

func toJsonHook*(request: sink Request): JsonNode =
  result = %request
  result["method"] = result["meth"]
  result.delete("meth")

func fromJsonHook*(response: out Response, data: JsonNode) =
  response = Response(id: data["id"], passed: "result" in data)
  if response.passed:
    response.result = data["result"]
  else:
    response.error.fromJson(data["error"])

func toJsonHook*(response: sink Response): JsonNode =
  result = %*{
    "id": response.id,
    "jsonrpc": "2.0"
  }
  if response.passed:
    result["result"] = response.result
  else:
    # TODO: Make a jsonhook
    result["error"] = %response.error
    if result["error"]["data"].kind == JNull:
      result["error"].delete("data")

func isNotification*(x: Request): bool =
  ## Checks if a request is a notification
  x.id.isNone()


func failed(req: Request, code: RPCErrorCode, msg: string, data: JsonNode = newJNull()): Response =
  ## Constructs an error in response to a request.
  ## Expects the request to not be a notification
  return Response(
    # "If there was an error in detecting the id in the Request object (e.g. Parse error/Invalid Request), it MUST be Null."
    id: req.id.get(newJNull()),
    passed: false,
    error: Error(
      code: code,
      message: msg,
      data: data
    )
  )

func failed(req: Request, exp: RPCError): Response =
  ## Constructs an error for an exception
  return req.failed(exp.code, exp.msg)

func failed(exp: RPCError): Response =
  return Request(id: some exp.id).failed(exp)

func failed(code: RPCErrorCode, msg: string, data: JsonNode = newJNull()): Response =
  ## Constructs an error. Use this when a valid request is not available
  return Response(
    # "If there was an error in detecting the id in the Request object (e.g. Parse error/Invalid Request), it MUST be Null."
    id: newJNull(),
    passed: false,
    error: Error(
      code: code,
      message: msg,
      data: data
    )
  )

proc passed[T](req: Request, res: sink T): Response =
  ## Constructs a response in response to a successful request
  return Response(
    # "If there was an error in detecting the id in the Request object (e.g. Parse error/Invalid Request), it MUST be Null."
    id: req.id.get(newJNull()),
    passed: true,
    result: res.toJson()
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

proc wrap[R](resp: Response, into: typedesc[R]): R =
  ## Wraps the reponse so it becomes `R`
  return $ resp.toJson()

macro wrapRPC(handler: proc, into: typedesc): proc =
  ## Wraps a proc so that it matches `into`. Performs the conversion
  ## of the passed JSON into whats expected for the handler
  let tupleVal = handler.createNamedTuple()
  return quote do:
    proc (data: JsonNode): `into` =
      var args = `tupleVal`
      data.parseArgs(args)
      return $ `handler`.call(args).toJson()

proc on*[R](exec: var Executor[R], meth: string, handler: proc) =
  ## Adds a method into the executor. Overwrites a method if it already exists
  exec.handlers[meth] = wrapRPC(handler, R)

proc on*[T](exec: var Executor, def: MethodDef[T], handler: T) =
  ## Adds a method into the executor. Enforces the method implements a
  ## a signature
  exec.add(def.name, handler)

proc call*[R](exec: Executor[R], request: Request): R =
  ## Handles a method. This is where the actual execution of
  ## the method happens
  let meth = request.meth
  if meth notin exec.handlers:
    return request.failed(MethodNotFound, fmt"Method not found: '{meth}'").wrap(R)

  request.passed(exec.handlers[request.meth](request.params)).wrap(R)

proc call*[R](exec: Executor[R], requests: openArray[Request]): R =
  ## Runs a batch series of calls

  var items = "["
  for request in requests:
    let resp = exec.call(request)
    if not request.isNotification:
      items &= resp & ","
  if items.len == 0:
    return ""
  items.setLen(items.len - 1)
  items &= "]"
  return items

proc call[R](exec: Executor[R], request: JsonNode, typ: typedesc): R =
  ## Handles a request that is still in JSON. This handles exceptions that can
  ## occur when deserialising the JSON
  var data: typ
  # Handle any exceptions that come from deserialising the JSON
  try:
    data.fromJson(request)
  except RPCError as e:
    return failed(e[]).wrap(R)
  except CatchableError as e:
    # TODO: Better error messages
    return failed(InvalidRequest, "Invalid request object", %*{"msg": e.msg, "err": $e.name}).wrap(R)

  return exec.call(data)

proc call[R](exec: Executor[R], request: JsonNode): R {.inline.} =
  ## Handle a request that is still in JSON.
  ## This is an internal proc, since we don't want people side stepping parsing
  case request.kind
  of JArray:
    if request.len == 0:
      return failed(InvalidRequest, "Batch calls must have at least 1 call").wrap(R)

    exec.call(request, seq[Request])
  of JObject:
    exec.call(request, Request)
  else:
    return failed(InvalidRequest, "Request must be a single call or an array of batch calls").wrap(R)

proc call*[R](exec: Executor[R], data: string | Stream): R =
  ## Handles a call in JSON. This should be used for most purposes since it
  ## handles parsing errors
  let data = try:
      data.parseJson()
    except JsonParsingError as e:
      return failed(ParseError, fmt"Invalid JSON: {e.msg}").wrap(R)
  exec.call(data)


export critbits
