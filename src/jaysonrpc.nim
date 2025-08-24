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
  asyncdispatch,
  tables
]

# TODO: Expose methods for parsing a request, can be handy for adding middlewares
# TODO: Some kind of context maybe?

type
  ReturnVal = Option[string]
    ## Represents a return value from a call. Optional is used to represent if a response
    ## actually needs to be sent. preprocessed into JSON to avoid and hook issues

  RPCFunction[R] = proc (params: SentParameters): R
    ## Function that takes in request parameters and returns `R`.
    ## `R` should be some form of a string, e.g. `Future[string]`, `string`.
    ## This is to enable using different execution schemes

  ConstructedCall[R] = proc (): Option[R] {.closure, raises: [].}
    ## Call that has parameters applied, can then be called without
    ## needing the original request.
    ## If this returns `none` then a response shouldn't be sent

  Executor*[R] = object
    ## Executor stores all the functions, this can then be queried later
    ## to get the function to then pass to your favourite executor
    # TODO: Add generic parameter for context
    # Return type is generic to allow for async/sync executors
    handlers: CritBitTree[RPCFunction[R]]

  SyncExecutor = Executor[ReturnVal]
    ## Synchronous RPC call executor. Not exactly useful, but I use it for tests

  AsyncExecutor = Executor[Future[ReturnVal]]

  MethodDef[T: proc] = object
    ## This is a definition of a method. Used to enforce a spec
    ## or for calling a pre-defined method.
    ## This has the benefit of being able to share defintions between server and client
    ## for type safe calling (don't worry, we have helpers)
    name: string

  ID* = distinct JsonNode
    ## ID of a request

  ParamKind = enum
    Void
    Positional
    Named

  SentParameters = object
    ## Parameters stored in a request.
    ## Is either a list of positional parameters or a table of named parameters.
    ## Left up to the wrapped function to handle parsing
    case kind: ParamKind
    of Void: discard
    of Positional:
      positionalParams: seq[JsonNode]
    of Named:
      namedParams: OrderedTable[string, JsonNode]

  Request* = object
    ## A request sent to the server
    jsonrpc = "2.0" # TODO: Remove?
      ## Version, only 2.0 is implemented
    id*: Option[JsonNode]
      ## ID of the request. If missing then its a notification
    meth*: string
      ## Method getting called
    params*: SentParameters

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

  RPCCalls[R] = object
    ## Stores all the calls from a request
    calls: seq[ConstructedCall[R]]
      ## Stores all calls sent. These are wrapped so that execution can
      ## be handled by the user.
    isBatch: bool
      ## Whether the request was batch. Needed to control
      ## how we form the response

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

func fromJsonHook*(params: out SentParameters, data: JsonNode) =
  case data.kind
  of JArray:
    params = SentParameters(kind: Positional, positionalParams: data.elems)
  of JObject:
    params = SentParameters(kind: Named, namedParams: data.fields)
  else:
    raise (ref ValueError)(msg: fmt"Params must be array or object, not {data.kind}")

func fromJsonHook*(request: out Request, data: JsonNode) =
  ## Hook for parsing the JSON
  # Perform some validation
  let id = option(data{"id"})
  if id.map(x => x.kind notin {JInt, JString, JNull}).get(false):
    raise (ref RPCError)(id: newJNull(), code: InvalidRequest, msg: "`id` must be one int, string, or null")

  # "This member MAY be omitted"
  let params = option(data{"params"})
  if data.kind notin {JArray, JObject}:
    raise (ref RPCError)(id: id.get(newJNull()), code: InvalidRequest, msg: "Params must be an array/object of arguments")

  request = Request(
      jsonrpc: data["jsonrpc"].str,
      id: id,
      meth: data["method"].str,
      params: params.map(x => x.jsonTo(SentParameters)).get(SentParameters(kind: Void))
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

func dump*(calls: RPCCalls, responses: openArray[Option[JsonNode]]): Option[string] =
  ## Forms a response from the responses. Responses be from the calls
  ## in `calls`. If return val is `none()` then you MUST not send a response back
  if responses.len == 0:
    return none(string)

  if calls.isBatch:
    let needed = collect:
      for resp in responses:
        if resp.isSome():
          %resp
    #  If there are no Response objects contained within the Response array as it is to be sent to the client,
    # the server MUST NOT return an empty Array and should return nothing at all.
    if needed.len > 0:
      some $needed
    else:
      none(string)
  else:
    responses[0].map(proc (x: JsonNode): string = $x)

func failed(req: Request, code: RPCErrorCode, msg: string, data: JsonNode = newJNull()): Response {.raises: [].}=
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

proc passed(req: Request, res: sink JsonNode): Response =
  ## Constructs a response in response to a successful request
  return Response(
    # "If there was an error in detecting the id in the Request object (e.g. Parse error/Invalid Request), it MUST be Null."
    id: req.id.get(newJNull()),
    passed: true,
    result: res
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

proc positionalParams(data: openArray[JsonNode], args: var tuple) =
  ## Parses positional params from the object

  # Do some checks
  if data.len != args.tupleLen:
    raise (ref RPCError)(code: InvalidParams, msg: "Expected {args.tupleLen} parameters but got {data.len}")

  # Parse each field
  var i = 0
  for field in args.fields:
    field.fromJson(data[i])
    i += 1

proc namedParams(data: OrderedTable[string, JsonNode], args: var tuple, allowedMissing: static seq[string]) =
  ## Parses named params from the object
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


proc parseArgs(params: SentParameters, args: var tuple) =
  ## Parses the arguments from `params` into `args`. Handles
  ## both positional and named args
  bind positionalParams, namedParams
  case params.kind
  of Positional:
    positionalParams(params.positionalParams, args)
  of Named:
    namedParams(params.namedParams, args, @["test"])
  else:
    assert false, "Expected either an array of positional params or object of named params"

macro wrapRPC(handler: proc, into: typedesc): proc =
  ## Wraps a proc so that it matches `into`. Performs the conversion
  ## of the passed JSON into whats expected for the handler
  let tupleVal = handler.createNamedTuple()
  return quote do:
    proc (params: SentParameters): `into` =
      var args = `tupleVal`
      params.parseArgs(args)
      return `handler`.call(args).toJson()

proc on*[R](exec: var Executor[R], meth: string, handler: proc) =
  ## Adds a method into the executor. Overwrites a method if it already exists
  exec.handlers[meth] = wrapRPC(handler, R)

proc on*[T](exec: var Executor, def: MethodDef[T], handler: T) =
  ## Adds a method into the executor. Enforces the method implements a
  ## a signature
  exec.add(def.name, handler)

proc constructFail[R](req: Request, code: RPCErrorCode, msg: string): ConstructedCall[R] =
  return proc (): Option[R] {.raises: [].} =
    {.cast(raises: []).}:
      if req.isNotification:
        return none(JsonNode)
      return some(req.failed(code, msg).toJson())


proc `[]`[R](exec: Executor[R], request: sink Request): ConstructedCall[R] =
  ## Gets the handler from the executor in a way that keeps reference to the request
  let meth = request.meth
  if meth notin exec.handlers:
    return request.constructFail[:R](MethodNotFound, fmt"Method not found: '{meth}'")

  let fun = exec.handlers[meth]
  return proc (): Option[R] {.raises: [].}=
    let response = fun(request.params)

    # If it doesn't have an ID, it doesn't get a response
    if request.id.isNone():
      return none(JsonNode)

    # Form a response object
    {.cast(raises: []).}:
      return some(request.passed(response).toJson())

func add[R](calls: var RPCCalls[R], call: ConstructedCall[R]) =
  calls.calls &= call

func initCalls[R](calls: seq[ConstructedCall[R]], isBatch = calls.len > 0): RPCCalls[R] =
  return RPCCalls[R](
    isBatch: isBatch,
    calls: calls
  )

iterator items*[R](calls: RPCCalls[R]): ConstructedCall[R] =
  for call in calls.calls:
    yield call

proc getCalls*[R](exec: Executor[R], json: string): RPCCalls[R] =
  ## Gets all the calls associated with data
  let data = try:
      # It could be a batch call or just a single call.
      # Either way, we just represent it as a batch call
      json.parseJson()
    except JsonParsingError:
      return initCalls(@[Request(id: none(JsonNode)).constructFail[:R](InvalidRequest, "Failed to parse JSON")])

  if data.kind notin {JObject, JArray}:
    raise (ref RPCError)(code: InvalidRequest, msg: "Must either be an array of calls or a single call object")

  result = RPCCalls[R](isBatch: data.kind == JArray)
  let requests = if result.isBatch: data.jsonTo(seq[Request])
                 else: @[data.jsonTo(Request)]
  for request in requests:
    result.calls &= exec[request]



export critbits
