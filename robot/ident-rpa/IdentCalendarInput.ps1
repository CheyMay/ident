function Initialize-IdentCalendarInput {
    if ('Code9.CalendarInputGuard' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
namespace Code9 {
    // Supervised single right-click only. No keyboard injection, left-click, drag, or input blocking.
    public sealed class CalendarInputGuard : IDisposable {
        [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct MouseInput {
            public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra;
        }
        [StructLayout(LayoutKind.Sequential)] public struct Input { public uint Type; public MouseInput Mouse; }
        [StructLayout(LayoutKind.Sequential)] struct MouseEvent {
            public Point Position; public uint Data, Flags, Time; public UIntPtr Extra;
        }
        [StructLayout(LayoutKind.Sequential)] struct Message {
            public IntPtr Window; public uint Id; public UIntPtr WParam; public IntPtr LParam;
            public uint Time; public Point Position; public uint Private;
        }
        [StructLayout(LayoutKind.Sequential)] struct LastInput { public uint Size, Time; }
        delegate IntPtr Hook(int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetWindowsHookEx(int id, Hook callback, IntPtr module, uint thread);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll")] static extern int GetMessage(out Message message, IntPtr window, uint min, uint max);
        [DllImport("user32.dll")] static extern bool PeekMessage(out Message message, IntPtr window, uint min, uint max, uint remove);
        [DllImport("user32.dll")] static extern bool TranslateMessage(ref Message message);
        [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Message message);
        [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, uint id, UIntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll")] static extern uint SendInput(uint count, Input[] inputs, int size);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInput input);
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        readonly Thread thread;
        readonly ManualResetEvent started = new ManualResetEvent(false);
        readonly Hook mouseCallback, keyboardCallback;
        readonly UIntPtr tag;
        IntPtr mouseHook, keyboardHook;
        uint threadId;
        volatile bool ready;
        volatile uint lastOwnTick;
        int foreignEvents, ownEvents, clicked, disposed;
        public bool Ready { get { return ready && thread.IsAlive && Volatile.Read(ref disposed)==0; } }
        public int ForeignEvents { get { return Volatile.Read(ref foreignEvents); } }
        public uint LastOwnTick { get { return lastOwnTick; } }
        public CalendarInputGuard() {
            tag=new UIntPtr(unchecked((uint)Guid.NewGuid().GetHashCode()) | 0x80000000U);
            mouseCallback=Mouse; keyboardCallback=Keyboard;
            thread=new Thread(Loop); thread.IsBackground=true; thread.Name="IDENT supervised input guard";
            thread.Start();
            if (!started.WaitOne(3000) || !Ready) { Dispose(); throw new InvalidOperationException("CALENDAR_INPUT_GUARD"); }
        }
        IntPtr Mouse(int code, IntPtr message, IntPtr data) {
            if (code>=0) {
                MouseEvent value=(MouseEvent)Marshal.PtrToStructure(data,typeof(MouseEvent));
                if ((value.Flags & 1)!=0 && value.Extra==tag) { lastOwnTick=value.Time; Interlocked.Increment(ref ownEvents); }
                else { Interlocked.Increment(ref foreignEvents); }
            }
            return CallNextHookEx(IntPtr.Zero,code,message,data);
        }
        IntPtr Keyboard(int code, IntPtr message, IntPtr data) {
            if (code>=0) Interlocked.Increment(ref foreignEvents);
            return CallNextHookEx(IntPtr.Zero,code,message,data);
        }
        void Loop() {
            try {
                threadId=GetCurrentThreadId(); Message message;
                PeekMessage(out message,IntPtr.Zero,0,0,0);
                IntPtr module=GetModuleHandle(null);
                mouseHook=SetWindowsHookEx(14,mouseCallback,module,0);
                keyboardHook=SetWindowsHookEx(13,keyboardCallback,module,0);
                ready=mouseHook!=IntPtr.Zero && keyboardHook!=IntPtr.Zero;
                started.Set();
                if (ready) while(GetMessage(out message,IntPtr.Zero,0,0)>0) {
                    TranslateMessage(ref message); DispatchMessage(ref message);
                }
            } catch { ready=false; started.Set(); }
            finally {
                ready=false;
                if (mouseHook!=IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
                if (keyboardHook!=IntPtr.Zero) UnhookWindowsHookEx(keyboardHook);
            }
        }
        public static uint InputTick() {
            LastInput input=new LastInput(); input.Size=(uint)Marshal.SizeOf(typeof(LastInput));
            if (!GetLastInputInfo(ref input)) throw new InvalidOperationException("CALENDAR_INPUT_GUARD");
            return input.Time;
        }
        public static int NormalizeCoordinate(int value, int origin, int size) {
            if (size<2 || size>65536 || value<origin || (long)value>=(long)origin+size) throw new ArgumentOutOfRangeException("value");
            return (int)Math.Floor(((double)value-origin+0.5)*65536.0/size);
        }
        public static bool NoKeysDown() {
            for(int key=1;key<255;key++) if((GetAsyncKeyState(key) & 0x8000)!=0) return false;
            return true;
        }
        public void AssertUntouched(uint expectedTick) {
            if (!Ready || ForeignEvents!=0 || InputTick()!=expectedTick) throw new InvalidOperationException("CALENDAR_USER_ACTIVE");
        }
        public void RightClick(int x, int y, long expectedWindow, int expectedProcess, uint expectedTick) {
            AssertUntouched(expectedTick);
            if (Interlocked.CompareExchange(ref clicked,1,0)!=0) throw new InvalidOperationException("CALENDAR_NO_RETRY");
            IntPtr window=new IntPtr(expectedWindow); uint process;
            GetWindowThreadProcessId(window,out process);
            Point point=new Point(); point.X=x; point.Y=y;
            if (process!=(uint)expectedProcess || GetForegroundWindow()!=window ||
                GetAncestor(WindowFromPoint(point),2)!=window || !NoKeysDown()) throw new InvalidOperationException("CALENDAR_WINDOW_CHANGED");
            int nx=NormalizeCoordinate(x,GetSystemMetrics(76),GetSystemMetrics(78));
            int ny=NormalizeCoordinate(y,GetSystemMetrics(77),GetSystemMetrics(79));
            Input move=new Input(); move.Mouse.X=nx; move.Mouse.Y=ny; move.Mouse.Flags=0xE001; move.Mouse.Extra=tag;
            Input down=new Input(); down.Mouse.Flags=8; down.Mouse.Extra=tag;
            Input up=new Input(); up.Mouse.Flags=16; up.Mouse.Extra=tag;
            AssertUntouched(expectedTick);
            uint sent=SendInput(3,new Input[]{move,down,up},Marshal.SizeOf(typeof(Input)));
            if(sent!=3) {
                // Release only our potentially injected right-down. Never retry the click or move the pointer back.
                if(sent==2) SendInput(1,new Input[]{up},Marshal.SizeOf(typeof(Input)));
                throw new InvalidOperationException("CALENDAR_INPUT_FAILED");
            }
            for(int i=0;i<100 && Volatile.Read(ref ownEvents)<3;i++) Thread.Sleep(10);
            if(Volatile.Read(ref ownEvents)!=3) throw new InvalidOperationException("CALENDAR_INPUT_FAILED");
            AssertUntouched(lastOwnTick);
        }
        public void Dispose() {
            if(Interlocked.Exchange(ref disposed,1)!=0) return;
            if(threadId!=0) PostThreadMessage(threadId,0x12,UIntPtr.Zero,IntPtr.Zero);
            if(thread.IsAlive) thread.Join(1500);
            if(!thread.IsAlive) started.Dispose();
            GC.KeepAlive(mouseCallback); GC.KeepAlive(keyboardCallback);
        }
    }
}
'@
}
