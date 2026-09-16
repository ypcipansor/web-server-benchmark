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
   function C_Write (Fd : int; Buf : System.Address; Count : size_t) return long;
   pragma Import (C, C_Write, "write");
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

   --  Returns True when the request line targets exactly "/hello".
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

   --  One task per accepted connection, so a blocked read on one client can't
   --  stall the accept loop. This lets the server handle 100 concurrent
   --  benchmark connections while still routing on the request path.
   task type Handler is
      entry Start (Fd : in int);
   end Handler;

   type Handler_Access is access Handler;

   task body Handler is
      Client       : int;
      Dummy        : long;
      Local_Buffer : aliased C.char_array (0 .. 1023);
   begin
      accept Start (Fd : in int) do
         Client := Fd;
      end Start;

      Dummy := C_Read (Client, Local_Buffer'Address, 1024);

      --  Serve 200 only for exact path /hello, otherwise 404. If the peer
      --  closed before sending a request (read <= 0), just close the socket
      --  without answering (avoids spurious 404s on dead connections).
      if Dummy > 0 and then Is_Hello (Local_Buffer, Natural (Dummy)) then
         Dummy := C_Write (Client, Response_Str'Address, Response_Len);
      elsif Dummy > 0 then
         Dummy := C_Write (Client, Response_404'Address, Response_404_Len);
      end if;

      Dummy := long (C_Close (Client));
   end Handler;

   Server_Fd     : int;
   Client_Fd     : int;
   Addr          : Sockaddr_In;
   Ret           : int;
   H             : Handler_Access;

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
         --  Hand each connection to its own task. Each task reads the request
         --  (blocking is fine because it can't stall the accept loop), routes
         --  on the path, and closes the socket.
         H := new Handler;
         H.Start (Client_Fd);
      end if;
   end loop;
end Server;
