# Examples

Six programs, each a single file. Every one of them runs in `zig build test`
against `redfish_bmc_mock`, so an example that stops working stops CI.

```bash
zig build examples          # builds and installs all six into zig-out/bin
./zig-out/bin/explore --bmc https://bmc.example --username root --password calvin
```

| Example | Shows | Needs |
| --- | --- | --- |
| [`explore.zig`](explore.zig) | The whole client: connect, read what the service supports, walk `Chassis` and `Systems`, follow each member. | A BMC. The service root alone needs no credentials. |
| [`session_login.zig`](session_login.zig) | Trading a password for a session token, and giving it back. | A BMC and an account. |
| [`event_stream.zig`](event_stream.zig) | `EventService` server-sent events, decoded into the generated `Event` type. | A BMC with a `ServerSentEventUri`. |
| [`firmware_push.zig`](firmware_push.zig) | A multipart image push to `UpdateService`, and the task that outlives the request. | A BMC, an account, and an image. |
| [`parse_payload.zig`](parse_payload.zig) | Parsing a recorded response, and naming every property the generated type dropped. | A JSON file. No BMC. |
| [`readme.zig`](readme.zig) | The program the top-level README shows — and a test that fails if the README stops showing it. | A BMC. |

[`cli.zig`](cli.zig) is shared support — flag reading and connection setup —
not a program.

## The shape of an example

Each file is three things:

```zig
pub fn run(gpa, transport: *core.BmcTransport, out: *std.Io.Writer, ...) !void
pub fn main(init: std.process.Init) !u8
test "..." { ... run(...) against MockBmc ... }
```

`run` is the example. It takes a `*core.BmcTransport` rather than a URL and
writes to a `*std.Io.Writer` rather than to stdout, which is the entire reason
the test below it can drive the same code an operator runs and then assert on
what it produced. `main` is the part a test cannot reach — argument parsing and
`HttpBmc` setup — so `zig build test` compiles the executables too, without
running them.

## Why there is one `explore` and not three

`nv-redfish` ships this program three times: `readme-minimal`,
`explore-with-dummy-bmc`, and `explore-with-reqwest-bmc`. Not duplication for
its own sake — there a BMC is a *type parameter*, a program is generic over the
`Bmc` trait, and each instantiation is a crate.

`BmcTransport` here is a function-pointer struct resolved at runtime. The same
machine code drives a real service and a mock, and which one it got is an
argument rather than a build. So the mock version of an example is not another
example; it is the test at the bottom of the file.
