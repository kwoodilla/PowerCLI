# PowerCLI
##This script creates a new AD user and a vapp for them and gives them permissions to that VAPP

#Create list of characters
$alphabet=$NULL;For ($a=48;$a –le 126;$a++) {$alphabet+=,[char][byte]$a }

$tempPass =""

#random password generator
Function GET-Temppassword() {

    #define parameters
    Param(

    [int]$length=10,
   
    [string[]]$sourcedata

    )

 
    #loop through list to generate password
    For ($loop=1; $loop –le $length; $loop++) {
                
        #put characters in string
        $TempPassword+=($sourcedata | GET-RANDOM)
    }

    return $TempPassword

}

#permsissions function
function SetUserPermissions($vapp){
    #set domain username
    $DomainUser = ("cyberpatriot\" + $vapp)

    #add permission for domain user to vapp
    New-VIPermission -Entity $vapp -Principal $DomainUser -Role 'Admin'  
}

#get input function
function getUserData(){
    #initialize empty array
    $data = @()

    #get data and store in variables
    #vsphere commands work because function is called after connected to vcenter
    Write-Host "`nAvailable Hosts:`n" 
    $temp = get-vmhost
    foreach($i in $temp){
        Write-Host -ForegroundColor Cyan $i.name
    }
    $esxiHost = read-host -prompt “Which host would you like to put the vapp on? “

    Write-Host "`nAvailable Vapps:`n" 
    $temp = get-vapp -location $esxiHost
    foreach($i in $temp){
        Write-Host -ForegroundColor Cyan $i.name
    }
    $original= read-host -prompt “What vapp would you like to clone? ”

    write-host "`nAvailable datastores:`n" 
    $temp = get-datastore -vmhost $esxiHost
    foreach($i in $temp){
        Write-Host -ForegroundColor Cyan $i.name
    }
    $ds= read-host -prompt “Which datastore would you like it on? “

    #store variables in array
    $data += $esxiHost, $original, $ds

    #return the array to be referenced when cloning
    return $data
}

function createUser(){
    #Get user input
    $name= read-host -prompt “what would you like to name the new user (do not use spaces)? ”

    $tempPass=GET-Temppassword -length 10 -sourcedata $alphabet

    #create the user
    New-ADUser -Name $name -GivenName $name -SamAccountName $name -UserPrincipalName ($name + "@cyberpatriot.local") -AccountPassword (ConvertTo-SecureString -AsPlainText $tempPass -Force) -PassThru |Enable-ADAccount

    #add user to security group
    Add-ADGroupMember -Identity TestGroup -Members $name

    #store username and password in list
    $userInfo = $name, $tempPass

    #return the list
    return $userInfo
}

#full clone function
function cloneVappFUll(){
    #create new user and store there info in variables to be referenced later
    $userInfo = createUser

    $name = $userInfo[0]
    $tempPass = $userInfo[1]

    #connect to vcenter server
    connect-viserver -server "216.93.159.131"
    $test=”f”

    #get user input and store in variables
    $data = getUserData
    $esxiHost = $data[0]
    $original= $data[1]
    $ds= $data[2]

    #Check if vapp is on
    #If it is on shut it off
    $vapp = get-vapp $original
    If ($vapp.Status -eq “Started”){
	    Stop-vapp $vapp
	    $test =”t”
    }

    #clone the vapp using user variables
    New-vapp -Name $name -vapp $original -location $esxiHost -datastore $ds

    #rename VMs within VAPP
    $vms = get-vm -location $name

    Foreach($vm in $vms){
        Set-vm $vm -name ($name + “-” + $vm.Name) -confirm:$false
    }

    #change name of port group
    #define new name
    $newName = ($name+'-net')

    #get port group to change
    $pgs = get-virtualportgroup -vmhost $esxiHost
    foreach ($i in $pgs){
        if($i.name -like"School*"){
            $pgName = $i.name
            break
        }
    }

    #change name
    get-vmhost $esxiHost | get-virtualportgroup -name $pgName | set-virtualportgroup -name $newName

    #delay next line so that pg names refresh
    Start-Sleep 15


    #Set vms in network to use portgroup
    $vms = get-vm -location $name
    foreach ($vm in $vms){
        get-vm $vm | get-networkadapter | set-networkadapter -NetworkName $newName -confirm:$false 
    }

    #change vms already in port group to use new name
    $allVM = get-vm
    Foreach ($i in $allVM){
	    $networkadapt = $i | get-networkadapter
    	Foreach ( $j in $networkadapt){
	    	if( $j.NetworkName -eq $pgname){
		    	Get-networkadapter -vm $i.name -name $j | set-networkadapter -networkname $newname -confirm:$false
	    	}
    	}
    }

    #restart vapp if it was shut off
    If ($test -eq “t”){
         Start-vapp $vapp
    }
    
    #set user permissions to the Vapp
    SetUserPermissions($name)

    ##Disconnect from vcenter
    Disconnect-VIServer -Server * -confirm:$false

    #echo user password
    Write-Host -ForegroundColor Cyan "###############################################"
    Write-Host -ForegroundColor Cyan ("Password for the new user is:" + $tempPass)
    Write-Host -ForegroundColor Cyan "###############################################"
}
    
#Linked Clone function
function cloneVappLinked(){
    #Create new user and store their info in varibales to be referenced later
    $userInfo = createUser

    $name = $userInfo[0]
    $tempPass = $userInfo[1]

    #connect to vcenter server
    connect-viserver -server "216.93.159.131"

    #initialize variable
    $test=”f”

    #get user input and store in variables
    $data = getUserData
    $data
    $esxiHost = $data[0]
    $original= $data[1]
    $ds= $data[2]

    #Check if vapp is on
    #If it is on shut it off 
    $vapp = get-vapp $original
    If ($vapp.Status -eq “Started”){
	    Stop-vapp $vapp
	    $test =”t”
    }

    #clone the vapp using user variables
    New-vapp -Name $name -location $esxiHost -datastore $ds -vapp "empty"
    $ogvms = Get-vm -location $vapp

    foreach ($i in $ogvms){

        #Name the VM
        $tempname = ($name + "-"+ $i.Name )

        #Search for Snapshot or Create One
        $snapshot = get-snapshot -vm $i
        if (!$snapshot)
        { 
        $ogsnapshot = New-Snapshot -VM $i -Name "Cloning Snapshot" -Description "Snapshot for linked clones" -Memory -Quiesce
        }
        else 
        {
        $ogsnapshot = get-snapshot -vm $i
        }

        #Create the Linked Clone
        new-vm -Name $tempname -vm $i -vmhost $esxihost -vapp $name -datastore $ds -LinkedClone -ReferenceSnapshot $ogsnapshot
    }


    #Change name of port group
    $newName = ($name+'-net')
    $pgs = get-virtualportgroup -vmhost $esxiHost
    foreach ($i in $pgs){
        if($i.name -like"School*"){
            $pgName = $i.name
            break
        }
    }

    #Rename Portgroup
    get-vmhost $esxiHost | get-virtualportgroup -name $pgName | set-virtualportgroup -name $newName

    Start-Sleep 15

    #Set VMs in new Vapp to use new portgroup
    $vms = get-vm -location $name
    foreach ($vm in $vms){
        get-vm $vm | get-networkadapter | set-networkadapter -NetworkName $newName -confirm:$false 
    }

    #change vms already in port group to use new name
    $allVM = get-vm
    Foreach ($i in $allVM){
	    $networkadapt = $i | get-networkadapter
    	Foreach ( $j in $networkadapt){
	    	if( $j.NetworkName -eq $pgname){
		    	Get-networkadapter -vm $i.name -name $j | set-networkadapter -networkname $newname -confirm:$false
	    	}
    	}
    }



    #restart vapp if it was shut off
    If ($test -eq “t”){
        Start-vapp $vapp
    }

    SetUserPermissions($name)

    ##Disconnect from vcenter
    Disconnect-VIServer -Server * -confirm:$false

    #echo user password
    Write-Host -ForegroundColor Cyan "###############################################"
    Write-Host -ForegroundColor Cyan ("Password for the new user is:" + $tempPass)
    Write-Host -ForegroundColor Cyan "###############################################"

}

#menu functions
#prompt for when finished then call main
function allDone(){
    Read-Host -Prompt "Press enter when done"
    MainMenu
}

#main menu output
function MainMenu(){
    Write-Host "Which type of Vapp would you like to create for the new user?"
    Write-Host "1) Full Clone"
    Write-Host "2) Linked Clone"
    Write-Host "3) Exit"
    $optionSelected= Read-host -Prompt "Please enter an option above"
    processOptions($optionSelected)
}

#process options selected in main menu to determine which function to call exit or invalid
function processOptions($selection){
    if ($selection -eq 1){
        cloneVappFull
    }
    elseif ($selection -eq 2){
        cloneVappLinked
    }
    elseif ($selection -eq 3){
        exit(0)
    }
    else{
        Write-Host -BackgroundColor Red -ForegroundColor White "Invalid option"
    }
    allDone
}

#run it
MainMenu
