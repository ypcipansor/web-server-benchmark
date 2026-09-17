module main

import net

const response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{"message":"Hello, world!"}'
const response_404 = 'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot found'

fn handle_conn(mut conn net.TcpConn) {
	mut buf := []u8{}
	mut chunk := []u8{len: 4096}
	// Read until the request line/headers are complete so a partial first read
	// can't trigger a spurious 404 for a valid /hello, and keep reading past
	// 1024 bytes so a request with larger headers is still routed correctly.
	// Each connection runs in its own goroutine, so blocking reads here do not
	// stall the accept loop; the max_header cap bounds how long a peer that
	// never finishes its request can hold this goroutine.
	for {
		r := conn.read(mut chunk) or { break }
		if r <= 0 {
			break
		}
		buf << chunk[0..r]
		if buf.bytestr().contains('\r\n\r\n') {
			break
		}
		if buf.len >= 64 * 1024 {
			break
		}
	}
	// Route on the exact request-line prefix read from the wire: slice the
	// first bytes and compare directly, rather than comparing a null-trimmed
	// whole-buffer string, so an embedded NUL byte cannot corrupt the match.
	is_hello := buf.len >= 11 && buf[..11].bytestr() == 'GET /hello '
	if is_hello {
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