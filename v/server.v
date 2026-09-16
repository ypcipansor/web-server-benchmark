module main

import net

const response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{"message":"Hello, world!"}'

fn handle_conn(mut conn net.TcpConn) {
	mut buf := []u8{len: 1024}
	// Non-blocking client so a slow peer cannot block the accept loop.
	conn.set_blocking(false) or {}
	conn.read(mut buf) or {}
	conn.write_string(response) or {}
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