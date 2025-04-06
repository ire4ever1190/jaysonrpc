# JayonRPC

> Best name I could come up with. I just needed a decent RPC for a few projects


JSONRPC implementation that is transport agnostic. Supports different executors so it can be used in sync/async context.
Just takes in JSON and sends back JSON, rest is up to you!

## Features

 - [ ] Full JSONRPC spec support
 - [ ] Supports default arguments
 - [ ] Supports multiple transports
 - [ ] Easy generation of client code

## Example

```nim
import src/jaysonrpc
import std/json

var rpc = Executor[JsonNode]()
rpc.add("hello") do (x: string) -> string:
  return x

echo rpc.call(Request(meth: "hello", params: %* ["hello"]))
```
