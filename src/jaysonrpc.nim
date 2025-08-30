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
  tables,
  sets
]

import pkg/threading/rwlock

## This is an implementation of the [JSON-RPC protocol](https://www.jsonrpc.org).

runnableExamples:
  import std/sugar # for collect:

  var rpc = initExecutor[JsonNode]()

  rpc.on("hello") do (x: string) -> string:
    return x

  # Data then needs to come in as a string
  let rawJson = $ %* {"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
  # You get a series of calls from the json
  let calls = rpc.getCalls(rawJson)
  assert calls.len == 1 # This is not a batch call, so we have one call
  # These functions can be called however you want, they are thread safe and handle everything themselves
  let responses = collect:
    for call in calls:
      call()
  # Once you collect them back, you can send back a response
  echo calls.dump(responses)

# TODO: Expose methods for parsing a request, can be handy for adding middlewares
# TODO: Some kind of context maybe?

type
  IDKind = enum
    ## Different formats an ID can be
    Numeric ## ID is s
    String
    None

  ReturnVal = Option[string]
    ## Represents a return value from a call. Optional is used to represent if a response
    ## actually needs to be sent. preprocessed into JSON to avoid and hook issues

  RPCFunction[R] = proc (inProgress: InProgressRequests, request: Request): R
    ## Function that takes in request parameters and returns `R`.
    ## `R` should be some form of a string, e.g. `Future[string]`, `string`.
    ## This is to enable using different execution schemes

  ConstructedCall[R] = proc (): Option[R] {.closure, raises: [].}
    ## Call that has parameters applied, can then be called without
    ## needing the original request.
    ## If this returns `none` then a response shouldn't be sent

  InProgressRequests = ref object
    ## Tracks in progress requests
    lock: RwLock
      ## Lock on the in progress table
    running {.guard: lock.}: HashSet[JsonNode]
      ## Table of request ID to whether they have been cancelled or not.
      ## i.e. if the value is false, then the request has been cancelled by the server.
      ## It is the request handlers just to check this on a regular basis.

  Executor*[R] = object
    ## Executor stores all the functions, this can then be queried later
    ## to get the function to then pass to your favourite executor
    # TODO: Add generic parameter for context
    # Return type is generic to allow for async/sync executors
    handlers: CritBitTree[RPCFunction[R]]
    inProgress: InProgressRequests

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
    jsonrpc* = "2.0"
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

  RPCErrorCode* = distinct int
    ## Error codes for JSONRPC. Stored as distinct int instead of enum
    ## so that it can be extended

  RPCError* = object of CatchableError
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

  Context* = object
    inProgress {.cursor.}: InProgressRequests
      ## Pointer to the executor to get cancellation info
    id: Option[JsonNode]
      ## ID of the current request getting executed.
      ## If its a notification it will be None

const
  InvalidRequest* = RPCErrorCode(-32600)
    ## Request object was invalid
  InvalidParams* = RPCErrorCode(-32602)
    ## Parameters passed were invalid
  MethodNotFound* = RPCErrorCode(-32601)
    ## Executor couldn't find the method
  ParseError* = RPCErrorCode(-32700)
    ## Error when trying to parse incoming JSON
  ServerError* = RPCErrorCode(-32603)
    ## Error from internal handler

func initInProgress(): InProgressRequests =
  ## Creates a new in progress object
  return InProgressRequests(lock: createRwLock())

func initExecutor*[R](): Executor[R] =
  return Executor[R](inProgress: initInProgress())

proc `%`*(code: RPCErrorCode): JsonNode {.borrow.}
proc `$`*(code: RPCErrorCode): string {.borrow.}
func `==`*(a, b: RPCErrorCode): bool {.borrow.}

func fromJsonHook*(params: out SentParameters, data: JsonNode) =
  case data.kind
  of JArray:
    params = SentParameters(kind: Positional, positionalParams: data.elems)
  of JObject:
    params = SentParameters(kind: Named, namedParams: data.fields)
  else:
    raise (ref ValueError)(msg: fmt"Params must be array or object, not {data.kind}")

func checkedGet*[T](data: JsonNode, key: string, into: typedesc[T]): T =
  ## Performs a checked get to access `key` from `data` and converts into T
  if data.kind != JObject:
    raise (ref RPCError)(id: newJNull(), code: InvalidRequest, msg: "Invalid Request")
  if key notin data:
    raise (ref RPCError)(id: newJNull(), code: InvalidRequest, msg: fmt"Missing {key}")
  let val = data[key]
  try:
    return val.to(into)
  except JsonKindError:
    raise (ref RPCError)(id: newJNull(), code: InvalidRequest, msg: fmt"Expected {$T} for {key} but got {val.kind}")

func test[T](opt: Option[T], pred: proc (value: T): bool): bool {.inline.} =
  ## Tests the value inside the option. Returns false if option is none
  opt.map(pred).get(false)

func isCancelled(this: InProgressRequests, id: JsonNode): bool =
  ## Internal function for checking if a request should still be running
  readWith this.lock:
    return id notin this.running

func cancel(this: InProgressRequests, id: JsonNode) =
  ## Cancels a request
  writeWith this.lock:
    this.running.excl(id)

func add(this: InProgressRequests, id: JsonNode) =
  ## Registers a request is running
  writeWith this.lock:
    this.running.incl(id)

func isCancelled*(ctx: Context, requestId: JsonNode): bool =
  ctx.inProgress.isCancelled(requestId)

func isCancelled*(ctx: Context): bool =
  ## Checks if the current request has been cancelled.
  # Notifications have no ID so no way to tell if they have been cancelled
  if ctx.id.isNone: return false
  ctx.isCancelled(ctx.id.unsafeGet())

func cancel*(ctx: Context, id: JsonNode) =
  ## Cancels an in-progress request.
  ## Does nothing if there is no request associated with that ID
  ctx.inProgress.cancel(id)

func inProgress*(exec: Executor): int =
  ## Returns the number of requests that are registered to be executed
  readWith exec.inProgress.lock:
    return exec.inProgress.running.len

func fromJsonHook*(request: out Request, data: JsonNode) =
  ## Hook for parsing the JSON
  # Perform some validation
  let id = option(data{"id"})
  if id.test(x => x.kind notin {JInt, JString, JNull}):
    raise (ref RPCError)(id: newJNull(), code: InvalidRequest, msg: "`id` must be one int, string, or null")

  # "This member MAY be omitted"
  let params = option(data{"params"})
  if params.test(x => x.kind notin {JArray, JObject}):
    raise (ref RPCError)(id: id.get(newJNull()), code: InvalidRequest, msg: "Params must be an array/object of arguments")

  # Check the rest

  request = Request(
      jsonrpc: data.checkedGet("jsonrpc", string),
      id: id,
      meth: data.checkedGet("method", string),
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
  # Notifications don't have an ID
  return x.id.isNone()

func dump*(calls: RPCCalls, responses: openArray[Option[JsonNode]]): Option[string] =
  ## Forms a response from the responses. Responses be from the calls
  ## in `calls`. If return val is `none()` then you MUST not send a response back
  if responses.len == 0:
    return none(string)

  if calls.isBatch:
    let needed = newJArray()
    for resp in responses:
      if resp.isSome():
        needed &= resp.unsafeGet()
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

  const tupleLen = args.tupleLen
  if data.len != tupleLen:
    raise (ref RPCError)(code: InvalidParams, msg: fmt"Expected {tupleLen} parameters but got {data.len}")

  # Parse each field
  var i = 0
  for field in args.fields:
    when type(field) is not Context: # We must skip the context param
      field.fromJson(data[i])
      i += 1

proc namedParams(data: OrderedTable[string, JsonNode], args: var tuple, allowedMissing: static seq[string]) =
  ## Parses named params from the object
  for name, field in args.fieldPairs:
    when type(field) is not Context: # We must skip the context param
      if name notin data and name notin allowedMissing:
        const fieldName = name
        raise (ref RPCError)(code: InvalidParams, msg: fmt"Missing expected argument: '{fieldName}'")

      field.fromJson(data[name])

macro call*(prc: proc, args: tuple): untyped =
  ## Calls a proc using arguments from `tuple`
  runnableExamples:
    proc foo(a, b: int): int = a + b

    assert foo.call((a: 1, b: 2)) == 3
  result = newCall(prc)
  for arg in args.getTypeImpl():
    if arg.kind != nnkIdentDefs:
      "Tuple must be made of named arguments".error(arg)
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
  of Void: discard

macro wrapRPC(handler: proc, into: typedesc): RPCFunction =
  ## Wraps a proc so that it matches `into`. Performs the conversion
  ## of the passed JSON into whats expected for the handler
  let tupleVal = handler.createNamedTuple()
  return quote do:
    proc (inProgress: InProgressRequests, request: Request): `into` =
      # Create the context
      let ctx = Context(inProgress: inProgress, id: request.id)

      # Convert the params
      var args = `tupleVal`
      request.params.parseArgs(args)
      # See if there is a context param we need to fill in
      for field in args.fields:
        when type(field) is Context:
          field = ctx

      # Call the request
      try:
        when typeof(`handler`.call(args)) is void:
          `handler`.call(args)
          # void returns are treated as null since the `result` member is required
          return newJNull()
        else:
          return `handler`.call(args).toJson()
      finally:
        # Make sure to deregister the call
        if request.id.isSome():
          ctx.cancel(request.id.unsafeGet())

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
      if req.isNotification and code notin [ParseError, InvalidRequest]:
        return none(JsonNode)
      return some(req.failed(code, msg).toJson())


proc `[]`[R](exec: Executor[R], request: sink Request): ConstructedCall[R] =
  ## Gets the handler from the executor in a way that keeps reference to the request
  let meth = request.meth
  if meth notin exec.handlers:
    return request.constructFail[:R](MethodNotFound, fmt"Method not found: '{meth}'")

  let fun = exec.handlers[meth]
  return proc (): Option[R] {.raises: [].}=
    let response = try: fun(exec.inProgress, request)
                   except Exception as e:
                     let code = if e of RPCError: (ref RPCError)(e).code
                                else: ServerError
                     {.cast(raises: []).}:
                       let val = some(request.failed(code, e.msg).toJson())
                     return val
    # If it doesn't have an ID, it doesn't get a response
    if request.id.isNone():
      return none(JsonNode)

    # Form a response object
    {.cast(raises: []).}:
      return some(request.passed(response).toJson())

func initCalls[R](calls: seq[ConstructedCall[R]], isBatch = calls.len > 0): RPCCalls[R] =
  return RPCCalls[R](
    isBatch: isBatch,
    calls: calls
  )

iterator items*[R](calls: RPCCalls[R]): ConstructedCall[R] =
  for call in calls.calls:
    yield call

func len*(calls: RPCCalls): int =
  ## Number of calls stored
  calls.calls.len

proc getCalls*[R](exec: Executor[R], json: string): RPCCalls[R] =
  ## Returns all the calls stored in a JSON message.
  ## Once all have been ran, they should be sent back to [dump]
  let data = try:
      # It could be a batch call or just a single call.
      # Either way, we just represent it as a batch call
      json.parseJson()
    except JsonParsingError:
      return initCalls(@[Request(id: none(JsonNode)).constructFail[:R](ParseError, "Failed to parse JSON")], false)

  if data.kind notin {JObject, JArray}:
    return initCalls(@[Request(id: none(JsonNode)).constructFail[:R](InvalidRequest, "Must either be an array of calls or a single call object")], false)

  result = RPCCalls[R](isBatch: data.kind == JArray)
  # Wrap the data in an array to make it easier
  let allData = if not result.isBatch: %[data] else: data
  # Batch calls MUST have atleast 1 call
  if allData.len == 0:
    return initCalls(@[Request(id: none(JsonNode)).constructFail[:R](InvalidRequest, "Batch calls must have at least 1 call")], false)

  for data in allData:
    try:
      let request = data.jsonTo(Request)
      # If its not a notification then register it so it can be cancelled
      if request.id.isSome():
        exec.inProgress.add(request.id.unsafeGet())

      result.calls &= exec[request]
    except RPCError as e:
      result.calls &= Request(id: none(JsonNode)).constructFail[:R](e.code, e.msg)


export critbits
export json
