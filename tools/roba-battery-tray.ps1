param(
    [switch]$Once,
    [ValidateRange(15, 3600)]
    [int]$RefreshSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Runtime.WindowsRuntime

if (-not ('RobaBufferReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport]
[Guid("905A0FEF-BC53-11DF-8C49-001E4FC686DA")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IBufferByteAccess
{
    [PreserveSig]
    int Buffer(out IntPtr value);
}

public static class RobaBufferReader
{
    public static byte[] Read(object buffer, uint length)
    {
        var access = (IBufferByteAccess)buffer;
        IntPtr pointer;
        access.Buffer(out pointer);

        var data = new byte[length];
        Marshal.Copy(pointer, data, 0, (int)length);
        return data;
    }
}
'@
}

[void][Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
[void][Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
[void][Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
[void][Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
[void][Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]

function Wait-WinRtOperation {
    param(
        [Parameter(Mandatory)]
        $Operation,

        [Parameter(Mandatory)]
        [Type]$ResultType
    )

    $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.IsGenericMethod -and
            $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1

    $task = $asTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))

    try {
        $task.Wait()
    }
    catch {
        throw $task.Exception.Flatten().InnerException
    }

    return $task.Result
}

function Get-RobaBatteryLevels {
    $selector = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromPairingState($true)
    $devices = Wait-WinRtOperation `
        ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector)) `
        ([Windows.Devices.Enumeration.DeviceInformationCollection])

    $deviceInfo = $devices |
        Where-Object Name -eq 'roBa' |
        Select-Object -First 1

    if (-not $deviceInfo) {
        throw 'A paired roBa device was not found.'
    }

    $device = Wait-WinRtOperation `
        ([Windows.Devices.Bluetooth.BluetoothLEDevice]::FromIdAsync($deviceInfo.Id)) `
        ([Windows.Devices.Bluetooth.BluetoothLEDevice])

    if (-not $device) {
        throw 'Could not open the roBa device.'
    }

    $servicesResult = Wait-WinRtOperation `
        ($device.GetGattServicesForUuidAsync(
            [Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceUuids]::Battery,
            [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached
        )) `
        ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult])

    if ($servicesResult.Status -ne 'Success') {
        throw "Could not read the Battery Service: $($servicesResult.Status)"
    }

    $levels = @()

    foreach ($service in $servicesResult.Services) {
        $characteristicsResult = Wait-WinRtOperation `
            ($service.GetCharacteristicsForUuidAsync(
                [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicUuids]::BatteryLevel,
                [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached
            )) `
            ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult])

        if ($characteristicsResult.Status -ne 'Success') {
            continue
        }

        foreach ($characteristic in $characteristicsResult.Characteristics) {
            $readResult = Wait-WinRtOperation `
                ($characteristic.ReadValueAsync(
                    [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached
                )) `
                ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult])

            if ($readResult.Status -ne 'Success') {
                continue
            }

            # The Bluetooth Battery Level characteristic is a single uint8.
            $bytes = [RobaBufferReader]::Read($readResult.Value, 1)
            $levels += [pscustomobject]@{
                Handle = [int]$characteristic.AttributeHandle
                Level  = [int]$bytes[0]
            }
        }
    }

    $levels = @($levels | Sort-Object Handle)

    if ($levels.Count -lt 2) {
        throw "Found only $($levels.Count) Battery Service value(s). Check the roBa_R firmware."
    }

    # ZMK registers the central BAS before the proxied peripheral BAS.
    return [pscustomobject]@{
        Central    = $levels[0].Level
        Peripheral = $levels[1].Level
        Timestamp  = Get-Date
    }
}

if ($Once) {
    $battery = Get-RobaBatteryLevels
    "roBa_R: {0}%  roBa_L: {1}%  ({2:yyyy-MM-dd HH:mm:ss})" -f `
        $battery.Central, $battery.Peripheral, $battery.Timestamp
    exit 0
}

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, 'Local\roBaBatteryTray', [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Text = 'roBa: reading battery levels'
$notifyIcon.Visible = $true

$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$statusItem = $menu.Items.Add('Reading...')
$statusItem.Enabled = $false
$refreshItem = $menu.Items.Add('Refresh now')
$exitItem = $menu.Items.Add('Exit')
$notifyIcon.ContextMenuStrip = $menu

function Update-RobaBatteryTray {
    try {
        $battery = Get-RobaBatteryLevels
        $status = "roBa_R $($battery.Central)% / roBa_L $($battery.Peripheral)%"
        $notifyIcon.Text = "roBa: $status"
        $statusItem.Text = $status
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
        return $status
    }
    catch {
        $message = $_.Exception.Message
        $notifyIcon.Text = 'roBa: battery read failed'
        $statusItem.Text = "Read failed: $message"
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Warning
        return $statusItem.Text
    }
}

$refreshItem.Add_Click({
    $status = Update-RobaBatteryTray
    $notifyIcon.ShowBalloonTip(3000, 'roBa Battery', $status, 'Info')
})

$notifyIcon.Add_DoubleClick({
    $status = Update-RobaBatteryTray
    $notifyIcon.ShowBalloonTip(3000, 'roBa Battery', $status, 'Info')
})

$exitItem.Add_Click({
    [System.Windows.Forms.Application]::Exit()
})

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = $RefreshSeconds * 1000
$timer.Add_Tick({
    [void](Update-RobaBatteryTray)
})

try {
    $initialStatus = Update-RobaBatteryTray
    $notifyIcon.ShowBalloonTip(3000, 'roBa Battery', $initialStatus, 'Info')
    $timer.Start()
    [System.Windows.Forms.Application]::Run()
}
finally {
    $timer.Stop()
    $timer.Dispose()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $menu.Dispose()

    if ($createdNew) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
