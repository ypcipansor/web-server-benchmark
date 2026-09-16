const std = @import("std");
const net = std.net;

pub fn main() !void {
    // Use c_allocator for better performance in benchmarks
    const allocator = std.heap.c_allocator;

    var pool: std.Thread.Pool = undefined;
    // The default (CPU-core-sized) thread pool and kernel listen backlog
    // cannot drain a burst of concurrent benchmark connections fast enough,
    // causing the last few connections to time out or be refused. Spawn
    // enough workers and accept a large backlog to handle the load.
    try pool.init(.{ .allocator = allocator, .n_jobs = 128 });
    defer pool.deinit();

    const address = try net.Address.parseIp("0.0.0.0", 8080);
    var server = try address.listen(.{
        .reuse_address = true,
        .kernel_backlog = 1024,
    });
    defer server.deinit();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Server running on port 8080\n", .{});

    while (true) {
        const connection = try server.accept();
        try pool.spawn(handleConnection, .{connection});
    }
}

fn handleConnection(connection: net.Server.Connection) void {
    defer connection.stream.close();

    var buffer: [1024]u8 = undefined;

    // Read request
    const bytes_read = connection.stream.read(&buffer) catch return;

    if (bytes_read == 0) return;

    const request = buffer[0..bytes_read];

    // Check for GET /hello
    if (std.mem.indexOf(u8, request, "GET /hello ") != null) {
        const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{\"message\":\"Hello, world!\"}";
        _ = connection.stream.writeAll(response) catch {};
    } else {
        const response = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot found";
        _ = connection.stream.writeAll(response) catch {};
    }
}
