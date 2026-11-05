# A bare RSGI app on Granian, a Python server written in Rust. RSGI is
# Granian's own interface: lower overhead than ASGI, and no framework at all.
BODY = b"Granian greets the world!"
HEADERS = [("content-type", "text/plain; charset=utf-8")]
NOT_FOUND = b"Not Found"


async def app(scope, proto):
    if scope.method == "GET" and scope.path == "/":
        proto.response_bytes(200, HEADERS, BODY)
    else:
        proto.response_bytes(404, HEADERS, NOT_FOUND)
