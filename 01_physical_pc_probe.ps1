param(
    [string]$OutputPath = ".\physical_pc_report.txt"
)

$ErrorActionPreference = "Continue"

function Write-Section {
    param([string]$Title)
    Add-Content -Path $OutputPath -Value ""
    Add-Content -Path $OutputPath -Value ("=" * 78)
    Add-Content -Path $OutputPath -Value $Title
    Add-Content -Path $OutputPath -Value ("=" * 78)
}

function Add-CommandOutput {
    param(
        [string]$Title,
        [scriptblock]$Command
    )

    Write-Section $Title
    try {
        $result = & $Command
        if ($null -eq $result) {
            Add-Content -Path $OutputPath -Value "<no output>"
        } else {
            $result | Out-String -Width 240 | Add-Content -Path $OutputPath
        }
    } catch {
        Add-Content -Path $OutputPath -Value ("ERROR: " + $_.Exception.Message)
    }
}

if (Test-Path -LiteralPath $OutputPath) {
    Remove-Item -LiteralPath $OutputPath -Force
}

Add-Content -Path $OutputPath -Value "Physical PC baseline report"
Add-Content -Path $OutputPath -Value ("Generated: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))
Add-Content -Path $OutputPath -Value ("Computer: " + $env:COMPUTERNAME)
Add-Content -Path $OutputPath -Value ("User: " + $env:USERNAME)

Add-CommandOutput "Task 1 - Computer system identity" {
    Get-CimInstance Win32_ComputerSystem |
        Select-Object Manufacturer, Model, SystemType, Domain, TotalPhysicalMemory,
            NumberOfProcessors, NumberOfLogicalProcessors
}

Add-CommandOutput "Task 2 - BIOS identity" {
    Get-CimInstance Win32_BIOS |
        Select-Object Manufacturer, SMBIOSBIOSVersion, Version, ReleaseDate, SerialNumber
}

Add-CommandOutput "Task 3 - CPU baseline" {
    Get-CimInstance Win32_Processor |
        Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors,
            MaxClockSpeed, VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions
}

Add-CommandOutput "Task 4 - RAM modules" {
    Get-CimInstance Win32_PhysicalMemory |
        Select-Object BankLabel, Manufacturer, PartNumber, Speed,
            @{Name="CapacityGB";Expression={[math]::Round($_.Capacity / 1GB, 2)}}
}

Add-CommandOutput "Task 5 - Disk free space" {
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Select-Object DeviceID, VolumeName,
            @{Name="SizeGB";Expression={[math]::Round($_.Size / 1GB, 2)}},
            @{Name="FreeGB";Expression={[math]::Round($_.FreeSpace / 1GB, 2)}}
}

Add-CommandOutput "Task 6 - Physical disks" {
    Get-CimInstance Win32_DiskDrive |
        Select-Object Model, InterfaceType, MediaType,
            @{Name="SizeGB";Expression={[math]::Round($_.Size / 1GB, 2)}}
}

Add-CommandOutput "Task 7 - GPU baseline" {
    Get-CimInstance Win32_VideoController |
        Select-Object Name, AdapterCompatibility, DriverVersion, DriverDate, VideoProcessor,
            @{Name="AdapterRAMGB";Expression={if ($_.AdapterRAM) {[math]::Round($_.AdapterRAM / 1GB, 2)} else {$null}}}
}

Add-CommandOutput "Task 8 - Physical network adapters" {
    Get-NetAdapter -Physical |
        Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress
}

Add-CommandOutput "Task 9 - OS baseline" {
    Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime
}

Write-Section "Student notes"
Add-Content -Path $OutputPath -Value "1. Is this a Dell OptiPlex or another physical host?"
Add-Content -Path $OutputPath -Value "2. How much RAM can we safely reserve for VMs?"
Add-Content -Path $OutputPath -Value "3. Is there enough free disk space for VM disks and snapshots?"
Add-Content -Path $OutputPath -Value "4. Is the GPU a real vendor driver or Microsoft Basic Display?"
Add-Content -Path $OutputPath -Value "5. Which physical NIC is the primary uplink?"

Write-Host "Report written to $OutputPath"
