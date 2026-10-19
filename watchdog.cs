// DSH 浏览器 - 关闭监视器
// 等待 DSH 浏览器窗口进程退出，然后停止 DSH 服务（Node.js）。
// 编译：csc.exe /nologo /target:winexe /out:watchdog.exe /win32icon:DSH.ico watchdog.cs
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

internal static class Program
{
    private static string _logPath;
    private static string _flagPath;

    private static void Log(string message)
    {
        try
        {
            if (string.IsNullOrEmpty(_logPath)) return;
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  [监视器] " + message + Environment.NewLine;
            File.AppendAllText(_logPath, line, System.Text.Encoding.UTF8);
        }
        catch { }
    }

    private static int Main(string[] args)
    {
        int browserPid = -1;
        int port = 0;
        int serverPid = -1;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--browser-pid": if (i + 1 < args.Length) int.TryParse(args[++i], out browserPid); break;
                case "--port": if (i + 1 < args.Length) int.TryParse(args[++i], out port); break;
                case "--server-pid": if (i + 1 < args.Length) int.TryParse(args[++i], out serverPid); break;
                case "--log": if (i + 1 < args.Length) _logPath = args[++i]; break;
                case "--flag-file": if (i + 1 < args.Length) _flagPath = args[++i]; break;
            }
        }
        if (browserPid <= 0 || port <= 0) return 2;

        // 1) 等浏览器进程退出
        try
        {
            Process browser = Process.GetProcessById(browserPid);
            browser.WaitForExit();
        }
        catch
        {
            // 进程不存在（可能已退出或启动失败）
        }
        Log("浏览器已退出，准备停止 DSH 服务（端口 " + port + "）");
        Thread.Sleep(1500);
        WriteFlag(true);
        try
        {
        // 2) 找到要停止的服务进程
        int target = -1;
        if (serverPid > 0)
        {
            try { Process.GetProcessById(serverPid); target = serverPid; }
            catch { target = -1; }
        }
        if (target <= 0)
        {
            target = FindListenerPid(port);
        }
        if (target <= 0)
        {
            Log("没有找到端口 " + port + " 上的服务进程，可能已经停止");
            return 0;
        }

        // 3) 停止服务进程树，并确认端口释放
        Log("正在停止 DSH 服务进程树（PID " + target + "）");
        Run("taskkill.exe", "/PID " + target + " /T /F");
        for (int i = 0; i < 20; i++)
        {
            Thread.Sleep(250);
            if (FindListenerPid(port) <= 0)
            {
                Log("DSH 服务已停止，端口 " + port + " 已释放");
                return 0;
            }
        }
        // 兜底：再按端口找一次并强杀
        int again = FindListenerPid(port);
        if (again > 0)
        {
            Log("服务仍在运行，再次停止 PID " + again);
            Run("taskkill.exe", "/PID " + again + " /T /F");
        }
        Thread.Sleep(500);
        if (FindListenerPid(port) <= 0) Log("DSH 服务已停止，端口 " + port + " 已释放");
        else Log("警告：端口 " + port + " 仍在监听，请手动检查");
        return 0;
        }
        finally
        {
            WriteFlag(false);
        }
    }

    private static void WriteFlag(bool create)
    {
        if (string.IsNullOrEmpty(_flagPath)) return;
        try
        {
            if (create)
            {
                File.WriteAllText(_flagPath, DateTime.Now.ToString("o"));
            }
            else if (File.Exists(_flagPath))
            {
                File.Delete(_flagPath);
            }
        }
        catch { }
    }

    private static int FindListenerPid(int port)
    {
        try
        {
            var psi = new ProcessStartInfo("netstat.exe", "-ano")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true
            };
            using (Process p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(5000);
                foreach (string raw in output.Split('\n'))
                {
                    string line = raw.Trim();
                    if (line.Length == 0) continue;
                    if (line.IndexOf("LISTENING", StringComparison.OrdinalIgnoreCase) < 0) continue;
                    string[] parts = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length < 5) continue;
                    if (!parts[1].EndsWith(":" + port)) continue;
                    int pid;
                    if (int.TryParse(parts[parts.Length - 1], out pid)) return pid;
                }
            }
        }
        catch { }
        return -1;
    }

    private static void Run(string exe, string arguments)
    {
        try
        {
            var psi = new ProcessStartInfo(exe, arguments)
            {
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using (Process p = Process.Start(psi)) { p.WaitForExit(8000); }
        }
        catch { }
    }
}
