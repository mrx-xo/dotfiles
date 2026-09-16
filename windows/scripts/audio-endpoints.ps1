<#
  audio-endpoints.ps1
  Diagnostic: list active Windows render endpoints (name, id, master volume, mute)
  and, per endpoint, the audio sessions on it (process, state, session volume).
  CoreAudio COM via Add-Type; PS 5.1 / C# 5 compatible. All COM work stays in C#.

  Why it exists: SteelSeries Sonar's channel sliders (Gaming/Media/Chat) ARE the
  Windows master volume of the matching "SteelSeries Sonar - <channel>" virtual
  endpoint, and OBS's wasapi_output_capture sees that endpoint post-volume. A
  Gaming channel at 10% therefore records clips ~35 dB too quiet. Keep Gaming at
  100% and set listening loudness on the real output (Speakers) instead; see
  set-endpoint-volume.ps1. Over SSH the per-app sessions of the desktop logon are
  not visible (only audiodg/system sounds), and live meters are unavailable.
#>
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace CA {
  public enum EDataFlow { eRender, eCapture, eAll }
  public enum ERole { eConsole, eMultimedia, eCommunications }

  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
  public class MMDeviceEnumeratorCom {}

  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IMMDeviceCollection devices);
    int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice device);
    int GetDevice(string id, out IMMDevice device);
  }
  [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IMMDeviceCollection {
    int GetCount(out int count);
    int Item(int index, out IMMDevice device);
  }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IMMDevice {
    int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    int OpenPropertyStore(int stgmAccess, out IntPtr props);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetState(out int state);
  }
  [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IAudioEndpointVolume {
    int RegisterControlChangeNotify(IntPtr n);
    int UnregisterControlChangeNotify(IntPtr n);
    int GetChannelCount(out int c);
    int SetMasterVolumeLevel(float db, ref Guid ctx);
    int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
    int GetMasterVolumeLevel(out float db);
    int GetMasterVolumeLevelScalar(out float level);
    int SetChannelVolumeLevel(int ch, float db, ref Guid ctx);
    int SetChannelVolumeLevelScalar(int ch, float level, ref Guid ctx);
    int GetChannelVolumeLevel(int ch, out float db);
    int GetChannelVolumeLevelScalar(int ch, out float level);
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
  }
  [ComImport, Guid("C02216F6-8C05-4D5E-8B17-F1CEB1FAD3C1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IAudioMeterInformation {
    int GetPeakValue(out float peak);
  }
  [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IAudioSessionManager2 {
    int GetAudioSessionControl(ref Guid g, int flags, out IntPtr ctl);
    int GetSimpleAudioVolume(ref Guid g, int flags, out IntPtr vol);
    int GetSessionEnumerator(out IAudioSessionEnumerator e);
  }
  [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IAudioSessionEnumerator {
    int GetCount(out int count);
    int GetSession(int index, out IAudioSessionControl2 session);
  }
  [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IAudioSessionControl2 {
    int GetState(out int state);
    int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
    int SetDisplayName(string n, ref Guid ctx);
    int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
    int SetIconPath(string p, ref Guid ctx);
    int GetGroupingParam(out Guid g);
    int SetGroupingParam(ref Guid g, ref Guid ctx);
    int RegisterAudioSessionNotification(IntPtr n);
    int UnregisterAudioSessionNotification(IntPtr n);
    int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetProcessId(out uint pid);
    int IsSystemSoundsSession();
    int SetDuckingPreference(bool opt);
  }
  [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface ISimpleAudioVolume {
    int SetMasterVolume(float level, ref Guid ctx);
    int GetMasterVolume(out float level);
    int SetMute(bool mute, ref Guid ctx);
    int GetMute(out bool mute);
  }

  public static class Probe {
    static Guid IID_Vol   = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
    static Guid IID_Meter = new Guid("C02216F6-8C05-4D5E-8B17-F1CEB1FAD3C1");
    static Guid IID_Sess  = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");

    static string Db(float mul) {
      if (mul <= 0) return "-inf";
      return (20 * Math.Log10(mul)).ToString("N1") + " dB";
    }
    static string FriendlyName(string id) {
      string[] parts = id.Split('.');
      string guid = parts[parts.Length - 1];
      try {
        using (RegistryKey k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\" + guid + @"\Properties")) {
          if (k != null) {
            object n = k.GetValue("{a45c254e-df1c-4efd-8020-67d146a850e0},14");
            if (n == null) n = k.GetValue("{a45c254e-df1c-4efd-8020-67d146a850e0},2");
            if (n != null) return n.ToString();
          }
        }
      } catch {}
      return id;
    }
    static string ProcName(uint pid) {
      if (pid == 0) return "system sounds";
      try { return Process.GetProcessById((int)pid).ProcessName; } catch { return "pid " + pid; }
    }

    public static string Report() {
      StringBuilder sb = new StringBuilder();
      string step = "enumerator";
      try {
      IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
      step = "default endpoint";
      IMMDevice def; en.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eConsole, out def);
      string defId; def.GetId(out defId);
      step = "enum endpoints";
      IMMDeviceCollection col; en.EnumAudioEndpoints(EDataFlow.eRender, 1, out col);
      int n; col.GetCount(out n);
      sb.AppendLine("active render endpoints: " + n);
      for (int i = 0; i < n; i++) {
        step = "device " + i;
        IMMDevice dev; col.Item(i, out dev);
        string id; dev.GetId(out id);
        sb.AppendLine();
        sb.AppendLine("== " + FriendlyName(id) + (id == defId ? "  [DEFAULT]" : ""));
        sb.AppendLine("   id: " + id);
        try {
          object o;
          step = "volume " + i;
          dev.Activate(ref IID_Vol, 23, IntPtr.Zero, out o);
          IAudioEndpointVolume vol = (IAudioEndpointVolume)o;
          float lvl; vol.GetMasterVolumeLevelScalar(out lvl);
          bool mute; vol.GetMute(out mute);
          sb.AppendLine("   master volume: " + (int)(lvl * 100) + "%   mute: " + mute);
          // Endpoint/session peak meters are unavailable from a non-interactive
          // (SSH) logon session; use obs-audio-meter.ps1 for live levels.
          step = "session mgr " + i;
          dev.Activate(ref IID_Sess, 23, IntPtr.Zero, out o);
          IAudioSessionManager2 sm = (IAudioSessionManager2)o;
          step = "session enum " + i;
          IAudioSessionEnumerator se; sm.GetSessionEnumerator(out se);
          int sc; se.GetCount(out sc);
          for (int j = 0; j < sc; j++) {
            step = "session " + i + "/" + j;
            IAudioSessionControl2 s; se.GetSession(j, out s);
            int st; s.GetState(out st);
            uint pid; s.GetProcessId(out pid);
            float slvl = -1; bool smute = false;
            try { ISimpleAudioVolume sv = (ISimpleAudioVolume)s; sv.GetMasterVolume(out slvl); sv.GetMute(out smute); } catch (Exception e) { sb.AppendLine("       (session vol err: " + e.Message + ")"); }
            string state = st == 1 ? "ACTIVE" : (st == 0 ? "inactive" : "expired");
            sb.AppendLine("     - " + ProcName(pid) + " (pid " + pid + ")  " + state + "  session vol: " + (int)(slvl * 100) + "%  mute: " + smute);
          }
        } catch (Exception e) { sb.AppendLine("   ERROR at " + step + ": " + e.Message); }
      }
      } catch (Exception e) { sb.AppendLine("FATAL at " + step + ": " + e.Message); }
      return sb.ToString();
    }
  }
}
"@

[CA.Probe]::Report()
