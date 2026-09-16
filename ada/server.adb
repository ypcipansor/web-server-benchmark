with Ada.Text_IO;
with Interfaces.C;
with System;

procedure Server is

   use Ada.Text_IO;
   use Interfaces.C;

   package C renames Interfaces.C;

   AF_INET    : constant int := 2;
   SOCK_STREAM: constant int := 1;
   INADDR_ANY : constant unsigned := 0;
   PORT        : constant int := 8080;
   MSG_NOSIGNAL: constant int := 16#4000#;  -- 0x4000, Linux send() flag

   --  Linux setsockopt constants for the per-connection receive timeout.
   SOL_SOCKET : constant int := 1;
   SO_RCVTIMEO: constant int := 20;         -- struct timeval receive timeout

   --  struct timeval for SO_RCVTIMEO (seconds + microseconds). Both fields are
   --  signed C long (time_t / suseconds_t on Linux).
   type Timeval is record
      Tv_Sec  : C.long;
      Tv_Usec : C.long;
   end record;
   pragma Convention (C, Timeval);

   --  Raw C socket API imported directly, mirroring the Fortran server.
   --  This avoids any external Ada web-server dependency and is fully
   --  reproducible from the GNAT runtime alone.

   type Sockaddr_In is record
      Sin_Family : short;
      Sin_Port   : unsigned_short;
      Sin_Addr   : unsigned;
      Sin_Zero   : unsigned_long;
   end record;
   pragma Convention (C, Sockaddr_In);

   function C_Socket (Domain, Sock_Type, Protocol : int) return int;
   pragma Import (C, C_Socket, "socket");
   function C_Bind (Sockfd : int; Addr : Sockaddr_In; Addrlen : int) return int;
   pragma Import (C, C_Bind, "bind");
   function C_Listen (Sockfd : int; Backlog : int) return int;
   pragma Import (C, C_Listen, "listen");
   function C_Accept (Sockfd : int; Addr : System.Address; Addrlen : System.Address) return int;
   pragma Import (C, C_Accept, "accept");
   function C_Read (Fd : int; Buf : System.Address; Count : size_t) return long;
   pragma Import (C, C_Read, "read");
   --  send() with an explicit flags argument. We pass MSG_NOSIGNAL so a client
   --  that resets the connection after sending its request cannot raise
   --  SIGPIPE (whose default action terminates the process). This mirrors the
   --  Assembly server, which already uses MSG_NOSIGNAL on its sendto().
   function C_Send (Fd : int; Buf : System.Address; Count : size_t; Flags : int) return long;
   pragma Import (C, C_Send, "send");
   --  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv): installs a short
   --  receive timeout so a peer holding a partial request open cannot block a
   --  worker forever (mirrors the Zig server's approach).
   function C_Setsockopt (Sockfd : int; Level : int; Optname : int;
                          Optval : System.Address; Optlen : unsigned) return int;
   pragma Import (C, C_Setsockopt, "setsockopt");
   function C_Close (Fd : int) return int;
   pragma Import (C, C_Close, "close");
   function C_Htons (Hostshort : unsigned_short) return unsigned_short;
   pragma Import (C, C_Htons, "htons");

   Response_Str : constant String :=
     "HTTP/1.1 200 OK" & ASCII.CR & ASCII.LF &
     "Content-Type: application/json" & ASCII.CR & ASCII.LF &
     "Content-Length: 27" & ASCII.CR & ASCII.LF &
     "Connection: close" & ASCII.CR & ASCII.LF &
     ASCII.CR & ASCII.LF &
     "{""message"":""Hello, world!""}";

   Response_Len     : constant size_t := size_t (Response_Str'Length);
   Response_404     : constant String :=
     "HTTP/1.1 404 Not Found" & ASCII.CR & ASCII.LF &
     "Content-Type: text/plain" & ASCII.CR & ASCII.LF &
     "Content-Length: 9" & ASCII.CR & ASCII.LF &
     "Connection: close" & ASCII.CR & ASCII.LF &
     ASCII.CR & ASCII.LF &
     "Not found";
   Response_404_Len : constant size_t := size_t (Response_404'Length);

   --  Two-second receive timeout applied to every client socket. Enabling it
   --  below means a peer that sends only a partial request (no CRLFCRLF) and
   --  then stalls will not pin a worker task forever; the blocking read returns
   --  an error after the timeout and the worker frees the slot. Even a burst of
   --  slow peers therefore cannot exhaust the fixed worker pool.
   Timeout_Tv : aliased Timeval := (Tv_Sec => 2, Tv_Usec => 0);

   --  Returns True when the request starts with the exact "GET /hello "
   --  request-line prefix.
   function Is_Hello (Req : C.char_array; Len : Natural) return Boolean is
      Wanted : constant String := "GET /hello ";
   begin
      if Len < Wanted'Length then
         return False;
      end if;
      for I in 0 .. Wanted'Length - 1 loop
         if C.To_Ada (Req (size_t (I))) /= Wanted (Wanted'First + I) then
            return False;
         end if;
      end loop;
      return True;
   end Is_Hello;

   --  Returns True when the request bytes contain the header terminator
   --  CRLFCRLF, i.e. the request headers are complete.
   function Has_Full_Headers (Req : C.char_array; Len : Natural) return Boolean is
      Marker : constant String := ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF;
   begin
      if Len < Marker'Length then
         return False;
      end if;
      for I in 0 .. Len - Marker'Length loop
         declare
            Match : Boolean := True;
         begin
            for J in Marker'First .. Marker'Last loop
               if C.To_Ada (Req (size_t (I + (J - Marker'First)))) /= Marker (J) then
                  Match := False;
                  exit;
               end if;
            end loop;
            if Match then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Has_Full_Headers;

   --  A fixed pool of worker tasks, each serving one connection at a time and
   --  then looping back to accept the next. Tasks are created once and reused,
   --  so no memory is allocated or leaked per connection. More workers than
   --  the benchmark's concurrent load (100-500) ensures the accept loop is not
   --  starved even if several workers are blocked reading slow peers.
   Worker_Count : constant := 256;

   task type Handler is
      entry Start (Fd : in int);
   end Handler;

   Workers : array (1 .. Worker_Count) of Handler;

   task body Handler is
      Client       : int;
      Dummy        : long;
      Opt_Result   : int;
      Total        : Natural;
      Local_Buffer : aliased C.char_array (0 .. 1023);
   begin
      loop
         accept Start (Fd : in int) do
            Client := Fd;
         end Start;

         --  Set a 2-second receive timeout so a peer that sends a partial
         --  request and then stalls cannot block this worker indefinitely.
         Opt_Result := C_Setsockopt
           (Client, SOL_SOCKET, SO_RCVTIMEO,
            Timeout_Tv'Address, unsigned (Timeval'Size / 8));

         --  Read until the request headers are complete (CRLFCRLF) so a
         --  partial first read cannot trigger a spurious 404 for a valid
         --  /hello. Stop early if the peer closes or the buffer fills.
         Total := 0;
         while Total < Local_Buffer'Length loop
            Dummy := C_Read
              (Client, Local_Buffer (size_t (Total))'Address,
               size_t (Local_Buffer'Length - Total));
            if Dummy <= 0 then
               exit;   -- error or peer closed
            end if;
            Total := Total + Natural (Dummy);
            if Has_Full_Headers (Local_Buffer, Total) then
               exit;
            end if;
         end loop;

         --  Serve 200 only for exact GET /hello, otherwise 404. If the peer
         --  closed before sending a request (Total = 0), just close the socket
         --  without answering (avoids spurious 404s on dead connections).
         if Total > 0 and then Is_Hello (Local_Buffer, Total) then
            Dummy := C_Send (Client, Response_Str'Address, Response_Len, MSG_NOSIGNAL); -- MSG_NOSIGNAL prevents SIGPIPE
         elsif Total > 0 then
            Dummy := C_Send (Client, Response_404'Address, Response_404_Len, MSG_NOSIGNAL); -- MSG_NOSIGNAL prevents SIGPIPE
         end if;

         Dummy := long (C_Close (Client));
      end loop;
   end Handler;

   Server_Fd     : int;
   Client_Fd     : int;
   Addr          : Sockaddr_In;
   Ret           : int;
   Next_Worker   : Positive := 1;

begin
   Put_Line ("Starting Ada HTTP Server on port 8080...");

   Server_Fd := C_Socket (AF_INET, SOCK_STREAM, 0);
   if Server_Fd < 0 then
      Put_Line ("Error creating socket");
      return;
   end if;

   Addr.Sin_Family := short (AF_INET);
   Addr.Sin_Addr   := INADDR_ANY;
   Addr.Sin_Port   := C_Htons (unsigned_short (PORT));
   Addr.Sin_Zero   := 0;

   Ret := C_Bind (Server_Fd, Addr, 16);
   if Ret < 0 then
      Put_Line ("Error binding socket");
      return;
   end if;

   Ret := C_Listen (Server_Fd, 128);
   if Ret < 0 then
      Put_Line ("Error listening");
      return;
   end if;

   Put_Line ("Listening...");

   loop
      Client_Fd := C_Accept (Server_Fd, System.Null_Address, System.Null_Address);
      if Client_Fd >= 0 then
         --  Hand each connection to a worker from the fixed pool (round-robin).
         --  The worker reads the full request, routes on the path, and closes
         --  the socket, then re-accepts its next Start entry. No per-connection
         --  allocation means no memory leak under sustained load.
         Workers (Next_Worker).Start (Client_Fd);
         if Next_Worker = Worker_Count then
            Next_Worker := 1;
         else
            Next_Worker := Next_Worker + 1;
         end if;
      end if;
   end loop;
end Server;
