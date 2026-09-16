<#
  set-endpoint-volume.ps1 -Match <friendly-name-substring> -Percent <0-100>
  Sets a render endpoint's master volume. Prints old -> new.
#>
param([Parameter(Mandatory)][string]$Match, [Parameter(Mandatory)][int]$Percent)
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32;
namespace CAV {
  public enum EDataFlow { eRender, eCapture, eAll }
  public enum ERole { eConsole, eMultimedia, eCommunications }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class MMDeviceEnumeratorCom {}
  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IMMDeviceCollection devices);
    int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice device);
    int GetDevice(string id, out IMMDevice device);
  }
  [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IMMDeviceCollection { int GetCount(out int count); int Item(int index, out IMMDevice device); }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IMMDevice {
    int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    int OpenPropertyStore(int stgmAccess, out IntPtr props);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetState(out int state);
  }
  [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IAudioEndpointVolume {
    int RegisterControlChangeNotify(IntPtr n); int UnregisterControlChangeNotify(IntPtr n);
    int GetChannelCount(out int c);
    int SetMasterVolumeLevel(float db, ref Guid ctx);
    int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
    int GetMasterVolumeLevel(out float db);
    int GetMasterVolumeLevelScalar(out float level);
  }
  public static class Vol {
    static Guid IID_Vol = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
    static string FriendlyName(string id) {
      string[] parts = id.Split('.'); string guid = parts[parts.Length - 1];
      using (RegistryKey k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\" + guid + @"\Properties")) {
        if (k != null) {
          object n = k.GetValue("{a45c254e-df1c-4efd-8020-67d146a850e0},14");
          if (n == null) n = k.GetValue("{a45c254e-df1c-4efd-8020-67d146a850e0},2");
          if (n != null) return n.ToString();
        }
      }
      return id;
    }
    public static string Set(string match, int percent) {
      IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
      IMMDeviceCollection col; en.EnumAudioEndpoints(EDataFlow.eRender, 1, out col);
      int n; col.GetCount(out n);
      for (int i = 0; i < n; i++) {
        IMMDevice dev; col.Item(i, out dev);
        string id; dev.GetId(out id);
        string name = FriendlyName(id);
        if (name.IndexOf(match, StringComparison.OrdinalIgnoreCase) < 0 && id.IndexOf(match, StringComparison.OrdinalIgnoreCase) < 0) continue;
        object o; dev.Activate(ref IID_Vol, 23, IntPtr.Zero, out o);
        IAudioEndpointVolume v = (IAudioEndpointVolume)o;
        float old; v.GetMasterVolumeLevelScalar(out old);
        float oldDb; v.GetMasterVolumeLevel(out oldDb);
        Guid ctx = Guid.Empty;
        v.SetMasterVolumeLevelScalar(percent / 100f, ref ctx);
        float now; v.GetMasterVolumeLevelScalar(out now);
        float nowDb; v.GetMasterVolumeLevel(out nowDb);
        return name + ": " + (int)(old * 100) + "% (" + oldDb.ToString("N1") + " dB) -> " + (int)(now * 100) + "% (" + nowDb.ToString("N1") + " dB)";
      }
      return "no active render endpoint matches '" + match + "'";
    }
  }
}
"@
[CAV.Vol]::Set($Match, $Percent)
