# Windows LIVE overlay compatibility

The Local LIVE overlay is a Windows-only companion to BStream Music. It serves
the overlay from the BStream process over HTTP and WebSocket, bound only to
`127.0.0.1`. The public-looking `.test` name is a local alias in the Windows
`hosts` file; it does not expose the page to the LAN or Internet and does not
install a TLS certificate.

This document describes the supported release package, not a guarantee that
every Windows installation or every TikTok LIVE Studio build will accept the
overlay.

## Compatibility matrix

| Environment | Status | Notes |
| --- | --- | --- |
| Windows 11 x64 | Supported | Primary Windows target for the x64 installer and Local LIVE overlay. |
| Windows 10 22H2 x64 | Legacy compatibility | The installer permits Windows 10, but Microsoft ended general Windows 10 support on October 14, 2025. Test the overlay with the installed TikTok LIVE Studio version. |
| Windows 11 ARM64 | Experimental | Windows can emulate x64 applications. BStream and TikTok LIVE Studio still require integration testing on the specific ARM64 device. |
| Windows 10 x86 | Not supported | The distributed BStream package is x64-only. |
| Windows 10 ARM64 | Not supported | Windows 10 on ARM does not provide the Windows 11 x64-emulation path required by this package. |
| Windows in S mode | Not supported | S mode permits only applications obtained from Microsoft Store, while BStream is currently distributed as a desktop installer. |
| Enterprise-restricted devices | Not guaranteed | UAC policy, AppLocker, Windows Defender Application Control, endpoint security, or a locked `hosts` file can prevent local-domain provisioning. |

The installer declares Windows 10 (`10.0`) as its minimum version, installs the
x64-compatible package per user, and launches BStream at the caller's current
privilege level (`asInvoker`). The installer itself does not request elevation.
The separate one-time `hosts` update initiated from the overlay control is the
operation that can request Windows administrator confirmation.

## Runtime requirements and limits

- TCP port `80` on `127.0.0.1` must be free and available to the BStream
  process. A different service, an HTTP reservation, or endpoint policy can
  make the bind fail. BStream does not terminate or reconfigure the owner.
- `overlay.bstreammusic.test` must resolve locally to `127.0.0.1`. The overlay
  relies on the Windows `hosts` file and DNS-client behavior. Before reporting
  an active server, BStream requires every IPv4 result to be exactly
  `127.0.0.1` and performs a direct HTTP health request with bounded retries.
- A proxy auto-configuration script, forced proxy, VPN, browser policy, or
  security product can intercept the dotted hostname before local name
  resolution. If this occurs, configure the managed environment to send
  `overlay.bstreammusic.test` directly rather than through its proxy. BStream
  does not change the system proxy configuration automatically.
- The browser-source process must be allowed to access loopback. Ordinary
  full-trust desktop applications normally can; an AppContainer or other
  network-isolated client can deny loopback by design.
- Windows PowerShell 5.1 and an elevation path must remain available for the
  one-time `hosts` update. UAC may request consent or administrator credentials,
  silently elevate, or deny the request according to system policy.
- No inbound Windows Firewall rule is required because BStream binds only to
  loopback. Creating one would not fix a port conflict or proxy policy and
  would unnecessarily broaden the network surface.
- TikTok LIVE Studio is a third-party client. Its browser-source validation and
  networking behavior can change independently of Windows and BStream. The
  direct BStream health check verifies Windows DNS and the local server; it
  cannot force LIVE Studio to bypass an organization-managed proxy.

## Operational checks

Before relying on the overlay during a broadcast, verify all of the following:

1. BStream can activate the Local LIVE overlay without reporting a permission,
   name-resolution, or port error.
2. `http://overlay.bstreammusic.test/overlay` loads from a local browser on the
   same PC while BStream is running.
3. The TikTok LIVE Studio browser source loads the same URL and receives live
   queue/progress changes.
4. The check is repeated after material changes to proxy, VPN, endpoint
   security, Windows policy, or TikTok LIVE Studio.

## Microsoft references

- [Resetting and using the Windows hosts file](https://support.microsoft.com/en-us/windows/experience/how-to-reset-the-hosts-file-back-to-the-default)
- [Windows DNS client queries and hosts-file loading](https://learn.microsoft.com/en-us/windows-server/networking/dns/queries-lookups)
- [Microsoft Edge proxy support and implicit bypass rules](https://learn.microsoft.com/en-us/deployedge/configure-microsoft-edge-proxy-support)
- [User Account Control](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/user-account-control/)
- [Windows PowerShell 5.1](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_windows_powershell_5.1?view=powershell-5.1)
- [AppContainer loopback restrictions](https://learn.microsoft.com/en-us/windows/uwp/communication/interprocess-communication)
- [x86 and x64 emulation on Arm](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation)
- [Windows release and servicing information](https://learn.microsoft.com/en-us/windows/release-health/release-information)
