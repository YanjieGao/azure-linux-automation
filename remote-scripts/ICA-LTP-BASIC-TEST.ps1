<#-------------Create Deployment Start------------------#>
Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()
$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
		$clientVMData = $allVMData
		#region CONFIGURE VM FOR TERASORT TEST
		LogMsg "Test VM details :"
		LogMsg "  RoleName : $($clientVMData.RoleName)"
		LogMsg "  Public IP : $($clientVMData.PublicIP)"
		LogMsg "  SSH Port : $($clientVMData.SSHPort)"
		#
		# PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.	
		#
		ProvisionVMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
		#endregion

		LogMsg "Generating constansts.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
		Add-Content -Value "TC_COVERED=LTP-01" -Path $constantsFile	
		LogMsg "constanst.sh created successfully..."
		LogMsg (Get-Content -Path $constantsFile)
		#endregion

		
		#region EXECUTE TEST
		$myString = @"
cd /root/
wget https://raw.githubusercontent.com/iamshital/lis-test/master/WS2012R2/lisa/remote-scripts/ica/LTP_test.sh
chmod +x LTP_test.sh
./LTP_test.sh &> LtpBasicConsoleLogs.txt
. azuremodules.sh
collect_VM_properties
"@
        $StartScriptName = "StartLTPBasic.sh"
		Set-Content "$LogDir\$StartScriptName" $myString
		RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files ".\$constantsFile,.\remote-scripts\azuremodules.sh,.\$LogDir\$StartScriptName" -username "root" -password $password -upload
		$out = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
		$testJob = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/$StartScriptName" -RunInBackground
		#endregion

		#region MONITOR TEST
		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -n 1  LtpBasicConsoleLogs.txt"
			LogMsg "Current Test Staus : $currentStatus"
			WaitFor -seconds 20
		}

        RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"
        RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "LtpBasicConsoleLogs.txt"
        $summary = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/summary.log"

		$finalStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"

        if ($finalStatus -imatch "TestCompleted")
        {
		
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "ltp-output.log"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "ltp-results.log"
		$testSummary = $null
		$ltpResultLog = Get-Content -Path "$LogDir\ltp-results.log"
        
        $totalLTPTests = (Select-String -Path "$LogDir\ltp-results.log" -Pattern "Total Tests").Line.Split(":")[1].Trim()
        $resultSummary +=  CreateResultSummary -testResult $totalLTPTests -metaData "Total Tests" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName

        $totalLTPSkippedTests = (Select-String -Path "$LogDir\ltp-results.log" -Pattern "Total Skipped Tests").Line.Split(":")[1].Trim()
        $resultSummary +=  CreateResultSummary -testResult $totalLTPSkippedTests -metaData "Total Skipped Tests" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName

        $totalLTPFails = (Select-String -Path "$LogDir\ltp-results.log" -Pattern "Total Failures").Line.Split(":")[1].Trim()
        $resultSummary +=  CreateResultSummary -testResult $totalLTPFails -metaData "Total Failures" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
		}
        else
        {

        }
		#endregion

		if ( ($totalLTPFails -ne 0) -or (!$finalStatus -imatch "TestCompleted"))
		{
			LogErr "Test failed. : $summary."
			$testResult = "FAIL"
		}
		elseif ( $totalLTPFails -eq 0)
		{
			LogMsg "Test Completed."
			$testResult = "PASS"
		}
		LogMsg "Test result : $testResult"
		LogMsg "Test Completed"
	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"   
	}
	Finally
	{
		$metaData = "NTTTCP RESULT"
		if (!$testResult)
		{
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}   
}

else
{
	$testResult = "Aborted"
	$resultArr += $testResult
}

$result = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $result, $resultSummary
