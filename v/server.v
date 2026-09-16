module main

import net

const response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{"message":"Hello, world!"}'
const response_404 = 'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot found'

fn handle_conn(mut conn net.TcpConn) {
	mut buf := []u8{len: 1024}
	// Non-blocking client so a slow peer cannot block the accept loop.
	conn.set_blocking(false) or {}
	conn.read(mut buf) or {}
	req := buf.bytestr().trim('\x00')
	// Serve 200 only for the exact path /hello, otherwise 404.
	if req.starts_with('GET /hello ') {
		conn.write_string(response) or {}
	} else {
		conn.write_string(response_404) or {}
	}
	conn.close() or {}
}

fn main() {
	mut listener := net.listen_tcp(.ip, ':8080', net.ListenOptions{
		backlog: 128
	}) or { panic(err.msg()) }
	println('Listening on 8080')
	for {
		mut conn := listener.accept() or { continue }
		// Handle each connection on its own thread for concurrency.
		go handle_conn(mut conn)
	}
}