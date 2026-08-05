# Deployed to C:\Tools\MultiMonitorTool\assert-hz.ps1 on VENGEANCE.
# Run by the mon-assert scheduled task, chained by monitor-mode.sh's
# sync_windows() after every topology task (mon-extend / mon-only3/4).
#
# Re-assert max refresh after monitor topology changes. Topology tasks
# (MultiMonitorTool /disable, SetDisplayConfig extend) make Windows fall back
# to the EDID preferred timing (native @ 59.95) — it treats the display as
# newly arrived and ignores the saved 155 Hz mode.
#
# Two-layer quirk, learned the hard way:
#  - CHECK must use GDI (EnumDisplaySettings) — that's the layer that falls
#    back to 59; the CCD path refresh can keep reading 154.846 while GDI
#    reports 59, so polling CCD misses the fallback entirely.
#  - SET must use CCD (SetDisplayConfig) — the legacy ChangeDisplaySettingsEx
#    gets DISP_CHANGE_FAILED from the NVIDIA driver in single-display
#    topologies, while the CCD apply (what the Settings app uses) works and
#    updates GDI too.
# Multi-pass because the caller's topology task races us: its fallback can
# land after our first assert.
param([uint32]$Hz = 155)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CcdHz {
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RATIONAL { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_SOURCE_INFO {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_TARGET_INFO {
        public LUID adapterId; public uint id; public uint modeInfoIdx;
        public uint outputTechnology; public uint rotation; public uint scaling;
        public RATIONAL refreshRate; public uint scanLineOrdering;
        public int targetAvailable; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_INFO {
        public PATH_SOURCE_INFO sourceInfo;
        public PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Explicit, Size = 64)]
    public struct MODE_INFO {
        [FieldOffset(0)] public uint infoType;
        [FieldOffset(4)] public uint id;
        [FieldOffset(8)] public LUID adapterId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY;
        public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DISPLAY_DEVICE {
        public uint cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);

    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH_INFO[] paths,
        ref uint numModes, [Out] MODE_INFO[] modes, IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint numPaths, PATH_INFO[] paths, uint numModes,
        MODE_INFO[] modes, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplayDevices(string device, uint devNum, ref DISPLAY_DEVICE dd, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    public const uint QDC_ONLY_ACTIVE_PATHS = 2;
    public const uint IDX_INVALID = 0xFFFFFFFF;
    public const uint ATTACHED_TO_DESKTOP = 0x1;
    public const int ENUM_CURRENT_SETTINGS = -1;
    // SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES
    public const uint SDC_FLAGS = 0x80u | 0x20u | 0x200u | 0x400u;

    // Min refresh across desktop-attached displays, per GDI — the layer
    // that shows the 59 Hz fallback.
    public static int GdiMinHz() {
        int min = int.MaxValue;
        DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
        dd.cb = (uint)Marshal.SizeOf(dd);
        for (uint i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++) {
            if ((dd.StateFlags & ATTACHED_TO_DESKTOP) != 0) {
                DEVMODE dm = new DEVMODE();
                dm.dmSize = (ushort)Marshal.SizeOf(dm);
                if (EnumDisplaySettings(dd.DeviceName, ENUM_CURRENT_SETTINGS, ref dm) &&
                    dm.dmDisplayFrequency > 1 && dm.dmDisplayFrequency < min)
                    min = (int)dm.dmDisplayFrequency;
            }
            dd = new DISPLAY_DEVICE();
            dd.cb = (uint)Marshal.SizeOf(dd);
        }
        return min == int.MaxValue ? -1 : min;
    }

    public static int Assert(uint hz) {
        uint np, nm;
        int rc = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out np, out nm);
        if (rc != 0) return rc;
        PATH_INFO[] paths = new PATH_INFO[np];
        MODE_INFO[] modes = new MODE_INFO[nm];
        rc = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero);
        if (rc != 0) return rc;
        for (int i = 0; i < np; i++) {
            paths[i].targetInfo.refreshRate.Numerator = hz;
            paths[i].targetInfo.refreshRate.Denominator = 1;
            paths[i].targetInfo.modeInfoIdx = IDX_INVALID;
            paths[i].sourceInfo.modeInfoIdx = IDX_INVALID;
        }
        return SetDisplayConfig(np, paths, 0, null, SDC_FLAGS);
    }
}
'@

foreach ($pass in 1..6) {
    Start-Sleep -Milliseconds 2500
    $gdi = [CcdHz]::GdiMinHz()
    "pass ${pass}: GDI min refresh $gdi"
    if ($gdi -lt 0 -or $gdi -ge ($Hz - 1)) { continue }
    $rc = [CcdHz]::Assert($Hz)
    "pass ${pass}: CCD assert ${Hz}Hz rc=$rc"
}
