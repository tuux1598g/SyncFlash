#Requires -version 2.0
#
# SyncFlash - Sync directories to flash drive on insert
# copyright (c)2011 Shaun Smith.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
##

# Setup the environment - please include trailing slash!
$syncFlashDir = "D:\Scripts\"
$syncFlashConfig = "${syncFlashDir}SyncFlash\"

# Check that we are not already running
$proc=Get-Process -Name "powershell" -ErrorAction SilentlyContinue

if ( $proc.count -gt 1 ) {
    write-host "Another powershell process is running, we will exit.."
    exit
}

# Unregister the event, in case it is already registered
Unregister-Event -SourceIdentifier volumeChange
Register-WmiEvent -Class win32_VolumeChangeEvent -SourceIdentifier volumeChange

# Use System.Windows.Forms for balloon notifications
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Security.Cryptography")

# Get the computer name
$computerName = get-content env:computername


# Write some debugging information to the console
#$now = get-date -format s
write-host (get-date -format s) "Beginning sync monitoring script on $computerName...`r`n"

# Function to compare checksums of two files
# Returns true for identical files, false for files that differ
function compareFiles ([string]$srcFilename, [string]$dstFilename) {
    # Choose the hashing algorithm to use
    try {
        $cryptoProvider = new-object System.Security.Cryptography.SHA256CryptoServiceProvider
    } catch {
        write-host (get-date -format s) "Unable to load Crypto Service Provider for verification.`r`n"
        out-host (get-date -format s) $_.Exception.toString()
        return $false;
    }
    
    # Ensure that the files exist at the destination (copy may have failed completely)
    if ( !(Test-Path -LiteralPath $dstFilename) ) {
        return $false;
    }
    
    $srcFile = [System.IO.File]::OpenRead("$srcFilename")
    $srcHash = $cryptoProvider.ComputeHash($srcFile)
    $srcHashString = [System.Bitconverter]::toString($srcHash).Replace("-","")
    $srcFile.Close()
    
    $dstFile = [System.IO.File]::OpenRead("$dstFilename")
    $dstHash = $cryptoProvider.ComputeHash($dstFile)
    $dstHashString = [System.Bitconverter]::toString($dstHash).Replace("-","")
    $dstFile.Close()
    
    
    # Compare the two, return true on success, false on failure
    if ( $srcHashString -eq $dstHashString ) {
        return $true;
    } else {
        write-output (get-date -format s) " Hash Failed: $dstFilename"
        return $false;
    }
}

# Start looping (with no break-out)
do{
    # Monitor for Volume insert/remove event
    $newEvent = Wait-Event -SourceIdentifier volumeChange
    $eventType = $newEvent.SourceEventArgs.NewEvent.EventType
    $eventTypeName = switch($eventType)
    {
        1 {"Configuration changed"}
        2 {"Device Inserted"}
        3 {"Device Removed"}
        4 {"Docking"}
    }

    write-host (get-date -format s) "Event detected =  $eventTypeName`r`n"
    
    # If a volume has been added, check our backup schedules
    if ($eventType -eq 2)
    {
        # Get some details about the device
        $driveLetter = $newEvent.SourceEventArgs.NewEvent.DriveName
        $driveLabel = ([wmi]"Win32_LogicalDisk='$driveLetter'").VolumeName
        write-host (get-date -format s) "Drive name = $driveLetter`r`n"
        write-host (get-date -format s) "Drive label = $driveLabel`r`n"
        
        # Check if this is one of our valid backup devices, based on the label - TODO: more security?
        if ( Test-Path ${syncFlashConfig}${driveLabel}.sfb )
        {
            write-host (get-date -format s) "Starting backup in 2 seconds...`r`n"
            start-sleep -seconds 2
            
            $numActions = (Get-Content ${syncFlashConfig}${driveLabel}.sfb | Measure-Object).Count

            # Prepare a popup window for user yes/no response
            $yesnoObj = new-object -comobject wscript.shell
            $yesnoMessage = @"
             A valid backup device named '$driveLabel' has been detected.
             
             There are $numActions backup actions registered for this device.
             
             Would you like to sync to the backup device now?
"@
            
            $intResponse = $yesnoObj.popup($yesnoMessage, 0, "$computerName Backup", 68)
            
            # If the response is 'YES', we should continue with the backup
            if ( $intResponse -eq 6 ) {
                Start-Transcript -Path "C:\Applications\SyncFlash.log"
                # Balloon notification to say backup is taking place
                $objNotifyIcon = new-object System.Windows.Forms.NotifyIcon
                $objNotifyIcon.Icon = "${syncFlashDir}SyncFlash.ico"
                $objNotifyIcon.BalloonTipIcon = "Info"
                $objNotifyIcon.BalloonTipText = "Syncing to the backup device $driveLabel..."
                $objNotifyIcon.BalloonTipTitle = "$computerName Backup Running"
                $objNotifyIcon.Visible = $true
                $objNotifyIcon.ShowBalloonTip(10000)
                
                # Set the backup option defaults for ROBOCOPY
                $backupOptions = "/MIR /R:3 /W:10 /XO /TEE /XJ"
                
                #/LOG:$driveLetter\BackupSync.log
                
                
                # Find the backups that we need to execute
                $roboExitCode=0
                $count=0;
                foreach ( $backupLine in Get-Content ${syncFlashConfig}${driveLabel}.sfb ) {
                    $count++;
                    
                    $backupLine = $backupLine.replace('&DRIVE&', $driveLetter)
                    $backupLine = $backupLine.replace('&COMPNAME&', $computerName)
                    
                    $backupArr  = $backupLine.split('|');
                    
                    $backupSrc = $backupArr[0];
                    $backupDest = $backupArr[1];
                    
                    if ( !$backupSrc.EndsWith(".") ) {
                        $backupSrc = "$backupSrc."
                    }
                    if ( !$backupDest.EndsWith(".") ) {
                        $backupDest = "$backupDest."
                    }
                    
                    $roboLogParameter = "/LOG:$driveLetter\BackupSync.log"
                    if ( $count -gt 1 ) {
                        $roboLogParameter = "/LOG+:$driveLetter\BackupSync.log"
                    }
                    $roboLogParameter += " /FP /NP /NS /NC /NFL /NDL"
                    
                    
                    write-host (get-date -format s) "Running: $backupSrc -> $backupDest`r`n"
                    write-host (get-date -format s) "Backup Options = $backupOptions $roboLogParameter`r`n"
                    
                    # Obtain a list of files that will be copied (for verification checks later)
                    $roboListFilesArguments = "/L /NDL /NC /NS /NP /NJH /NJS /XX"
                    $roboListFilesInfo = New-Object System.Diagnostics.ProcessStartInfo;
                    $roboListFilesInfo.FileName = "C:\Windows\System32\robocopy.exe";
                    $roboListFilesInfo.Arguments = "`"$backupSrc`"","`"$backupDest`"",$backupOptions,$roboListFilesArguments;
                    $roboListFilesInfo.CreateNoWindow = $false;
                    $roboListFilesInfo.UseShellExecute = $false;
                    $roboListFilesInfo.RedirectStandardOutput = $true;
                    
                    $roboListFilesProc = [System.Diagnostics.Process]::Start($roboListFilesInfo);

                    # We read stdout before WaitForExit to avoid deadlock if the stdout buffer fills
                    $roboListFilesOutput = $roboListFilesProc.StandardOutput.ReadToEnd();
                    $roboListFilesProc.WaitForExit();
                    
                    $roboFileList = @();
                    foreach ( $line in $roboListFilesOutput.split("`n") ) {
                        $line = $line.Trim();
                        if ( $line -ne "" ) {
                            $roboFileList += $line.Replace($backupSrc.TrimEnd("."),"");
                        }
                    }
                    
                    $roboListFilesProc.Dispose();
                    
                    #####
                    # $roboFileList is now an array of relative filenames for this backup job
                    #####
                    
                    
                    # Perform the backup process
                    $roboProc = start-process "C:\Windows\System32\robocopy.exe" -ArgumentList "`"$backupSrc`"","`"$backupDest`"",$backupOptions,$roboLogParameter -Wait -PassThru -NoNewWindow
                
                    # Check exit code from ROBOCOPY process
                    
                    $curRoboProcExitCode = $roboProc.ExitCode
                    write-host (get-date -format s) "ROBOCOPY Exit Code = $curRoboProcExitCode`r`n"
                
                    if ( $curRoboProcExitCode -gt $roboExitCode ) 
                    {
                        $roboExitCode = $curRoboProcExitCode
                    }
                    
                    
                    ## Now, we should verify all files have been written
                    write-host (get-date -format s) "Performing read-write-read verification of backup..`r`n"
                    
                    $verifyPassed = $true;
                    foreach ( $filename in $roboFileList ) {
                        $srcFile = "$backupSrc\$filename";
                        $dstFile = "$backupDest\$filename";
                        
                        $verifyResult = $false;
                        $verifyResult = compareFiles "$srcFile" "$dstFile";
                        
                        ##write-host (get-date -format s) "   Verify: $dstFile - $verifyResult`r`n"
                        
                        if ( !$verifyResult ) {
                            # We should log the file somewhere
                            write-host (get-date -format s) " COPY FAILED: $srcFile`r`n"
                            $verifyPassed = $false;
                            
                            $roboExitCode = 999;
                        }
                    }
                    
                }
                
                write-host (get-date -format s) "Final exit code =  $roboExitCode`r`n"
                if ( $roboExitCode -le 3 ) {
                
                    # Show backup completed message
                    $objNotifyIcon.BalloonTipTitle = "$computerName Backup Complete"
                    
                    if ( $roboExitCode -ne 0 ) {
                        write-host (get-date -format s) "Backup completed successfully, all files verified`r`n"
                        $objNotifyIcon.BalloonTipText = "Backup to $driveLabel completed."
                    } else {
                        write-host (get-date -format s) "No files to be updated on this backup`r`n"
                        $objNotifyIcon.BalloonTipText = "Nothing to backup to $driveLabel."
                    }
                } elseif ( $roboExitCode -eq 999 ) {
                    # Show backup verification failed
                    write-host (get-date -format s) "File verification failed for $driveLabel, please see logfile`r`n"
                    $objNotifyIcon.BalloonTipText = "Backup verification failed for $driveLabel."
                    $objNotifyIcon.BalloonTipTitle = "$computerName Backup ERROR"
                    $objNotifyIcon.BalloonTipIcon = "Error"
                } else {
                    # Show backup error message
                    write-host (get-date -format s) "A robocopy error occurred during backup, see logfile on backup destination`r`n"
                    $objNotifyIcon.BalloonTipText = "An error occurrred whilst backing up to $driveLabel."
                    $objNotifyIcon.BalloonTipTitle = "$computerName Backup ERROR"
                    $objNotifyIcon.BalloonTipIcon = "Error"
                }
                
                $objNotifyIcon.ShowBalloonTip(10000)
                
                # Display this icon/message for 10 seconds max, then dispose of it
                start-sleep -seconds 10
                $objNotifyIcon.Dispose();
                
                Stop-Transcript
            }
        } else {
            write-host (get-date -format s) "Not a valid backup drive, ignoring.`r`n"
        }
        
    }
    Remove-Event -SourceIdentifier volumeChange
} while (1-eq1) #Loop until next event
Unregister-Event -SourceIdentifier volumeChange


