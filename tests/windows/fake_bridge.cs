// Stand-in for ham-bridge.exe / ham-pty-host.exe / ham-ctl.exe in the hermetic
// scripts/install.ps1 test (tests/windows/install_ps1_test.ps1). One binary,
// behaviour picked by its file name and argv; every call is recorded (argv plus
// the HEIMDALL_* environment the installer or the Scheduled Task gave it).
//   serve <port> [root]   stub Hub + release mirror: /api/v1/health -> 200, files under root
//   --version / --help    version line / usage
//   --probe-hub URL       exit 0 (FAKE_PROBE_FAIL=1 -> exit 1)
//   enroll ...            writes --bridge-token-file, prints a pairing code, exit 0
//   (ham-bridge runtime)  listens on 127.0.0.1:--port until killed
// Calls log to %FAKE_LOG% when set (the installer's children), else to
// fake-calls.log next to the exe's directory (the task's runtime: <data dir>).
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public static class FakeBridge {
    static string Opt(string[] a, string name) {
        for (int i = 0; i < a.Length - 1; i++) if (a[i] == name) return a[i + 1];
        return null;
    }

    static void Record(string file, string kind, string[] a) {
        var sb = new StringBuilder(kind);
        foreach (var x in a) sb.Append('\t').Append(x);
        foreach (var k in new[] { "HEIMDALL_HAM_PTY_HOST_BIN", "HEIMDALL_BRIDGE_PTY_HOST", "HEIMDALL_HAM_CTL_BIN", "HEIMDALL_BRIDGE_ENDPOINT", "HEIMDALL_BRIDGE_SERVICE_NAME" })
            sb.Append('\t').Append(k).Append('=').Append(Environment.GetEnvironmentVariable(k) ?? "");
        var processPath = Environment.GetEnvironmentVariable("PATH") ?? "";
        sb.Append("\tPATH0=").Append(processPath.Split(';')[0]);
        sb.Append("\tPATH=").Append(processPath);
        sb.Append("\r\n");
        for (int i = 0; i < 40; i++) {
            try { File.AppendAllText(file, sb.ToString()); return; } catch (IOException) { Thread.Sleep(50); }
        }
    }

    public static int Main(string[] a) {
        if (a.Length >= 2 && a[0] == "serve") { Serve(int.Parse(a[1]), a.Length > 2 ? a[2] : null); return 0; }
        string exe = System.Reflection.Assembly.GetEntryAssembly().Location;
        string name = Path.GetFileNameWithoutExtension(exe);
        string log = Environment.GetEnvironmentVariable("FAKE_LOG");
        if (string.IsNullOrEmpty(log)) log = Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(exe)), "fake-calls.log");
        Record(log, name, a);
        if (Array.IndexOf(a, "--version") >= 0) {
            Console.WriteLine(name == "ham-bridge" ? "ham-bridge 0.4.99 protocol 1 bridge 1 ws 2" : name + " 0.4.99");
            return 0;
        }
        if (Array.IndexOf(a, "--help") >= 0) { Console.WriteLine("usage: " + name + " (fake)"); return 0; }
        if (Array.IndexOf(a, "--probe-hub") >= 0) {
            if (Environment.GetEnvironmentVariable("FAKE_PROBE_FAIL") == "1") { Console.Error.WriteLine("probe-hub FAILED (fake)"); return 1; }
            Console.WriteLine("probe-hub OK (fake)");
            return 0;
        }
        if (a.Length > 0 && a[0] == "enroll") {
            string bridgeId = Opt(a, "--reuse-bridge") ?? "brg_fake123";
            File.WriteAllText(Opt(a, "--bridge-token-file"), "heimdall-bridge-credential/v1 fake " + bridgeId + "\n");
            string config = Opt(a, "--config");
            string text = File.ReadAllText(config);
            if (text.IndexOf("daemon_id", StringComparison.Ordinal) < 0)
                File.WriteAllText(config, text.Replace("[daemon]", "[daemon]\ndaemon_id = \"" + bridgeId + "\""));
            Console.WriteLine("  Pairing code:");
            Console.WriteLine("    ABCD-EFGH-JKLM-NP");
            return 0;
        }
        if (name == "ham-bridge") {
            var l = new TcpListener(IPAddress.Loopback, int.Parse(Opt(a, "--port")));
            l.Start();
            while (true) l.AcceptTcpClient().Close();
        }
        return 0;
    }

    static void Serve(int port, string root) {
        var l = new TcpListener(IPAddress.Loopback, port);
        l.Start();
        while (true) {
            using (var c = l.AcceptTcpClient()) {
                try { Answer(c.GetStream(), root); } catch (Exception) { }
            }
        }
    }

    static void Answer(NetworkStream s, string root) {
        var head = new StringBuilder();
        var buf = new byte[1];
        while (!head.ToString().EndsWith("\r\n\r\n") && head.Length < 16384) {
            if (s.Read(buf, 0, 1) != 1) return;
            head.Append((char)buf[0]);
        }
        var parts = head.ToString().Split(' ');
        string path = parts.Length > 1 ? Uri.UnescapeDataString(parts[1].Split('?')[0]) : "/";
        byte[] body = null;
        int code = 404;
        if (path == "/api/v1/health") { body = Encoding.ASCII.GetBytes("{\"ok\":true}"); code = 200; }
        else if (root != null && path.IndexOf("..", StringComparison.Ordinal) < 0) {
            string f = Path.Combine(root, path.TrimStart('/').Replace('/', '\\'));
            if (File.Exists(f)) { body = File.ReadAllBytes(f); code = 200; }
        }
        if (body == null) body = Encoding.ASCII.GetBytes("not found");
        var h = Encoding.ASCII.GetBytes("HTTP/1.1 " + code + (code == 200 ? " OK" : " Not Found") + "\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n");
        s.Write(h, 0, h.Length);
        s.Write(body, 0, body.Length);
    }
}
