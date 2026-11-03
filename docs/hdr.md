# Brightness with HDR on

Most external-monitor brightness tools use DDC/CI: the computer writes VCP code `0x10` (luminance)
to the monitor over the video cable. With HDR on, many monitors ignore that write. Reading `0x10`
still works and the write returns success, but the backlight does not move.

Daylit uses a different control on each OS when that happens.

## macOS: the system brightness API

`DisplayServicesSetBrightness`, from the private `DisplayServices` framework, is what macOS uses for
the built-in screen. Many external monitors accept it too, and it keeps working while HDR is on.

For each external monitor Daylit first tries `DisplayServicesGetBrightness`. If it answers, the
monitor uses that API (`control: native`). Otherwise Daylit falls back to DDC/CI through
[`m1ddc`](https://github.com/waydabber/m1ddc), addressing the monitor by its system UUID because
m1ddc often lists monitors as "Unknown Display". A monitor's `"control": "native"` or `"ddc"` in the
config forces one.

## Windows: the SDR white level

With HDR on, the control that changes what you see is the **SDR content brightness** slider
(Settings → System → Display → HDR). It sets how bright non-HDR content (the desktop, most apps) is
drawn inside the HDR signal. There is no public API for it.

Daylit sets it with `DisplayConfigSetDeviceInfo` and the undocumented request type `0xFFFFFFEE`, the
one the Settings app uses. The level is 1000–6000 (80–480 nits); Daylit maps it to 0–100. It reads
the current level back with the documented `DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL`.

When HDR is off, Daylit uses DDC/CI through the Monitor Configuration API (`dxva2`:
`GetVCPFeatureAndVCPFeatureReply` / `SetVCPFeature`, code `0x10`). The choice is made per monitor
on every update, so turning HDR on or off in Settings just switches the control; it is not mistaken
for a level you set by hand.

## Caveats

- Both the macOS framework and the Windows request type are undocumented. An OS update could change
  them; Daylit then reports the monitor as having no brightness control instead of guessing.
