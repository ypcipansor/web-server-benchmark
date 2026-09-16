; ---------------------------------------------------------------------------
; Minimal HTTP server for the benchmark suite.
;
; Single process, poll()-based event loop. The listening socket plus every
; accepted client socket is monitored with poll(2). When a client is readable
; we read the request and immediately send the response (using MSG_NOSIGNAL so
; a client that closed early cannot kill us with SIGPIPE). Because the handler
; is non-blocking and multiplexed, it keeps up with the benchmark's concurrent
; load (100 or 500 simultaneous connections) without dropping responses.
; ---------------------------------------------------------------------------

%define MAX_CLIENTS 256
%define POLLIN    0x001
%define POLLHUP   0x010
%define POLLERR   0x008
%define POLLNVAL  0x020
%define READ_FLAGS (POLLIN | POLLHUP | POLLERR | POLLNVAL)
%define MSG_NOSIGNAL 0x4000

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

    sockaddr:
        dw AF_INET          ; family
        dw 0x901f           ; port 8080 (0x1f90 big-endian)
        dd 0                ; INADDR_ANY
        times 8 db 0        ; padding

section .bss
    ; pollfds[0] is the listening socket, pollfds[1..] are clients.
    ; struct pollfd = { int fd; short events; short revents; } (8 bytes)
    pollfds   resb (MAX_CLIENTS + 1) * 8
    buffer    resb 4096

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
    ; read(fd, buffer, 4096)  -- rdi = fd held for later send/close
    mov edi, dword [r10]
    mov rax, SYS_read
    mov rsi, buffer
    mov rdx, 4096
    syscall
    ; rax = bytes read. rdi still holds the client fd for send/get close.
    test rax, rax
    jle .close_client        ; read error / peer closed: just close, no answer
    ; Route: only the exact request-line prefix "GET /hello " gets a 200;
    ; every other path or method gets a 404.
    cmp rax, hello_path_len
    jl  .send_404
    xor rcx, rcx
.route_cmp:
    ; Compare byte-by-byte. Use al/dl (not cl) so rcx stays the array index.
    mov al, byte [buffer + rcx]
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
    ; remove this entry (compact the array)
    dec rbx
    cmp r15, rbx
    jge .next_client         ; removed slot was last; nothing to move
    imul rcx, rbx, 8
    lea rsi, [r13 + rcx]     ; last valid entry
    imul rcx, r15, 8
    lea rdi, [r13 + rcx]     ; freed slot
    mov rcx, qword [rsi]
    mov qword [rdi], rcx     ; copy last entry into freed slot
    jmp .client_loop         ; re-check this index (may hold a moved entry)
.next_client:
    inc r15
    jmp .client_loop

section .note.GNU-stack noalloc noexec nowrite progbits
