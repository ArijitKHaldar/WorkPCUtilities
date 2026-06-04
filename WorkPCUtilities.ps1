[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    $relaunchArgs = @(
        '-STA'
        '-ExecutionPolicy', 'Bypass'
        '-File', $PSCommandPath
    )

    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $relaunchArgs -WindowStyle Hidden
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Security

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", CharSet = CharSet.Auto, ExactSpelling = true)]
    public static extern void keybd_event(byte bVk, byte bScan, int dwFlags, int extraInfo);

    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
'@

try {
    $consoleHandle = [NativeMethods]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [NativeMethods]::ShowWindow($consoleHandle, 0) | Out-Null
    }
}
catch {
    # If the console cannot be hidden, the GUI still works.
}

$script:AppRoot = Join-Path $env:APPDATA 'WorkPCUtilities'
$script:SettingsPath = Join-Path $script:AppRoot 'settings.json'
$script:VaultPath = Join-Path $script:AppRoot 'vault.dat'

$script:MainWindow = $null
$script:AllTotpWindow = $null
$script:KeepAliveTimer = $null
$script:ClockTimer = $null
$script:ThemeTimer = $null
$script:CaffeinateRunning = $false
$script:CurrentAppliedTheme = $null
$script:IsLoadingUi = $true
$script:WpfShellInitialized = $false
$script:VaultItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'

function Ensure-AppRoot {
    if (-not (Test-Path -LiteralPath $script:AppRoot)) {
        New-Item -ItemType Directory -Path $script:AppRoot -Force | Out-Null
    }
}

function New-Brush {
    param(
        [Parameter(Mandatory = $true)][byte]$R,
        [Parameter(Mandatory = $true)][byte]$G,
        [Parameter(Mandatory = $true)][byte]$B,
        [byte]$A = 255
    )

    $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($A, $R, $G, $B))
    $brush.Freeze()
    return $brush
}

function Get-ThemeResource {
    param([Parameter(Mandatory = $true)][string]$Key)

    $value = [System.Windows.Application]::Current.Resources[$Key]
    if ($null -eq $value) {
        return $null
    }

    return $value.PSObject.BaseObject
}

function Get-DefaultSettings {
    $localZone = [System.TimeZoneInfo]::Local.Id
    $clientZone = 'UTC'
    if (-not ([System.TimeZoneInfo]::GetSystemTimeZones() | Where-Object { $_.Id -eq $clientZone })) {
        $clientZone = $localZone
    }

    [pscustomobject]@{
        ThemeMode            = 'System'
        LocalClockZoneId     = $localZone
        ClientClockZoneId     = $clientZone
        WindowWidth          = 1280
        WindowHeight         = 860
        WindowLeft           = $null
        WindowTop            = $null
        WindowState          = 'Normal'
        SelectedTabIndex     = 0
        CaffeinateIntervalSec = 120
    }
}

function Merge-ObjectProperties {
    param(
        [Parameter(Mandatory = $true)]$Base,
        [Parameter(Mandatory = $true)]$Overlay
    )

    $result = [ordered]@{}
    foreach ($property in $Base.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }

    foreach ($property in $Overlay.PSObject.Properties) {
        if ($null -ne $property.Value -and $property.Value -ne '') {
            $result[$property.Name] = $property.Value
        }
    }

    [pscustomobject]$result
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Depth = 20
    )

    $json = $Object | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return $raw | ConvertFrom-Json
}

function Backup-CorruptFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path (Split-Path -Parent $Path) ("{0}.corrupt.{1}" -f $Prefix, $stamp)
    Move-Item -LiteralPath $Path -Destination $backup -Force
}

function ConvertTo-Bytes {
    param([Parameter(Mandatory = $true)][string]$Text)
    [System.Text.Encoding]::UTF8.GetBytes($Text)
}

function ConvertFrom-Bytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Protect-String {
    param([Parameter(Mandatory = $true)][string]$PlainText)

    $bytes = ConvertTo-Bytes -Text $PlainText
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [Convert]::ToBase64String($protected)
}

function Unprotect-String {
    param([Parameter(Mandatory = $true)][string]$ProtectedText)

    $bytes = [Convert]::FromBase64String($ProtectedText)
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    ConvertFrom-Bytes -Bytes $plain
}

function Get-SystemThemeMode {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $value = $null
    try {
        $value = Get-ItemPropertyValue -Path $path -Name AppsUseLightTheme -ErrorAction Stop
    }
    catch {
        $value = 1
    }

    if ($value -eq 0) { 'Dark' } else { 'Light' }
}

function Get-EffectiveThemeMode {
    param([Parameter(Mandatory = $true)][string]$ThemeMode)

    switch ($ThemeMode) {
        'Light' { 'Light' }
        'Dark'  { 'Dark' }
        default  { Get-SystemThemeMode }
    }
}

function Set-AppTheme {
    param(
        [Parameter(Mandatory = $true)][string]$ThemeMode
    )

    $mode = Get-EffectiveThemeMode -ThemeMode $ThemeMode
    $script:CurrentAppliedTheme = $mode

    $palette = switch ($mode) {
        'Dark' {
            @{
                WindowBackground = (New-Brush 11 18 32)
                Surface          = (New-Brush 17 27 46)
                SurfaceAlt       = (New-Brush 23 36 58)
                Border           = (New-Brush 40 55 80)
                Text             = (New-Brush 244 247 252)
                Muted            = (New-Brush 152 165 184)
                Accent           = (New-Brush 56 189 248)
                AccentText       = (New-Brush 5 14 23)
                InputBackground  = (New-Brush 15 23 42)
                InputBorder      = (New-Brush 49 65 88)
                Selection        = (New-Brush 37 99 235)
                Success          = (New-Brush 52 211 153)
                Warning          = (New-Brush 251 191 36)
                Danger           = (New-Brush 248 113 113)
            }
        }
        default {
            @{
                WindowBackground = (New-Brush 244 247 252)
                Surface          = (New-Brush 255 255 255)
                SurfaceAlt       = (New-Brush 238 244 252)
                Border           = (New-Brush 214 224 235)
                Text             = (New-Brush 17 24 39)
                Muted            = (New-Brush 99 114 129)
                Accent           = (New-Brush 37 99 235)
                AccentText       = (New-Brush 255 255 255)
                InputBackground  = (New-Brush 255 255 255)
                InputBorder      = (New-Brush 200 210 223)
                Selection        = (New-Brush 191 219 254)
                Success          = (New-Brush 16 185 129)
                Warning          = (New-Brush 245 158 11)
                Danger           = (New-Brush 220 38 38)
            }
        }
    }

    $resources = [System.Windows.Application]::Current.Resources
    foreach ($key in $palette.Keys) {
        $resourceKey = switch ($key) {
            'WindowBackground' { 'WindowBackgroundBrush' }
            'Surface'          { 'SurfaceBrush' }
            'SurfaceAlt'       { 'SurfaceAltBrush' }
            'Border'           { 'SurfaceBorderBrush' }
            'Text'             { 'TextBrush' }
            'Muted'            { 'MutedTextBrush' }
            'Accent'           { 'AccentBrush' }
            'AccentText'       { 'AccentTextBrush' }
            'InputBackground'  { 'InputBackgroundBrush' }
            'InputBorder'      { 'InputBorderBrush' }
            'Selection'        { 'SelectionBrush' }
            'Success'          { 'SuccessBrush' }
            'Warning'          { 'WarningBrush' }
            'Danger'           { 'DangerBrush' }
        }

        $resources[$resourceKey] = $palette[$key].PSObject.BaseObject
    }

    Apply-MainWindowThemeSurface
}

function Apply-MainWindowThemeSurface {
    $window = $script:MainWindow
    if (-not $window) {
        return
    }

    $surface = Get-ThemeResource -Key 'SurfaceBrush'
    $border = Get-ThemeResource -Key 'SurfaceBorderBrush'
    $windowBg = Get-ThemeResource -Key 'WindowBackgroundBrush'

    if ($windowBg) {
        $window.Background = $windowBg
    }

    foreach ($name in @(
        'HeaderCard',
        'CaffeinateCard',
        'CaffeinateStatusCard',
        'LocalClockCard',
        'ClientClockCard',
        'VaultActionCard',
        'FooterCard'
    )) {
        $element = $window.FindName($name)
        if ($element) {
            $element.Background = $surface
            $element.BorderBrush = $border
        }
    }
}

function Apply-MutedTextBrushes {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Window]$Window,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $muted = Get-ThemeResource -Key 'MutedTextBrush'
    foreach ($name in $Names) {
        $element = $Window.FindName($name)
        if ($element) {
            $element.Foreground = $muted
        }
    }
}

function Build-ThemeStyles {
    $xaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Style x:Key="ModernTabItemStyle" TargetType="{x:Type TabItem}">
        <Setter Property="Foreground" Value="{DynamicResource MutedTextBrush}" />
        <Setter Property="Background" Value="{DynamicResource SurfaceAltBrush}" />
        <Setter Property="BorderBrush" Value="{DynamicResource SurfaceBorderBrush}" />
        <Setter Property="BorderThickness" Value="1" />
        <Setter Property="Padding" Value="16,9" />
        <Setter Property="Margin" Value="0,0,8,0" />
        <Setter Property="FontWeight" Value="SemiBold" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type TabItem}">
                    <Border x:Name="Bd"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            CornerRadius="12,12,0,0"
                            Padding="{TemplateBinding Padding}">
                        <ContentPresenter ContentSource="Header"
                                          HorizontalAlignment="Center"
                                          VerticalAlignment="Center" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SurfaceBrush}" />
                            <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
                        </Trigger>
                        <Trigger Property="IsSelected" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SurfaceBrush}" />
                            <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource AccentBrush}" />
                            <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style x:Key="PrimaryButtonStyle" TargetType="{x:Type Button}">
        <Setter Property="Foreground" Value="{DynamicResource AccentTextBrush}" />
        <Setter Property="Background" Value="{DynamicResource AccentBrush}" />
        <Setter Property="BorderBrush" Value="{DynamicResource AccentBrush}" />
        <Setter Property="BorderThickness" Value="1" />
        <Setter Property="Padding" Value="14,9" />
        <Setter Property="Margin" Value="0,0,10,0" />
        <Setter Property="MinHeight" Value="38" />
        <Setter Property="Cursor" Value="Hand" />
        <Setter Property="FontWeight" Value="SemiBold" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Button}">
                    <Border x:Name="Bd"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            CornerRadius="12"
                            Padding="{TemplateBinding Padding}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Opacity" Value="0.92" />
                        </Trigger>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="Bd" Property="RenderTransform">
                                <Setter.Value>
                                    <ScaleTransform ScaleX="0.985" ScaleY="0.985" />
                                </Setter.Value>
                            </Setter>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter TargetName="Bd" Property="Opacity" Value="0.5" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style x:Key="SecondaryButtonStyle" TargetType="{x:Type Button}">
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
        <Setter Property="Background" Value="{DynamicResource SurfaceAltBrush}" />
        <Setter Property="BorderBrush" Value="{DynamicResource SurfaceBorderBrush}" />
        <Setter Property="BorderThickness" Value="1" />
        <Setter Property="Padding" Value="14,9" />
        <Setter Property="Margin" Value="0,0,10,0" />
        <Setter Property="MinHeight" Value="38" />
        <Setter Property="Cursor" Value="Hand" />
        <Setter Property="FontWeight" Value="SemiBold" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Button}">
                    <Border x:Name="Bd"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            CornerRadius="12"
                            Padding="{TemplateBinding Padding}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SurfaceBrush}" />
                        </Trigger>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="Bd" Property="RenderTransform">
                                <Setter.Value>
                                    <ScaleTransform ScaleX="0.985" ScaleY="0.985" />
                                </Setter.Value>
                            </Setter>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter TargetName="Bd" Property="Opacity" Value="0.5" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style x:Key="DangerButtonStyle" TargetType="{x:Type Button}">
        <Setter Property="Foreground" Value="White" />
        <Setter Property="Background" Value="{DynamicResource DangerBrush}" />
        <Setter Property="BorderBrush" Value="{DynamicResource DangerBrush}" />
        <Setter Property="BorderThickness" Value="1" />
        <Setter Property="Padding" Value="14,9" />
        <Setter Property="Margin" Value="0,0,10,0" />
        <Setter Property="MinHeight" Value="38" />
        <Setter Property="Cursor" Value="Hand" />
        <Setter Property="FontWeight" Value="SemiBold" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Button}">
                    <Border x:Name="Bd"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            CornerRadius="12"
                            Padding="{TemplateBinding Padding}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Opacity" Value="0.92" />
                        </Trigger>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="Bd" Property="RenderTransform">
                                <Setter.Value>
                                    <ScaleTransform ScaleX="0.985" ScaleY="0.985" />
                                </Setter.Value>
                            </Setter>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="{x:Type TextBox}">
        <Setter Property="Background" Value="{DynamicResource InputBackgroundBrush}" />
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
        <Setter Property="BorderBrush" Value="{DynamicResource InputBorderBrush}" />
        <Setter Property="BorderThickness" Value="1" />
        <Setter Property="Padding" Value="10,8" />
        <Setter Property="MinHeight" Value="36" />
        <Setter Property="VerticalContentAlignment" Value="Center" />
        <Setter Property="CaretBrush" Value="{DynamicResource TextBrush}" />
    </Style>

    <Style TargetType="{x:Type ComboBox}">
        <Setter Property="Background" Value="{DynamicResource InputBackgroundBrush}" />
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
        <Setter Property="BorderBrush" Value="{DynamicResource InputBorderBrush}" />
        <Setter Property="BorderThickness" Value="1" />
        <Setter Property="MinHeight" Value="36" />
        <Setter Property="Padding" Value="10,8" />
    </Style>

    <Style TargetType="{x:Type DataGrid}">
        <Setter Property="Background" Value="{DynamicResource SurfaceBrush}" />
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
        <Setter Property="BorderBrush" Value="{DynamicResource SurfaceBorderBrush}" />
        <Setter Property="BorderThickness" Value="1" />
        <Setter Property="RowBackground" Value="{DynamicResource SurfaceBrush}" />
        <Setter Property="AlternatingRowBackground" Value="{DynamicResource SurfaceAltBrush}" />
        <Setter Property="GridLinesVisibility" Value="Horizontal" />
        <Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource SurfaceBorderBrush}" />
        <Setter Property="VerticalGridLinesBrush" Value="{DynamicResource SurfaceBorderBrush}" />
        <Setter Property="RowHeaderWidth" Value="0" />
    </Style>

    <Style TargetType="{x:Type DataGridRow}">
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
        <Setter Property="Background" Value="{DynamicResource SurfaceBrush}" />
        <Setter Property="BorderBrush" Value="{DynamicResource SurfaceBorderBrush}" />
    </Style>

    <Style TargetType="{x:Type DataGridColumnHeader}">
        <Setter Property="Background" Value="{DynamicResource SurfaceAltBrush}" />
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
        <Setter Property="BorderBrush" Value="{DynamicResource SurfaceBorderBrush}" />
        <Setter Property="BorderThickness" Value="0,0,0,1" />
        <Setter Property="Padding" Value="10,8" />
        <Setter Property="FontWeight" Value="SemiBold" />
    </Style>

    <Style TargetType="{x:Type DataGridCell}">
        <Setter Property="Padding" Value="10,8" />
        <Setter Property="BorderBrush" Value="{DynamicResource SurfaceBorderBrush}" />
        <Setter Property="BorderThickness" Value="0" />
    </Style>
</ResourceDictionary>
'@

    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

function Ensure-WpfShell {
    if ($script:WpfShellInitialized) {
        return
    }

    if (-not [System.Windows.Application]::Current) {
        $null = New-Object System.Windows.Application
    }

    $themeStyles = Build-ThemeStyles
    [System.Windows.Application]::Current.Resources.MergedDictionaries.Add($themeStyles) | Out-Null
    $script:WpfShellInitialized = $true
}

function Get-Settings {
    $defaults = Get-DefaultSettings
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) {
        return $defaults
    }

    try {
        $loaded = Read-JsonFile -Path $script:SettingsPath
        if ($null -eq $loaded) {
            return $defaults
        }
        return Merge-ObjectProperties -Base $defaults -Overlay $loaded
    }
    catch {
        Backup-CorruptFile -Path $script:SettingsPath -Prefix 'settings'
        return $defaults
    }
}

function Save-Settings {
    param([Parameter(Mandatory = $true)]$Settings)

    Save-JsonFile -Object $Settings -Path $script:SettingsPath -Depth 10
}

function Normalize-VaultEntry {
    param([Parameter(Mandatory = $true)]$Entry)

    $created = if ($Entry.PSObject.Properties.Name -contains 'CreatedAt' -and $Entry.CreatedAt) { $Entry.CreatedAt } else { (Get-Date).ToString('o') }
    $updated = if ($Entry.PSObject.Properties.Name -contains 'UpdatedAt' -and $Entry.UpdatedAt) { $Entry.UpdatedAt } else { $created }

    $name = [string]$Entry.Name
    $issuer = [string]$Entry.Issuer
    $secret = [string]$Entry.Secret
    $period = 30
    $digits = 6
    $algorithm = 'SHA1'

    try { if ($Entry.PSObject.Properties.Name -contains 'Period' -and $Entry.Period) { $period = [int]$Entry.Period } } catch {}
    try { if ($Entry.PSObject.Properties.Name -contains 'Digits' -and $Entry.Digits) { $digits = [int]$Entry.Digits } } catch {}
    try { if ($Entry.PSObject.Properties.Name -contains 'Algorithm' -and $Entry.Algorithm) { $algorithm = ([string]$Entry.Algorithm).ToUpperInvariant() } } catch {}

    if ($algorithm -notin @('SHA1', 'SHA256', 'SHA512')) {
        $algorithm = 'SHA1'
    }
    if ($period -lt 5) { $period = 30 }
    if ($digits -lt 4 -or $digits -gt 10) { $digits = 6 }

    $item = [pscustomobject]@{
        Id               = if ($Entry.PSObject.Properties.Name -contains 'Id' -and $Entry.Id) { [string]$Entry.Id } else { [guid]::NewGuid().ToString() }
        Name             = $name
        Issuer           = $issuer
        Secret           = ($secret -replace '\s', '').ToUpperInvariant()
        Period           = $period
        Digits           = $digits
        Algorithm        = $algorithm
        CreatedAt        = $created
        UpdatedAt        = $updated
        CodeRaw          = ''
        CodeDisplay      = ''
        RemainingSeconds = 0
        RemainingText    = ''
        DisplayName      = ''
    }

    if ([string]::IsNullOrWhiteSpace($item.Name)) {
        $item.Name = 'Unnamed entry'
    }

    $item.DisplayName = if (-not [string]::IsNullOrWhiteSpace($item.Issuer)) {
        '{0} - {1}' -f $item.Issuer, $item.Name
    }
    else {
        $item.Name
    }

    return $item
}

function Load-VaultItems {
    if (-not (Test-Path -LiteralPath $script:VaultPath)) {
        return @()
    }

    try {
        $protectedText = [System.IO.File]::ReadAllText($script:VaultPath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($protectedText)) {
            return @()
        }

        $json = Unprotect-String -ProtectedText $protectedText.Trim()
        $doc = $json | ConvertFrom-Json
        $entries = @()
        if ($doc.PSObject.Properties.Name -contains 'Entries' -and $doc.Entries) {
            foreach ($entry in @($doc.Entries)) {
                $entries += ,(Normalize-VaultEntry -Entry $entry)
            }
        }

        return $entries
    }
    catch {
        Backup-CorruptFile -Path $script:VaultPath -Prefix 'vault'
        return @()
    }
}

function Save-VaultItems {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Items
    )

    $payloadEntries = @()
    foreach ($item in @($Items)) {
        $payloadEntries += [pscustomobject]@{
            Id        = $item.Id
            Name      = $item.Name
            Issuer    = $item.Issuer
            Secret    = $item.Secret
            Period    = [int]$item.Period
            Digits    = [int]$item.Digits
            Algorithm = $item.Algorithm
            CreatedAt = $item.CreatedAt
            UpdatedAt = $item.UpdatedAt
        }
    }

    $payload = [pscustomobject]@{
        Version = 1
        Entries = $payloadEntries
    }

    $json = $payload | ConvertTo-Json -Depth 20
    $protected = Protect-String -PlainText $json
    [System.IO.File]::WriteAllText($script:VaultPath, $protected, [System.Text.Encoding]::UTF8)
}

function Get-Base32Bytes {
    param([Parameter(Mandatory = $true)][string]$Base32)

    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $clean = ($Base32.ToUpperInvariant() -replace '\s', '') -replace '=', ''
    $clean = ($clean -replace '[^A-Z2-7]', '')
    if ([string]::IsNullOrWhiteSpace($clean)) {
        throw 'TOTP secret is empty.'
    }

    $buffer = 0
    $bitsLeft = 0
    $output = New-Object 'System.Collections.Generic.List[byte]'

    foreach ($character in $clean.ToCharArray()) {
        $value = $alphabet.IndexOf($character)
        if ($value -lt 0) {
            throw "Invalid Base32 character: $character"
        }

        $buffer = ($buffer -shl 5) -bor $value
        $bitsLeft += 5
        while ($bitsLeft -ge 8) {
            $bitsLeft -= 8
            $byteValue = ($buffer -shr $bitsLeft) -band 0xFF
            $output.Add([byte]$byteValue)
            $mask = if ($bitsLeft -eq 0) { 0 } else { (1 -shl $bitsLeft) - 1 }
            $buffer = $buffer -band $mask
        }
    }

    return ,$output.ToArray()
}

function Get-HmacHash {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Key,
        [Parameter(Mandatory = $true)][byte[]]$Message,
        [Parameter(Mandatory = $true)][string]$Algorithm
    )

    $hmac = $null
    switch ($Algorithm) {
        'SHA1'   { $hmac = New-Object System.Security.Cryptography.HMACSHA1   (,$Key) }
        'SHA256' { $hmac = New-Object System.Security.Cryptography.HMACSHA256 (,$Key) }
        'SHA512' { $hmac = New-Object System.Security.Cryptography.HMACSHA512 (,$Key) }
        default  { throw "Unsupported algorithm: $Algorithm" }
    }

    try {
        return $hmac.ComputeHash($Message)
    }
    finally {
        if ($hmac) { $hmac.Dispose() }
    }
}

function Format-TotpCode {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][int]$Digits
    )

    switch ($Digits) {
        6 { return '{0} {1}' -f $Code.Substring(0, 3), $Code.Substring(3, 3) }
        8 { return '{0} {1}' -f $Code.Substring(0, 4), $Code.Substring(4, 4) }
        default { return $Code }
    }
}

function Get-TotpCode {
    param(
        [Parameter(Mandatory = $true)][string]$Secret,
        [Parameter(Mandatory = $true)][int]$Period,
        [Parameter(Mandatory = $true)][int]$Digits,
        [Parameter(Mandatory = $true)][string]$Algorithm
    )

    $keyBytes = Get-Base32Bytes -Base32 $Secret
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [int64]$counter = [math]::Floor($timestamp / $Period)

    $counterBytes = New-Object 'System.Byte[]' 8
    for ($index = 7; $index -ge 0; $index--) {
        $counterBytes[$index] = [byte]($counter -band 0xFF)
        $counter = $counter -shr 8
    }

    $hash = Get-HmacHash -Key $keyBytes -Message $counterBytes -Algorithm $Algorithm
    $offset = $hash[$hash.Length - 1] -band 0x0F

    $binary =
        ((($hash[$offset]     -band 0x7F) -shl 24) -bor
         (($hash[$offset + 1] -band 0xFF) -shl 16) -bor
         (($hash[$offset + 2] -band 0xFF) -shl 8)  -bor
          ($hash[$offset + 3] -band 0xFF))

    [int64]$modulus = 1
    for ($index = 0; $index -lt $Digits; $index++) {
        $modulus *= 10
    }

    [int64]$otp = [int64]$binary % $modulus
    return $otp.ToString().PadLeft($Digits, '0')
}

function Get-TotpSnapshot {
    param([Parameter(Mandatory = $true)]$Entry)

    $code = Get-TotpCode -Secret $Entry.Secret -Period ([int]$Entry.Period) -Digits ([int]$Entry.Digits) -Algorithm $Entry.Algorithm
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $remaining = [int]([int]$Entry.Period - ($timestamp % [int]$Entry.Period))
    if ($remaining -le 0) { $remaining = [int]$Entry.Period }

    [pscustomobject]@{
        CodeRaw          = $code
        CodeDisplay      = Format-TotpCode -Code $code -Digits ([int]$Entry.Digits)
        RemainingSeconds = $remaining
        RemainingText    = '{0}s' -f $remaining
    }
}

function Update-TotpSnapshots {
    if ($script:VaultItems.Count -eq 0) {
        if ($script:MainWindow -and $script:MainWindow.FindName('VaultStatusText')) {
            $script:MainWindow.FindName('VaultStatusText').Text = 'No TOTP entries saved yet.'
        }
        return
    }

    foreach ($item in $script:VaultItems) {
        try {
            $snapshot = Get-TotpSnapshot -Entry $item
            $item.CodeRaw = $snapshot.CodeRaw
            $item.CodeDisplay = $snapshot.CodeDisplay
            $item.RemainingSeconds = $snapshot.RemainingSeconds
            $item.RemainingText = $snapshot.RemainingText
            $item.DisplayName = if (-not [string]::IsNullOrWhiteSpace($item.Issuer)) {
                '{0} - {1}' -f $item.Issuer, $item.Name
            }
            else {
                $item.Name
            }
        }
        catch {
            $item.CodeRaw = ''
            $item.CodeDisplay = 'ERR'
            $item.RemainingSeconds = 0
            $item.RemainingText = 'Invalid'
        }
    }

    if ($script:MainWindow -and $script:MainWindow.FindName('TotpGrid')) {
        Refresh-ItemsView -Control $script:MainWindow.FindName('TotpGrid')
    }
    if ($script:AllTotpWindow -and $script:AllTotpWindow.FindName('AllTotpItems')) {
        Refresh-ItemsView -Control $script:AllTotpWindow.FindName('AllTotpItems')
    }

    if ($script:MainWindow -and $script:MainWindow.FindName('VaultStatusText')) {
        $script:MainWindow.FindName('VaultStatusText').Text = '{0} entries saved. Live codes refresh every second.' -f $script:VaultItems.Count
    }
}

function Refresh-ItemsView {
    param([Parameter(Mandatory = $true)]$Control)

    if ($null -eq $Control) {
        return
    }

    try {
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Control.ItemsSource)
        if ($view) {
            $view.Refresh()
        }
    }
    catch {
        if ($Control.PSObject.Properties.Name -contains 'Items') {
            try { $Control.Items.Refresh() } catch {}
        }
    }
}

function Update-ClockDisplays {
    param(
        [Parameter(Mandatory = $true)]$Settings
    )

    if (-not $script:MainWindow) {
        return
    }

    $localCombo = $script:MainWindow.FindName('LocalZoneCombo')
    $clientCombo = $script:MainWindow.FindName('ClientZoneCombo')
    $localClockText = $script:MainWindow.FindName('LocalClockText')
    $localDateText = $script:MainWindow.FindName('LocalDateText')
    $localZoneText = $script:MainWindow.FindName('LocalZoneText')
    $clientClockText = $script:MainWindow.FindName('ClientClockText')
    $clientDateText = $script:MainWindow.FindName('ClientDateText')
    $clientZoneText = $script:MainWindow.FindName('ClientZoneText')

    if (-not $localCombo -or -not $clientCombo) { return }

    $localZone = Get-TimeZoneByIdSafe -ZoneId ([string]$localCombo.SelectedValue)
    $clientZone = Get-TimeZoneByIdSafe -ZoneId ([string]$clientCombo.SelectedValue)

    $utcNow = [DateTimeOffset]::UtcNow
    $localTime = [System.TimeZoneInfo]::ConvertTime($utcNow, $localZone)
    $clientTime = [System.TimeZoneInfo]::ConvertTime($utcNow, $clientZone)

    if ($localClockText) { $localClockText.Text = $localTime.ToString('HH:mm:ss') }
    if ($localDateText)  { $localDateText.Text  = $localTime.ToString('dddd, MMMM d, yyyy') }
    if ($localZoneText)  { $localZoneText.Text  = '{0} ({1})' -f $localZone.DisplayName, $localZone.Id }

    if ($clientClockText) { $clientClockText.Text = $clientTime.ToString('HH:mm:ss') }
    if ($clientDateText)  { $clientDateText.Text  = $clientTime.ToString('dddd, MMMM d, yyyy') }
    if ($clientZoneText)  { $clientZoneText.Text  = '{0} ({1})' -f $clientZone.DisplayName, $clientZone.Id }
}

function Get-TimeZoneByIdSafe {
    param([Parameter(Mandatory = $true)][string]$ZoneId)

    if ([string]::IsNullOrWhiteSpace($ZoneId)) {
        return [System.TimeZoneInfo]::Local
    }

    try {
        return [System.TimeZoneInfo]::FindSystemTimeZoneById($ZoneId)
    }
    catch {
        return [System.TimeZoneInfo]::Local
    }
}

function Get-TimeZoneOptions {
    [System.TimeZoneInfo]::GetSystemTimeZones() |
        Sort-Object DisplayName |
        ForEach-Object {
            [pscustomobject]@{
                Id      = $_.Id
                Display = '{0} - {1}' -f $_.Id, $_.DisplayName
            }
        }
}

function Set-CaffeinateUiState {
    param([Parameter(Mandatory = $true)][bool]$Running)

    $script:CaffeinateRunning = $Running
    $startButton = $script:MainWindow.FindName('StartKeepAliveButton')
    $stopButton = $script:MainWindow.FindName('StopKeepAliveButton')
    $statusText = $script:MainWindow.FindName('CaffeinateStatusText')
    $detailText = $script:MainWindow.FindName('CaffeinateDetailText')

    if ($startButton) { $startButton.IsEnabled = -not $Running }
    if ($stopButton) { $stopButton.IsEnabled = $Running }
    if ($statusText) {
        $statusText.Text = if ($Running) { 'Running' } else { 'Stopped' }
        $statusText.Foreground = if ($Running) { Get-ThemeResource -Key 'SuccessBrush' } else { Get-ThemeResource -Key 'MutedTextBrush' }
    }
    if ($detailText) {
        if ($Running) {
            $detailText.Text = 'The app is sending a low-impact F15 heartbeat and keeping the Windows session awake.'
        }
        else {
            $detailText.Text = 'Stop disables the heartbeat and releases the Windows keep-awake request.'
        }
    }
}

function Send-KeepAlivePulse {
    [NativeMethods]::keybd_event(0x7E, 0, 0, 0)
    Start-Sleep -Milliseconds 40
    [NativeMethods]::keybd_event(0x7E, 0, 2, 0)
}

function Start-Caffeinate {
    if ($script:CaffeinateRunning) {
        return
    }

    [NativeMethods]::SetThreadExecutionState(0x80000001) | Out-Null
    Send-KeepAlivePulse

    if ($script:KeepAliveTimer) {
        $script:KeepAliveTimer.Stop()
        $script:KeepAliveTimer = $null
    }

    $interval = [int]$script:Settings.CaffeinateIntervalSec
    if ($interval -lt 30) { $interval = 30 }

    $script:KeepAliveTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:KeepAliveTimer.Interval = [TimeSpan]::FromSeconds($interval)
    $script:KeepAliveTimer.Add_Tick({
        try {
            [NativeMethods]::SetThreadExecutionState(0x80000001) | Out-Null
            Send-KeepAlivePulse
        }
        catch {
            Stop-Caffeinate
        }
    })
    $script:KeepAliveTimer.Start()
    Set-CaffeinateUiState -Running $true
}

function Stop-Caffeinate {
    if ($script:KeepAliveTimer) {
        $script:KeepAliveTimer.Stop()
        $script:KeepAliveTimer = $null
    }

    [NativeMethods]::SetThreadExecutionState(0x80000000) | Out-Null
    Set-CaffeinateUiState -Running $false
}

function Parse-IntegerOrThrow {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [Parameter(Mandatory = $true)][int]$Min,
        [Parameter(Mandatory = $true)][int]$Max
    )

    $value = 0
    if (-not [int]::TryParse($Text, [ref]$value)) {
        throw "$FieldName must be a whole number."
    }
    if ($value -lt $Min -or $value -gt $Max) {
        throw "$FieldName must be between $Min and $Max."
    }
    return $value
}

function Parse-TotpInput {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Issuer,
        [Parameter(Mandatory = $true)][string]$SecretOrUri,
        [Parameter(Mandatory = $true)][string]$ExistingSecret
    )

    $nameValue = $Name.Trim()
    $issuerValue = $Issuer.Trim()
    $input = $SecretOrUri.Trim()

    if ([string]::IsNullOrWhiteSpace($nameValue)) {
        throw 'Name is required.'
    }

    if ([string]::IsNullOrWhiteSpace($input)) {
        if ([string]::IsNullOrWhiteSpace($ExistingSecret)) {
            throw 'TOTP secret is required.'
        }
        $input = $ExistingSecret
    }

    $period = 30
    $digits = 6
    $algorithm = 'SHA1'
    $secret = $input

    if ($input.ToLowerInvariant().StartsWith('otpauth://')) {
        $clean = $input -replace '&amp;', '&'
        $uri = [Uri]$clean
        if ($uri.Scheme -ne 'otpauth') {
            throw 'The URI must start with otpauth://'
        }

        $queryMap = @{}
        $query = $uri.Query.TrimStart('?')
        foreach ($pair in @($query -split '&')) {
            if ([string]::IsNullOrWhiteSpace($pair)) { continue }
            $kv = $pair -split '=', 2
            $key = [Uri]::UnescapeDataString($kv[0]).ToLowerInvariant()
            $val = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1]) } else { '' }
            $queryMap[$key] = $val
        }

        if ($queryMap.ContainsKey('secret')) {
            $secret = $queryMap['secret']
        }
        else {
            throw 'The otpauth URI is missing a secret value.'
        }

        if ($queryMap.ContainsKey('period') -and $queryMap['period']) {
            $period = Parse-IntegerOrThrow -Text $queryMap['period'] -FieldName 'Period' -Min 5 -Max 300
        }

        if ($queryMap.ContainsKey('digits') -and $queryMap['digits']) {
            $digits = Parse-IntegerOrThrow -Text $queryMap['digits'] -FieldName 'Digits' -Min 4 -Max 10
        }

        if ($queryMap.ContainsKey('algorithm') -and $queryMap['algorithm']) {
            $algorithm = $queryMap['algorithm'].ToUpperInvariant()
        }

        $label = [Uri]::UnescapeDataString($uri.AbsolutePath.TrimStart('/'))
        if ([string]::IsNullOrWhiteSpace($nameValue) -and -not [string]::IsNullOrWhiteSpace($label)) {
            if ($label -match '^(.*?):(.*)$') {
                if ([string]::IsNullOrWhiteSpace($issuerValue)) { $issuerValue = $matches[1].Trim() }
                if ([string]::IsNullOrWhiteSpace($nameValue)) { $nameValue = $matches[2].Trim() }
            }
            elseif ([string]::IsNullOrWhiteSpace($nameValue)) {
                $nameValue = $label
            }
        }

        if ($queryMap.ContainsKey('issuer') -and -not [string]::IsNullOrWhiteSpace($queryMap['issuer']) -and [string]::IsNullOrWhiteSpace($issuerValue)) {
            $issuerValue = $queryMap['issuer']
        }
    }

    $normalizedSecret = ($secret -replace '\s', '').ToUpperInvariant()
    $null = Get-Base32Bytes -Base32 $normalizedSecret

    if ($algorithm -notin @('SHA1', 'SHA256', 'SHA512')) {
        $algorithm = 'SHA1'
    }
    if ($period -lt 5) { $period = 30 }
    if ($digits -lt 4 -or $digits -gt 10) { $digits = 6 }

    [pscustomobject]@{
        Name      = $nameValue
        Issuer    = $issuerValue
        Secret    = $normalizedSecret
        Period    = $period
        Digits    = $digits
        Algorithm = $algorithm
    }
}

function New-TotpItem {
    param(
        [Parameter(Mandatory = $true)]$Data
    )

    $item = Normalize-VaultEntry -Entry $Data
    return $item
}

function Show-Message {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Caption = 'WorkPCUtilities',
        [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Information
    )

    [System.Windows.MessageBox]::Show($script:MainWindow, $Text, $Caption, [System.Windows.MessageBoxButton]::OK, $Icon) | Out-Null
}

function Confirm-Action {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Caption = 'WorkPCUtilities'
    )

    return ([System.Windows.MessageBox]::Show($script:MainWindow, $Text, $Caption, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) -eq [System.Windows.MessageBoxResult]::Yes)
}

function Show-TotpEditorDialog {
    param(
        [Parameter(Mandatory = $false)]$Entry,
        [Parameter(Mandatory = $true)][System.Windows.Window]$Owner
    )

    $windowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TOTP Entry"
        Width="620"
        Height="520"
        MinWidth="560"
        MinHeight="480"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Border x:Name="EditorHeaderCard"
                BorderThickness="1"
                CornerRadius="18"
                Padding="18">
            <StackPanel>
                <TextBlock x:Name="EditorTitle" FontSize="22" FontWeight="SemiBold" />
                <TextBlock x:Name="EditorSubtitle" Margin="0,4,0,0" TextWrapping="Wrap" />
            </StackPanel>
        </Border>

        <Border x:Name="EditorBodyCard"
                Grid.Row="1"
                Margin="0,14,0,14"
                BorderThickness="1"
                CornerRadius="18"
                Padding="18">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="180" />
                        <ColumnDefinition Width="*" />
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <TextBlock Text="Name" Margin="0,0,14,10" VerticalAlignment="Center" />
                    <TextBox x:Name="NameBox" Grid.Column="1" Margin="0,0,0,10" />

                    <TextBlock Text="Issuer" Grid.Row="1" Margin="0,0,14,10" VerticalAlignment="Center" />
                    <TextBox x:Name="IssuerBox" Grid.Row="1" Grid.Column="1" Margin="0,0,0,10" />

                    <TextBlock Text="Secret or otpauth URI" Grid.Row="2" Margin="0,0,14,10" VerticalAlignment="Center" />
                    <TextBox x:Name="SecretBox" Grid.Row="2" Grid.Column="1" Margin="0,0,0,10" AcceptsReturn="True" Height="120" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" />

                    <TextBlock Text="Period (seconds)" Grid.Row="3" Margin="0,0,14,10" VerticalAlignment="Center" />
                    <TextBox x:Name="PeriodBox" Grid.Row="3" Grid.Column="1" Width="120" HorizontalAlignment="Left" Margin="0,0,0,10" />

                    <TextBlock Text="Digits" Grid.Row="4" Margin="0,0,14,10" VerticalAlignment="Center" />
                    <TextBox x:Name="DigitsBox" Grid.Row="4" Grid.Column="1" Width="120" HorizontalAlignment="Left" Margin="0,0,0,10" />

                    <TextBlock Text="Algorithm" Grid.Row="5" Margin="0,0,14,0" VerticalAlignment="Center" />
                    <ComboBox x:Name="AlgorithmBox" Grid.Row="5" Grid.Column="1" Width="160" HorizontalAlignment="Left" />

                    <TextBlock Grid.Row="6" Grid.ColumnSpan="2"
                               x:Name="EditorHint"
                               Margin="0,16,0,0"
                               TextWrapping="Wrap" />
                </Grid>
            </ScrollViewer>
        </Border>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CancelButton" Content="Cancel" Style="{StaticResource SecondaryButtonStyle}" />
            <Button x:Name="SaveButton" Content="Save" Style="{StaticResource PrimaryButtonStyle}" Margin="0" />
        </StackPanel>
    </Grid>
</Window>
'@

    $window = [System.Windows.Markup.XamlReader]::Parse($windowXaml)
    $window.Owner = $Owner
    $window.Background = Get-ThemeResource -Key 'WindowBackgroundBrush'
    $window.Foreground = Get-ThemeResource -Key 'TextBrush'
    $surfaceBrush = Get-ThemeResource -Key 'SurfaceBrush'
    $borderBrush = Get-ThemeResource -Key 'SurfaceBorderBrush'
    foreach ($name in @('EditorHeaderCard', 'EditorBodyCard')) {
        $card = $window.FindName($name)
        if ($card) {
            $card.Background = $surfaceBrush
            $card.BorderBrush = $borderBrush
        }
    }
    Apply-MutedTextBrushes -Window $window -Names @('EditorSubtitle', 'EditorHint')

    $title = $window.FindName('EditorTitle')
    $subtitle = $window.FindName('EditorSubtitle')
    $hint = $window.FindName('EditorHint')
    $nameBox = $window.FindName('NameBox')
    $issuerBox = $window.FindName('IssuerBox')
    $secretBox = $window.FindName('SecretBox')
    $periodBox = $window.FindName('PeriodBox')
    $digitsBox = $window.FindName('DigitsBox')
    $algorithmBox = $window.FindName('AlgorithmBox')
    $saveButton = $window.FindName('SaveButton')
    $cancelButton = $window.FindName('CancelButton')

    $algorithmBox.ItemsSource = @('SHA1', 'SHA256', 'SHA512')

    if ($Entry) {
        $window.Title = 'Edit TOTP entry'
        $title.Text = 'Edit TOTP entry'
        $subtitle.Text = 'Update the name, issuer, or secret. Leaving the secret box empty keeps the current secret.'
        $hint.Text = 'Tip: you can paste a raw Base32 secret or a full otpauth:// URI.'
        $nameBox.Text = $Entry.Name
        $issuerBox.Text = $Entry.Issuer
        $secretBox.Text = $Entry.Secret
        $periodBox.Text = [string]$Entry.Period
        $digitsBox.Text = [string]$Entry.Digits
        $algorithmBox.SelectedItem = $Entry.Algorithm
    }
    else {
        $window.Title = 'Add TOTP entry'
        $title.Text = 'Add TOTP entry'
        $subtitle.Text = 'Store one secret or many. The vault is saved only under %APPDATA% and encrypted for the current user.'
        $hint.Text = 'Tip: paste a raw Base32 secret or a full otpauth:// URI. If you paste a URI, the app can read period, digits, and algorithm too.'
        $periodBox.Text = '30'
        $digitsBox.Text = '6'
        $algorithmBox.SelectedItem = 'SHA1'
    }

    if (-not $algorithmBox.SelectedItem) {
        $algorithmBox.SelectedItem = 'SHA1'
    }

    $result = $null
    $saveButton.Add_Click({
        try {
            $parsed = Parse-TotpInput -Name $nameBox.Text -Issuer $issuerBox.Text -SecretOrUri $secretBox.Text -ExistingSecret $(if ($Entry) { $Entry.Secret } else { '' })
            $period = Parse-IntegerOrThrow -Text $periodBox.Text -FieldName 'Period' -Min 5 -Max 300
            $digits = Parse-IntegerOrThrow -Text $digitsBox.Text -FieldName 'Digits' -Min 4 -Max 10
            $algorithm = [string]$algorithmBox.SelectedItem
            if ($algorithm -notin @('SHA1', 'SHA256', 'SHA512')) {
                $algorithm = 'SHA1'
            }

            if ($parsed.Secret -notmatch '^[A-Z2-7]+$') {
                throw 'The TOTP secret must be Base32 text.'
            }

            $result = [pscustomobject]@{
                Id        = if ($Entry) { $Entry.Id } else { [guid]::NewGuid().ToString() }
                Name      = $parsed.Name
                Issuer    = $parsed.Issuer
                Secret    = $parsed.Secret
                Period    = $period
                Digits    = $digits
                Algorithm = $algorithm
                CreatedAt = if ($Entry) { $Entry.CreatedAt } else { (Get-Date).ToString('o') }
                UpdatedAt = (Get-Date).ToString('o')
            }

            $window.Tag = $result
            $window.DialogResult = $true
        }
        catch {
            Show-Message -Text $_.Exception.Message -Caption 'Invalid TOTP entry' -Icon Error
        }
    })

    $cancelButton.Add_Click({
        $window.DialogResult = $false
    })

    [void]$window.ShowDialog()
    return $window.Tag
}

function Copy-CodeToClipboard {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        [System.Windows.Clipboard]::SetText($Code)
        if ($script:MainWindow) {
            $status = $script:MainWindow.FindName('AppStatusText')
            if ($status) {
                $status.Text = "Copied $Name to the clipboard."
            }
        }
    }
    catch {
        Show-Message -Text 'Could not copy the code to the clipboard.' -Caption 'Clipboard error' -Icon Warning
    }
}

function Show-TotpDetailDialog {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][System.Windows.Window]$Owner
    )

    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TOTP"
        Width="520"
        Height="360"
        MinWidth="480"
        MinHeight="320"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Border x:Name="DetailHeaderCard"
                BorderThickness="1"
                CornerRadius="18"
                Padding="18">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <StackPanel>
                    <TextBlock x:Name="EntryName" FontSize="22" FontWeight="SemiBold" />
                    <TextBlock x:Name="EntryIssuer" Margin="0,4,0,0" TextWrapping="Wrap" />
                </StackPanel>
                <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                    <Button x:Name="CopyButton" Content="Copy code" Style="{StaticResource PrimaryButtonStyle}" Margin="0,0,0,0" />
                </StackPanel>
            </Grid>
        </Border>

        <Border x:Name="DetailBodyCard"
                Grid.Row="1"
                Margin="0,14,0,14"
                BorderThickness="1"
                CornerRadius="18"
                Padding="18">
            <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                <TextBlock x:Name="CodeText" FontFamily="Consolas" FontSize="48" FontWeight="Bold" HorizontalAlignment="Center" />
                <TextBlock x:Name="RemainingText" Margin="0,8,0,0" HorizontalAlignment="Center" />
                <TextBlock x:Name="MetaText" Margin="0,12,0,0" HorizontalAlignment="Center" />
            </StackPanel>
        </Border>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CloseButton" Content="Close" Style="{StaticResource SecondaryButtonStyle}" Margin="0" />
        </StackPanel>
    </Grid>
</Window>
'@

    $window = [System.Windows.Markup.XamlReader]::Parse($dialogXaml)
    $window.Owner = $Owner
    $window.Background = Get-ThemeResource -Key 'WindowBackgroundBrush'
    $window.Foreground = Get-ThemeResource -Key 'TextBrush'
    $surfaceBrush = Get-ThemeResource -Key 'SurfaceBrush'
    $borderBrush = Get-ThemeResource -Key 'SurfaceBorderBrush'
    foreach ($name in @('DetailHeaderCard', 'DetailBodyCard')) {
        $card = $window.FindName($name)
        if ($card) {
            $card.Background = $surfaceBrush
            $card.BorderBrush = $borderBrush
        }
    }
    Apply-MutedTextBrushes -Window $window -Names @('EntryIssuer', 'RemainingText', 'MetaText')

    $entryName = $window.FindName('EntryName')
    $entryIssuer = $window.FindName('EntryIssuer')
    $codeText = $window.FindName('CodeText')
    $remainingText = $window.FindName('RemainingText')
    $metaText = $window.FindName('MetaText')
    $copyButton = $window.FindName('CopyButton')
    $closeButton = $window.FindName('CloseButton')

    $entryName.Text = $Entry.DisplayName
    $entryIssuer.Text = if ([string]::IsNullOrWhiteSpace($Entry.Issuer)) { 'No issuer provided' } else { $Entry.Issuer }

    $refresh = {
        try {
            $snapshot = Get-TotpSnapshot -Entry $Entry
            $codeText.Text = $snapshot.CodeDisplay
            $remainingText.Text = 'Valid for {0}s' -f $snapshot.RemainingSeconds
            $metaText.Text = 'Period: {0}s   Digits: {1}   Algorithm: {2}' -f $Entry.Period, $Entry.Digits, $Entry.Algorithm
        }
        catch {
            $codeText.Text = 'ERR'
            $remainingText.Text = 'Unable to calculate code.'
            $metaText.Text = $_.Exception.Message
        }
    }

    $copyButton.Add_Click({
        $snapshot = Get-TotpSnapshot -Entry $Entry
        Copy-CodeToClipboard -Code $snapshot.CodeRaw -Name $Entry.DisplayName
    })

    $closeButton.Add_Click({
        $window.DialogResult = $true
    })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick($refresh)
    $timer.Start()
    & $refresh

    $window.Add_Closed({
        $timer.Stop()
    })

    [void]$window.ShowDialog()
}

function Show-AllTotpDialog {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Window]$Owner
    )

    $windowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="All TOTPs"
        Width="960"
        Height="720"
        MinWidth="820"
        MinHeight="620"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Border x:Name="AllHeaderCard"
                BorderThickness="1"
                CornerRadius="18"
                Padding="18">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <StackPanel>
                    <TextBlock Text="All saved TOTP codes" FontSize="22" FontWeight="SemiBold" />
                    <TextBlock x:Name="AllTotpHintText" Text="Click any card to copy that code to the clipboard." Margin="0,4,0,0" />
                </StackPanel>
                <Button x:Name="CloseButton" Grid.Column="1" Content="Close" Style="{StaticResource SecondaryButtonStyle}" Margin="0" />
            </Grid>
        </Border>

        <Border x:Name="AllBodyCard"
                Grid.Row="1"
                Margin="0,14,0,14"
                BorderThickness="1"
                CornerRadius="18"
                Padding="18">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <ItemsControl x:Name="AllTotpItems">
                    <ItemsControl.ItemsPanel>
                        <ItemsPanelTemplate>
                            <WrapPanel IsItemsHost="True" />
                        </ItemsPanelTemplate>
                    </ItemsControl.ItemsPanel>
                    <ItemsControl.ItemTemplate>
                        <DataTemplate>
                            <Button Background="{DynamicResource SurfaceAltBrush}"
                                    BorderBrush="{DynamicResource SurfaceBorderBrush}"
                                    BorderThickness="1"
                                    Padding="0"
                                    Margin="0,0,14,14"
                                    Tag="{Binding}"
                                    Cursor="Hand">
                                <Button.Template>
                                    <ControlTemplate TargetType="{x:Type Button}">
                                        <Border Background="{TemplateBinding Background}"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                BorderThickness="{TemplateBinding BorderThickness}"
                                                CornerRadius="18"
                                                Padding="16">
                                            <StackPanel Width="240">
                                                <TextBlock Text="{Binding DisplayName}" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap" />
                                                <TextBlock Text="{Binding Issuer}" Margin="0,4,0,0" TextWrapping="Wrap" />
                                                <Border Margin="0,14,0,0"
                                                        Background="{DynamicResource SurfaceBrush}"
                                                        BorderThickness="1"
                                                        CornerRadius="14"
                                                        Padding="14">
                                                    <StackPanel>
                                                        <TextBlock Text="{Binding CodeDisplay}" FontFamily="Consolas" FontSize="30" FontWeight="Bold" HorizontalAlignment="Center" />
                                                        <TextBlock Text="{Binding RemainingText}" Margin="0,8,0,0" HorizontalAlignment="Center" />
                                                    </StackPanel>
                                                </Border>
                                                <TextBlock Text="Click card to copy" Margin="0,10,0,0" HorizontalAlignment="Center" />
                                            </StackPanel>
                                        </Border>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>
                        </DataTemplate>
                    </ItemsControl.ItemTemplate>
                </ItemsControl>
            </ScrollViewer>
        </Border>

        <TextBlock Grid.Row="2" x:Name="AllTotpFooter" />
    </Grid>
</Window>
'@

    $window = [System.Windows.Markup.XamlReader]::Parse($windowXaml)
    $window.Owner = $Owner
    $window.Background = Get-ThemeResource -Key 'WindowBackgroundBrush'
    $window.Foreground = Get-ThemeResource -Key 'TextBrush'
    $surfaceBrush = Get-ThemeResource -Key 'SurfaceBrush'
    $borderBrush = Get-ThemeResource -Key 'SurfaceBorderBrush'
    foreach ($name in @('AllHeaderCard', 'AllBodyCard')) {
        $card = $window.FindName($name)
        if ($card) {
            $card.Background = $surfaceBrush
            $card.BorderBrush = $borderBrush
        }
    }
    Apply-MutedTextBrushes -Window $window -Names @('AllTotpHintText', 'AllTotpFooter')

    $allItems = $window.FindName('AllTotpItems')
    $footer = $window.FindName('AllTotpFooter')
    $closeButton = $window.FindName('CloseButton')

    $allItems.ItemsSource = $script:VaultItems
    $footer.Text = '{0} entries visible. Click any card to copy its code.' -f $script:VaultItems.Count

    $copyHandler = [System.Windows.RoutedEventHandler]{
        param($sender, $e)

        $source = $e.OriginalSource
        while ($source -and -not ($source -is [System.Windows.Controls.Button])) {
            if ($source -is [System.Windows.DependencyObject]) {
                $source = [System.Windows.Media.VisualTreeHelper]::GetParent($source)
            }
            else {
                $source = $null
            }
        }

        if ($source -is [System.Windows.Controls.Button] -and $source.Tag -and $source.Tag.PSObject.Properties.Name -contains 'CodeRaw') {
            $item = $source.Tag
            if ($item.CodeRaw) {
                Copy-CodeToClipboard -Code $item.CodeRaw -Name $item.DisplayName
            }
        }
    }

    $window.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $copyHandler, $true)
    $closeButton.Add_Click({ $window.DialogResult = $true })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        Update-TotpSnapshots
        $footer.Text = '{0} entries visible. Click any card to copy its code.' -f $script:VaultItems.Count
    })
    $timer.Start()

    $window.Add_Closed({
        $timer.Stop()
        if ($script:AllTotpWindow -eq $window) {
            $script:AllTotpWindow = $null
        }
    })

    $script:AllTotpWindow = $window
    [void]$window.ShowDialog()
}

function Refresh-VaultUi {
    if ($script:MainWindow -and $script:MainWindow.FindName('TotpGrid')) {
        Refresh-ItemsView -Control $script:MainWindow.FindName('TotpGrid')
    }
    Update-TotpSnapshots
}

function Build-TimeZoneItems {
    return Get-TimeZoneOptions
}

function Select-ComboByValue {
    param(
        [Parameter(Mandatory = $true)]$ComboBox,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $ComboBox.SelectedValue = $Value
}

function Initialize-Ui {
    param([Parameter(Mandatory = $true)]$Settings)

    Ensure-WpfShell
    Set-AppTheme -ThemeMode $Settings.ThemeMode

    $mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WorkPCUtilities"
        Width="1280"
        Height="860"
        MinWidth="980"
        MinHeight="680"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        SnapsToDevicePixels="True"
        UseLayoutRounding="True">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Border x:Name="HeaderCard"
                Grid.Row="0"
                BorderThickness="1"
                CornerRadius="20"
                Padding="18">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <StackPanel>
                    <TextBlock Text="WorkPCUtilities" FontSize="28" FontWeight="SemiBold" />
                    <TextBlock x:Name="HeaderSubtitleText" Margin="0,4,0,0" TextWrapping="Wrap"
                               Text="Citrix keepalive, dual clocks, and a DPAPI-protected TOTP vault in one portable PowerShell 5.1 app." />
                </StackPanel>
                <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                    <TextBlock Text="Theme" HorizontalAlignment="Left" FontWeight="SemiBold" />
                    <ComboBox x:Name="ThemeCombo" Width="160" Margin="0,6,0,0" />
                </StackPanel>
            </Grid>
        </Border>

        <TabControl Grid.Row="1"
                    x:Name="MainTabs"
                    Margin="0,14,0,14"
                    Background="Transparent"
                    BorderThickness="0"
                    ItemContainerStyle="{StaticResource ModernTabItemStyle}">
            <TabItem Header="Caffeinate">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <Grid Margin="2">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="Auto" />
                        </Grid.RowDefinitions>

        <Border x:Name="CaffeinateCard"
                                BorderThickness="1"
                                CornerRadius="20"
                                Padding="18">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="Auto" />
                                </Grid.ColumnDefinitions>
                                <StackPanel>
                                    <TextBlock Text="Citrix / Windows keepalive" FontSize="22" FontWeight="SemiBold" />
                                    <TextBlock x:Name="CaffeinateDescriptionText" Margin="0,6,0,0"
                                               TextWrapping="Wrap"
                                               Text="Start sends a harmless F15 heartbeat and keeps the current session awake. Stop turns it off and releases the keep-awake request." />
                                </StackPanel>
                                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                                    <Button x:Name="StartKeepAliveButton" Content="Start" Style="{StaticResource PrimaryButtonStyle}" />
                                    <Button x:Name="StopKeepAliveButton" Content="Stop" Style="{StaticResource SecondaryButtonStyle}" Margin="0" />
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border x:Name="CaffeinateStatusCard"
                Grid.Row="1"
                Margin="0,14,0,0"
                BorderThickness="1"
                CornerRadius="20"
                Padding="18">
                            <StackPanel>
                                <TextBlock Text="Status" FontWeight="SemiBold" />
                                <TextBlock x:Name="CaffeinateStatusText" Margin="0,8,0,0" FontSize="18" FontWeight="SemiBold" />
                                <TextBlock x:Name="CaffeinateDetailText" Margin="0,10,0,0" TextWrapping="Wrap" />
                                <TextBlock x:Name="CaffeinateNoteText" Margin="0,10,0,0" TextWrapping="Wrap" />
                            </StackPanel>
                        </Border>
                    </Grid>
                </ScrollViewer>
            </TabItem>

            <TabItem Header="Clocks">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <Grid Margin="2">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>
        <Border x:Name="LocalClockCard"
                                BorderThickness="1"
                                CornerRadius="20"
                                Padding="18"
                                Margin="0,0,10,0">
                            <StackPanel>
                                <TextBlock Text="Local time" FontSize="22" FontWeight="SemiBold" />
                                <TextBlock x:Name="LocalClockHintText" Margin="0,4,0,0" TextWrapping="Wrap" Text="Choose any timezone for the left clock." />
                                <ComboBox x:Name="LocalZoneCombo" Margin="0,14,0,0" IsEditable="True" IsTextSearchEnabled="True" />
                                <TextBlock x:Name="LocalClockText" Margin="0,16,0,0" FontFamily="Consolas" FontSize="48" FontWeight="Bold" />
                                <TextBlock x:Name="LocalDateText" Margin="0,8,0,0" FontSize="16" />
                            </StackPanel>
                        </Border>

        <Border x:Name="ClientClockCard"
                Grid.Column="1"
                                BorderThickness="1"
                                CornerRadius="20"
                                Padding="18"
                                Margin="10,0,0,0">
                            <StackPanel>
                                <TextBlock Text="Client time" FontSize="22" FontWeight="SemiBold" />
                                <TextBlock x:Name="ClientClockHintText" Margin="0,4,0,0" TextWrapping="Wrap" Text="Choose any timezone for the right clock." />
                                <ComboBox x:Name="ClientZoneCombo" Margin="0,14,0,0" IsEditable="True" IsTextSearchEnabled="True" />
                                <TextBlock x:Name="ClientClockText" Margin="0,16,0,0" FontFamily="Consolas" FontSize="48" FontWeight="Bold" />
                                <TextBlock x:Name="ClientDateText" Margin="0,8,0,0" FontSize="16" />
                            </StackPanel>
                        </Border>
                    </Grid>
                </ScrollViewer>
            </TabItem>

            <TabItem Header="TOTP Vault">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <Grid Margin="2">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="*" />
                            <RowDefinition Height="Auto" />
                        </Grid.RowDefinitions>

        <Border x:Name="VaultActionCard"
                                BorderThickness="1"
                                CornerRadius="20"
                                Padding="18">
                            <WrapPanel>
                                <Button x:Name="AddTotpButton" Content="Add" Style="{StaticResource PrimaryButtonStyle}" />
                                <Button x:Name="EditTotpButton" Content="Edit" Style="{StaticResource SecondaryButtonStyle}" />
                                <Button x:Name="DeleteTotpButton" Content="Delete" Style="{StaticResource DangerButtonStyle}" />
                                <Button x:Name="ViewTotpButton" Content="View" Style="{StaticResource SecondaryButtonStyle}" />
                                <Button x:Name="CopyTotpButton" Content="Copy code" Style="{StaticResource SecondaryButtonStyle}" />
                                <Button x:Name="ViewAllTotpButton" Content="View all" Style="{StaticResource SecondaryButtonStyle}" />
                                <Button x:Name="RefreshTotpButton" Content="Refresh" Style="{StaticResource SecondaryButtonStyle}" Margin="0" />
                            </WrapPanel>
                        </Border>

                        <DataGrid x:Name="TotpGrid"
                                  Grid.Row="1"
                                  Margin="0,14,0,0"
                                  AutoGenerateColumns="False"
                                  CanUserAddRows="False"
                                  CanUserDeleteRows="False"
                                  IsReadOnly="True"
                                  SelectionMode="Single"
                                  SelectionUnit="FullRow">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="2*" />
                                <DataGridTextColumn Header="Issuer" Binding="{Binding Issuer}" Width="1.2*" />
                                <DataGridTextColumn Header="Code" Binding="{Binding CodeDisplay}" Width="*" />
                                <DataGridTextColumn Header="Expires" Binding="{Binding RemainingText}" Width="*" />
                                <DataGridTextColumn Header="Digits" Binding="{Binding Digits}" Width="Auto" />
                                <DataGridTextColumn Header="Period" Binding="{Binding Period}" Width="Auto" />
                                <DataGridTextColumn Header="Alg" Binding="{Binding Algorithm}" Width="Auto" />
                            </DataGrid.Columns>
                        </DataGrid>

                        <TextBlock Grid.Row="2"
                                   x:Name="VaultStatusText"
                                   Margin="2,12,2,0"
                                   TextWrapping="Wrap" />
                    </Grid>
                </ScrollViewer>
            </TabItem>
        </TabControl>

        <Border x:Name="FooterCard"
                Grid.Row="2"
                BorderThickness="1"
                CornerRadius="16"
                Padding="14">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="AppStatusText" Text="Ready." />
                <TextBlock Grid.Column="1" x:Name="BuildStatusText" />
            </Grid>
        </Border>
    </Grid>
</Window>
'@

    $window = [System.Windows.Markup.XamlReader]::Parse($mainXaml)
    $window.Title = 'WorkPCUtilities'
    $window.Background = Get-ThemeResource -Key 'WindowBackgroundBrush'
    $window.Foreground = Get-ThemeResource -Key 'TextBrush'

    $themeCombo = $window.FindName('ThemeCombo')
    $mainTabs = $window.FindName('MainTabs')
    $startKeepAliveButton = $window.FindName('StartKeepAliveButton')
    $stopKeepAliveButton = $window.FindName('StopKeepAliveButton')
    $localZoneCombo = $window.FindName('LocalZoneCombo')
    $clientZoneCombo = $window.FindName('ClientZoneCombo')
    $totpGrid = $window.FindName('TotpGrid')
    $addTotpButton = $window.FindName('AddTotpButton')
    $editTotpButton = $window.FindName('EditTotpButton')
    $deleteTotpButton = $window.FindName('DeleteTotpButton')
    $viewTotpButton = $window.FindName('ViewTotpButton')
    $copyTotpButton = $window.FindName('CopyTotpButton')
    $viewAllTotpButton = $window.FindName('ViewAllTotpButton')
    $refreshTotpButton = $window.FindName('RefreshTotpButton')
    $caffeinateNoteText = $window.FindName('CaffeinateNoteText')
    $appStatusText = $window.FindName('AppStatusText')
    $buildStatusText = $window.FindName('BuildStatusText')

    $script:MainWindow = $window
    Apply-MainWindowThemeSurface
    Apply-MutedTextBrushes -Window $window -Names @(
        'HeaderSubtitleText',
        'CaffeinateDescriptionText',
        'LocalClockHintText',
        'ClientClockHintText',
        'AllTotpHintText',
        'CaffeinateDetailText',
        'CaffeinateNoteText',
        'LocalZoneText',
        'ClientZoneText',
        'VaultStatusText',
        'AppStatusText',
        'BuildStatusText'
    )

    $themeCombo.ItemsSource = @('System', 'Light', 'Dark')
    $themeCombo.SelectedItem = $Settings.ThemeMode

    $zoneItems = Build-TimeZoneItems
    $localZoneCombo.ItemsSource = $zoneItems
    $clientZoneCombo.ItemsSource = $zoneItems
    $localZoneCombo.DisplayMemberPath = 'Display'
    $clientZoneCombo.DisplayMemberPath = 'Display'
    $localZoneCombo.SelectedValuePath = 'Id'
    $clientZoneCombo.SelectedValuePath = 'Id'
    Select-ComboByValue -ComboBox $localZoneCombo -Value $Settings.LocalClockZoneId
    Select-ComboByValue -ComboBox $clientZoneCombo -Value $Settings.ClientClockZoneId

    $mainTabs.SelectedIndex = [int]$Settings.SelectedTabIndex

    $totpGrid.ItemsSource = $script:VaultItems

    $caffeinateNoteText.Text = 'Citrix sessions typically need a small heartbeat loop. This app uses a harmless F15 pulse plus Windows execution-state protection so the session stays alive without manual input.'
    $buildStatusText.Text = 'Portable PowerShell 5.1'

    $themeCombo.Add_SelectionChanged({
        if ($script:IsLoadingUi) { return }
        $selected = [string]$themeCombo.SelectedItem
        if ([string]::IsNullOrWhiteSpace($selected)) { $selected = 'System' }
        $script:Settings.ThemeMode = $selected
        Save-Settings -Settings $script:Settings
        Set-AppTheme -ThemeMode $selected
        Set-CaffeinateUiState -Running $script:CaffeinateRunning
        Update-ClockDisplays -Settings $script:Settings
        $appStatusText.Text = 'Theme updated to {0}.' -f $selected
    })

    $localZoneCombo.Add_SelectionChanged({
        if ($script:IsLoadingUi) { return }
        $script:Settings.LocalClockZoneId = [string]$localZoneCombo.SelectedValue
        Save-Settings -Settings $script:Settings
        Update-ClockDisplays -Settings $script:Settings
    })

    $clientZoneCombo.Add_SelectionChanged({
        if ($script:IsLoadingUi) { return }
        $script:Settings.ClientClockZoneId = [string]$clientZoneCombo.SelectedValue
        Save-Settings -Settings $script:Settings
        Update-ClockDisplays -Settings $script:Settings
    })

    $startKeepAliveButton.Add_Click({
        Start-Caffeinate
        $appStatusText.Text = 'Keepalive started.'
    })

    $stopKeepAliveButton.Add_Click({
        Stop-Caffeinate
        $appStatusText.Text = 'Keepalive stopped.'
    })

    $addTotpButton.Add_Click({
        $entry = Show-TotpEditorDialog -Owner $window
        if ($entry) {
            $newItem = New-TotpItem -Data $entry
            $script:VaultItems.Add($newItem)
            Save-VaultItems -Items $script:VaultItems
            Update-TotpSnapshots
            $totpGrid.SelectedItem = $newItem
            $appStatusText.Text = 'TOTP entry added.'
        }
    })

    $editTotpButton.Add_Click({
        $selected = $totpGrid.SelectedItem
        if (-not $selected) {
            Show-Message -Text 'Choose a TOTP entry first.' -Caption 'Edit entry' -Icon Warning
            return
        }

        $edited = Show-TotpEditorDialog -Entry $selected -Owner $window
        if ($edited) {
            $selected.Name = $edited.Name
            $selected.Issuer = $edited.Issuer
            $selected.Secret = $edited.Secret
            $selected.Period = [int]$edited.Period
            $selected.Digits = [int]$edited.Digits
            $selected.Algorithm = $edited.Algorithm
            $selected.UpdatedAt = $edited.UpdatedAt
            $selected.DisplayName = if (-not [string]::IsNullOrWhiteSpace($selected.Issuer)) { '{0} - {1}' -f $selected.Issuer, $selected.Name } else { $selected.Name }
            Save-VaultItems -Items $script:VaultItems
            Update-TotpSnapshots
            $appStatusText.Text = 'TOTP entry updated.'
        }
    })

    $deleteTotpButton.Add_Click({
        $selected = $totpGrid.SelectedItem
        if (-not $selected) {
            Show-Message -Text 'Choose a TOTP entry first.' -Caption 'Delete entry' -Icon Warning
            return
        }

        if (Confirm-Action -Text "Delete '$($selected.DisplayName)'?" -Caption 'Delete entry') {
            $null = $script:VaultItems.Remove($selected)
            Save-VaultItems -Items $script:VaultItems
            Update-TotpSnapshots
            $appStatusText.Text = 'TOTP entry deleted.'
        }
    })

    $viewTotpButton.Add_Click({
        $selected = $totpGrid.SelectedItem
        if (-not $selected) {
            Show-Message -Text 'Choose a TOTP entry first.' -Caption 'View TOTP' -Icon Warning
            return
        }
        Show-TotpDetailDialog -Entry $selected -Owner $window
    })

    $copyTotpButton.Add_Click({
        $selected = $totpGrid.SelectedItem
        if (-not $selected) {
            Show-Message -Text 'Choose a TOTP entry first.' -Caption 'Copy TOTP' -Icon Warning
            return
        }

        try {
            $snapshot = Get-TotpSnapshot -Entry $selected
            Copy-CodeToClipboard -Code $snapshot.CodeRaw -Name $selected.DisplayName
        }
        catch {
            Show-Message -Text $_.Exception.Message -Caption 'Copy code' -Icon Warning
        }
    })

    $viewAllTotpButton.Add_Click({
        Show-AllTotpDialog -Owner $window
    })

    $refreshTotpButton.Add_Click({
        Update-TotpSnapshots
        $appStatusText.Text = 'TOTP view refreshed.'
    })

    $totpGrid.Add_MouseDoubleClick({
        $selected = $totpGrid.SelectedItem
        if ($selected) {
            Show-TotpDetailDialog -Entry $selected -Owner $window
        }
    })

    $window.Add_Closing({
        try {
            if ($script:ClockTimer) {
                $script:ClockTimer.Stop()
                $script:ClockTimer = $null
            }
            if ($script:ThemeTimer) {
                $script:ThemeTimer.Stop()
                $script:ThemeTimer = $null
            }
            if ($script:CaffeinateRunning) {
                Stop-Caffeinate
            }

            $script:Settings.ThemeMode = [string]$themeCombo.SelectedItem
            $script:Settings.LocalClockZoneId = [string]$localZoneCombo.SelectedValue
            $script:Settings.ClientClockZoneId = [string]$clientZoneCombo.SelectedValue
            $script:Settings.SelectedTabIndex = [int]$mainTabs.SelectedIndex

            if ($window.WindowState -eq [System.Windows.WindowState]::Normal) {
                $script:Settings.WindowWidth = [int][math]::Round($window.Width)
                $script:Settings.WindowHeight = [int][math]::Round($window.Height)
                $script:Settings.WindowLeft = [int][math]::Round($window.Left)
                $script:Settings.WindowTop = [int][math]::Round($window.Top)
                $script:Settings.WindowState = 'Normal'
            }
            else {
                if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
                    $script:Settings.WindowState = 'Normal'
                }
                else {
                    $script:Settings.WindowState = [string]$window.WindowState
                }
            }

            Save-Settings -Settings $script:Settings
            Save-VaultItems -Items $script:VaultItems
        }
        catch {
            # Best-effort persistence only.
        }
    })

    $window.Add_ContentRendered({
        if ($window.WindowState -eq [System.Windows.WindowState]::Normal) {
            $window.Width = [double]$script:Settings.WindowWidth
            $window.Height = [double]$script:Settings.WindowHeight
            if ($null -ne $script:Settings.WindowLeft) { $window.Left = [double]$script:Settings.WindowLeft }
            if ($null -ne $script:Settings.WindowTop) { $window.Top = [double]$script:Settings.WindowTop }
        }
        if ($script:Settings.WindowState -and $script:Settings.WindowState -ne 'Normal') {
            try {
                $restoredState = [System.Enum]::Parse([System.Windows.WindowState], [string]$script:Settings.WindowState)
                if ($restoredState -eq [System.Windows.WindowState]::Minimized) {
                    $restoredState = [System.Windows.WindowState]::Normal
                }
                $window.WindowState = $restoredState
            }
            catch {
                $window.WindowState = [System.Windows.WindowState]::Normal
            }
        }
    })

    $script:IsLoadingUi = $false
    Set-CaffeinateUiState -Running $false
    Update-ClockDisplays -Settings $Settings
    Update-TotpSnapshots
    $appStatusText.Text = 'Ready.'

    $script:ClockTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ClockTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:ClockTimer.Add_Tick({
        Update-ClockDisplays -Settings $script:Settings
        Update-TotpSnapshots
    })
    $script:ClockTimer.Start()

    $script:ThemeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ThemeTimer.Interval = [TimeSpan]::FromSeconds(5)
    $script:ThemeTimer.Add_Tick({
        if ($script:Settings.ThemeMode -eq 'System') {
            $effective = Get-EffectiveThemeMode -ThemeMode 'System'
            if ($script:CurrentAppliedTheme -ne $effective) {
                Set-AppTheme -ThemeMode 'System'
                Set-CaffeinateUiState -Running $script:CaffeinateRunning
            }
        }
    })
    $script:ThemeTimer.Start()

    return $window
}

function Initialize-App {
    Ensure-AppRoot
    Ensure-WpfShell

    $script:Settings = Get-Settings
    if (-not $script:Settings) {
        $script:Settings = Get-DefaultSettings
    }

    if ($script:Settings.ThemeMode -notin @('System', 'Light', 'Dark')) {
        $script:Settings.ThemeMode = 'System'
    }

    $localCandidate = Get-TimeZoneByIdSafe -ZoneId ([string]$script:Settings.LocalClockZoneId)
    if ($localCandidate.Id -ne [string]$script:Settings.LocalClockZoneId) {
        $script:Settings.LocalClockZoneId = [System.TimeZoneInfo]::Local.Id
    }
    $clientCandidate = Get-TimeZoneByIdSafe -ZoneId ([string]$script:Settings.ClientClockZoneId)
    if ($clientCandidate.Id -ne [string]$script:Settings.ClientClockZoneId) {
        $script:Settings.ClientClockZoneId = 'UTC'
    }

    try {
        $script:Settings.CaffeinateIntervalSec = [int]$script:Settings.CaffeinateIntervalSec
    }
    catch {
        $script:Settings.CaffeinateIntervalSec = 120
    }
    if ($script:Settings.CaffeinateIntervalSec -lt 30 -or $script:Settings.CaffeinateIntervalSec -gt 3600) {
        $script:Settings.CaffeinateIntervalSec = 120
    }

    if (-not (Test-Path -LiteralPath $script:SettingsPath)) {
        Save-Settings -Settings $script:Settings
    }

    $script:VaultItems.Clear()
    foreach ($entry in @(Load-VaultItems)) {
        $script:VaultItems.Add($entry)
    }

    if (-not (Test-Path -LiteralPath $script:VaultPath)) {
        Save-VaultItems -Items $script:VaultItems
    }

    $window = Initialize-Ui -Settings $script:Settings

    if ($script:VaultItems.Count -gt 0) {
        Update-TotpSnapshots
    }

    return $window
}

try {
    $script:Settings = $null
    $window = Initialize-App
    [void]$window.ShowDialog()
}
catch {
    try {
        [System.Windows.MessageBox]::Show("WorkPCUtilities could not start.`n`n$($_.Exception.Message)", 'WorkPCUtilities', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
    catch {
        # Fallback to silent failure if GUI startup itself broke.
    }
}
