<?php
/**
 * Minimal HTTP server for benchmarking.
 *
 * Uses raw sockets (like the other polyglot implementations) so it responds as
 * soon as the request headers arrive, which keeps it compatible with Apache
 * Bench (curl-style clients that half-close the send side are not required).
 */

$response_ok  = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{\"message\":\"Hello, world!\"}";
$response_404 = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot found";

$sock = socket_create(AF_INET, SOCK_STREAM, SOL_TCP);
socket_set_option($sock, SOL_SOCKET, SO_REUSEADDR, 1);
socket_bind($sock, '0.0.0.0', 8080);
socket_listen($sock, 512);

// Fork worker processes so multiple connections are handled concurrently.
// More workers than CPU cores give blocking reads enough parallelism to keep
// up with the benchmark's concurrent load (100-500 connections).
$workers = 16;
for ($i = 0; $i < $workers; $i++) {
    $pid = pcntl_fork();
    if ($pid === 0) {
        serve($sock, $response_ok, $response_404);
        exit(0);
    }
}

while (pcntl_waitpid(-1, $status) > 0) {
    // parent waits for children
}
die();

/**
 * Accept loop for a single worker process.
 */
function serve($sock, $ok, $n404): void
{
    while (true) {
        $client = @socket_accept($sock);
        if ($client === false) {
            continue;
        }

        // Block on reading the request (with a 100ms receive timeout each
        // worker) until the full request headers arrive, then respond. Because
        // several forked workers accept connections in parallel, blocking reads
        // here do not stall the whole server.
        socket_set_option($client, SOL_SOCKET, SO_RCVTIMEO, ['sec' => 0, 'usec' => 200000]);
        $buf = '';
        while (true) {
            $data = @socket_read($client, 4096);
            if ($data === false || $data === '') {
                break;
            }
            $buf .= $data;
            if (strpos($buf, "\r\n\r\n") !== false) {
                break; // full headers received
            }
        }

        // Parse the request line (e.g. "GET /hello HTTP/1.1") and compare the
        // exact method + target path instead of a raw substring scan, so
        // requests to any other path (e.g. /notfound) or with a non-GET method
        // correctly get a 404.
        $line = strtok($buf, "\r\n");
        $parts = $line === false ? [] : explode(' ', $line);
        $method = isset($parts[0]) ? $parts[0] : '';
        $path = isset($parts[1]) ? $parts[1] : '';

        if ($method === 'GET' && $path === '/hello') {
            @socket_write($client, $ok, strlen($ok));
        } else {
            @socket_write($client, $n404, strlen($n404));
        }

        socket_close($client);
    }
}