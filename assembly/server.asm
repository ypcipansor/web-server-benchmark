; ---------------------------------------------------------------------------
; Minimal HTTP server for the benchmark suite.
;
; Single process, poll()-based event loop. The listening socket plus every
; accepted client socket is monitored with poll(2). When a client is readable
; we read from it with a running offset, accumulating into a per-client buffer
; until the request headers (\r\n\r\n) are complete, and only then route and
; respond. This avoids:
;   - a false 404 when TCP splits one request across several segments (a single
;     read might return only part of the request line), and
;   - answering a request we have not yet read.
; Responses use MSG_NOSIGNAL so a client that closed early cannot kill us with
; SIGPIPE. Because the handler is non-blocking and multiplexed, it keeps up with
; the benchmark's concurrent load without dropping responses.
; ---------------------------------------------------------------------------

%define MAX_CLIENTS 256
%define POLLIN    0x001
%define POLLHUP   0x010
%define POLLERR   0x008
%define POLLNVAL  0x020
%define READ_FLAGS (POLLIN | POLLHUP | POLLERR | POLLNVAL)
%define MSG_NOSIGNAL 0x4000
%define BUFSIZE  4096

%define SYS_socket  41
%define SYS_bind    49
%define SYS_listen  50
%define SYS_accept  43
%define SYS_read    0
%define SYS_sendto  44
%define SYS_close   3
%define SYS_poll    7

AF_INET   equ 2
SOCK_STREAM equ 1

section .data
    response db 'HTTP/1.1 200 OK', 13, 10
             db 'Content-Type: application/json', 13, 10
             db 'Content-Length: 27', 13, 10
             db 'Connection: close', 13, 10
             db 13, 10
             db '{"message":"Hello, world!"}'
    response_len equ $ - response

    response_404 db 'HTTP/1.1 404 Not Found', 13, 10
                 db 'Content-Type: text/plain', 13, 10
                 db 'Content-Length: 9', 13, 10
                 db 'Connection: close', 13, 10
                 db 13, 10
                 db 'Not found'
    response_404_len equ $ - response_404

    ; Request-line prefix that maps to a 200 (exact "GET /hello ", 11 bytes).
    hello_path db 'GET /hello '
    hello_path_len equ $ - hello_path

    ; Header terminator "\r\n\r\n" viewed as a little-endian dword (0D 0A 0D 0A
    ; in memory becomes the value 0x0A0D0A0D).
    crlf_dword equ 0x0A0D0A0D

    sockaddr:
        dw AF_INET          ; family
        dw 0x901f           ; port 8080 (0x1f90 big-endian)
        dd 0                ; INADDR_ANY
        times 8 db 0        ; padding

section .bss
    ; pollfds[0] is the listening socket, pollfds[1..] are clients.
    ; struct pollfd = { int fd; short events; short revents; } (8 bytes)
    pollfds   resb (MAX_CLIENTS + 1) * 8
    ; Per-client read buffer and running byte count, indexed by poll slot.
    ; Because a request may arrive in fragments across multiple poll passes,
    ; each client owns its own buffer and offset.
    bufs      resb (MAX_CLIENTS + 1) * BUFSIZE
    offsets   resb (MAX_CLIENTS + 1) * 4

section .text
    global _start

_start:
    mov rax, SYS_socket
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    mov r12, rax            ; r12 = listen fd

    mov rax, SYS_bind
    mov rdi, r12
    lea rsi, [sockaddr]
    mov rdx, 16
    syscall

    mov rax, SYS_listen
    mov rdi, r12
    mov rsi, 512
    syscall

    lea r13, [pollfds]      ; r13 = pollfds base
    mov dword [r13 + 0], r12d       ; fd
    mov word  [r13 + 4], POLLIN     ; events
    mov word  [r13 + 6], 0          ; revents
    mov rbx, 1              ; number of pollfds in use

event_loop:
    mov rax, SYS_poll
    mov rdi, r13
    mov rsi, rbx
    mov rdx, -1
    syscall
    cmp rax, 0
    jle event_loop

    movzx eax, word [r13 + 6]       ; revents[0]
    test ax, POLLIN
    jz  .check_clients
    ; Accept exactly ONE connection per poll pass. The listening socket is
    ; blocking, so accepting in a loop would block and stall the event loop
    ; until another connection arrives. poll() will wake us again if more
    ; connections are still pending.
    mov rax, SYS_accept
    mov rdi, r12
    xor rsi, rsi
    xor rdx, rdx
    syscall
    js .check_clients       ; error (e.g. EAGAIN): no pending connection
    mov r14d, eax
    cmp rbx, MAX_CLIENTS + 1
    jge .close_client_no_poll
    imul rcx, rbx, 8
    add rcx, r13
    mov dword [rcx + 0], r14d
    mov word  [rcx + 4], POLLIN
    mov word  [rcx + 6], 0
    mov dword [offsets + rbx*4], 0  ; reset this client's read offset
    inc rbx
    jmp .check_clients
.close_client_no_poll:
    mov rax, SYS_close
    mov rdi, r14
    syscall
    jmp .check_clients
.check_clients:
    ; r15 is the pollfds index we are examining (not touched by syscalls).
    mov r15, 1
.client_loop:
    cmp r15, rbx
    jge event_loop
    imul r9, r15, 8
    lea r10, [r13 + r9]      ; r10 = &pollfds[r15]
    movzx eax, word [r10 + 6]
    and ax, READ_FLAGS
    jz  .next_client
    ; Common per-client state for this slot:
    ;   r8  = &bufs[r15]        (read buffer base)
    ;   r14 = current offset    (bytes accumulated so far)
    ;   r10 = &pollfds[r15]
    ;   rdi = fd (set just before the read; preserved across syscall)
    imul r8, r15, BUFSIZE
    lea r8, [bufs + r8]
    mov r14d, dword [offsets + r15*4]
    ; read(fd, &bufs[r15][r14], BUFSIZE - r14)
    mov edi, dword [r10]
    mov rax, SYS_read
    lea rsi, [r8 + r14]
    mov edx, BUFSIZE
    sub edx, r14d
    syscall
    test rax, rax
    jle .read_stall_or_close
    ; accumulate and persist the new offset
    add r14d, eax
    mov dword [offsets + r15*4], r14d
    ; scan the accumulated bytes [r8, r8+r14) for CRLFCRLF (0x0A0D0A0D)
    mov r9, r8               ; r9 = scan pointer
    lea r10, [r8 + r14]
    sub r10, 3              ; r10 = last valid 4-byte start (end - 4)
.scan_loop:
    cmp r9, r10
    jae .not_complete_yet   ; not enough bytes for a 4-byte terminator
    cmp dword [r9], crlf_dword
    je  .route_now
    inc r9
    jmp .scan_loop
.not_complete_yet:
    ; Headers not complete yet: leave this client pending and continue. The
    ; socket is polled again and a later poll pass accumulates the rest.
    jmp .next_client
.read_stall_or_close:
    ; rax <= 0. r8/r14/rdi are still valid.
    cmp rax, -11            ; EAGAIN: no more data right now, leave pending
    je  .next_client
    test rax, rax
    jne .close_client       ; real error: drop the connection
    ; rax == 0 (peer closed). If we have some data, route what we got; if the
    ; peer closed without sending anything, just close.
    test r14d, r14d
    jnz .route_now
    jmp .close_client
.route_now:
    ; rdi = fd, r8 = buffer base, r14 = offset. Route: only an exact
    ; "GET /hello " request-line prefix gets a 200; everything else gets a 404.
    cmp r14d, hello_path_len
    jl  .send_404
    xor rcx, rcx
.route_cmp:
    ; Compare byte-by-byte. Use al/dl (not cl) so rcx stays the array index.
    mov al, byte [r8 + rcx]
    mov dl, byte [hello_path + rcx]
    cmp al, dl
    jne .send_404
    inc rcx
    cmp rcx, hello_path_len
    jl  .route_cmp
    ; sendto(fd, response, response_len, MSG_NOSIGNAL, NULL, 0)
    mov rax, SYS_sendto
    mov rsi, response
    mov rdx, response_len
    mov r10d, MSG_NOSIGNAL
    xor r8, r8
    xor r9, r9
    syscall
    jmp .close_client
.send_404:
    ; sendto(fd, response_404, response_404_len, MSG_NOSIGNAL, NULL, 0)
    mov rax, SYS_sendto
    mov rsi, response_404
    mov rdx, response_404_len
    mov r10d, MSG_NOSIGNAL
    xor r8, r8
    xor r9, r9
    syscall
.close_client:
    ; close(fd) -- rdi already holds the client fd
    mov rax, SYS_close
    syscall
    ; remove this entry (compact the arrays: pollfds, bufs, offsets)
    dec rbx
    cmp r15, rbx
    jge .next_client         ; removed slot was last; nothing to move
    ; move bufs[rbx] -> bufs[r15]  (BUFSIZE bytes).
    ; BUFSIZE (4096) is not a valid x86-64 index scale, so compute rbx*4096 and
    ; r15*4096 with a shift instead of an addressing-scale lea.
    mov rax, rbx
    shl rax, 12             ; rax = rbx * 4096
    lea rsi, [bufs + rax]
    mov rax, r15
    shl rax, 12             ; rax = r15 * 4096
    lea rdi, [bufs + rax]
    mov ecx, BUFSIZE
    rep movsb
    ; move offsets[rbx] -> offsets[r15]
    mov eax, dword [offsets + rbx*4]
    mov dword [offsets + r15*4], eax
    ; move pollfd entry: pollfds[rbx] -> pollfds[r15] (8 bytes)
    imul rsi, rbx, 8
    add rsi, r13
    imul rdi, r15, 8
    add rdi, r13
    mov rcx, qword [rsi]
    mov qword [rdi], rcx
    jmp .client_loop         ; re-check this index (may hold a moved entry)
.next_client:
    inc r15
    jmp .client_loop

section .note.GNU-stack noalloc noexec nowrite progbits