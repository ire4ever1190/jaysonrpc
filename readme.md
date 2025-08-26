# JayonRPC

> Best name I could come up with. I just needed a decent RPC for a few projects

> [!WARNING]
> This is very alpha software, not very well tested

JSONRPC implementation that doesn't come with any transports (You bring it yourself!).
Just takes in JSON and sends back JSON, rest is up to you!.


Go to the [docs here](https://ire4ever1190.github.io/jaysonrpc/jaysonrpc.html) for more information and examples

## Features

 - [x] Full JSONRPC spec support
 - [ ] Supports default arguments
 - [ ] Supports multiple transports
 - [ ] Easy generation of client code

## Example

```nim
import pkg/jaysonrpc

# You register all the calls to an executor.
# The generic here is what you want it to return
var rpc = Executor[JsonNode]()
rpc.on("hello") do (x: string) -> string:
  return x

# Data then needs to come in as a string
const rawJson = $ %* {"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
# You get a series of calls from the json
let calls = rpc.getCalls(rawJson)
# These functions can be called however you want, they are thread safe and handle everything themselves
let responses = collect:
  for call in calls:
    call()
# Once you collect them back, you can send back a response
echo calls.dump(responses)
```
