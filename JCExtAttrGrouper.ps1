## ------------------------------   JumpCloud Group from Command Results   ----------------------------------- ##
##                                    Chris Riendeau ---- March 2026                                           ##
##          Fakes the Jamf-style extension attribute-based dynamic grouping. Get a command result and          ##
##                                   creates a group based on that result                                      ##
##-------------------------------------------------------------------------------------------------------------##


###                                  Global JC Variables                                      ###

## API key - needs write privileges to add to the group
$apiKey=""

## Org ID for your JC instance
$orgID=""

## ID of command we're getting results from
## Command output must be formatted <result>variable_you_want</result>.
## Last line of the command would be something like echo "<result>$version_number</result>"
$commandID=""

## Group ID for the group we are populating (if it already exists)
$groupID=""

## Name for group if you are going to create one
$groupName=""


###                                   Global Switches                                         ###

##    Clear Group Roster
##   For true dynamic grouping - removes systems that don't match then adds new ones based on  ##
##   the logical condition selected below. If set to false, roster will add new group members  ##
##   but not remove any older ones that may no longer meet the condition. If createGroup       ##
##   is set to True, this is irrelevant                                                        ##
$clearGroupRoster=$true

##   Create Group - if you aren't updating an existing group but would like to make a          ##
##   a new one based on the condition. If no groupID is set, this is on by default             ##
$createGroup=$false


###                               Conditional Logic Function                                  ###
##   Here we will define what result from the command will qualify a system for group          ##
##   membership. This function should return true/false. It is set up to use only the 3        ##
##   variables returned below from the command result: SystemID, Exit Code, and Output.        ##
##   But you can of course build in more, based on more complex outputs, other variables       ##
##   from the getCommandResults return,  or whatever you like.                                 ##

##   Three simple functions - date older than a certain number of days, string match           ##
##   and a version check. Can switch them by changing the conditionType variable here          ##
##   to either "date", "string" or "version"                                                   ##

## Set Condition Type
# $conditionType = "string"
$conditionType = "date"
# $conditionType = "version"

## REVERSE CONDITION LOGIC - essentially a NOT gate, inverts the logic of your selected condition
$reverseLogic=$false

## set variables here
$days=7
$expectedVersion="0.0.0"
$expectedString="x"

##   This function checks if a date returned in ISO 8601 format is older than x number         ##
##   of days, for things like last update, last contact, etc.                                  ##
##   defaults to true if there is an error, you can flip that in the Catch block if you want   ##
function isOlderThanXDays {
    param (
        [string]$dateString,
        [int]$Days
    )

    try {
        # Convert the string to a DateTime object
        $inputDate = [datetime]$dateString
        
        # Calculate the threshold (Current time minus X days)
        $threshold = ([datetime]::UtcNow).AddDays(-$Days)

        # Return True if the input date is older (less than) the threshold
        ##check for reverseLogic
        if ($reverseLogic){
            return $inputDate -ge $threshold
        }
        else {
            return $inputDate -lt $threshold
        }
    }
    catch {
        Write-Error "Invalid date format provided: $dateString"
        return $true
    }
}

##   Function to check against an expected version                                             ##
##   defaults to true if there is an error, you can flip that in the Catch block if you want   ##

function versionCheck {
    param (
        [string]$currentVersion,
        [string]$expectedVersion
    )

    try {
        # Cast strings to Version objects for proper comparison
        $current = [System.Version]$currentVersion
        $expected = [System.Version]$expectedVersion

        # Returns True if Current is less than Expected
        # Check for reverse logic
        if ($reverseLogic) {
            return $current -ge $expected
        }
        else {
            return $current -lt $expected
        }
    }
    catch {
        Write-Error "Invalid version format. Please use 'x.x' or 'x.x.x' (Numbers only)."
        return $true
    }
}

## Check if strings match (case sensitive or insensitive option) can also be used as a true/false boolean   ##
##   Currently no error handling...                                                                         ##

function stringMatch {
    param (
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$resultString,

        [Parameter(Mandatory=$true)]
        [string]$expectedString,

        [switch]$caseSensitive
    )

    if ($caseSensitive) {
        #Case-Sensitive equal operator
        if ($reverseLogic) {
            return !($resultString -ceq $expectedString)
        } else {
            return $resultString -ceq $expectedString
        }
    } else {
        if ($reverseLogic) {
            return !($resultString -eq $expectedString)
        } else {
        return $resultString -eq $expectedString
        }
    }
}

function filterLatestResults {
    param (
        [Parameter(Mandatory=$true)]
        [array]$InputData
    )
    
    $refinedResults = $InputData | Group-Object -Property systemID | ForEach-Object {
        $_.Group | Sort-Object { [datetime]$_.responseTime } | Select-Object -Last 1
    }

    return $refinedResults
}

###   Gathering our info                     
## Connect to JC
Connect-JCOnline -JumpCloudOrgId $orgID -JumpCloudApiKey $apiKey -force | Out-Null

## Get command results
$commandResult = Get-JCCommandResult -CommandID $commandID

## Filter out only the newest results if the command has been run multiple times on a system
$filteredResult = filterLatestResults -InputData $commandResult

## Parse out the useful bits
$formattedResults = $filteredResult | Select-Object `
    @{Name="systemID"; Expression={$_.systemId}}, 
    ExitCode, 
    @{Name="result"; Expression={
        # Check if the Output contains the <result> tag
        # Return only the text inside the tags
        if ($_.Output -match '<result>(.*?)</result>') {
            $Matches[1]
        } else {
            $null
        }
    }}

# Create empty list of group members
$updatedGroupRoster = New-Object System.Collections.Generic.List[string]

## Check our results against the logical condition we selected, and populate the list

switch ($conditionType) {
    "date" {### Date conditional check  -  set number of days of age    
        $formattedResults | ForEach-Object {
        $date = $_.result
        if (isOlderThanXDays -dateString $date -Days $days) {
            $updatedGroupRoster.Add($_.systemID)}
        }  
    }
    "version" {
        ### Version conditional check  -  set expectedVersion
        $formattedResults | ForEach-Object {
        $version = $_.result
        if (versionCheck -currentVersion $version -expectedVersion $expectedVersion) {
            $updatedGroupRoster.Add($_.systemID)}
        }
    }
    "string" {
        ### Version conditional check - set expectedString
        $formattedResults | ForEach-Object {
        $str = $_.result
        if (stringMatch -resultString $str -expectedString $expectedString) {
            $updatedGroupRoster.Add($_.systemID)}
        }
    }
Default {break}
}


###                          JC Group Actions                           ###

##  Check for GroupID, if left blank, we need to create the group, 
##  but we don't need to clear the roster, since it is new
if ($groupID -eq "") {
    $createGroup=$true
    $clearGroupRoster=$false
}

## Check if the group name variable is set (if we're creating a group), if not, names it with timestamp
if ($createGroup -and $groupName -eq "") {
    $defaultName = "extension-attribute-group $(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss')"
    $groupName = $defaultName
    Write-Host "No group name set. Setting Group Name: $defaultName"
}

## Create a group (if we need to)
if ($createGroup) {
    Write-Host "creating group condition is true"
    $newGroup = New-JCSystemGroup -GroupName $groupName
    $groupID = $newGroup.id
}

##Get group current roster
$currentGroupRoster = @()
$groupQuery = Get-JCSystemGroupMember -ByID $groupID
Write-Host "Current Group Roster:"
foreach ($system in $groupQuery){
    $currentGroupRoster += $system.SystemID
}

## Clear the group roster of machines no longer meeting the logical condition (if we need to)
if ($clearGroupRoster) {
    Write-Host "Clearing group roster condition is true - removing systems:"
    foreach ($systemID in $currentGroupRoster){
    if ($updatedGroupRoster.Contains($systemID)){
        continue
    }
    else {
        Remove-JCSystemGroupMember -GroupID $groupID -SystemID $systemID
        # Write-Host "Removing: " $systemID
    }
    }
}


## Populate the group with the roster from our command results and conditional logic
Write-Host "Populating GroupID $groupID with these systems"
foreach ($systemID in $updatedGroupRoster){
    if ($currentGroupRoster.Contains($systemID)){
        continue
    }
    else {
        Add-JCSystemGroupMember -GroupID $groupID -SystemID $systemID
    }
}



## Profit

