using System;
using System.Net;
using System.Threading;

namespace SockTest;

class Program
{
	static int sFailCount = 0;
	static int32 sPort = 5561;

	static Socket sClient;
	static Socket.IPv6Address sLoopback;
	static bool sConnectOk;
	static int32 sConnectErr;
	static bool sByName;   // true => use ConnectEx(hostname) i.e. the getaddrinfo path

	static void TryListen(StringView label, Result<void, Socket.SocketError> result)
	{
		switch (result)
		{
		case .Ok:           Console.WriteLine("  [PASS] {}", label);
		case .Err(let err): Console.WriteLine("  [FAIL] {} : err {}", label, err); sFailCount++;
		}
	}

	static void Check(StringView label, bool ok)
	{
		Console.WriteLine("  [{}] {}", ok ? "PASS" : "FAIL", label);
		if (!ok) sFailCount++;
	}

	// Runs on a worker thread so the blocking accept() on the main thread can complete.
	static void ClientThread()
	{
		sClient = new Socket();
		sClient.Blocking = true;

		if (sByName)
		{
			// getaddrinfo-based path (the IPv6-capable one)
			Socket.SockAddrInfo info;
			switch (sClient.ConnectEx("::1", (int32)sPort, out info))
			{
			case .Ok:           sConnectOk = true;
			case .Err(let err): sConnectErr = (int32)err;
			}
			return;
		}

		// explicit sockaddr_in6 path
		Socket.SockAddr_in6 to = default;
		to.sin6_addr = sLoopback;
		to.sin6_port = (.)Socket.htons((int16)sPort);
		to.sin6_family = Socket.AF_INET6;

		switch (sClient.ConnectEx(&to, sizeof(Socket.SockAddr_in6), .Stream, .TCP))
		{
		case .Ok:           sConnectOk = true;
		case .Err(let err): sConnectErr = (int32)err;
		}
	}

	static void RunRoundTrip(StringView label, bool byName, int32 port)
	{
		var port;   // parameters are immutable in Beef; this shadows it with a mutable copy

		Console.WriteLine();
		Console.WriteLine("{} (::1:{})", label, port);

		sPort = port;
		sByName = byName;
		sConnectOk = false;
		sConnectErr = 0;

		// A previous run's connection can leave the port in TIME_WAIT, so walk forward until a
		// port is free (a fresh Socket per attempt, since a failed bind closes the handle).
		Socket listener = null;
		for (int32 attempt < 20)
		{
			var candidate = new Socket();
			candidate.Blocking = true;
			if (candidate.Listen(sLoopback, port) case .Ok)
			{
				listener = candidate;
				break;
			}
			delete candidate;
			port++;
		}

		if (listener == null)
		{
			Console.WriteLine("  [FAIL] listen : no free port in range");
			sFailCount++;
			return;
		}
		sPort = port;
		Console.WriteLine("  [PASS] listen on port {}", port);

		Thread thread = new .(new => ClientThread);
		thread.Start(false);

		Socket serverConn = scope .();
		if (serverConn.AcceptFrom(listener) case .Err(let err))
		{
			Console.WriteLine("  [FAIL] accept : err {}", err);
			sFailCount++;
			thread.Join();
			listener.Close();
			delete listener;
			return;
		}
		Console.WriteLine("  [PASS] accept");

		thread.Join();
		delete thread;

		if (!sConnectOk)
		{
			Console.WriteLine("  [FAIL] client connect : err {}", sConnectErr);
			sFailCount++;
			return;
		}
		Console.WriteLine("  [PASS] client connect");

		String fromServer = "ping over ipv6";
		if (serverConn.Send(fromServer.Ptr, fromServer.Length) case .Err(let err))
		{
			Console.WriteLine("  [FAIL] server send : err {}", err);
			sFailCount++;
			return;
		}

		uint8[64] buf = ?;
		int n = 0;
		switch (sClient.Recv(&buf[0], buf.Count))
		{
		case .Ok(let got):  n = got;
		case .Err(let err): Console.WriteLine("  [FAIL] client recv : err {}", err); sFailCount++; return;
		}
		Check("client received server payload", StringView((char8*)&buf[0], n) == fromServer);

		String fromClient = "pong from client";
		if (sClient.Send(fromClient.Ptr, fromClient.Length) case .Err(let err))
		{
			Console.WriteLine("  [FAIL] client send : err {}", err);
			sFailCount++;
			return;
		}

		uint8[64] buf2 = ?;
		int n2 = 0;
		switch (serverConn.Recv(&buf2[0], buf2.Count))
		{
		case .Ok(let got):  n2 = got;
		case .Err(let err): Console.WriteLine("  [FAIL] server recv : err {}", err); sFailCount++; return;
		}
		Check("server received client payload", StringView((char8*)&buf2[0], n2) == fromClient);

		serverConn.Close();
		sClient.Close();
		delete sClient;
		listener.Close();
		delete listener;
	}

	public static int Main()
	{
		Console.WriteLine("compiled constants: AF_INET={} AF_INET6={} IPV6_V6ONLY={}",
			Socket.AF_INET, Socket.AF_INET6, Socket.IPV6_V6ONLY);
		Console.WriteLine("(macOS expects AF_INET6=30, IPV6_V6ONLY=27)");

		Socket.Init();

		// ---- listen variants ----
		Console.WriteLine();
		Console.WriteLine("listen variants:");
		{
			Socket s = scope .();
			s.Blocking = true;
			TryListen("Listen(5557)           [IPv6 any]", s.Listen(5557));
		}
		{
			Socket s = scope .();
			s.Blocking = true;
			TryListen("ListenLocal(5557)      [127.0.0.1]", s.ListenLocal(5557));
		}
		{
			Socket s = scope .();
			s.Blocking = true;
			TryListen("Listen(IPv4 any, 5558) [0.0.0.0]", s.Listen((Socket.IPv4Address)default, 5558));
		}

		// ::1 - IPv6Address is a union with a uint8[16] 'byte' member, so set the last byte
		sLoopback = default;
		sLoopback.byte[15] = 1;

		// ---- two round trips over IPv6 ----
		RunRoundTrip("round trip A: explicit sockaddr_in6 + ConnectEx(SockAddr*)", false, 5561);
		RunRoundTrip("round trip B: hostname path ConnectEx(\"::1\") via getaddrinfo", true, 5562);

		// ---- does the IPv4-only Connect() accept an IPv6 literal? ----
		Console.WriteLine();
		Console.WriteLine("Connect(StringView \"::1\") : the gethostbyname-based convenience overload");
		{
			Socket s = scope .();
			switch (s.Connect("::1", 5563))
			{
			case .Ok:           Console.WriteLine("  [info] connected (unexpected)");
			case .Err(let err): Console.WriteLine("  [info] failed with err {} - gethostbyname only resolves IPv4", err);
			}
			s.Close();
		}

		Console.WriteLine();
		if (sFailCount == 0)
		{
			Console.WriteLine("ALL CHECKS PASSED");
			return 0;
		}
		Console.WriteLine("{} CHECK(S) FAILED", sFailCount);
		return 1;
	}
}
