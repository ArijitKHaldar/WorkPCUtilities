# Work PC Utilities

A portable, single-file PowerShell 5.1 desktop utility for corporate Windows workstations.  
Keeps Citrix sessions alive, shows dual-timezone clocks, and manages TOTP 2FA codes — all in one lightweight WPF window with light/dark theme support.

---

## Features

### 🟢 Caffeinate (Citrix / Windows keepalive)
- Sends a harmless **F15 key pulse** at a configurable interval (default: every 2 minutes)
- Simultaneously sets the Windows **execution state** (`ES_SYSTEM_REQUIRED`) to prevent the machine from sleeping
- Start / Stop with a single click; status shown in real-time

### 🕐 Dual Clocks
- Two independently configurable timezone clocks (local and client)
- Full timezone name search — pick any of the ~140 Windows system timezones
- Updates every second

### 🔐 TOTP Vault
- Add, edit, delete, view, and copy TOTP codes
- Accepts raw **Base32 secrets** or **`otpauth://` URIs** (full QR-scan format)
- Supports **SHA1 / SHA256 / SHA512**, configurable period and digit count
- Vault is encrypted with **Windows DPAPI** (`CurrentUser` scope) — only you can decrypt it on this machine
- Live countdown bar in the detail view: green → yellow → red as the code expires
- "View all" grid shows all codes at once with one-click copy

### 🎨 Themes
- **System** (follows Windows dark/light setting, auto-refreshes every 5 s)
- **Light** / **Dark** — manually override

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Windows 10 / 11 |
| PowerShell | 5.1 (built-in — no install needed) |
| .NET | 4.x WPF (included with Windows) |
| Permissions | Standard user — no admin required |

> The script self-relaunches in **STA mode** if needed, and hides the console window automatically.

---

## Usage

```powershell
# Right-click → Run with PowerShell
# Or from a terminal:
powershell -ExecutionPolicy Bypass -File .\WorkPCUtilities.ps1
```

That's it — no installation, no dependencies to install, no registry writes.  
All data lives in `%APPDATA%\WorkPCUtilities\`.

---

## Data storage

| File | Contents |
|---|---|
| `%APPDATA%\WorkPCUtilities\settings.json` | Window size, theme, selected timezones, tab index |
| `%APPDATA%\WorkPCUtilities\vault.dat` | DPAPI-encrypted TOTP vault (Base64 ciphertext) |

To reset to defaults, delete `settings.json`.  
To wipe all TOTP secrets, delete `vault.dat`.

---

## Adding a TOTP entry

1. Open the **TOTP Vault** tab and click **Add**
2. Enter a **Name** (required) and optional **Issuer**
3. Paste either:
   - A raw Base32 secret (e.g. `JBSWY3DPEHPK3PXP`)
   - A full `otpauth://totp/...` URI (period, digits and algorithm are parsed automatically)
4. Click **Save**

The vault is saved immediately and survives restarts.

---

## Keyboard shortcuts (TOTP grid)

| Action | How |
|---|---|
| View code + countdown | Double-click any row |
| Copy code | Select row → **Copy code** button |
| Edit | Select row → **Edit** |
| Delete | Select row → **Delete** |

---

## Architecture

Single-file, no external modules:

```
WorkPCUtilities.ps1
├── NativeMethods       P/Invoke: console hide, keybd_event, SetThreadExecutionState
├── Theme engine        Palette switching via Application.Resources (DynamicResource)
├── TOTP engine         Pure-PS RFC 6238 implementation (Base32 → HMAC → OTP)
├── DPAPI vault         ProtectedData encrypt/decrypt, JSON payload
├── WPF UI (XAML)       Inline XAML strings parsed at runtime — no compiled resources
└── Settings            JSON file, merged with defaults on load
```

All WPF event handlers use `$script:MainWindow.FindName()` for control lookup (required under `Set-StrictMode -Version 2.0` in PowerShell 5.1 — captured locals in scriptblock closures are unreliable).

---

## License

[MIT](LICENSE)
