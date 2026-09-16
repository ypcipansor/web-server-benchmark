program http_server
    use iso_c_binding
    implicit none
    
    integer(c_int), parameter :: AF_INET = 2
    integer(c_int), parameter :: SOCK_STREAM = 1
    integer(c_int), parameter :: INADDR_ANY = 0
    integer(c_int), parameter :: PORT = 8080

    type, bind(C) :: sockaddr_in
        integer(c_short) :: sin_family
        integer(c_int16_t) :: sin_port
        integer(c_int32_t) :: sin_addr
        integer(c_int64_t) :: sin_zero
    end type sockaddr_in

    interface
        function socket(domain, type, protocol) bind(C, name="socket")
            import :: c_int
            integer(c_int), value :: domain, type, protocol
            integer(c_int) :: socket
        end function socket
        
        function bind(sockfd, addr, addrlen) bind(C, name="bind")
            import :: c_int, c_ptr, sockaddr_in
            integer(c_int), value :: sockfd
            type(sockaddr_in), intent(in) :: addr
            integer(c_int), value :: addrlen
            integer(c_int) :: bind
        end function bind
        
        function listen(sockfd, backlog) bind(C, name="listen")
            import :: c_int
            integer(c_int), value :: sockfd, backlog
            integer(c_int) :: listen
        end function listen
        
        function accept(sockfd, addr, addrlen) bind(C, name="accept")
            import :: c_int, c_ptr
            integer(c_int), value :: sockfd
            type(c_ptr), value :: addr, addrlen
            integer(c_int) :: accept
        end function accept
        
        function c_write(fd, buf, count) bind(C, name="write")
            import :: c_int, c_ptr, c_size_t, c_long
            integer(c_int), value :: fd
            type(c_ptr), value :: buf
            integer(c_size_t), value :: count
            integer(c_long) :: c_write
        end function c_write
        
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

        function htons(hostshort) bind(C, name="htons")
            import :: c_int16_t
            integer(c_int16_t), value :: hostshort
            integer(c_int16_t) :: htons
        end function htons

        function fcntl(fd, cmd, arg) bind(C, name="fcntl")
            import :: c_int
            integer(c_int), value :: fd, cmd
            integer(c_int), value :: arg
            integer(c_int) :: fcntl
        end function fcntl
    end interface
    
    integer(c_int) :: server_fd, client_fd
    type(sockaddr_in) :: addr
    integer(c_int) :: addrlen
    integer(c_int) :: ret
    integer(c_long) :: bytes_written, bytes_read
    character(len=200), target :: response_str
    character(len=1024), target :: buffer
    type(c_ptr) :: buf_ptr
    
    ! Construct response
    response_str = 'HTTP/1.1 200 OK' // char(13) // char(10) // &
                  'Content-Type: application/json' // char(13) // char(10) // &
                  'Content-Length: 27' // char(13) // char(10) // &
                  char(13) // char(10) // &
                  '{"message":"Hello, world!"}'
    
    print *, "Starting Fortran HTTP Server on port 8080..."

    ! 1. Socket
    server_fd = socket(AF_INET, SOCK_STREAM, 0)
    if (server_fd < 0) then
        print *, "Error creating socket"
        stop
    end if

    ! 2. Bind
    addr%sin_family = int(AF_INET, c_short)
    addr%sin_addr = INADDR_ANY
    addr%sin_port = htons(int(PORT, c_int16_t))
    addr%sin_zero = 0

    ! Size of sockaddr_in is 16 bytes
    ret = bind(server_fd, addr, 16)
    if (ret < 0) then
        print *, "Error binding socket"
        stop
    end if

    ! 3. Listen
    ret = listen(server_fd, 128)
    if (ret < 0) then
        print *, "Error listening"
        stop
    end if

    print *, "Listening..."

    ! 4. Accept loop (single-threaded, one connection per iteration)
    do
        ! Blocking accept: waits for the next pending connection. This is the
        ! correct model for this single-threaded server -- each iteration serves
        ! exactly one connection before looping to accept the next one.
        client_fd = accept(server_fd, c_null_ptr, c_null_ptr)
        if (client_fd < 0) then
            ! accept failed (unexpected for a blocking listener); loop again
            continue
        else
            ! Set client socket to non-blocking so a slow/stalled peer
            ! cannot block the response write under concurrent load.
            ! fcntl(fd, F_SETFL=4, O_NONBLOCK=0x800)
            ret = fcntl(client_fd, 4, 2048)

            ! Best-effort read of the request (non-blocking, ignored)
            buf_ptr = c_loc(buffer)
            bytes_read = c_read(client_fd, buf_ptr, 1024_8)

            ! Write response, then close deterministically
            buf_ptr = c_loc(response_str)
            bytes_written = c_write(client_fd, buf_ptr, len_trim(response_str, kind=8))

            ret = c_close(client_fd)
        end if
    end do

    ret = c_close(server_fd)
    
end program http_server
