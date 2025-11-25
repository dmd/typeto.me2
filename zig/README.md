# typeto.me Zig port

This directory contains a minimal Zig implementation of the typeto.me server.
The goal of the port is to mirror the Rust server's WebSocket API with a focus
on readability and correctness.

## Building and running

You need a Zig compiler (0.11 or later). From this directory run:

```bash
zig build
./zig-out/bin/typeto-zig
```

The server listens on `0.0.0.0:8090` and expects the static assets from the
repository root's `gui/` directory to be present when serving the web client.
