Function Test-SqlSa      {
 <#
	.SYNOPSIS
	  Ensures sysadmin account access on SQL Server. $server is an SMO server object.

	.EXAMPLE
	  if (!(Test-SQLSA $server)) { throw "Not a sysadmin on $source. Quitting." }  

	.OUTPUTS
		$true if syadmin
		$false if not
	
        #>
		[CmdletBinding()]
        param(
			[Parameter(Mandatory = $true)]
			[ValidateNotNullOrEmpty()]
            [object]$server	
		)
		
try {
		return ($server.ConnectionContext.FixedServerRoles -match "SysAdmin")
	}
	catch { return $false }
}

Function Get-ParamSqlCmsGroups {
	<# 
	 .SYNOPSIS 
	 Returns System.Management.Automation.RuntimeDefinedParameterDictionary 
	 filled with server groups from specified SQL Server Central Management server name.
	 
	  .EXAMPLE
      Get-ParamSqlCmsGroups sqlserver
	#> 
	[CmdletBinding()]
        param(
			[Parameter(Mandatory = $true)]
            [string]$Server	
		)

		if ([Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") -eq $null) {return}
		if ([Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Management.RegisteredServers") -eq $null) {return}

		$cmserver = New-Object Microsoft.SqlServer.Management.Smo.Server $server
		$sqlconnection = $cmserver.ConnectionContext.SqlConnectionObject

		try { $cmstore = new-object Microsoft.SqlServer.Management.RegisteredServers.RegisteredServersStore($sqlconnection)}
		catch { return }
		
		if ($cmstore -eq $null) { return }
		
		$newparams = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
		$paramattributes = New-Object System.Management.Automation.ParameterAttribute
		$paramattributes.ParameterSetName = "__AllParameterSets"
		$paramattributes.Mandatory = $false
		
		$argumentlist = $cmstore.DatabaseEngineServerGroup.ServerGroups.name
		
		if ($argumentlist -ne $null) {
			$validationset = New-Object System.Management.Automation.ValidateSetAttribute -ArgumentList $argumentlist
			
			$combinedattributes = New-Object -Type System.Collections.ObjectModel.Collection[System.Attribute]
			$combinedattributes.Add($paramattributes)
			$combinedattributes.Add($validationset)

			$SqlCmsGroups = New-Object -Type System.Management.Automation.RuntimeDefinedParameter("SqlCmsGroups", [String[]], $combinedattributes)
			$newparams.Add("SqlCmsGroups", $SqlCmsGroups)
			
			return $newparams
		} else { return }
}

Function Get-SqlCmsRegServers {
	<# 
	 .SYNOPSIS 
	 Returns array of server names from CMS Server. If -Groups is specified,
	 only servers within the given groups are returned.
	 
	  .EXAMPLE
     Get-SqlCmsRegServers -Server sqlserver -Groups "Accounting", "HR"

	#> 
	[CmdletBinding()]
        param(
			[Parameter(Mandatory = $true)]
            [string]$server,
            [string[]]$groups
		)
	
	if ([Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") -eq $null) {return}
	if ([Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Management.RegisteredServers") -eq $null) {return}

	$cmserver = New-Object Microsoft.SqlServer.Management.Smo.Server $server
	$sqlconnection = $cmserver.ConnectionContext.SqlConnectionObject

	try { $cmstore = new-object Microsoft.SqlServer.Management.RegisteredServers.RegisteredServersStore($sqlconnection)}
	catch { throw "Cannot access Central Management Server" }
	
	$servers = @()
	if ($groups -ne $null) {
		foreach ($group in $groups) {
			$cms = $cmstore.ServerGroups["DatabaseEngineServerGroup"].ServerGroups[$group]
			$servers += ($cms.GetDescendantRegisteredServers()).servername	
		}
	} else {
		$cms = $cmstore.ServerGroups["DatabaseEngineServerGroup"]
		$servers = ($cms.GetDescendantRegisteredServers()).servername
	}

	return $servers
}

Function Get-SqlMaxMemory {

	<# 
	.SYNOPSIS 
	Displays information relating to SQL Server Max Memory configuration settings.  Works on SQL Server 2000-2014.

	.DESCRIPTION 
	Inspired by Jonathan Kehayias's post about SQL Server Max memory (http://bit.ly/sqlmemcalc), this script displays a SQL Server's: 
	total memory, currently configured SQL max memory, and the calculated recommendation.

	Jonathan notes that the forumla used provides a *general recommendation* that doesn't account for everything that may be going on in your specific enviornment. 
	
	.PARAMETER Servers
	Allows you to specify a comma seperated list of servers to query.
	
	.PARAMETER ServersFromFile
	Allows you to specify a list that's been populated by a list of servers to query. The format is as follows
	server1
	server2
	server3

	.PARAMETER SqlCms
	Reports on a list of servers populated by the specified SQL Server Central Management Server.

	.PARAMETER SqlCmsGroups
	This is a parameter that appears when SqlCms has been specified. It is populated by Server Groups within the given Central Management Server.
	
	.NOTES 
	Author  : Chrissy LeMaire
	Requires: 	PowerShell Version 3.0, SQL Server SMO, sysadmin access on SQL Servers 
	DateUpdated: 2015-May-21

	.LINK 
	https://gallery.technet.microsoft.com/scriptcenter/Get-Set-SQL-Max-Memory-19147057
	
	.EXAMPLE   
	Get-SqlMaxMemory -SqlCms sqlcluster
	
	Get Memory Settings for all servers within the SQL Server Central Management Server "sqlcluster"

	.EXAMPLE 
	Get-SqlMaxMemory -SqlCms sqlcluster | Where-Object { $_.SqlMaxMB -gt $_.TotalMB } | Set-SqlMaxMemory -UseRecommended
	
	Find all servers in CMS that have Max SQL memory set to higher than the total memory of the server (think 2147483647)
	
	#>
	
	[CmdletBinding()]

	Param(
		[parameter(Position=0)]
		[string[]]$Servers,
		# File with one server per line
		[string]$ServersFromFile,	
		# Central Management Server
		[string]$SqlCms
		)
		
	DynamicParam  { if ($SqlCms) { return (Get-ParamSqlCmsGroups $SqlCms) } }

	PROCESS { 
		
		if ([string]::IsNullOrEmpty($SqlCms) -and [string]::IsNullOrEmpty($ServersFromFile) -and [string]::IsNullOrEmpty($servers)) 
		{ throw "You must specify a server list source using -Servers or -SqlCms or -ServersFromFile" }
		if ([Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") -eq $null )
		{ throw "Quitting: SMO Required. You can download it from http://goo.gl/R4yA6u" }
		 if ([Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Management.RegisteredServers") -eq $null )
		{ throw "Quitting: SMO Required. You can download it from http://goo.gl/R4yA6u" }
		
		$SqlCmsGroups = $psboundparameters.SqlCmsGroups
		if ($SqlCms) { $servers = Get-SqlCmsRegServers -server $SqlCms -groups $SqlCmsGroups }
		If ($ServersFromFile) { $servers = Get-Content $ServersFromFile }
		
		$collection = @()
		foreach ($servername in $servers) {
			Write-Verbose "Attempting to connect to $servername"
			$server = New-Object Microsoft.SqlServer.Management.Smo.Server $servername
			try { $server.ConnectionContext.Connect() } catch { Write-Warning "Can't connect to $servername. Moving on."; continue }

			$maxmem = $server.Configuration.MaxServerMemory.ConfigValue

			$reserve = 1
			$totalMemory = $server.PhysicalMemory
			
			# Some servers underreport by 1MB.
			if (($totalmemory % 1024) -ne 0) { $totalMemory = $totalMemory + 1 }
			if ($servername -eq "sqlcluster") { $totalMemory = 1024*32 }
			if ($totalMemory -ge 4096) {
				$currentCount = $totalMemory
				while ($currentCount/4096 -gt 0) {
					if ($currentCount -gt 16384) {
						$reserve += 1
						$currentCount += -8192
					} else {
						$reserve += 1
						$currentCount += -4096
					}
				}
			}

			$recommendedMax = [int]($totalMemory-($reserve*1024))
			$object = New-Object PSObject -Property @{
			Server = $server.name
			TotalMB = $totalMemory
			SqlMaxMB = $maxmem
			RecommendedMB = $recommendedMax
			}
			$server.ConnectionContext.Disconnect()
			$collection += $object
		}
		return ($collection | Sort-Object Server | Select Server, TotalMB, SqlMaxMB, RecommendedMB)
	}
}

Function Set-SqlMaxMemory {
	<# 
	.SYNOPSIS 
	Sets SQL Server max memory then displays information relating to SQL Server Max Memory configuration settings. Works on SQL Server 2000-2014.
	
	.PARAMETER Servers
	Allows you to specify a comma seperated list of servers to query.
	
	.PARAMETER ServersFromFile
	Allows you to specify a list that's been populated by a list of servers to query. The format is as follows
	server1
	server2
	server3

	.PARAMETER SqlCms
	Reports on a list of servers populated by the specified SQL Server Central Management Server.

	.PARAMETER SqlCmsGroups
	This is a parameter that appears when SqlCms has been specified. It is populated by Server Groups within the given Central Management Server.
	
	.PARAMETER MaxMB
	Specifies the max megabytes
	
	.PARAMETER UseRecommended
	Inspired by Jonathan Kehayias's post about SQL Server Max memory (http://bit.ly/sqlmemcalc), this script displays a SQL Server's: 
	total memory, currently configured SQL max memory, and the calculated recommendation.

	Jonathan notes that the forumla used provides a *general recommendation* that doesn't account for everything that may be going on in your specific enviornment. 
	
	.NOTES 
	Author  : Chrissy LeMaire
	Requires: 	PowerShell Version 3.0, SQL Server SMO, sysadmin access on SQL Servers 
	DateUpdated: 2015-May-21

	.LINK 
	https://gallery.technet.microsoft.com/scriptcenter/Get-Set-SQL-Max-Memory-19147057
	
	.EXAMPLE 
	Set-SqlMaxMemory sqlserver 2048
	
	Set max memory to 2048 MB on just one server, "sqlserver"
	
	.EXAMPLE 
	Get-SqlMaxMemory -SqlCms sqlcluster | Where-Object { $_.SqlMaxMB -gt $_.TotalMB } | Set-SqlMaxMemory -UseRecommended
	
	Find all servers in CMS that have Max SQL memory set to higher than the total memory of the server (think 2147483647),
	then pipe those to Set-SqlMaxMemory and use the default recommendation

	.EXAMPLE 
	Set-SqlMaxMemory -SqlCms sqlcluster -SqlCmsGroups Express -MaxMB 512 -Verbose
	Specifically set memory to 512 MB for all servers within the "Express" server group on CMS "sqlcluster"
	
	#>
	[CmdletBinding()]

	Param(
		[parameter(Position=0)]
		[string[]]$Servers,
		[parameter(Position=1)]
		[int]$MaxMB,
		[string]$ServersFromFile,	
		[string]$SqlCms,
		[switch]$UseRecommended,
		[Parameter(ValueFromPipeline=$True)]
		[object]$collection
		)
		
	DynamicParam  { if ($SqlCms) { return (Get-ParamSqlCmsGroups $SqlCms)} }

	PROCESS {
		
		if ([string]::IsNullOrEmpty($SqlCms) -and [string]::IsNullOrEmpty($ServersFromFile) -and [string]::IsNullOrEmpty($servers) -and $collection -eq $null) 
		{ throw "You must specify a server list source using -Servers or -SqlCms or -ServersFromFile or you can pipe results from Get-SqlMaxMemory" }
		
		if ($MaxMB -eq 0 -and $UseRecommended -eq $false -and $collection -eq $null) { throw "You must specify -MaxMB or -UseRecommended" }
		
		if ($collection -eq $null) {
			$SqlCmsGroups = $psboundparameters.SqlCmsGroups
			if ($SqlCmsGroups -ne $null) { 
				$collection =  Get-SqlMaxMemory -Servers $servers -SqlCms $SqlCms -ServersFromFile $ServersFromFile -SqlCmsGroups $SqlCmsGroups 
			} else { $collection =  Get-SqlMaxMemory -Servers $servers -SqlCms $SqlCms -ServersFromFile $ServersFromFile  } 
		}
		
		$collection | Add-Member -NotePropertyName OldMaxValue -NotePropertyValue 0
		
		foreach ($row in $collection) {
			$server = New-Object Microsoft.SqlServer.Management.Smo.Server $row.server
			try { $server.ConnectionContext.Connect() } catch { Write-Warning "Can't connect to $servername. Moving on."; continue }
			
			if (!(Test-SqlSa $server)) { 
				Write-Warning "Not a sysadmin on $servername. Moving on."
				$server.ConnectionContext.Disconnect()
				continue 
			}
			
			$row.OldMaxValue = $row.SqlMaxMB

			try { 
				if ($UseRecommended) {
					Write-Verbose "Changing $($row.server) SQL Server max from $($row.SqlMaxMB) to $($row.RecommendedMB) MB" 
					$server.Configuration.MaxServerMemory.ConfigValue = $row.RecommendedMB
					$row.SqlMaxMB = $row.RecommendedMB
				} else { 
					Write-Verbose "Changing $($row.server) SQL Server max from $($row.SqlMaxMB) to $MaxMB MB" 
					$server.Configuration.MaxServerMemory.ConfigValue = $MaxMB 
					$row.SqlMaxMB = $MaxMB 
				}
				$server.Configuration.Alter()
				
			} catch { Write-Warning "Could not modify Max Server Memory for $($row.server)" }
			
			$server.ConnectionContext.Disconnect()
		}

		return $collection | Select Server, TotalMB, OldMaxValue, @{name="CurrentMaxValue";expression={$_.SqlMaxMB}}
	}
}
