program http_server
    use iso_c_binding
    implicit none

    integer(c_int), parameter :: AF_INET = 2
    integer(c_int), parameter :: SOCK_STREAM = 1
    integer(c_int), parameter :: INADDR_ANY = 0
    integer(c_int), parameter :: PORT = 8080
    ! MSG_NOSIGNAL = 0x4000: prevents send() from raising SIGPIPE when the peer
    ! resets the connection after sending its request (a reset otherwise kills
    ! the whole server, since SIGPIPE's default action terminates the process).
    integer(c_int), parameter :: MSG_NOSIGNAL = int(z'4000', c_int)
    ! O_NONBLOCK = 0x800 (Linux); fcntl F_SETFL = 4.
    integer(c_int), parameter :: O_NONBLOCK = int(z'800', c_int)
    integer(c_int), parameter :: F_SETFL = 4
    ! poll() event bits.
    integer(c_short), parameter :: POLLIN   = int(z'001', c_short)
    integer(c_short), parameter :: POLLHUP  = int(z'010', c_short)
    integer(c_short), parameter :: POLLERR  = int(z'008', c_short)
    integer(c_short), parameter :: POLLNVAL = int(z'020', c_short)
    integer(c_short), parameter :: READ_FLAGS = int(z'039', c_short)  ! IN|HUP|ERR|NVAL
    integer, parameter :: MAXC = 256
    integer, parameter :: BUFSIZE = 4096

    ! struct pollfd { int fd; short events; short revents; }
    type, bind(C) :: c_pollfd
        integer(c_int) :: fd
        integer(c_short) :: events
        integer(c_short) :: revents
    end type c_pollfd

    type, bind(C) :: sockaddr_in
        integer(c_short) :: sin_family
        integer(c_int16_t) :: sin_port
        integer(c_int32_t) :: sin_addr
        integer(c_int64_t) :: sin_zero
    end type sockaddr_in

    interface
        function c_socket(domain, type, protocol) bind(C, name="socket")
            import :: c_int
            integer(c_int), value :: domain, type, protocol
            integer(c_int) :: c_socket
        end function c_socket

        function c_bind(sockfd, addr, addrlen) bind(C, name="bind")
            import :: c_int, sockaddr_in
            integer(c_int), value :: sockfd
            type(sockaddr_in), intent(in) :: addr
            integer(c_int), value :: addrlen
            integer(c_int) :: c_bind
        end function c_bind

        function c_listen(sockfd, backlog) bind(C, name="listen")
            import :: c_int
            integer(c_int), value :: sockfd, backlog
            integer(c_int) :: c_listen
        end function c_listen

        function c_accept(sockfd, addr, addrlen) bind(C, name="accept")
            import :: c_int, c_ptr
            integer(c_int), value :: sockfd
            type(c_ptr), value :: addr, addrlen
            integer(c_int) :: c_accept
        end function c_accept

        ! poll(struct pollfd *fds, nfds_t nfds, int timeout)
        function c_poll(fds, nfds, timeout_msec) bind(C, name="poll")
            import :: c_int, c_ptr, c_size_t
            type(c_ptr), value :: fds
            integer(c_size_t), value :: nfds
            integer(c_int), value :: timeout_msec
            integer(c_int) :: c_poll
        end function c_poll

        ! send() with an explicit flags argument; MSG_NOSIGNAL prevents SIGPIPE.
        function c_send(fd, buf, count, flags) bind(C, name="send")
            import :: c_int, c_ptr, c_size_t, c_long
            integer(c_int), value :: fd
            type(c_ptr), value :: buf
            integer(c_size_t), value :: count
            integer(c_int), value :: flags
            integer(c_long) :: c_send
        end function c_send

        function c_read(fd, buf, count) bind(C, name="read")
            import :: c_int, c_ptr, c_size_t, c_long
            integer(c_int), value :: fd
            type(c_ptr), value :: buf
            integer(c_size_t), value :: count
            integer(c_long) :: c_read
        end function c_read

        function c_close(fd) bind(C, name="close")
            import :: c_int
            integer(c_int), value :: fd
            integer(c_int) :: c_close
        end function c_close

        function c_fcntl(fd, cmd, arg) bind(C, name="fcntl")
            import :: c_int
            integer(c_int), value :: fd, cmd, arg
            integer(c_int) :: c_fcntl
        end function c_fcntl

        ! glibc helper returning the thread-local errno address; used to tell a
        ! non-fatal EAGAIN (send buffer full on a non-blocking socket) apart from
        ! a real error (EPIPE/ECONNRESET) so respond() can keep writing.
        function c_errno_location() bind(C, name="__errno_location")
            import :: c_ptr
            type(c_ptr) :: c_errno_location
        end function c_errno_location

        ! Yield the CPU briefly when a non-blocking send returns EAGAIN instead
        ! of busy-spinning while the peer drains its receive buffer.
        function c_sched_yield() bind(C, name="sched_yield")
            import :: c_int
            integer(c_int) :: c_sched_yield
        end function c_sched_yield

        function htons(hostshort) bind(C, name="htons")
            import :: c_int16_t
            integer(c_int16_t), value :: hostshort
            integer(c_int16_t) :: htons
        end function htons
    end interface

    integer(c_int) :: server_fd, client_fd
    type(sockaddr_in) :: addr
    integer(c_int) :: ret
    integer(c_long) :: n
    integer :: i
    integer(c_int) :: nfds
    type(c_pollfd), target :: pfds(0:MAXC)
    character(len=BUFSIZE), target :: bufs(0:MAXC)
    character(len=BUFSIZE), target :: chunk
    integer :: offs(0:MAXC)
    integer(c_int) :: fd
    character(len=4), parameter :: terminator = char(13)//char(10)//char(13)//char(10)
    integer, parameter :: hello_len = 11

    ! Construct responses
    character(len=200), target :: response_str
    character(len=200), target :: response_404

    response_str = 'HTTP/1.1 200 OK' // char(13) // char(10) // &
                  'Content-Type: application/json' // char(13) // char(10) // &
                  'Content-Length: 27' // char(13) // char(10) // &
                  'Connection: close' // char(13) // char(10) // &
                  char(13) // char(10) // &
                  '{"message":"Hello, world!"}'

    response_404 = 'HTTP/1.1 404 Not Found' // char(13) // char(10) // &
                  'Content-Type: text/plain' // char(13) // char(10) // &
                  'Content-Length: 9' // char(13) // char(10) // &
                  'Connection: close' // char(13) // char(10) // &
                  char(13) // char(10) // &
                  'Not found'

    print *, "Starting Fortran HTTP Server on port 8080..."

    server_fd = c_socket(AF_INET, SOCK_STREAM, 0)
    if (server_fd < 0) then
        print *, "Error creating socket"
        stop
    end if

    addr%sin_family = int(AF_INET, c_short)
    addr%sin_addr = INADDR_ANY
    addr%sin_port = htons(int(PORT, c_int16_t))
    addr%sin_zero = 0

    ret = c_bind(server_fd, addr, 16)
    if (ret < 0) then
        print *, "Error binding socket"
        stop
    end if

    ret = c_listen(server_fd, 512)
    if (ret < 0) then
        print *, "Error listening"
        stop
    end if

    print *, "Listening..."

    ! 4. poll()-based non-blocking event loop. pollfds(0) is the listening
    ! socket; pollfds(1..nfds-1) are clients. Each client is non-blocking and
    ! owns a per-slot buffer + offset so a request split across several TCP
    ! segments is accumulated and routed only once CRLFCRLF has arrived (no
    ! false 404, and never a 200 answered without reading the request). Because
    ! no single read can block the loop, one slow peer cannot stall the server,
    ! and the multiplexing keeps up with 100 concurrent benchmark connections.
    pfds(0)%fd = server_fd
    pfds(0)%events = POLLIN
    pfds(0)%revents = 0
    nfds = 1            ! Linux nfds_t == number of pollfds

    do
        ret = c_poll(c_loc(pfds(0)), int(nfds, c_size_t), -1)
        if (ret <= 0) cycle

        ! --- accept new connections (one per poll pass, non-blocking style) ---
        if (iand(pfds(0)%revents, POLLIN) /= 0) then
            client_fd = c_accept(server_fd, c_null_ptr, c_null_ptr)
            if (client_fd >= 0) then
                ! Mark the client socket non-blocking so an attempted read on a
                ! peer with no pending data returns immediately (EAGAIN) instead
                ! of blocking the whole event loop.
                ret = c_fcntl(client_fd, F_SETFL, O_NONBLOCK)
                if (nfds <= MAXC) then
                    pfds(nfds)%fd = client_fd
                    pfds(nfds)%events = POLLIN
                    pfds(nfds)%revents = 0
                    offs(nfds) = 0
                    nfds = nfds + 1
                else
                    ret = c_close(client_fd)
                end if
            end if
        end if

        ! --- service clients ---
        i = 1
        do while (i < nfds)
            if (iand(pfds(i)%revents, READ_FLAGS) == 0) then
                i = i + 1
                cycle
            end if

            fd = pfds(i)%fd
            n = c_read(fd, c_loc(chunk), int(BUFSIZE - offs(i), c_size_t))
            if (n > 0) then
                bufs(i)(offs(i)+1:offs(i)+n) = chunk(1:n)
                offs(i) = offs(i) + n
                if (index(bufs(i)(1:offs(i)), terminator) > 0) then
                    ! request complete: route and close
                    call respond(fd, bufs(i), offs(i))
                    call close_slot(i)
                    cycle          ! slot i now holds a moved entry; reprocess
                else
                    i = i + 1
                end if
            else
                ! n <= 0: EOF (0) or EAGAIN/error (<0)
                if (n == 0 .or. iand(pfds(i)%revents, int(POLLHUP, c_short)) /= 0 &
                    .or. iand(pfds(i)%revents, int(POLLERR, c_short)) /= 0) then
                    ! peer closed or error: if we already buffered a complete
                    ! request without a terminator, still route what we have;
                    ! otherwise drop the connection.
                    if (offs(i) > 0) then
                        call respond(fd, bufs(i), offs(i))
                    end if
                    call close_slot(i)
                    cycle
                else
                    i = i + 1     ! EAGAIN: no data yet, leave pending
                end if
            end if
        end do
    end do

contains

    ! Return the current thread's errno (dereferences __errno_location()).
    function get_errno() result(e)
        integer(c_int) :: e
        type(c_ptr) :: loc
        integer(c_int), pointer :: p
        loc = c_errno_location()
        call c_f_pointer(loc, p)
        e = p
    end function get_errno

    ! Write the full response to a non-blocking client socket. A single send()
    ! may return a partial count, or -1/EAGAIN when the socket send buffer is
    ! full (the peer is slow to read). Loop with a running offset until every
    ! byte has been written; retry on EAGAIN and only stop on a fatal error.
    ! This guarantees the client never sees a truncated response (which ab
    ! would otherwise count as a failed request when we close too early).
    !
    ! The EAGAIN retry is bounded by an absolute wall-clock deadline so a peer
    ! that never drains its receive buffer (a stuck/slow reader) cannot make
    ! this single-threaded event loop busy-spin here forever, starving every
    ! other connection. sched_yield() alone does not wait for the socket to
    ! become writable, so without a cap one stuck client would monopolize the
    ! whole server. Under normal benchmark load the tiny response fits in the
    ! socket send buffer and EAGAIN never fires, so the full response is always
    ! delivered; the deadline only trips for a truly stuck peer, which is then
    ! dropped instead of being allowed to hold the loop.
    subroutine send_all(fd, resp, resp_len)
        integer(c_int), intent(in) :: fd
        character(len=*), intent(in), target :: resp
        integer(c_long), intent(in) :: resp_len
        integer(c_long) :: sent, sent_total
        integer(c_int) :: e, y
        integer :: t0, t1, cr, cm
        real :: elapsed_sec
        ! EAGAIN == EWOULDBLOCK == 11 on Linux: send buffer is full; retry.
        integer(c_int), parameter :: EAGAIN = 11
        ! Give a blocked send at most this much wall-clock time before giving
        ! up on the peer (prevents a slow reader from monopolizing the loop).
        real, parameter :: send_deadline_sec = 2.0
        call system_clock(count_rate=cr, count_max=cm)
        call system_clock(count=t0)
        sent_total = 0
        do while (sent_total < resp_len)
            sent = c_send(fd, c_loc(resp(sent_total+1:sent_total+1)), &
                          resp_len - sent_total, MSG_NOSIGNAL)
            if (sent > 0) then
                sent_total = sent_total + sent
            else
                e = get_errno()
                if (e == EAGAIN) then
                    y = c_sched_yield()   ! wait for the peer to drain a bit
                    call system_clock(count=t1)
                    elapsed_sec = real(t1 - t0) / real(max(cr, 1))
                    if (elapsed_sec > send_deadline_sec) then
                        exit   ! stuck peer; stop holding the event loop
                    end if
                else
                    exit                    ! fatal error; give up on this peer
                end if
            end if
        end do
    end subroutine send_all

    ! Route a buffered request: only an exact "GET /hello " request-line prefix
    ! gets a 200; everything else gets a 404. Response is fully flushed (all
    ! bytes) before returning so the caller can safely close the socket.
    subroutine respond(fd, buf, total)
        integer(c_int), intent(in) :: fd
        character(len=*), intent(in) :: buf
        integer, intent(in) :: total
        if (total >= hello_len) then
            if (buf(1:hello_len) == 'GET /hello ') then
                call send_all(fd, response_str, len_trim(response_str, kind=8))
            else
                call send_all(fd, response_404, len_trim(response_404, kind=8))
            end if
        else
            call send_all(fd, response_404, len_trim(response_404, kind=8))
        end if
    end subroutine respond

    ! Remove slot k from the client table, compacting the trailing entry into
    ! the freed slot so the arrays stay dense (like the Assembly server).
    subroutine close_slot(k)
        integer, intent(in) :: k
        integer(c_int) :: r
        r = c_close(pfds(k)%fd)
        nfds = nfds - 1
        if (k < nfds) then
            pfds(k) = pfds(nfds)
            bufs(k) = bufs(nfds)
            offs(k) = offs(nfds)
        end if
    end subroutine close_slot

end program http_server