# Claude Usage Tray - a Windows system tray gauge for Claude / Claude Code
# usage limits.
#
# Windows answer to ClaudeUsageBar (claudeusagebar.com), which is macOS-only and
# scrapes a claude.ai session cookie. We don't need the cookie: the OAuth access
# tokens cswap already keeps on disk let us call the same usage endpoint that
# `cswap --list` and claude-switch-gui use.
#
# Design: usage is fetched in a BACKGROUND runspace on a timer and kept in
# memory, so hovering the tray icon only has to draw - the popup never waits on
# the network. A snapshot is persisted so a fresh start paints immediately too.
#
# Read-only. It never refreshes or writes a token: refresh tokens rotate and are
# single-use, so writing them back is cswap's job, not ours. A dead token simply
# renders "usage unavailable" - exactly as cswap shows it.
#
# NOTE: keep this file pure ASCII. PowerShell 5.1 reads a BOM-less .ps1 as ANSI,
# which mangles non-ASCII literals. Glyphs go through [char]0xNNNN instead.

# -Once: collect the usage data, print it as JSON, exit. No tray, no window.
#   Useful to see what the API actually returned when a bar looks wrong.
# -Preview <dir>: render the popup and the tray ring to PNGs and exit, so the
#   layout can be checked without hovering a live tray icon.
param(
    [switch]$Once,
    [string]$Preview
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Per-monitor DPI awareness must be declared before any window exists, or
# Windows bitmap-stretches (blurs) the popup. Guarded because a locked-down host
# can fail the C# compile, and that's a terminating error -ErrorAction can't
# suppress.
try {
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Dpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static void Enable() {
        try { if (SetProcessDpiAwarenessContext((IntPtr)(-4))) return; } catch {}  // PER_MONITOR_V2
        try { SetProcessDpiAwareness(2); return; } catch {}                        // PER_MONITOR
        try { SetProcessDPIAware(); } catch {}                                     // SYSTEM
    }
}
"@
} catch {}
try { [Dpi]::Enable() } catch {}

# PS 5.1 still defaults to SSL3/TLS1.0 on some hosts; Anthropic rejects those.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------------------------------------------------------------------
# Win32 interop
# ---------------------------------------------------------------------------
# Shell_NotifyIconGetRect gives us the tray icon's screen rectangle, which is
# what makes hover-to-open work properly: the "keep the popup open" hot zone is
# the union of the popup and the icon, so a stationary cursor resting on the
# icon doesn't dismiss it (MouseMove stops firing when the mouse stops).
try {
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Native {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct NOTIFYICONIDENTIFIER {
        public int cbSize; public IntPtr hWnd; public uint uID; public Guid guidItem;
    }
    [DllImport("shell32.dll")]
    private static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER id, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    // Add WS_EX_COMPOSITED so Windows paints the whole window (form + every child
    // panel/label) into one off-screen buffer and blits it at once, instead of
    // the controls flashing in one by one as the popup appears.
    public static void EnableComposited(IntPtr hWnd) {
        const int GWL_EXSTYLE = -20;
        const int WS_EX_COMPOSITED = 0x02000000;
        int ex = GetWindowLong(hWnd, GWL_EXSTYLE);
        SetWindowLong(hWnd, GWL_EXSTYLE, ex | WS_EX_COMPOSITED);
    }

    // Marshalling the struct from PowerShell is fiddly; keep it on this side.
    public static bool TryGetIconRect(IntPtr hwnd, uint uid, out int l, out int t, out int r, out int b) {
        l = t = r = b = 0;
        try {
            NOTIFYICONIDENTIFIER nid = new NOTIFYICONIDENTIFIER();
            nid.cbSize = Marshal.SizeOf(typeof(NOTIFYICONIDENTIFIER));
            nid.hWnd = hwnd; nid.uID = uid; nid.guidItem = Guid.Empty;
            RECT rc;
            if (Shell_NotifyIconGetRect(ref nid, out rc) != 0) return false;
            l = rc.Left; t = rc.Top; r = rc.Right; b = rc.Bottom;
            return (r > l && b > t);
        } catch { return false; }
    }
}
"@
} catch {}

$SW_SHOWNOACTIVATE = 4

# ---------------------------------------------------------------------------
# Single instance
# ---------------------------------------------------------------------------
$script:mutex = $null
if (-not $Once -and -not $Preview) {
    $created = $false
    $script:mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeUsageTray', [ref]$created)
    if (-not $created) { exit 0 }
}

# ---------------------------------------------------------------------------
# DPI scaling + theme
# ---------------------------------------------------------------------------
# Authored in logical pixels at 96 DPI, multiplied by $scale. Fonts use
# GraphicsUnit.Pixel (also scaled) and the form sets AutoScaleMode = None, so
# this manual scaling is the single source of truth.
$gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:scale = $gfx.DpiX / 96.0
$gfx.Dispose()
if ($script:scale -lt 1) { $script:scale = 1 }

function Px([double]$n)  { return [int][math]::Round($n * $script:scale) }
function Pxf([double]$n) { return [single]($n * $script:scale) }
function Pt($x, $y)      { return New-Object System.Drawing.Point((Px $x), (Px $y)) }
function Sz($w, $h)      { return New-Object System.Drawing.Size((Px $w), (Px $h)) }
function Fnt($name, $px, $style) {
    if ($null -eq $style) { $style = [System.Drawing.FontStyle]::Regular }
    return New-Object System.Drawing.Font($name, (Pxf $px), $style, [System.Drawing.GraphicsUnit]::Pixel)
}

# PowerShell variable names are case-insensitive, so theme colors take a $c
# prefix to avoid colliding with locals like $card / $track / $text.
$cBg     = [System.Drawing.Color]::FromArgb(24, 24, 27)
$cCard   = [System.Drawing.Color]::FromArgb(39, 39, 42)
$cActive = [System.Drawing.Color]::FromArgb(54, 46, 40)      # active-account tint
$cAccent = [System.Drawing.Color]::FromArgb(224, 130, 95)    # claude-ish terracotta
$cText   = [System.Drawing.Color]::FromArgb(245, 245, 247)
$cMuted  = [System.Drawing.Color]::FromArgb(184, 186, 198)
$cTrack  = [System.Drawing.Color]::FromArgb(70, 70, 78)
$cSubtle = [System.Drawing.Color]::FromArgb(150, 152, 164)
$cLine   = [System.Drawing.Color]::FromArgb(52, 52, 58)
# Fill for a bar drawn from cswap's lastGoodUsage. Deliberately OUTSIDE the
# green/amber/red scale: the level is still worth reading, but the colour must
# not shout urgency about a number that may already have moved.
$cStale  = [System.Drawing.Color]::FromArgb(116, 118, 132)

$reg = [System.Drawing.FontStyle]::Regular
$FONT_TITLE = Fnt "Segoe UI Semibold" 14 $reg
$FONT_EMAIL = Fnt "Segoe UI Semibold" 14 $reg
$FONT_ORG   = Fnt "Segoe UI"          11 $reg
$FONT_ROW   = Fnt "Segoe UI"          12 $reg
$FONT_SMALL = Fnt "Segoe UI"          11 $reg
# Segoe UI Symbol renders U+267B monochrome (no color-emoji fallback).
$FONT_RESET = Fnt "Segoe UI Symbol"   11 $reg
$FONT_CLOSE = Fnt "Segoe UI"          15 $reg

$cFoot   = [System.Drawing.Color]::FromArgb(96, 96, 106)   # footer hint

# 380 rather than 340 so a full-length gmail address fits on a compact row
# without ellipsizing next to its usage numbers.
$W_POPUP = 380
$PAD     = 14
$BAR_H   = 6

# Refresh cadence, and the ceiling the 429 backoff climbs to.
$BASE_REFRESH_MS = 60000
$MAX_REFRESH_MS  = 600000
$GLYPH_RESET = [char]0x267B

# Green (plenty left) -> amber -> red (about to bite).
function Get-UsageColor([int]$pct) {
    if ($pct -ge 85) { return [System.Drawing.Color]::FromArgb(229, 72, 77) }
    if ($pct -ge 60) { return [System.Drawing.Color]::FromArgb(245, 166, 35) }
    return [System.Drawing.Color]::FromArgb(48, 164, 108)
}

# Where the tray ring switches to its zoomed scale (see New-RingIcon). ONE
# threshold on purpose: each extra one is another scale the user would have to
# identify at a glance in 16 pixels. 90 also happens to be where `cswap auto`
# starts considering a switch, so the icon changes meaning exactly where the
# engine changes behaviour.
$TAIL_FROM_PCT = 90

# ---------------------------------------------------------------------------
# Talking to cswap (the ONLY path that writes credentials)
# ---------------------------------------------------------------------------
# Reading usage is native (see $script:Collect). Anything that MUTATES account
# state - switching, removing - is delegated to cswap, which owns the refresh
# token rotation and the on-disk layout. We never write those files ourselves.

# ProcessStartInfo.ArgumentList doesn't exist on .NET Framework (PS 5.1 / ps2exe),
# so the command line is built by hand and any token with whitespace is quoted.
function Quote-Arg([string]$a) {
    if ($a -notmatch '[\s"]') { return $a }
    return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Runs `cswap <args>`, optionally feeding $StdinText to its stdin (that's how the
# removal confirmation prompt gets its "y"). Returns {Ok; ExitCode; Output}.
# cswap prints box-drawing glyphs, so the CHILD gets UTF-8 forced on it (scoped
# to the subprocess); NO_COLOR keeps the output free of ANSI escapes.
function Invoke-Cswap([string[]]$Arguments, [string]$StdinText) {
    $argStr = ($Arguments | ForEach-Object { Quote-Arg "$_" }) -join " "
    $psi = [System.Diagnostics.ProcessStartInfo]::new("cswap", $argStr)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["PYTHONUTF8"]       = "1"
    $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
    $psi.EnvironmentVariables["NO_COLOR"]         = "1"
    $psi.EnvironmentVariables.Remove("FORCE_COLOR") | Out-Null

    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ Ok = $false; ExitCode = -1; Output = "cswap nao encontrado no PATH." } }

    # Always close stdin: cswap blocks on input() forever otherwise.
    try {
        if ($StdinText) { $p.StandardInput.Write($StdinText) }
        $p.StandardInput.Close()
    } catch {}

    # Drain stderr async so a child filling one pipe while we read the other
    # can't deadlock this (otherwise sequential) pair of ReadToEnd calls.
    $out = ""
    try {
        $errTask = $p.StandardError.ReadToEndAsync()
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(20000)) { try { $p.Kill() } catch {} }
        $out += $errTask.GetAwaiter().GetResult()
    } catch {}
    $code = -1
    try { $code = $p.ExitCode } catch {}
    try { $p.Dispose() } catch {}
    return [pscustomobject]@{ Ok = ($code -eq 0); ExitCode = $code; Output = ($out.Trim()) }
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# $PSScriptRoot / $PSCommandPath are empty in a ps2exe-compiled build, where the
# process' own module path is the exe.
$script:selfPath = if ($PSCommandPath) { $PSCommandPath }
                   else { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
$script:selfDir  = Split-Path -Parent $script:selfPath
$script:isExe    = ($script:selfPath -like '*.exe')

$script:stateDir  = Join-Path $env:LOCALAPPDATA 'claude-usage-tray'
$script:snapPath  = Join-Path $script:stateDir 'snapshot.json'
$script:settingsPath = Join-Path $script:stateDir 'settings.json'
$script:startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Tray.lnk'

# ---------------------------------------------------------------------------
# Data collection (runs in a background runspace - never on the UI thread)
# ---------------------------------------------------------------------------
# Primary source is `cswap --list --json`. We already depend on cswap for the
# account list and for switching, and letting it fetch usage buys three things a
# direct API call can't:
#   1. It REFRESHES expired tokens (rotating + rewriting them) - an inactive
#      account whose .enc token went stale comes back on its own, instead of
#      staying dead until you manually run cswap or switch to it.
#   2. Its 15s usage cache absorbs bursts, so we stop earning 429s.
#   3. It already surfaces per-model "scoped" windows (e.g. Fable) that the
#      legacy five_hour/seven_day fields never expose.
# Fallback (cswap absent) is a direct API call for the one logged-in account, so
# the app still does something standalone.
#
# It returns a JSON *string*, not objects. Handing PSCustomObjects back across a
# runspace boundary silently delivered an object[] of nulls on Windows 11's
# inbox PS 5.1 (same broken DLR/interpreter path that makes @() over a
# New-Object List[object] throw). A string crosses intact; the caller parses it.
# For the same reason this uses ArrayList rather than List[object] throughout.
#
# The string is an ENVELOPE: {"accounts":[...],"auto":{...}}. When $AutoTick is
# true (the "Auto-switch de conta" toggle), one `cswap auto --once --json` tick
# runs here FIRST - cswap's own engine decides and performs any switch, we only
# carry its events back for balloons - and only then the account list is
# fetched, so a switch is already visible in the same refresh.
$script:Collect = {
    param([bool]$AutoTick)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    function Read-Json($path) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
        try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json) } catch { return $null }
    }

    # Run `cswap --list --json` and return the parsed object, or $null if cswap
    # isn't installed / times out / prints junk. Process.Start (not a cmdlet) so
    # it works inside the bare background runspace; UTF-8 + NO_COLOR forced on the
    # child so its box-drawing/ANSI output can't corrupt the JSON.
    function Invoke-CswapJson {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName  = 'cswap'
            $psi.Arguments = '--list --json'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.RedirectStandardInput  = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.CreateNoWindow = $true
            $psi.EnvironmentVariables["PYTHONUTF8"]       = "1"
            $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
            $psi.EnvironmentVariables["NO_COLOR"]         = "1"
            $psi.EnvironmentVariables.Remove("FORCE_COLOR") | Out-Null
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $errT = $p.StandardError.ReadToEndAsync()
            $out  = $p.StandardOutput.ReadToEnd()
            if (-not $p.WaitForExit(15000)) { try { $p.Kill() } catch {}; return $null }
            $null = $errT.GetAwaiter().GetResult()
            try { $p.Dispose() } catch {}
            if ([string]::IsNullOrWhiteSpace($out)) { return $null }
            return ($out | ConvertFrom-Json)
        } catch { return $null }
    }

    # One `cswap auto --once --json` tick. The auto-switch decision AND the
    # write both live in cswap (threshold/hysteresis/cooldown, token
    # freshening, quarantine, failover - state persisted under its own file
    # locks); this app only relays the JSONL events. Returns
    # {Exit; Events[]} or $null when cswap is absent / times out / prints
    # junk. 45s timeout: a tick may refresh a target's token or escalate to
    # fetching every account's usage.
    function Invoke-CswapAutoOnce {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName  = 'cswap'
            $psi.Arguments = 'auto --once --json'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.RedirectStandardInput  = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.CreateNoWindow = $true
            $psi.EnvironmentVariables["PYTHONUTF8"]       = "1"
            $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
            $psi.EnvironmentVariables["NO_COLOR"]         = "1"
            $psi.EnvironmentVariables.Remove("FORCE_COLOR") | Out-Null
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $errT = $p.StandardError.ReadToEndAsync()
            $out  = $p.StandardOutput.ReadToEnd()
            if (-not $p.WaitForExit(45000)) { try { $p.Kill() } catch {}; return $null }
            $null = $errT.GetAwaiter().GetResult()
            $code = -1
            try { $code = $p.ExitCode } catch {}
            try { $p.Dispose() } catch {}
            $events = New-Object System.Collections.ArrayList
            foreach ($line in ($out -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { [void]$events.Add(($line | ConvertFrom-Json)) } catch {}
            }
            return [pscustomobject]@{ Exit = $code; Events = @($events) }
        } catch { return $null }
    }

    # cswap's usageStatus string -> our short status token.
    #
    # cswap emits snake_case (json_output.usage_fields); the space-separated
    # forms are its older spelling, kept so a rollback of cswap doesn't silently
    # turn every account into "unknown". An unmapped value is 'nodata', NOT
    # 'offline': saying "API indisponivel" about a status we simply don't know
    # is a claim we can't back - that mistake is exactly what made a
    # relogin_required account read as an outage.
    function Map-CswapStatus($s) {
        switch ("$s") {
            'ok'                   { 'ok' }
            'token_expired'        { 'expired' }
            'token expired'        { 'expired' }
            'relogin_required'     { 'relogin' }
            're-login needed'      { 'relogin' }
            'no_credentials'       { 'notoken' }
            'no credentials'       { 'notoken' }
            'api_key'              { 'apikey' }
            'api key'              { 'apikey' }
            'keychain_unavailable' { 'offline' }
            'keychain unavailable' { 'offline' }
            # No usable measurement this pass (fetch failed, or the stored one is
            # too old to act on). cswap still ships lastGoodUsage alongside it.
            'unavailable'          { 'nodata' }
            default                { if ("$s") { 'nodata' } else { 'ok' } }
        }
    }

    # One usage window (cswap shape: { pct; resetsAt }) -> our bar, or $null.
    function New-BarFrom($label, $node) {
        if (-not $node -or $null -eq $node.pct) { return $null }
        return [pscustomobject]@{
            Label    = "$label"
            Pct      = [int][math]::Round([double]$node.pct)
            ResetsAt = "$($node.resetsAt)"
        }
    }

    # A whole usage object (cswap's `usage` OR `lastGoodUsage` - same shape)
    # -> the bars, emitted one by one. Callers wrap the call in @() to get a
    # real array (empty when there's nothing). Deliberately NOT `return
    # ,$array`: that idiom nests one level here, and a nested array's .Count is
    # always 1 - which silently made "no bars" look like "one bar".
    function New-BarsFrom($u) {
        if (-not $u) { return }
        $b = New-BarFrom '5h' $u.fiveHour; if ($b) { $b }
        $b = New-BarFrom '7d' $u.sevenDay; if ($b) { $b }
        # Per-model windows (Fable today, maybe Opus later) - keep each,
        # labelled by the model name cswap carries.
        if ($u.scoped) {
            foreach ($s in @($u.scoped)) {
                $b = New-BarFrom "$($s.name)" $s; if ($b) { $b }
            }
        }
    }

    $out  = New-Object System.Collections.ArrayList
    $auto = $null
    if ($AutoTick) { $auto = Invoke-CswapAutoOnce }
    $cj   = Invoke-CswapJson

    if ($cj -and $cj.accounts) {
        foreach ($ac in $cj.accounts) {
            # `usage` is cswap's decision-grade value: it disappears the moment
            # the measurement is too old to act on. cswap 0.24+ keeps shipping
            # the last useful one in `lastGoodUsage`, stamped with
            # `lastGoodAgeSeconds` - display-grade by contract. We draw that,
            # dimmed and dated (revised invariant 5): a number the user can see
            # is old beats "sem dados". Pre-0.24 cswap omits the field, and the
            # account falls back to reading as no-data, exactly as before.
            $stale = $false
            $ageS  = $null
            $bars  = @(New-BarsFrom $ac.usage)
            if ($bars.Count -eq 0 -and $ac.lastGoodUsage) {
                $bars = @(New-BarsFrom $ac.lastGoodUsage)
                if ($bars.Count -gt 0) {
                    $stale = $true
                    if ($null -ne $ac.lastGoodAgeSeconds) { $ageS = [double]$ac.lastGoodAgeSeconds }
                }
            }
            $status = Map-CswapStatus $ac.usageStatus
            [void]$out.Add([pscustomobject]@{
                Num = [int]$ac.number; Email = "$($ac.email)"; Org = "$($ac.organizationName)"
                Active = [bool]$ac.active
                Unavailable = ($bars.Count -eq 0); Status = $status; Bars = @($bars)
                Stale = $stale; AgeS = $ageS
            })
        }
        return ([pscustomobject]@{ accounts = $out.ToArray(); auto = $auto } |
            ConvertTo-Json -Depth 8 -Compress)
    }

    # ---- Fallback: no cswap. Direct API call for the logged-in account. ----
    function Get-Usage([string]$token) {
        if (-not $token) { return @{ Body = $null; Status = 'notoken' } }
        try {
            $req = [System.Net.HttpWebRequest]::Create('https://api.anthropic.com/api/oauth/usage')
            $req.Method = 'GET'; $req.Timeout = 6000; $req.UserAgent = 'claude-usage-tray/1.0'
            $req.Headers.Add('Authorization', "Bearer $token")
            $req.Headers.Add('anthropic-beta', 'oauth-2025-04-20')
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
            return @{ Body = [string]$body; Status = 'ok' }
        } catch [System.Net.WebException] {
            $code = 0
            try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch {}
            $st = switch ($code) {
                401 { 'expired' } 403 { 'expired' } 429 { 'ratelimited' }
                default { 'offline' }
            }
            return @{ Body = $null; Status = $st }
        } catch { return @{ Body = $null; Status = 'offline' } }
    }

    $userHome = $env:USERPROFILE
    if ([string]::IsNullOrEmpty($userHome)) { $userHome = [Environment]::GetFolderPath('UserProfile') }
    $cfgHome   = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $userHome '.claude' }
    $credsPath = Join-Path $cfgHome '.credentials.json'

    $j   = Read-Json $credsPath
    $cfg = Read-Json (Join-Path $userHome '.claude.json')
    $tok = if ($j) { $j.claudeAiOauth.accessToken } else { $null }
    $email = 'Claude'; $org = ''
    if ($cfg -and $cfg.oauthAccount) {
        if ($cfg.oauthAccount.emailAddress)     { $email = "$($cfg.oauthAccount.emailAddress)" }
        if ($cfg.oauthAccount.organizationName) { $org   = "$($cfg.oauthAccount.organizationName)" }
    }

    $res = Get-Usage $tok
    $bars = New-Object System.Collections.ArrayList
    $status = "$($res.Status)"
    if ($res.Body) {
        try {
            $usg = $res.Body | ConvertFrom-Json
            foreach ($spec in @(@{K='five_hour';L='5h'}, @{K='seven_day';L='7d'})) {
                $node = $usg.($spec.K)
                if ($node -and $null -ne $node.utilization) {
                    [void]$bars.Add([pscustomobject]@{
                        Label = $spec.L; Pct = [int][math]::Round([double]$node.utilization); ResetsAt = "$($node.resets_at)"
                    })
                }
            }
        } catch {}
    }
    if ($status -eq 'ok' -and $bars.Count -eq 0) { $status = 'offline' }
    # No store behind this path, so nothing can be stale: it's this second's
    # answer or nothing. The fields exist only so both paths yield the same shape.
    [void]$out.Add([pscustomobject]@{
        Num = 1; Email = $email; Org = $org; Active = $true
        Unavailable = ($bars.Count -eq 0); Status = $status; Bars = @($bars)
        Stale = $false; AgeS = $null
    })
    return ([pscustomobject]@{ accounts = $out.ToArray(); auto = $auto } |
        ConvertTo-Json -Depth 8 -Compress)
}

# The other half of that contract: turn Collect's envelope JSON back into
# {Accounts; Auto}. Auto is the raw `cswap auto --once` result ({Exit; Events})
# or $null when the toggle was off / cswap missing.
#
# Two PS 5.1 traps here. ConvertFrom-Json emits a JSON array as ONE object, so
# @(...) around a pipeline would wrap instead of unrolling - hence the explicit
# walk. And a lone account can deserialize as a bare object rather than a
# 1-element array, which the same walk handles.
function ConvertFrom-CollectJson($raw) {
    $empty = [pscustomobject]@{ Accounts = @(); Auto = $null }
    if ([string]::IsNullOrWhiteSpace("$raw")) { return $empty }
    try {
        $parsed = ConvertFrom-Json -InputObject "$raw"
        $list = @()
        foreach ($x in @($parsed.accounts)) { if ($x) { $list += $x } }
        return [pscustomobject]@{ Accounts = $list; Auto = $parsed.auto }
    } catch { return $empty }
}

if ($Once) {
    # Straight on this thread - there's no UI to keep responsive. Read-only by
    # design: $AutoTick is not passed, so -Once can never switch accounts.
    # Round-trip through ConvertFrom/To so the compact JSON prints readably.
    (ConvertFrom-CollectJson (& $script:Collect)).Accounts | ConvertTo-Json -Depth 6
    exit 0
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:data      = @()        # last known accounts
$script:updatedAt = $null      # [datetime] of that data
$script:stale     = $false     # data came from disk, not yet re-fetched

# No per-account cache: the popup shows ONLY what the latest fetch returned. An
# inactive account whose .enc token is stale simply reads "sem dados" with its
# status, instead of a stale number pretending to be current (by explicit user
# request - a cached "5h: 90%" from hours ago is misleading, not helpful).
$script:fetching  = $false
$script:job       = $null
$script:visible   = $false     # our own flag: ShowWindow bypasses Form.Visible
$script:pinned    = $false
$script:modal     = $false     # a dialog is up; hover must not hide the popup
$script:busy      = $null      # text of an in-flight cswap action, or $null
$script:menuOpen  = $false     # tray context menu is open; do NOT reopen the popup
$script:autoSwitchWarned = $false   # one all-exhausted balloon per episode, not one per tick
$script:leaveAt   = 0
$script:anchor    = [System.Drawing.Rectangle]::Empty
$script:iconHandle = [IntPtr]::Zero
$script:iconObj   = $null

function Save-Snapshot {
    try {
        if (-not (Test-Path -LiteralPath $script:stateDir)) {
            New-Item -ItemType Directory -Force -Path $script:stateDir | Out-Null
        }
        $payload = [pscustomobject]@{
            savedAt  = (Get-Date).ToString('o')
            accounts = $script:data
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:snapPath -Encoding UTF8
    } catch {}
}

# Paint the last known state the instant the tray icon appears, instead of an
# empty popup for the ~1-2s the first API round trip takes. This is the last
# real fetch, not a per-account cache; the boot re-fetch (3s) corrects it, and
# any account that now fails loses its bars rather than showing an old number.
function Load-Snapshot {
    try {
        if (-not (Test-Path -LiteralPath $script:snapPath)) { return }
        $s = Get-Content -Raw -LiteralPath $script:snapPath | ConvertFrom-Json
        if ($s -and $s.accounts) {
            $script:data      = @($s.accounts)
            $script:updatedAt = [datetime]::Parse("$($s.savedAt)")
            $script:stale     = $true
        }
    } catch {}
}

$script:autoSwitchEnabled = $true   # default ON; overwritten by Load-Settings if a file exists

function Save-Settings {
    try {
        if (-not (Test-Path -LiteralPath $script:stateDir)) {
            New-Item -ItemType Directory -Force -Path $script:stateDir | Out-Null
        }
        [pscustomobject]@{ autoSwitch = $script:autoSwitchEnabled } |
            ConvertTo-Json | Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
    } catch {}
}

function Load-Settings {
    try {
        if (-not (Test-Path -LiteralPath $script:settingsPath)) { return }
        $s = Get-Content -Raw -LiteralPath $script:settingsPath | ConvertFrom-Json
        if ($s -and $null -ne $s.autoSwitch) { $script:autoSwitchEnabled = [bool]$s.autoSwitch }
    } catch {}
}
Load-Settings   # before the context menu is built, so the checkbox reflects the saved value

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
function Format-ResetClock($iso) {
    if ([string]::IsNullOrWhiteSpace("$iso")) { return "" }
    try {
        $dt  = [datetimeoffset]::Parse("$iso").ToLocalTime()
        $now = [datetimeoffset]::Now
        if ($dt.Date -eq $now.Date) { return $dt.ToString('HH:mm') }
        return $dt.ToString('MMM d, HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    } catch { return "" }
}

# "2h14m" / "3d 4h" / "now" - the popup is rebuilt on every open, so this is
# always fresh at the moment the user looks at it. No ticking timer needed.
function Format-ResetRel($iso) {
    if ([string]::IsNullOrWhiteSpace("$iso")) { return "" }
    try {
        $span = [datetimeoffset]::Parse("$iso") - [datetimeoffset]::Now
        if ($span.TotalSeconds -le 0) { return "now" }
        if ($span.TotalDays -ge 1)    { return "{0}d {1}h" -f [int]$span.TotalDays, $span.Hours }
        if ($span.TotalHours -ge 1)   { return "{0}h{1:00}m" -f [int]$span.TotalHours, $span.Minutes }
        return "{0}m" -f [math]::Max(1, [int]$span.TotalMinutes)
    } catch { return "" }
}

# How old a measurement is, short and ASCII-only (invariant 8): "45s" / "8m" /
# "3h" / "2d". One unit is enough - this qualifies a number, it isn't the number.
function Format-Age($seconds) {
    if ($null -eq $seconds) { return "" }
    $s = [double]$seconds
    if ($s -lt 0)     { $s = 0 }
    if ($s -lt 60)    { return "{0}s" -f [int]$s }
    if ($s -lt 3600)  { return "{0}m" -f [int][math]::Floor($s / 60) }
    if ($s -lt 86400) { return "{0}h" -f [int][math]::Floor($s / 3600) }
    return "{0}d" -f [int][math]::Floor($s / 86400)
}

# The age as the user reads it next to a dimmed bar. Falls back to a qualifier
# with no number when cswap sent lastGoodUsage without lastGoodAgeSeconds -
# never silence, or the number would look current.
function Format-StaleTag($acct) {
    $age = Format-Age $acct.AgeS
    if ($age) { return "$age atras" }
    return 'medicao antiga'
}

# Why an account has no live numbers, in words. 'expired' is the normal state of
# an INACTIVE account (cswap only rewrites its .enc on switch), so it gets the
# gentlest phrasing; a 429 must never be reported as an expired token.
function Format-Status($acct, [bool]$long) {
    switch ("$($acct.Status)") {
        'ratelimited' { return 'API limitando (429)' }
        'offline'     { return 'API indisponivel' }
        'nodata'      { return 'sem medicao recente' }
        'notoken'     { return 'sem credencial salva' }
        'apikey'      { return 'conta usa API key (sem uso)' }
        'relogin'     { if ($long) { return 're-login preciso (cswap add)' } else { return 're-login preciso' } }
        'expired'     { if ($long) { return 'token expirado (troque p/ esta conta p/ atualizar)' } else { return 'token expirado' } }
        default       { return 'sem dados' }
    }
}

function Get-ActiveAccount {
    if (-not $script:data -or @($script:data).Count -eq 0) { return $null }
    foreach ($a in $script:data) { if ($a.Active) { return $a } }
    return @($script:data)[0]
}

# The tray ring tracks the SESSION window (5h) specifically - that's the limit
# that bites minute to minute. Falls back to the first available bar only if a
# plan doesn't expose a 5h window at all.
function Get-SessionPct($acct) {
    if (-not $acct) { return $null }
    $bars = @($acct.Bars)
    foreach ($b in $bars) { if ("$($b.Label)" -eq '5h') { return [int]$b.Pct } }
    if ($bars.Count -gt 0) { return [int]$bars[0].Pct }
    return $null
}

# ---------------------------------------------------------------------------
# Tray icon: a ring gauge of the active account's 5h session usage
# ---------------------------------------------------------------------------
# Drawn at 4x and downsampled so the arc has clean edges at 16-24px, where a
# number would be illegible.
# $stale draws the arc grey instead of on the green/amber/red scale: the ring is
# the one surface with no room to explain itself, so a stale reading must not
# look like a live one. The number it shows is still the last one we know.
function New-RingIcon($pct, [bool]$stale) {
    $target = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    if ($target -lt 16) { $target = 16 }
    $ss = $target * 4

    $big = New-Object System.Drawing.Bitmap($ss, $ss)
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $stroke = [single]($ss * 0.17)
    $inset  = [single]($stroke / 2 + $ss * 0.06)
    $box = New-Object System.Drawing.RectangleF($inset, $inset, ($ss - 2 * $inset), ($ss - 2 * $inset))

    $trackColor = [System.Drawing.Color]::FromArgb(120, 150, 150, 160)
    $trackPen = New-Object System.Drawing.Pen($trackColor, $stroke)
    $trackPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $trackPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawEllipse($trackPen, $box)

    if ($null -ne $pct) {
        $p = [math]::Max(0, [math]::Min(100, [int]$pct))

        # Above $TAIL_FROM_PCT the ring changes scale: that last stretch takes
        # the whole circle, so 95% is half a turn and 98% is four fifths. At the
        # normal scale those readings are the SAME icon - 2% of usage is 7
        # degrees of arc, under one pixel at 16px, which is the size this thing
        # actually lives at. The centre dot says "you're reading the zoomed
        # scale". Colour disambiguates it even if the dot goes unnoticed: at the
        # normal scale a barely-filled ring is green, never red.
        $tail  = ($p -ge $TAIL_FROM_PCT)
        $shown = if ($tail) { [int](100.0 * ($p - $TAIL_FROM_PCT) / (100.0 - $TAIL_FROM_PCT)) } else { $p }

        $arcColor = if ($stale) { $cStale } else { Get-UsageColor $p }
        $arcPen = New-Object System.Drawing.Pen($arcColor, $stroke)
        $arcPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $arcPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        if ($shown -ge 100) {
            $g.DrawEllipse($arcPen, $box)
        } elseif ($shown -gt 0 -or $tail) {
            # Sweep clockwise from 12 o'clock. Floor a hair of sweep so a 1%
            # reading still shows a visible tick rather than nothing - and so
            # that exactly $TAIL_FROM_PCT (zero on the zoomed scale) reads as
            # "start of the tail", not as an empty ring.
            $sweep = [single][math]::Max(8, 360.0 * $shown / 100.0)
            $g.DrawArc($arcPen, $box, -90, $sweep)
        }
        $arcPen.Dispose()

        if ($tail) {
            # Centre dot: the one part of the icon nothing else uses, ~4px at
            # 16px. Same colour as the arc, so a stale reading stays grey - the
            # dot marks the scale, it never asserts urgency on its own.
            $r  = [single]($ss * 0.17)
            $cx = [single]($ss / 2.0)
            $dot = New-Object System.Drawing.SolidBrush($arcColor)
            $g.FillEllipse($dot, ($cx - $r), ($cx - $r), (2 * $r), (2 * $r))
            $dot.Dispose()
        }
    }
    $trackPen.Dispose()
    $g.Dispose()

    $small = New-Object System.Drawing.Bitmap($target, $target)
    $g2 = [System.Drawing.Graphics]::FromImage($small)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($big, 0, 0, $target, $target)
    $g2.Dispose(); $big.Dispose()

    $hicon = $small.GetHicon()
    $small.Dispose()
    return $hicon
}

function Update-TrayIcon {
    $acct = Get-ActiveAccount
    $pct  = Get-SessionPct $acct

    $hicon = New-RingIcon $pct ([bool]$acct.Stale)
    $newIcon = [System.Drawing.Icon]::FromHandle($hicon)

    $oldHandle = $script:iconHandle
    $oldIcon   = $script:iconObj
    $notify.Icon = $newIcon
    $script:iconHandle = $hicon
    $script:iconObj    = $newIcon

    # Icon.FromHandle does not own the handle, so free it ourselves - otherwise
    # we leak a GDI handle on every refresh (once a minute, forever).
    if ($oldIcon) { try { $oldIcon.Dispose() } catch {} }
    if ($oldHandle -ne [IntPtr]::Zero) { try { [void][Native]::DestroyIcon($oldHandle) } catch {} }

    # Windows shows its own tooltip for NotifyIcon.Text and it would fight our
    # popup, so keep it empty once we have data to draw.
    $notify.Text = if ($null -eq $pct) { 'Claude Usage - loading...' } else { '' }
}

# ---------------------------------------------------------------------------
# Account actions (switch / remove) - both go through cswap
# ---------------------------------------------------------------------------
# While a modal dialog is up, the hover timer must not yank the popup out from
# under it. Callers set $script:modal around anything that blocks.
function Show-Message([string]$text, [string]$title, $icon) {
    $script:modal = $true
    try {
        [void][System.Windows.Forms.MessageBox]::Show($popup, $text, $title,
            [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
    } finally { $script:modal = $false }
}

# Ground truth for "did the removal happen": cswap's own sequence.json. On any
# read failure we assume the account is still there, so we never report a
# deletion we can't see.
function Read-Sequence {
    try {
        $userHome = $env:USERPROFILE
        if ([string]::IsNullOrEmpty($userHome)) { $userHome = [Environment]::GetFolderPath('UserProfile') }
        $seqPath = Join-Path $userHome '.claude-swap-backup\sequence.json'
        if (-not (Test-Path -LiteralPath $seqPath)) { return $null }
        return (Get-Content -Raw -LiteralPath $seqPath | ConvertFrom-Json)
    } catch { return $null }
}

function Test-AccountExists($num) {
    $seq = Read-Sequence
    if ($null -eq $seq) { return $true }   # can't see it -> assume still there
    return ($null -ne $seq.accounts."$num")
}

function Get-ActiveAccountNum {
    $seq = Read-Sequence
    if ($null -eq $seq) { return -1 }
    try { return [int]$seq.activeAccountNumber } catch { return -1 }
}

function Switch-Account($acct) {
    if (-not $acct -or $acct.Active) { return }
    $script:pinned = $true          # keep the popup up across the call
    $script:busy = "trocando de conta..."
    Build-Popup
    [System.Windows.Forms.Application]::DoEvents()

    $r = Invoke-Cswap @('--switch-to', "$($acct.Num)")
    $script:busy = $null
    # cswap refuses to switch while a Claude session is running. Confirm against
    # sequence.json rather than the exit code, same reason as in Remove-Account.
    if (-not $r.Ok -or (Get-ActiveAccountNum) -ne [int]$acct.Num) {
        $msg = if ($r.Output) { $r.Output } else { "cswap saiu com codigo $($r.ExitCode)." }
        Show-Message "Conta NAO trocada.`n`n$msg" 'Trocar de conta' ([System.Windows.Forms.MessageBoxIcon]::Warning)
    }
    # The active account changed on disk: re-read everything, tokens included.
    Start-Refresh
}

# cswap's own confirmation is an input() prompt on stdin. We ask the user with a
# real dialog first, then feed it "y" - never the other way round.
#
# Removal legitimately fails when a live Claude session is using that account
# (cswap's _ensure_no_live_session): surface that message instead of pretending
# it worked.
function Remove-Account($acct) {
    if (-not $acct) { return }
    $script:pinned = $true
    $script:modal = $true
    $warn = if ($acct.Active) { "`n`nATENCAO: esta e a conta ATIVA no momento." } else { "" }
    $ans = [System.Windows.Forms.MessageBox]::Show($popup,
        "Remover permanentemente a conta $($acct.Num) ($($acct.Email)) do cswap?$warn`n`nO login em si nao e cancelado - o cswap apaga a credencial guardada.",
        'Remover conta',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    $script:modal = $false
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $script:busy = "removendo conta..."
    Build-Popup
    [System.Windows.Forms.Application]::DoEvents()

    # Pass the NUMBER, never the email: an email that matches more than one
    # account sends cswap down an interactive disambiguation prompt.
    $r = Invoke-Cswap @('remove', "$($acct.Num)") -StdinText "y`n"
    $script:busy = $null

    # Exit code 0 is NOT proof of removal: cswap answers "Cancelled" with 0 too,
    # and it refuses (by design) while a live Claude session holds the account.
    # Ask the on-disk truth instead of trusting the status code.
    if (Test-AccountExists $acct.Num) {
        $msg = if ($r.Output) { $r.Output } else { "cswap saiu com codigo $($r.ExitCode)." }
        Show-Message "Conta NAO removida.`n`n$msg" 'Remover conta' ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
    Start-Refresh
}

# Auto-switch: the DECISION and the WRITE both live in cswap now. The
# background Collect runs `cswap auto --once --json` (when the toggle is on)
# right before fetching the account list, so any switch is already reflected
# in the same refresh - no extra re-fetch, no post-hoc confirmation. cswap's
# engine owns the whole policy: proactive threshold (default 90%) with a
# hysteresis margin, a cooldown that an at-limit account bypasses, token
# freshening of the target, quarantine of dead refresh tokens, and failover
# when the active account's usage turns unreadable. It persists its own state
# (autoswitch_state.json) under file locks, which also closes the old
# "switched:true but silently reverted" race this app used to re-check for
# with Get-ActiveAccountNum - the checker and the switcher are the same
# process now. Tune it with `cswap config set autoswitch.*`, not here.
#
# This function only translates the tick's events into balloons. It runs
# unattended off the refresh timer, so it must never block or open a modal:
#   switch              -> info balloon (the fresh list already shows it)
#   account-quarantined -> warning balloon (engine emits only on transition)
#   all-exhausted       -> warning balloon, ONE per episode (autoSwitchWarned)
#   exit 0/2            -> episode over: re-arm the all-exhausted balloon
# Everything else (below-threshold, hysteresis misses, transient errors) is
# routine - stay silent and let the next refresh re-evaluate.
function Show-AutoSwitchEvents($auto) {
    if (-not $auto -or $null -eq $auto.Events) { return }
    foreach ($ev in @($auto.Events)) {
        switch ("$($ev.event)") {
            'switch' {
                if (-not $ev.dryRun -and $ev.to) {
                    $from = if ($ev.from) { "$($ev.from.number)" } else { '?' }
                    $msg = "Conta trocada automaticamente: $from -> $($ev.to.number) ($($ev.to.email)) [$($ev.trigger)]"
                    try { $notify.ShowBalloonTip(4000, 'Claude Usage', $msg, [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
                }
            }
            'account-quarantined' {
                $msg = "Conta $($ev.number) ($($ev.email)) em quarentena: $($ev.reason). Recupere com 'cswap --add-account --slot $($ev.number)'."
                try { $notify.ShowBalloonTip(5000, 'Claude Usage', $msg, [System.Windows.Forms.ToolTipIcon]::Warning) } catch {}
            }
            'all-exhausted' {
                if (-not $script:autoSwitchWarned) {
                    $script:autoSwitchWarned = $true
                    $when = ''
                    if ($ev.earliestResetAt) {
                        $clock = Format-ResetClock "$($ev.earliestResetAt)"
                        if ($clock) { $when = " Reset mais cedo: $clock." }
                    }
                    try {
                        $notify.ShowBalloonTip(5000, 'Claude Usage',
                            "Todas as contas esgotadas - sem alvo para troca automatica.$when",
                            [System.Windows.Forms.ToolTipIcon]::Warning)
                    } catch {}
                }
            }
        }
    }
    if ($auto.Exit -eq 0 -or $auto.Exit -eq 2) { $script:autoSwitchWarned = $false }
}

# ---------------------------------------------------------------------------
# Background refresh
# ---------------------------------------------------------------------------
function Start-Refresh {
    if ($script:fetching) { return }
    $script:fetching = $true
    try {
        $rs = [runspacefactory]::CreateRunspace([initialsessionstate]::CreateDefault())
        try { $rs.ApartmentState = 'MTA' } catch {}
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:Collect).AddArgument([bool]$script:autoSwitchEnabled)
        $script:job = [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
        $pollTimer.Start()
    } catch {
        $script:fetching = $false
    }
    if ($script:visible) { Build-Popup }
}

function Complete-Refresh {
    $job = $script:job
    $script:job = $null
    $script:fetching = $false
    $pollTimer.Stop()
    if (-not $job) { return }

    $raw = $null
    try {
        $res = $job.PS.EndInvoke($job.Handle)
        if ($res -and $res.Count -gt 0) { $raw = "$($res[$res.Count - 1])" }
    } catch {}
    try { $job.PS.Dispose() } catch {}
    try { $job.RS.Close(); $job.RS.Dispose() } catch {}

    $parsed = ConvertFrom-CollectJson $raw
    $accounts = @($parsed.Accounts)
    if ($accounts.Count -gt 0) {
        $script:data      = $accounts
        $script:updatedAt = Get-Date
        $script:stale     = $false
        Save-Snapshot
        Update-TrayIcon
        try { Show-AutoSwitchEvents $parsed.Auto } catch {}

        # Back off when Anthropic throttles us. One tray poll per minute times N
        # accounts, alongside cswap's own calls, is enough to earn a 429 - and a
        # throttled poll returns nothing useful anyway, so hammering is pure loss.
        # Double the interval up to 10 min; snap back on the first clean round.
        $throttled = @($accounts | Where-Object { "$($_.Status)" -eq 'ratelimited' }).Count -gt 0
        if ($throttled) {
            $next = [Math]::Min($refreshTimer.Interval * 2, $MAX_REFRESH_MS)
        } else {
            $next = $BASE_REFRESH_MS
        }
        if ($next -ne $refreshTimer.Interval) {
            $refreshTimer.Stop(); $refreshTimer.Interval = $next; $refreshTimer.Start()
        }
    }
    if ($script:visible) { Build-Popup; Move-Popup }
}

# ---------------------------------------------------------------------------
# Popup
# ---------------------------------------------------------------------------
$popup = New-Object System.Windows.Forms.Form
$popup.FormBorderStyle = 'None'
$popup.ShowInTaskbar   = $false
$popup.TopMost         = $true
$popup.StartPosition   = 'Manual'
$popup.AutoScaleMode   = 'None'
$popup.BackColor       = $cBg
$popup.KeyPreview      = $true
$popup.ClientSize      = Sz $W_POPUP 120

# Control.SetStyle is protected; reflection is the only way from PowerShell.
# Without it, rebuilding the content while the popup is open flickers.
try {
    $mi = [System.Windows.Forms.Control].GetMethod('SetStyle', [Reflection.BindingFlags]'NonPublic,Instance')
    $styles = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
              [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint
    $mi.Invoke($popup, @([System.Windows.Forms.ControlStyles]$styles, $true))
} catch {}

# Force the handle now so we can ShowWindow(SW_SHOWNOACTIVATE) it later without
# ever calling Show()/Visible, which would steal focus from whatever the user is
# typing in.
$null = $popup.Handle
try { $corner = 2; [void][Native]::DwmSetWindowAttribute($popup.Handle, 33, [ref]$corner, 4) } catch {}
# Whole-window compositing: the popup and all its children paint as one frame.
try { [Native]::EnableComposited($popup.Handle) } catch {}

$popup.add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen($cLine, 1)
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.ClientSize.Width - 1, $s.ClientSize.Height - 1)
    $pen.Dispose()
})
$popup.add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { Hide-Popup } })
# Clicking away from a pinned popup dismisses it, like a real menu. But a modal
# dialog we opened ourselves also deactivates the popup - don't vanish behind it.
$popup.add_Deactivate({ if ($script:pinned -and -not $script:modal) { Hide-Popup } })

function New-Label($text, $font, $color, $x, $y, $w, $h, $align) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Font = $font
    $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.AutoSize = $false
    $l.AutoEllipsis = $true
    $l.Location = Pt $x $y
    $l.Size = Sz $w $h
    if ($align) { $l.TextAlign = $align }
    return $l
}

function New-Bar($parent, $x, $y, $w, $h, $pct, $fillColor) {
    $track = New-Object System.Windows.Forms.Panel
    $track.BackColor = $cTrack
    $track.Location = Pt $x $y
    $track.Size = Sz $w $h
    $parent.Controls.Add($track)
    if ($null -ne $pct) {
        # Floor at 2px so a 1% reading is still visibly non-zero.
        $fillW = [math]::Max(2, [int]((Px $w) * ([math]::Min(100, [int]$pct) / 100.0)))
        $fill = New-Object System.Windows.Forms.Panel
        $fill.BackColor = if ($fillColor) { $fillColor } else { Get-UsageColor ([int]$pct) }
        $fill.Location = New-Object System.Drawing.Point(0, 0)
        $fill.Size = New-Object System.Drawing.Size($fillW, (Px $h))
        $track.Controls.Add($fill)
    }
    return $track
}

# One labelled bar with its percentage and reset time. Returns the next y.
# labelW is wide enough for a model name like "Fable"/"opus", not just "5h".
# $stale dims the whole row (grey fill, muted percentage): same information,
# visibly demoted, so it can never be mistaken for this minute's reading.
function Add-UsageRow($card, $bar, $y, $cardW, [bool]$stale) {
    $labelW = 44
    $pctW   = 42
    $barX   = 12 + $labelW
    $barW   = $cardW - $barX - $pctW - 12
    $fill   = if ($stale) { $cStale } else { $null }
    $pctCol = if ($stale) { $cMuted } else { $cText }

    $card.Controls.Add((New-Label $bar.Label $FONT_ROW $cMuted 12 $y $labelW 15 $null))
    New-Bar $card $barX ($y + 4) $barW $BAR_H ([int]$bar.Pct) $fill | Out-Null
    $card.Controls.Add((New-Label ("{0}%" -f [int]$bar.Pct) $FONT_ROW $pctCol ($barX + $barW + 4) ($y - 1) $pctW 16 'MiddleRight'))

    $clock = Format-ResetClock $bar.ResetsAt
    if ($clock) {
        $rel = Format-ResetRel $bar.ResetsAt
        $txt = if ($rel) { "$GLYPH_RESET $clock  (in $rel)" } else { "$GLYPH_RESET $clock" }
        $card.Controls.Add((New-Label $txt $FONT_RESET $cSubtle $barX ($y + 14) ($cardW - $barX - 12) 14 $null))
        return ($y + 31)
    }
    return ($y + 20)
}

# Make a panel behave as one clickable row. Child labels/bars swallow clicks and
# mouse-enter, so every descendant gets the same handlers - otherwise clicking
# the usage bar (most of the row's area) would do nothing.
#
# Everything the handlers need is stashed in each control's .Tag (panel + colors
# + click). The handlers read $this.Tag at fire time, so nothing depends on a
# closure capturing $panel - a nested-scope GetNewClosure DOESN'T capture it, and
# that was crashing OnMouseEnter with "BackColor not found on this object".
function Set-RowInteractive($panel, $normalColor, $hoverColor, [scriptblock]$onClick) {
    $ctx = [pscustomobject]@{ Panel = $panel; Normal = $normalColor; Hover = $hoverColor; Click = $onClick }
    $enter = { $t = $this.Tag; if ($t) { $t.Panel.BackColor = $t.Hover } }
    $leave = {
        $t = $this.Tag
        if ($t) {
            # Leaving a child for its parent also fires MouseLeave on the child;
            # only un-highlight once the cursor is truly outside the whole row.
            $pt = $t.Panel.PointToClient([System.Windows.Forms.Cursor]::Position)
            if (-not $t.Panel.ClientRectangle.Contains($pt)) { $t.Panel.BackColor = $t.Normal }
        }
    }
    $click = { $t = $this.Tag; if ($t -and $t.Click) { & $t.Click } }
    $wire = {
        param($c)
        $c.Tag = $ctx
        $c.Add_MouseEnter($enter)
        $c.Add_MouseLeave($leave)
        $c.Add_Click($click)
        $c.Cursor = [System.Windows.Forms.Cursors]::Hand
    }
    & $wire $panel
    foreach ($c in $panel.Controls) {
        & $wire $c
        foreach ($g in $c.Controls) { & $wire $g }   # bar fill inside its track
    }
}

# Small "x" that removes the account. Kept visually quiet: destructive, rarely
# wanted, and always behind a confirmation.
function Add-RemoveButton($panel, $acct, $x, $y) {
    $b = New-Object System.Windows.Forms.Label
    $b.Text = [string][char]0x00D7          # multiplication sign: a real x glyph
    $b.Font = $FONT_CLOSE
    $b.ForeColor = $cSubtle
    $b.BackColor = [System.Drawing.Color]::Transparent
    $b.AutoSize = $false
    $b.TextAlign = 'MiddleCenter'
    $b.Size = Sz 18 18
    $b.Location = Pt $x $y
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Add_MouseEnter({ $this.ForeColor = [System.Drawing.Color]::FromArgb(229, 72, 77) })
    $b.Add_MouseLeave({ $this.ForeColor = $cSubtle })
    # Stop the click bubbling into the row's "switch to this account" handler.
    $b.Add_Click({ Remove-Account $acct }.GetNewClosure())
    $panel.Controls.Add($b)
    $b.BringToFront()
    return $b
}

function Build-Popup {
    $popup.SuspendLayout()
    foreach ($c in @($popup.Controls)) { $popup.Controls.Remove($c); $c.Dispose() }

    $innerW = $W_POPUP - 2 * $PAD
    $y = $PAD

    # --- header -------------------------------------------------------------
    $popup.Controls.Add((New-Label 'Claude Usage' $FONT_TITLE $cText $PAD $y 150 18 $null))
    $status = if ($script:busy) { $script:busy }
              elseif ($script:fetching -and -not $script:updatedAt) { 'loading...' }
              elseif ($script:fetching) { 'updating...' }
              elseif ($script:updatedAt) { $script:updatedAt.ToString('HH:mm') }
              else { '' }
    $popup.Controls.Add((New-Label $status $FONT_SMALL $cSubtle ($PAD + 150) ($y + 3) ($innerW - 150) 14 'TopRight'))
    $y += 26

    $active = Get-ActiveAccount
    $others = @()
    if ($script:data) { $others = @($script:data | Where-Object { -not $_.Active }) }

    if (-not $active) {
        $popup.Controls.Add((New-Label 'No Claude account found.' $FONT_ROW $cMuted $PAD $y $innerW 18 $null))
        $y += 26
    } else {
        # --- active account: full card ---------------------------------------
        $card = New-Object System.Windows.Forms.Panel
        $card.BackColor = $cActive
        $card.Location = Pt $PAD $y
        $cardW = $innerW

        $cy = 10
        $card.Controls.Add((New-Label $active.Email $FONT_EMAIL $cText 12 $cy ($cardW - 40) 18 $null))
        $cy += 19
        if ($active.Org) {
            $card.Controls.Add((New-Label $active.Org $FONT_ORG $cSubtle 12 $cy ($cardW - 24) 15 $null))
            $cy += 17
        }
        $cy += 4

        $aBars  = @($active.Bars)
        $aStale = [bool]$active.Stale
        if ($aBars.Count -eq 0) {
            $card.Controls.Add((New-Label ("sem dados - " + (Format-Status $active $true)) $FONT_ROW $cMuted 12 $cy ($cardW - 40) 18 $null))
            $cy += 22
        } else {
            foreach ($b in $aBars) { $cy = Add-UsageRow $card $b $cy $cardW $aStale }
            if ($aStale) {
                # Said once under the bars, not per row: they all come from the
                # same lastGoodUsage snapshot. The reason is appended only when
                # it adds something - "sem medicao recente" next to the age is
                # the same sentence twice.
                $tag = 'medicao de ' + (Format-StaleTag $active)
                if ("$($active.Status)" -ne 'nodata' -and "$($active.Status)" -ne 'ok') {
                    $tag = $tag + ' - ' + (Format-Status $active $false)
                }
                $card.Controls.Add((New-Label $tag $FONT_SMALL $cSubtle 12 $cy ($cardW - 24) 15 $null))
                $cy += 18
            }
        }
        $cy += 4
        $card.Size = Sz $cardW $cy
        $popup.Controls.Add($card)
        # The active account is removable too (cswap allows it, with a warning),
        # but it is NOT clickable-to-switch: it's already the active one.
        Add-RemoveButton $card $active ($cardW - 24) 8 | Out-Null
        $y += $cy + 10
    }

    # --- other accounts: compact rows ---------------------------------------
    if ($others.Count -gt 0) {
        $sep = New-Object System.Windows.Forms.Panel
        $sep.BackColor = $cLine
        $sep.Location = Pt $PAD $y
        $sep.Size = Sz $innerW 1
        $popup.Controls.Add($sep)
        $y += 9

        foreach ($a in $others) {
            # Compact rows show only the two windows the user compares at a glance
            # - session (5h) and weekly (7d). Per-model scoped windows (Fable etc.)
            # would crowd the row; they live in the active account's full card.
            $bars = @(@($a.Bars) | Where-Object { $_.Label -eq '5h' -or $_.Label -eq '7d' })

            # Each inactive account is one clickable card: click switches to it,
            # the trailing "x" removes it. Two rows tall when it has data (name +
            # the 5h/7d bars), one row tall when it doesn't.
            $hasData = $bars.Count -gt 0
            $rowH = if ($hasData) { 54 } else { 22 }
            $row = New-Object System.Windows.Forms.Panel
            $row.BackColor = $cBg
            $row.Location = Pt $PAD $y
            $rowW = $innerW
            $row.Size = Sz $rowW $rowH

            $delW  = 20
            $statW = 150
            $nameW = $rowW - $statW - $delW - 4

            # The right-hand tag always dates the numbers on its left: "agora"
            # for a fresh fetch, the measurement's age when they come from
            # cswap's lastGoodUsage, the reason when there are none at all.
            $stat = if (-not $hasData) { Format-Status $a $false }
                    elseif ($a.Stale)  { Format-StaleTag $a }
                    else               { 'agora' }

            $row.Controls.Add((New-Label "$($a.Num)  $($a.Email)" $FONT_ROW $cMuted 0 0 $nameW 16 $null))
            $row.Controls.Add((New-Label $stat $FONT_SMALL $cSubtle $nameW 1 $statW 15 'TopRight'))

            # Session (5h) and weekly (7d) each get their own labelled, full-width
            # half of the row - the two bars the user actually compares.
            if ($hasData) {
                $gap    = 10
                $slotW  = [int](($rowW - $delW - $gap * ($bars.Count - 1)) / $bars.Count)
                $lblW   = 24
                $pctW   = 34
                $bx = 0
                $fill = if ($a.Stale) { $cStale } else { $null }
                foreach ($b in $bars) {
                    $barW = $slotW - $lblW - $pctW - 4
                    $row.Controls.Add((New-Label $b.Label $FONT_SMALL $cSubtle $bx 21 $lblW 14 $null))
                    New-Bar $row ($bx + $lblW) 25 $barW 5 ([int]$b.Pct) $fill | Out-Null
                    $row.Controls.Add((New-Label ("{0}%" -f [int]$b.Pct) $FONT_SMALL $cMuted ($bx + $lblW + $barW + 2) 20 $pctW 14 'TopRight'))

                    # Reset time for this bar - same info the active card shows,
                    # just compact (relative only, no absolute clock: the slot
                    # is half the card's width).
                    $rel = Format-ResetRel $b.ResetsAt
                    if ($rel) {
                        $row.Controls.Add((New-Label "$GLYPH_RESET $rel" $FONT_RESET $cSubtle ($bx + $lblW) 33 ($slotW - $lblW) 14 $null))
                    }

                    $bx += $slotW + $gap
                }
            }

            $popup.Controls.Add($row)
            $acctRef = $a
            Set-RowInteractive $row $cBg $cCard { Switch-Account $acctRef }.GetNewClosure()
            # Added AFTER Set-RowInteractive so it keeps its own click handler
            # instead of inheriting the row's "switch to this account".
            Add-RemoveButton $row $acctRef ($rowW - $delW) 0 | Out-Null

            $y += $rowH + 4
        }
    }

    # --- footer -------------------------------------------------------------
    $y += 6
    $hint = if ($others.Count -gt 0) { 'clique numa conta para trocar  -  x remove' }
            else { 'clique para fixar  -  botao direito abre o menu' }
    $popup.Controls.Add((New-Label $hint $FONT_SMALL $cFoot $PAD $y $innerW 14 'TopCenter'))
    $y += 16 + $PAD - 8

    $popup.ClientSize = Sz $W_POPUP $y
    $popup.ResumeLayout()
    $popup.Invalidate()
}

# Screen rect of our tray icon, or $null if Windows won't say (icon hidden in
# the overflow flyout, or the reflection below stopped matching WinForms).
$script:nidHwnd = [IntPtr]::Zero
$script:nidId   = 0
function Resolve-NotifyIconIds {
    try {
        $t = $notify.GetType()
        $bf = [Reflection.BindingFlags]'NonPublic,Instance'
        $win = $t.GetField('window', $bf).GetValue($notify)
        $script:nidHwnd = $win.Handle
        $script:nidId   = [int]$t.GetField('id', $bf).GetValue($notify)
    } catch {
        $script:nidHwnd = [IntPtr]::Zero
    }
}

function Get-IconRect {
    if ($script:nidHwnd -eq [IntPtr]::Zero) { return $null }
    $l = 0; $t = 0; $r = 0; $b = 0
    try {
        if ([Native]::TryGetIconRect($script:nidHwnd, [uint32]$script:nidId, [ref]$l, [ref]$t, [ref]$r, [ref]$b)) {
            return New-Object System.Drawing.Rectangle($l, $t, ($r - $l), ($b - $t))
        }
    } catch {}
    return $null
}

# Anchor the popup to the icon and keep it inside the working area, whichever
# edge the taskbar is docked to.
function Move-Popup {
    $rect = Get-IconRect
    if ($null -eq $rect) { $rect = $script:anchor }
    if ($rect.Width -le 0) {
        $p = [System.Windows.Forms.Cursor]::Position
        $rect = New-Object System.Drawing.Rectangle($p.X, $p.Y, 1, 1)
    }

    $cx = $rect.Left + [int]($rect.Width / 2)
    $cy = $rect.Top + [int]($rect.Height / 2)
    $scr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point($cx, $cy)))
    $wa = $scr.WorkingArea
    $bd = $scr.Bounds
    $w = $popup.Width
    $h = $popup.Height
    $m = 6

    if ($wa.Width -lt $bd.Width) {
        # Vertical taskbar: hug its inner edge, center vertically on the icon.
        $x = if ($wa.Left -gt $bd.Left) { $wa.Left + $m } else { $wa.Right - $w - $m }
        $y = $cy - [int]($h / 2)
    } else {
        # Horizontal taskbar (the common case): sit above or below it.
        $x = $cx - [int]($w / 2)
        $y = if ($cy -gt ($bd.Top + $bd.Height / 2)) { $wa.Bottom - $h - $m } else { $wa.Top + $m }
    }

    if ($x -lt $wa.Left + $m) { $x = $wa.Left + $m }
    if ($x + $w -gt $wa.Right - $m) { $x = $wa.Right - $w - $m }
    if ($y -lt $wa.Top + $m) { $y = $wa.Top + $m }
    if ($y + $h -gt $wa.Bottom - $m) { $y = $wa.Bottom - $h - $m }

    $popup.Location = New-Object System.Drawing.Point($x, $y)
}

function Show-Popup([bool]$pin) {
    if ($script:menuOpen) { return }   # never fight the context menu for focus
    Build-Popup
    Move-Popup
    $script:leaveAt = 0
    $script:visible = $true
    if ($pin) {
        $script:pinned = $true
        $popup.Show()
        $popup.Activate()
    } else {
        $script:pinned = $false
        [void][Native]::ShowWindow($popup.Handle, $SW_SHOWNOACTIVATE)
    }
    $popup.TopMost = $true
    $hoverTimer.Start()

    # Opportunistic top-up: hovering never waits for it, the popup just fills in
    # when the call lands. Never sooner than half the current refresh interval,
    # so opening the popup repeatedly can't defeat the 429 backoff.
    $minAge = [Math]::Max(30, $refreshTimer.Interval / 2000)
    if (-not $script:updatedAt -or ((Get-Date) - $script:updatedAt).TotalSeconds -gt $minAge) { Start-Refresh }
}

function Hide-Popup {
    $hoverTimer.Stop()
    $script:visible = $false
    $script:pinned  = $false
    # SW_HIDE first: a popup shown via ShowWindow (never Show()) can leave
    # WinForms' Visible flag out of sync, and then Hide() alone is a no-op.
    try { [void][Native]::ShowWindow($popup.Handle, 0) } catch {}
    $popup.Hide()
}

# Rectangle is a struct, but PowerShell hands out the same boxed instance on
# assignment - so Inflate() on a "copy" would silently mutate the original.
# Always build a new one.
function Grow-Rect($r, [int]$by) {
    return New-Object System.Drawing.Rectangle(
        ($r.Left - $by), ($r.Top - $by), ($r.Width + 2 * $by), ($r.Height + 2 * $by))
}

if ($Preview) {
    # DrawToBitmap uses WM_PRINT, so the window has to exist but doesn't have to
    # be on a visible part of the desktop.
    if (-not (Test-Path -LiteralPath $Preview)) { New-Item -ItemType Directory -Force -Path $Preview | Out-Null }
    # .Accounts, not the envelope: $script:data is the account array everywhere
    # else, and handing Build-Popup the envelope drew a card for a non-account.
    $script:data = @((ConvertFrom-CollectJson (& $script:Collect)).Accounts)
    $script:updatedAt = Get-Date
    $script:stale = $false

    Build-Popup
    $popup.Location = New-Object System.Drawing.Point(-6000, -6000)
    [void][Native]::ShowWindow($popup.Handle, $SW_SHOWNOACTIVATE)
    $bmp = New-Object System.Drawing.Bitmap($popup.ClientSize.Width, $popup.ClientSize.Height)
    $popup.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)))
    $popupPng = Join-Path $Preview 'popup.png'
    $bmp.Save($popupPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose(); $popup.Hide()

    # The ring at its real pixel size, then magnified so the anti-aliasing is
    # actually inspectable.
    # Two rows: live (top) and stale (bottom, grey arc) - the stale ring has no
    # text to explain itself, so it has to be checkable side by side.
    $strip = New-Object System.Drawing.Bitmap(628, 184)
    $sg = [System.Drawing.Graphics]::FromImage($strip)
    $sg.Clear([System.Drawing.Color]::FromArgb(24, 24, 27))
    $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $sg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $rowY = 16
    foreach ($isStale in @($false, $true)) {
        $x = 12
        # The last four cross $TAIL_FROM_PCT: 89 is the normal scale, 93/96/100
        # are the zoomed one - which is exactly the transition worth eyeballing.
        foreach ($p in @(0, 45, 72, 89, 93, 96, 100)) {
            $h = New-RingIcon $p $isStale
            $ic = [System.Drawing.Icon]::FromHandle($h)
            $ib = $ic.ToBitmap()
            $sg.DrawImage($ib, $x, $rowY, 72, 72)
            $ib.Dispose(); $ic.Dispose(); [void][Native]::DestroyIcon($h)
            $x += 88
        }
        $rowY += 88
    }
    $sg.Dispose()
    $iconPng = Join-Path $Preview 'icons.png'
    $strip.Save($iconPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $strip.Dispose()

    "popup -> $popupPng ($($popup.ClientSize.Width)x$($popup.ClientSize.Height) px, scale $($script:scale))"
    "icons -> $iconPng (0, 45, 72, 89, 93, 96, 100 % - linha 1 ao vivo, linha 2 stale)"
    exit 0
}

# ---------------------------------------------------------------------------
# Tray icon + hover behaviour
# ---------------------------------------------------------------------------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Application
$notify.Text = 'Claude Usage - loading...'
$notify.Visible = $true
Resolve-NotifyIconIds

$notify.add_MouseMove({
    param($s, $e)
    try {
        # While the right-click menu is up, moving the mouse over the icon must
        # NOT reopen the popup - a reopened TopMost popup steals focus and closes
        # the menu before the user can pick anything.
        if ($script:menuOpen) { return }
        if (-not $script:visible) {
            # Remember where the icon was, as a fallback anchor/hot zone for when
            # Shell_NotifyIconGetRect won't answer.
            $p = [System.Windows.Forms.Cursor]::Position
            $script:anchor = New-Object System.Drawing.Rectangle(($p.X - 10), ($p.Y - 10), 20, 20)
            Show-Popup $false
        }
        $script:leaveAt = 0
    } catch {}
})

$notify.add_MouseClick({
    param($s, $e)
    try {
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        if ($script:pinned)      { Hide-Popup }
        elseif ($script:visible) { $script:pinned = $true; $popup.Activate() }
        else                     { Show-Popup $true }
    } catch {}
})

# A hover popup has to decide when the mouse has "left". The hot zone is the
# popup plus the icon (plus slack for the gap between them); leaving only counts
# after a short grace, so sweeping across the gap doesn't dismiss it.
$hoverTimer = New-Object System.Windows.Forms.Timer
$hoverTimer.Interval = 60
$hoverTimer.add_Tick({
  try {
    if (-not $script:visible -or $script:pinned -or $script:modal) { return }
    $p = [System.Windows.Forms.Cursor]::Position

    $inZone = (Grow-Rect $popup.Bounds 8).Contains($p)
    if (-not $inZone) {
        $ir = Get-IconRect
        if ($null -eq $ir) { $ir = $script:anchor }
        if ($ir.Width -gt 0) { $inZone = (Grow-Rect $ir 10).Contains($p) }
    }

    if ($inZone) { $script:leaveAt = 0; return }
    if ($script:leaveAt -eq 0) { $script:leaveAt = [Environment]::TickCount; return }
    if (([Environment]::TickCount - $script:leaveAt) -gt 220) { Hide-Popup }
  } catch { try { Hide-Popup } catch {} }
})

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 150
$pollTimer.add_Tick({
    # An exception escaping a WinForms event handler becomes a modal .NET crash
    # dialog, which for a tray app is worse than any bug it reports. Swallow,
    # and make sure the poll loop can't spin forever on a wedged job.
    try {
        if (-not $script:job) { $pollTimer.Stop(); return }
        if ($script:job.Handle.IsCompleted) { Complete-Refresh }
    } catch {
        $pollTimer.Stop()
        $script:job = $null
        $script:fetching = $false
    }
})

$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = $BASE_REFRESH_MS
$refreshTimer.add_Tick({ try { Start-Refresh } catch {} })

# ---------------------------------------------------------------------------
# Context menu
# ---------------------------------------------------------------------------
function Test-StartupEnabled { return (Test-Path -LiteralPath $script:startupLnk) }

function Set-Startup([bool]$enable) {
    try {
        if (-not $enable) {
            if (Test-Path -LiteralPath $script:startupLnk) { Remove-Item -LiteralPath $script:startupLnk -Force }
            return
        }
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($script:startupLnk)
        if ($script:isExe) {
            $lnk.TargetPath = $script:selfPath
        } else {
            # Running as a raw .ps1: launch it through a hidden PowerShell host.
            $lnk.TargetPath = (Get-Process -Id $PID).Path
            $lnk.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:selfPath)`""
        }
        $lnk.WorkingDirectory = $script:selfDir
        $lnk.Description = 'Claude usage in the system tray'
        $lnk.Save()
    } catch {}
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miRefresh = $menu.Items.Add('Refresh now')
$miRefresh.add_Click({ Start-Refresh })

$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem('Start with Windows')
$miStartup.CheckOnClick = $true
$miStartup.Checked = Test-StartupEnabled
$miStartup.add_Click({ Set-Startup ([bool]$miStartup.Checked) })
[void]$menu.Items.Add($miStartup)

$miAutoSwitch = New-Object System.Windows.Forms.ToolStripMenuItem('Auto-switch de conta')
$miAutoSwitch.CheckOnClick = $true
$miAutoSwitch.Checked = $script:autoSwitchEnabled
$miAutoSwitch.add_Click({
    $script:autoSwitchEnabled = [bool]$miAutoSwitch.Checked
    Save-Settings
})
[void]$menu.Items.Add($miAutoSwitch)

# Only offer the switcher if it's actually sitting next to us.
$switchExe = Join-Path (Split-Path -Parent $script:selfDir) 'claude-switch-gui\Claude Switch.exe'
if (Test-Path -LiteralPath $switchExe) {
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miSwitch = $menu.Items.Add('Open Claude Switch')
    $miSwitch.add_Click({ try { Start-Process -FilePath $switchExe } catch {} })
}

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit = $menu.Items.Add('Exit')
$miExit.add_Click({
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

# Opening the menu while hovering would leave the popup stranded on top of it.
# Guard the whole time the menu is up: opening hides the popup and blocks the
# hover from reopening it (MouseMove/Show-Popup both check $script:menuOpen);
# closing clears the guard so hover works again.
$menu.add_Opening({ $script:menuOpen = $true; if ($script:visible) { Hide-Popup } })
$menu.add_Closed({ $script:menuOpen = $false })
$notify.ContextMenuStrip = $menu

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
Load-Snapshot
Update-TrayIcon
Start-Refresh
$refreshTimer.Start()

[System.Windows.Forms.Application]::Run()

# Without this the icon lingers as a ghost until the user mouses over the tray.
try { $notify.Visible = $false; $notify.Dispose() } catch {}
try { if ($script:iconObj) { $script:iconObj.Dispose() } } catch {}
try { if ($script:iconHandle -ne [IntPtr]::Zero) { [void][Native]::DestroyIcon($script:iconHandle) } } catch {}
try { $script:mutex.ReleaseMutex() } catch {}
