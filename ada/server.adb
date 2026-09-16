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
   function C_Fcntl (Fd : int; Cmd : int; Arg : int) return int;
   pragma Import (C, C_Fcntl, "fcntl");
   function C_Htons (Hostshort : unsigned_short) return unsigned_short;
   pragma Import (C, C_Htons, "htons");

   Response_Str : constant String :=
     "HTTP/1.1 200 OK" & ASCII.CR & ASCII.LF &
     "Content-Type: application/json" & ASCII.CR & ASCII.LF &
     "Content-Length: 27" & ASCII.CR & ASCII.LF &
     ASCII.CR & ASCII.LF &
     "{""message"":""Hello, world!""}";

   Buffer        : aliased C.char_array (0 .. 1023);
   Response_Len  : constant size_t := size_t (Response_Str'Length);
   Server_Fd     : int;
   Client_Fd     : int;
   Addr          : Sockaddr_In;
   Ret           : int;
   Dummy         : long;

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
         --  Non-blocking client so a slow peer can't stall the accept loop.
         --  fcntl(fd, F_SETFL=4, O_NONBLOCK=2048)
         Ret := C_Fcntl (Client_Fd, 4, 2048);

         --  Best-effort read of the request (ignored)
         Dummy := C_Read (Client_Fd, Buffer'Address, 1024);

         --  Write fixed response, then close deterministically
         Dummy := C_Write (Client_Fd, Response_Str'Address, Response_Len);

         Ret := C_Close (Client_Fd);
      end if;
   end loop;
end Server;
