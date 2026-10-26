# Run with: pwsh -NoProfile -File windows/scripts/tests/assert-hz.test.ps1
# Exercise the real refresh repair with only the three native CCD calls
# replaced, so this runs without changing a desktop (including on macOS).
$ErrorActionPreference = 'Stop'
$script = Get-Content (Join-Path $PSScriptRoot '..\assert-hz.ps1') -Raw
$source = [regex]::Match($script, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $source) { throw 'CcdHz type definition not found' }
$native = @{
    GetDisplayConfigBufferSizes = @'
    public static int GetDisplayConfigBufferSizes(uint flags, out uint np, out uint nm) {
        np = TestNative.Count; nm = np * 2; return 0;
    }
'@
    QueryDisplayConfig = @'
    public static int QueryDisplayConfig(uint flags, ref uint np, PATH_INFO[] paths,
        ref uint nm, MODE_INFO[] modes, IntPtr topology) {
        for (int i = 0; i < np; i++) {
            paths[i].sourceInfo.adapterId.LowPart = 42;
            paths[i].sourceInfo.id = (uint)i;
            paths[i].sourceInfo.modeInfoIdx = (uint)(i * 2 + 1);
            paths[i].targetInfo.adapterId.LowPart = 42;
            paths[i].targetInfo.id = (uint)(10 + i);
            paths[i].targetInfo.modeInfoIdx = (uint)(i * 2);
            paths[i].targetInfo.refreshRate.Numerator = 60000;
            paths[i].targetInfo.refreshRate.Denominator = 1001;
            paths[i].flags = 1;
            byte[] bytes = new byte[64];
            TestNative.Write(bytes, 0, 1); // DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE
            TestNative.Write(bytes, 4, i);
            TestNative.Write(bytes, 8, 42); // adapter LUID
            TestNative.Write(bytes, 16, 2560); // source width
            TestNative.Write(bytes, 20, 1440); // source height
            TestNative.Write(bytes, 24, 4); // DISPLAYCONFIG_PIXELFORMAT_32BPP
            TestNative.Write(bytes, 28, i == 0 ? TestNative.X : 0);
            TestNative.Write(bytes, 32, 0);
            IntPtr ptr = Marshal.AllocHGlobal(64);
            try {
                Marshal.Copy(bytes, 0, ptr, 64);
                modes[i * 2 + 1] = (MODE_INFO)Marshal.PtrToStructure(ptr, typeof(MODE_INFO));
            } finally { Marshal.FreeHGlobal(ptr); }
        }
        return 0;
    }
'@
    SetDisplayConfig = @'
    public static int SetDisplayConfig(uint np, PATH_INFO[] paths, uint nm,
        MODE_INFO[] modes, uint flags) {
        TestNative.Paths = paths; TestNative.Modes = modes; TestNative.ModeCount = nm;
        return 0;
    }
'@
}
foreach ($name in $native.Keys) {
    $pattern = '(?s)\[DllImport\("user32.dll"\)\]\s+public static extern int ' + $name + '\(.*?;'
    if ([regex]::Matches($source, $pattern).Count -ne 1) { throw "Native boundary not found: $name" }
    $source = [regex]::Replace($source, $pattern, $native[$name])
}
$source += @'

public static class TestNative {
    public static uint Count;
    public static int X;
    public static uint ModeCount;
    public static CcdHz.PATH_INFO[] Paths;
    public static CcdHz.MODE_INFO[] Modes;
    public static void Write(byte[] bytes, int offset, int value) {
        Array.Copy(BitConverter.GetBytes(value), 0, bytes, offset, 4);
    }
    public static int ReadMode(int index, int offset) {
        IntPtr ptr = Marshal.AllocHGlobal(64);
        try {
            Marshal.StructureToPtr(Modes[index], ptr, false);
            return Marshal.ReadInt32(ptr, offset);
        } finally { Marshal.FreeHGlobal(ptr); }
    }
}
'@
Add-Type -TypeDefinition $source

function Equal($actual, $expected, $message) {
    if ($actual -ne $expected) { throw "${message}: expected $expected, got $actual" }
}
foreach ($case in @(
    @{ Name = 'normal'; Count = 2; X = -2560 },
    @{ Name = 'flipped'; Count = 2; X = 2560 },
    @{ Name = 'single display'; Count = 1; X = 0 }
)) {
    [TestNative]::Count = $case.Count
    [TestNative]::X = $case.X
    Equal ([CcdHz]::Assert(155)) 0 "$($case.Name) API result"
    Equal ([TestNative]::ModeCount) ($case.Count * 2) "$($case.Name) supplies current modes"
    for ($i = 0; $i -lt $case.Count; $i++) {
        $path = [TestNative]::Paths[$i]
        Equal $path.sourceInfo.modeInfoIdx ($i * 2 + 1) 'Source mode remains attached'
        Equal $path.targetInfo.modeInfoIdx ([uint32]::MaxValue) 'Target timing is recalculated'
        Equal $path.targetInfo.refreshRate.Numerator 155 'Requested refresh numerator'
        Equal $path.targetInfo.refreshRate.Denominator 1 'Requested refresh denominator'
        Equal ([TestNative]::ReadMode($i * 2 + 1, 16)) 2560 'Source width survives marshalling'
        Equal ([TestNative]::ReadMode($i * 2 + 1, 20)) 1440 'Source height survives marshalling'
        $wantX = if ($i -eq 0) { $case.X } else { 0 }
        Equal ([TestNative]::ReadMode($i * 2 + 1, 28)) $wantX 'Monitor position survives marshalling'
    }
    "PASS: $($case.Name) retains position while requesting 155 Hz"
}
