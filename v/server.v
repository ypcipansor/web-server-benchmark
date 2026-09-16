module main

import net

const response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{"message":"Hello, world!"}'
const response_404 = 'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot found'

fn handle_conn(mut conn net.TcpConn) {
	mut buf := []u8{}
	mut chunk := []u8{len: 1024}
	// Read until the request line/headers are complete so a partial first read
	// can't trigger a spurious 404 for a valid /hello. Each connection runs in
	// its own goroutine, so blocking reads here do not stall the accept loop.
	for {
		r := conn.read(mut chunk) or { break }
		if r <= 0 {
			break
		}
		buf << chunk[0..r]
		if buf.bytestr().contains('\r\n\r\n') {
			break
		}
		if buf.len >= 1024 {
			break
		}
	}
	req := buf.bytestr().trim('\x00')
	// Serve 200 only for the exact GET /hello, otherwise 404.
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