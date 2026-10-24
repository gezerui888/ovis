using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Ovis
{
    internal struct RunResult
    {
        public int Status;
        public string Output;
    }

    /// <summary>
    /// Runs what a terminal user would run. Every program goes through cmd.exe, which finds it on PATH as a
    /// terminal does (bun.exe or a bun.cmd shim alike), and which is started with the desktop app breakaway
    /// policy: from the Store's MSIX, whatever cmd starts runs outside the package, so herdr, Bun and the
    /// installer write to the user's real AppData, and a herdr server outlives an update or removal of the app.
    /// Outside a package the policy changes nothing.
    /// </summary>
    internal static class Run
    {
        /// <summary>Runs a program to its end with an empty stdin, so nothing it runs can wait for an answer.</summary>
        public static Task<RunResult> Program(string program, IEnumerable<string> arguments, Action<string> onLine = null, bool keepStderr = true)
        {
            return Task.Run(() => RunToEnd(CommandLine(program, arguments), onLine, keepStderr));
        }

        /// <summary>Starts a program that keeps running (herdr's server), with no window and nothing tied to this app.</summary>
        public static void Detached(string program, IEnumerable<string> arguments)
        {
            // start /b: cmd hands the program its own hidden console and exits, so no cmd lives on beside it
            var command = "start \"\" /b " + CommandLine(program, arguments);
            var process = Create("/d /s /c \"" + command + "\"", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            process.WaitForExit(10000);
            process.Dispose();
        }

        public static string Quote(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new[] { ' ', '\t', '"', '&', '|', '<', '>', '^', '(', ')' }) < 0) return argument;
            return "\"" + argument.Replace("\"", "\\\"") + "\"";
        }

        private static string CommandLine(string program, IEnumerable<string> arguments)
        {
            return string.Join(" ", new[] { Quote(program) }.Concat(arguments.Select(Quote)));
        }

        private static RunResult RunToEnd(string command, Action<string> onLine, bool keepStderr)
        {
            var lines = new List<string>();
            var security = new SecurityAttributes { Length = Marshal.SizeOf(typeof(SecurityAttributes)), Inherit = 1 };
            IntPtr read, write;
            if (!CreatePipe(out read, out write, ref security, 0)) return Failed(new Win32Exception().Message);
            // only the child gets the pipe's write end and the empty stdin
            SetHandleInformation(read, HandleFlagInherit, 0);
            var input = CreateFile("NUL", GenericRead, 3, ref security, OpenExisting, 0, IntPtr.Zero);
            var error = keepStderr ? write : CreateFile("NUL", GenericWrite, 3, ref security, OpenExisting, 0, IntPtr.Zero);
            ChildProcess process;
            try
            {
                process = Create("/d /s /c \"" + command + "\"", input, write, error);
            }
            catch (Win32Exception exception)
            {
                CloseHandle(read);
                return Failed(exception.Message);
            }
            finally
            {
                CloseHandle(write);
                CloseHandle(input);
                if (!keepStderr) CloseHandle(error);
            }
            var stream = new FileStream(new SafeFileHandle(read, true), FileAccess.Read);
            var reader = new Thread(() =>
            {
                try
                {
                    using (var text = new StreamReader(stream, new UTF8Encoding(false)))
                    {
                        string line;
                        while ((line = text.ReadLine()) != null)
                        {
                            line = line.Replace("\r", "");
                            lock (lines) lines.Add(line);
                            if (onLine != null) onLine(line);
                        }
                    }
                }
                catch (IOException) { } // closed below when a child the program left behind still holds the pipe
                catch (ObjectDisposedException) { }
            }) { IsBackground = true };
            reader.Start();
            process.WaitForExit(Timeout.Infinite);
            // A background child the program started (the installer's server) can hold the pipe open for good:
            // wait for the rest of the output, but briefly.
            if (!reader.Join(2000)) stream.Dispose();
            var status = process.ExitCode;
            process.Dispose();
            lock (lines) return new RunResult { Status = status, Output = string.Join("\n", lines) };
        }

        private static RunResult Failed(string message)
        {
            return new RunResult { Status = -1, Output = message };
        }

        private sealed class ChildProcess : IDisposable
        {
            public IntPtr Handle;

            public void WaitForExit(int milliseconds)
            {
                WaitForSingleObject(Handle, unchecked((uint)milliseconds));
            }

            public int ExitCode
            {
                get
                {
                    int code;
                    return GetExitCodeProcess(Handle, out code) ? code : -1;
                }
            }

            public void Dispose()
            {
                if (Handle != IntPtr.Zero) CloseHandle(Handle);
                Handle = IntPtr.Zero;
            }
        }

        private static ChildProcess Create(string arguments, IntPtr input, IntPtr output, IntPtr error)
        {
            var comspec = Environment.GetEnvironmentVariable("ComSpec") ?? Path.Combine(Environment.SystemDirectory, "cmd.exe");
            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            var list = Marshal.AllocHGlobal(size);
            var policy = Marshal.AllocHGlobal(4);
            try
            {
                if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) throw new Win32Exception();
                Marshal.WriteInt32(policy, BreakawayEnableProcessTree);
                if (!UpdateProcThreadAttribute(list, 0, (IntPtr)DesktopAppPolicyAttribute, policy, (IntPtr)4, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
                var startup = new StartupInfoEx();
                startup.StartupInfo.Size = Marshal.SizeOf(typeof(StartupInfoEx));
                startup.AttributeList = list;
                var redirect = output != IntPtr.Zero;
                if (redirect)
                {
                    startup.StartupInfo.Flags = UseStdHandles;
                    startup.StartupInfo.Input = input;
                    startup.StartupInfo.Output = output;
                    startup.StartupInfo.Error = error;
                }
                ProcessInformation info;
                var commandLine = new StringBuilder(Quote(comspec) + " " + arguments);
                if (!CreateProcess(comspec, commandLine, IntPtr.Zero, IntPtr.Zero, redirect, ExtendedStartupInfoPresent | CreateNoWindow | CreateUnicodeEnvironment,
                        IntPtr.Zero, null, ref startup, out info)) throw new Win32Exception();
                CloseHandle(info.Thread);
                return new ChildProcess { Handle = info.Process };
            }
            finally
            {
                DeleteProcThreadAttributeList(list);
                Marshal.FreeHGlobal(list);
                Marshal.FreeHGlobal(policy);
            }
        }

        private const int DesktopAppPolicyAttribute = 0x00020012; // PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY
        private const int BreakawayEnableProcessTree = 0x01; // PROCESS_CREATION_DESKTOP_APP_BREAKAWAY_ENABLE_PROCESS_TREE
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint CreateNoWindow = 0x08000000;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const int UseStdHandles = 0x00000100;
        private const uint HandleFlagInherit = 1;
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint OpenExisting = 3;

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr Descriptor;
            public int Inherit;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved, Desktop, Title;
            public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
            public short ShowWindow, Reserved2;
            public IntPtr Reserved3, Input, Output, Error;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process, Thread;
            public int ProcessId, ThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SecurityAttributes attributes, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFile(string name, uint access, uint share, ref SecurityAttributes attributes, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr list);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcess(string application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
            bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInformation info);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out int code);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
