// DSH 浏览器 - 关闭监视器
// 等待 DSH 浏览器窗口进程退出，然后停止 DSH 服务（Node.js）。
// 编译（Windows 自带 .NET Framework 4.x）：
//   csc.exe /nologo /target:winexe /optimize+ /codepage:65001 /out:watchdog.exe /win32icon:DSH.ico watchdog.cs
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
        WriteFlag(true, browserPid);
        try
        {
            // 2) 找到要停止的服务进程，并校验它确实是 node（避免 PID 复用/端口被占用时误杀）
            int target = -1;
            if (serverPid > 0)
            {
                if (IsNodeProcess(serverPid)) { target = serverPid; }
                else { Log("记录的服务 PID " + serverPid + " 已不是 node 进程（可能被复用），改为按端口查找"); }
            }
            if (target <= 0) { target = FindListenerPid(port); }
            if (target <= 0)
            {
                Log("没有找到端口 " + port + " 上的服务进程，可能已经停止");
                return 0;
            }
            if (!IsNodeProcess(target))
            {
                Log("端口 " + port + " 上的进程 PID " + target + " 不是 node/DSH 服务，已跳过停止（避免误杀）");
                return 0;
            }

            // 3) 停止服务进程树，并确认端口释放
            Log("正在停止 DSH 服务进程树（PID " + target + "）");
            KillTree(target);
            for (int i = 0; i < 32; i++)
            {
                Thread.Sleep(250);
                int still = FindListenerPid(port);
                if (still <= 0)
                {
                    Log("DSH 服务已停止，端口 " + port + " 已释放");
                    return 0;
                }
                if (still != target && !IsNodeProcess(still))
                {
                    Log("端口 " + port + " 已被其它进程占用，停止继续操作");
                    return 0;
                }
            }
            // 兜底：再按端口找一次，仅当仍是 node 进程才强杀
            int again = FindListenerPid(port);
            if (again > 0 && IsNodeProcess(again))
            {
                Log("服务仍在运行，再次停止 PID " + again);
                KillTree(again);
            }
            Thread.Sleep(800);
            if (FindListenerPid(port) <= 0) { Log("DSH 服务已停止，端口 " + port + " 已释放"); }
            else { Log("警告：端口 " + port + " 仍在监听，请手动检查"); }
            return 0;
        }
        finally
        {
            WriteFlag(false, 0);
        }
    }

    private static bool IsNodeProcess(int pid)
    {
        try
        {
            using (Process p = Process.GetProcessById(pid))
            {
                return string.Equals(p.ProcessName, "node", StringComparison.OrdinalIgnoreCase);
            }
        }
        catch { return false; }
    }

    // 先托管 Kill（不依赖外部 taskkill，避免在无控制台/Job 环境下挂起），再用 taskkill /T 兜底清理子进程树
    private static void KillTree(int pid)
    {
        try
        {
            using (Process p = Process.GetProcessById(pid))
            {
                try { p.Kill(); } catch { }
                try { p.WaitForExit(5000); } catch { }
            }
        }
        catch { }
        try
        {
            var psi = new ProcessStartInfo("taskkill.exe", "/PID " + pid + " /T /F")
            {
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using (Process k = Process.Start(psi)) { try { k.WaitForExit(4000); } catch { } }
        }
        catch { }
    }

    private static void WriteFlag(bool create, int browserPid)
    {
        if (string.IsNullOrEmpty(_flagPath)) return;
        try
        {
            if (create)
            {
                // 写入“浏览器 PID + 时间戳”，便于 launcher 判断是否陈旧
                File.WriteAllText(_flagPath, browserPid + Environment.NewLine + DateTime.Now.ToString("o"));
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
}
