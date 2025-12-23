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
  asyncdispatch,
  tables,
  sets,
  macrocache,
  sequtils,
  logging,
  atomics
]

import pkg/threading/rwlock

## This is an implementation of the [JSON-RPC protocol](https://www.jsonrpc.org).

runnableExamples:
  import std/sugar # for collect:

  var rpc = initExecutor[JsonNode, void]()

  rpc.on("hello") do (x: string) -> string:
    return x

  # Data then needs to come in as a string
  let rawJson = $ %* {"jsonrpc": "2.0", "method": "hello", "params": ["world"], "id": 1}
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

  RPCFunction[R, C] = proc (inProgress: InProgressRequests, request: Request, ctx: C): R
    ## Function that takes in request parameters and returns `R`.
    ## `R` should be some form of a string, e.g. `Future[string]`, `string`.
    ## This is to enable using different execution schemes
    ##
    ## `C` is the context parameter, this allows extra info to be passed along to every request

  ConstructedCallProc[R] = proc (): Option[R] {.closure, raises: [].}
  ConstructedCall*[R] = object
    ## Call that has parameters applied, can then be called without
    ## needing the original request.
    ## If this returns `none` then a response shouldn't be sent
    fun: ConstructedCallProc[R]
    name: string

  InProgressRequests = ref object
    ## Tracks in progress requests
    lock: RwLock
      ## Lock on the in progress table
    running {.guard: lock.}: HashSet[JsonNode]
      ## Table of request ID to whether they have been cancelled or not.
      ## i.e. if the value is false, then the request has been cancelled by the server.
      ## It is the request handlers just to check this on a regular basis.
    isRunning: Atomic[bool]

  Executor*[R, C] = object
    ## Executor stores all the functions, this can then be queried later
    ## to get the function to then pass to your favourite executor
    # TODO: Add generic parameter for context
    # Return type is generic to allow for async/sync executors
    handlers: CritBitTree[RPCFunction[R, C]]
    inProgress: InProgressRequests

  MethodDef*[A: tuple, R] = object
    ## This is a definition of a method. Used to enforce a spec
    ## or for calling a pre-defined method.
    ## This has the benefit of being able to share defintions between server and client.
    ## - `A` tuple representing the args to send
    ##
    name*: string ## Name of the method getting called

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

  TypedRequest*[R] = distinct Request
    ## [Request] but has type info associated on what the expected return type is.
    ## Used when sending a call to a remote server

  Notification = distinct Request
    ## Like [TypedRequest] but signifies this is a notification

  RPCErrorCode* = distinct int
    ## Error codes for JSONRPC. Stored as distinct int instead of enum
    ## so that it can be extended

  RPCError* = object of CatchableError
    ## Exception to throw about an error
    code*: RPCErrorCode
      ## Corresponding error code defined in the spec
    id*: Option[JsonNode]
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

  Context*[C] = object
    inProgress {.cursor.}: InProgressRequests
      ## Pointer to the executor to get cancellation info
    id: Option[JsonNode]
      ## ID of the current request getting executed.
      ## If its a notification it will be None
    data*: C
      ## Optional metadata attached to the request by the server
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
  result = InProgressRequests(lock: createRwLock())
  result.isRunning.store(true)

func initExecutor*[R, C](): Executor[R, C] =
  return Executor[R, C](inProgress: initInProgress())

proc findParmeters(x: NimNode): NimNode =
  ## Finds the parameters node
  case x.kind
  of nnkProcTy: x[0]
  of nnkFormalParams: x
  else: raise (ref ValueError)(msg: fmt"Can't find the parameter node for {x.kind}")

iterator parameters(x: NimNode): NimNode =
  ## Returns all the parameters for a proc. Doesn't return the return type
  ## This flattens the identDefs so the case of `a, b: int` can be ignored
  x.expectKind({nnkProcTy, nnkFormalParams})

  let parameters = x.findParmeters()

  for i in 1 ..< parameters.len:
    let identDef = x[i]
    if identDef.len == 3:
      # Simple case of `a: int`, we can return it
      yield identDef
    else:
      for paramIdx in 0 ..< (identDef.len - 2):
        # Return new identDef, keeping the same line info for each
        let newIdentDef = nnkIdentDefs.newTree(
          identDef[paramIdx], # name
          identDef[^2], # type
          identDef[^1] # default
        )
        newIdentDef.copyLineInfo(identDef)
        yield newIdentDef


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
    raise (ref RPCError)(id: none(JsonNode), code: InvalidRequest, msg: "Invalid Request")
  if key notin data:
    raise (ref RPCError)(id: none(JsonNode), code: InvalidRequest, msg: fmt"Missing {key}")
  let val = data[key]
  try:
    return val.to(into)
  except JsonKindError:
    raise (ref RPCError)(id: none(JsonNode), code: InvalidRequest, msg: fmt"Expected {$T} for {key} but got {val.kind}")

func test[T](opt: Option[T], pred: proc (value: T): bool): bool {.inline.} =
  ## Tests the value inside the option. Returns false if option is none
  opt.map(pred).get(false)

func isCancelled(this: InProgressRequests, id: JsonNode): bool =
  ## Internal function for checking if a request should still be running
  readWith this.lock:
    return id notin this.running

func isRunning*(this: Executor): bool =
  ## Returns true if the server is considered to still be running
  return this.inProgress.isRunning.load()

func cancel(this: InProgressRequests, ids: HashSet[JsonNode]) =
  ## Cancels a series of requests
  writeWith this.lock:
    this.running.excl(ids)

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

func shutdown*(exec: Executor) =
  ## Shutdowns the executor by cancelling all in progress requests
  exec.inProgress.isRunning.store(false)
  writeWith exec.inProgress.lock:
    exec.inProgress.running.clear()

func inProgress*(exec: Executor): int =
  ## Returns the number of requests that are registered to be executed
  readWith exec.inProgress.lock:
    return exec.inProgress.running.len

func id*(ctx: Context): Option[JsonNode] =
  ## Returns ID for current request
  return ctx.id

func fromJsonHook*(request: out Request, data: JsonNode) =
  ## Hook for parsing the JSON
  # Perform some validation
  let id = option(data{"id"})
  if id.test(x => x.kind notin {JInt, JString, JNull}):
    raise (ref RPCError)(id: none(JsonNode), code: InvalidRequest, msg: "`id` must be one int, string, or null")

  # "This member MAY be omitted"
  let params = option(data{"params"})
  if params.test(x => x.kind notin {JArray, JObject}):
    raise (ref RPCError)(id: id, code: InvalidRequest, msg: "Params must be an array/object of arguments")

  # Check the rest

  request = Request(
      jsonrpc: data.checkedGet("jsonrpc", string),
      id: id,
      meth: data.checkedGet("method", string),
      params: params.map(x => x.jsonTo(SentParameters)).get(SentParameters(kind: Void))
  )

func toJsonHook*(parameters: SentParameters): JsonNode =
  case parameters.kind
  of Void:
    result = newJObject()
  of Named:
    result = newJObject()
    result.fields = parameters.namedParams
  of Positional:
    result = newJArray()
    result.elems = parameters.positionalParams

func toJsonHook*(request: sink Request): JsonNode =
  result = %* {
    "jsonrpc": "2.0",
    "method": request.meth,
  }
  if request.params.kind != Void:
    result["params"] = request.params.toJson()
  if request.id.isSome():
    result["id"] = request.id.get()

func fromJsonHook*(response: out Response, data: JsonNode) =
  response = Response(id: data["id"], passed: "result" in data)
  if response.passed:
    response.result = data["result"]
  else:
    if "data" notin data["error"]:
      data["error"]["data"] = newJNull()
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
  return Request(id: exp.id).failed(exp)

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

iterator procArgs(prc: NimNode): (string, NimNode, NimNode) =
  ## Returns all the fields inside a proc.
  ## Must be passed the actual proc type implementation
  assert prc.kind == nnkProcTy, "Must be a proc type passed"
  let params = prc[0]
  for i in 1 ..< params.len:
    yield (params[i][0].strVal, params[i][1], params[i][2])

proc createNamedTuple(prc: NimNode): NimNode =
  ## Takes in the NimNode for a proc type and returns a named tuple to
  ## parse the parameters.
  ## Tuple has default values set
  let typ = prc.getTypeImpl()
  # First we need to construct the type
  let tupleType = nnkTupleTy.newTree()

  # Add all the args
  for (name, param, _) in typ.procArgs():
    tupleType &= newIdentDefs(ident name, param)

  # Then construct it
  return newCall("default", tupleType)

  # Then assign the defaults (TODO)

template argumentKeys(args: tuple): HashSet[string] =
  ## Returns the keys in the argument tuple that must be parsed.
  ## This handles getting rid of the [Context] argument
  var keys = initHashSet[string]()
  for name, field in args.fieldPairs:
    when type(field) is not Context:
      keys.incl(name)
  keys

proc positionalParams(data: openArray[JsonNode], args: var tuple) =
  ## Parses positional params from the object

  const tupleLen = args.argumentKeys().len
  if data.len != tupleLen:
    raise (ref RPCError)(code: InvalidParams, msg: fmt"Expected {tupleLen} parameters but got {data.len}")

  # Parse each field
  var i = 0
  for field in args.fields:
    when type(field) is not Context: # We must skip the context param
      field.fromJson(data[i])
      i += 1

proc namedParams(data: OrderedTable[string, JsonNode], args: var tuple) =
  ## Parses named params from the object
  # Check every key in the passed object to ensure there aren't extra keys
  const allowedKeys =  args.argumentKeys()

  when not defined(jaysonrpc.allowExtraArguments):
    for key in data.keys:
      if key notin allowedKeys:
        raise (ref RPCError)(code: InvalidParams, msg: fmt"Unknown argument: '{key}'")

  for name, field in args.fieldPairs:
    when type(field) isnot Context: # We must skip the context param
      const optional = type(field) is Option
      if name notin data and not optional:
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

func formCall(name: string, args: openArray[(string, JsonNode)] = []): Request =
  ## Low level proc for forming JSON RPC call objects. Making it be a call/notification is left up to when calling
  ## Currently just supports named parameters
  runnableExamples:
    let fooCall = formCall("foo", {"someArg": %1})
  #==#
  result = default(Request)
  # Only assign the name, ID will be assigned later when calling/notifying.
  #
  result.meth = name

  # Add params if provided
  if args.len > 0:
    var params = initOrderedTable[string, JsonNode](args.len)
    for (name, value) in args:
      params[name] = value
    result.params = SentParameters(kind: Named, namedParams: params)


proc call*[A, R](def: MethodDef[A, R], args: A): TypedRequest[R] {.inline.} =
  ## Returns the proc for calling a method
  var argsArr: array[tupleLen(args), (string, JsonNode)]
  var idx = 0
  for key, val in fieldPairs(args):
    argsArr[idx] = (key, val.toJson())
    idx += 1
  return TypedRequest[R](formCall(def.name, argsArr))

func `id=`*[R](request: var TypedRequest[R], id: int | string) =
  ## Sets the ID for a request
  Request(request).id = some %id

proc notify*[A, R](def: MethodDef[A, R], args: A): Notification {.inline.} =
  ## Creates a notification call that can be sent
  Notification(Request(def.call(args)))

proc parseArgs(params: SentParameters, args: var tuple) =
  ## Parses the arguments from `params` into `args`. Handles
  ## both positional and named args
  bind positionalParams, namedParams
  case params.kind
  of Positional:
    positionalParams(params.positionalParams, args)
  of Named:
    namedParams(params.namedParams, args)
  of Void:
    # We still need to check we haven't missed args if any are required
    for name, field in args.fieldPairs:
      when type(field) isnot Context: # We must skip the context param
        const optional = type(field) is Option
        const fieldName = name
        raise (ref RPCError)(code: InvalidParams, msg: fmt"Missing expected argument: '{fieldName}'")

func initContext[C](inProgress: sink InProgressRequests, id: Option[JsonNode], context: C): Context[C] =
  return Context[C](inProgress: inProgress, id: id, data: context)

func initContext(inProgress: sink InProgressRequests, id: Option[JsonNode]): Context[void] =
  return Context[void](inProgress: inProgress, id: id)

macro wrapRPC(handler: proc, into: typedesc, ctx: typedesc): RPCFunction =
  ## Wraps a proc so that it matches `into`. Performs the conversion
  ## of the passed JSON into whats expected for the handler
  let tupleVal = handler.createNamedTuple()
  return quote do:
    RPCFunction[`into`, `ctx`](proc (inProgress: InProgressRequests, request: Request, context: `ctx`): `into` =
      # Create the context
      let ctx = when `ctx` is void: initContext(inProgress, request.id) else: initContext(inProgress, request.id, context)

      # Convert the params
      var args = `tupleVal`
      try:
        request.params.parseArgs(args)
      except RPCError as e:
        # Attach id
        e.id = request.id
        raise

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
    )
proc on*[R, C](exec: var Executor[R, C], meth: string, handler: proc) =
  ## Adds a method into the executor. Overwrites a method if it already exists
  exec.handlers[meth] = wrapRPC(handler, R, C)

func name*(call: ConstructedCall): string =
  ## Returns the method that a constructed call handles
  return call.name

func call*[R](call: ConstructedCall[R]): ConstructedCallProc[R] =
  ## Returns the proc that you call to get the response
  return call.fun

{.experimental: "callOperator".}
func `()`*[R](call: ConstructedCall[R]): Option[R] =
  ## Helper function that calls the internal proc
  call.fun()

proc constructFail[R](req: Request, code: RPCErrorCode, msg: string): ConstructedCall[R] =
  let fun = proc (): Option[R] {.raises: [].} =
    {.cast(raises: []).}:
      if req.isNotification and code notin [ParseError, InvalidRequest]:
        return none(JsonNode)
      return some(req.failed(code, msg).toJson())
  return ConstructedCall[R](
    name: req.meth,
    fun: fun
  )

proc get[R, C](exec: Executor[R, C], request: sink Request, context: (sink C) | typedesc[void]): ConstructedCall[R] =
  ## Gets the handler from the executor in a way that keeps reference to the request
  let meth = request.meth
  if meth notin exec.handlers:
    logging.error(fmt"Unknown method '{meth}' call attemtped")
    return request.constructFail[:R](MethodNotFound, fmt"Method not found: '{meth}'")

  let fun = exec.handlers[meth]
  return ConstructedCall[R](
    name: meth,
    fun: proc (): Option[R] {.raises: [].} =
      let response =
                    try:
                      when C is void: fun(exec.inProgress, request)
                      else: fun(exec.inProgress, request, context)
                    except Exception as e:
                      let code = if e of RPCError: (ref RPCError)(e).code
                                  else: ServerError
                      {.cast(raises: []).}:
                        logging.error(fmt"Failed to execute {meth} with exception {e.name}: {e.msg}")
                        let val = some(request.failed(code, e.msg).toJson())
                      return val
      # If it doesn't have an ID, it doesn't get a response
      if request.id.isNone():
        return none(JsonNode)

      # Form a response object
      {.cast(raises: []).}:
        return some(request.passed(response).toJson())
  )

proc `[]`[R](exec: Executor[R, void], request: sink Request): ConstructedCall[R] =
  ## Gets the handler from the executor in a way that keeps reference to the request
  exec.get(request)

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

proc getCalls*[R, C](exec: Executor[R, C], json: string, ctx: C | typedesc[void]): RPCCalls[R] =
  ## Returns all the calls stored in a JSON message.
  ## Once all have been ran, they should be sent back to [dump]

  let data = try:
      # It could be a batch call or just a single call.
      # Either way, we just represent it as a batch call
      json.parseJson()
    except JsonParsingError:
      logging.error("Invalid JSON recieved")
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

      if not exec.isRunning:
        # If we are shutdown, just return an error . We wait til here for the error so we can get an ID
        if request.id.isSome():
          result.calls &= request.constructFail[:R](InvalidRequest, "Server is shutdown and not handling requests")
        continue

      # If its not a notification then register it so it can be cancelled
      if request.id.isSome():
        exec.inProgress.add(request.id.unsafeGet())

      result.calls &= exec.get(request, ctx)
    except RPCError as e:
      result.calls &= Request(id: none(JsonNode)).constructFail[:R](e.code, e.msg)

proc getCalls*[R](exec: Executor[R, void], json: string): RPCCalls[R] =
  exec.getCalls(json, void)

export critbits
export json
export options
