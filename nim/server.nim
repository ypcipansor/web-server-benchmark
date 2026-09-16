import std/[asynchttpserver, asyncdispatch]

proc cb(req: Request) {.async, gcsafe.} =
  # Only respond 200 for an exact GET /hello; any other method or path gets 405/404.
  if req.reqMethod == HttpGet and req.url.path == "/hello":
    let headers = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(Http200, """{"message":"Hello, world!"}""", headers)
  else:
    await req.respond(Http404, "Not Found")

var server = newAsyncHttpServer()
echo "Server running on port 8080"
waitFor server.serve(Port(8080), cb, "0.0.0.0")
