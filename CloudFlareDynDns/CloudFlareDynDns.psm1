#Requires -Version 3
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Function Update-CloudFlareDynamicDns
{
    <# 
        .SYNOPSIS
        Updates specified CloudFlare DNS hostname to the current connection's external IP address using CloudFlare API v4 
		https://api.cloudflare.com/
		
        .DESCRIPTION
        This module is useful for homelabs. Remember how DynDns used to dynamically update your IP address for free? The functionality provided by this module is similar but updates CloudFlare hosted domains. CloudFlare is free and awesome, and I recommend it, if even for its simplified DNS management and free HTTPS.
		
        This should be setup as a scheduled task. I set mine for 5 minutes.

        .PARAMETER Token
        CloudFlare API Token. 
		
		As of 22 Dec 2015, you can find your API key at: https://www.cloudflare.com/a/account/my-account -> API Key
		
        .PARAMETER Email
        The email address associated with your CloudFlare account

        .PARAMETER Zone
        The zone you want to modify. For example, netnerds.net

        .PARAMETER Record
        This is the record you'd like to update or add. For example, homelab.
		
		Using -Zone netnerds.net and -Record homelab would update homelab.netnerds.net
		
		.PARAMETER UseDns
		Resolves hostname using DNS instead of checking CloudFlare. The intention is to reduce the number of calls to CloudFlare (they allow 200 reqs/minute, which is usually plenty), but the downside is that if the IP changes, it won't be updated until the hostname expires from cache. 
		
		.PARAMETER Ip
		Allows to specify the IP explicitily, disabling automatic recognition of the external IP. Can be an IPv4 or IPv6 address.

		.PARAMETER V6
		Updates AAAA record with current external IPv6 address (instead of updating A record with IPv4 address). IPv4/IPv6 is determined automatically if an explicit IP is specified via the -Ip parameter.

        .EXAMPLE
        Update-CloudFlareDynamicDns -Token 1234567893feefc5f0q5000bfo0c38d90bbeb -Email example@example.com -Zone example.com
        
		Checks ipify.org for current external IP address. Checks CloudFlare's API for current IP of example.com. (Root Domain)
		
		If record doesn't exist within CloudFlare, it will be created. If record exists, but does not match to current external IP, the record will be updated. If the external IP and the CloudFlare IP match, no changes will be made.

        .EXAMPLE
        Update-CloudFlareDynamicDns -Token 1234567893feefc5f0q5000bfo0c38d90bbeb -Email example@example.com -Zone example.com -Record homelab
        
		Checks ipify.org for current external IP address. Checks CloudFlare's API for current IP of homelab.example.com.
		
		If A record for homelab.example.com doesn't exist within CloudFlare, it will be created. If record exists, but does not match to current external IP, the record will be updated. If the external IP and the CloudFlare IP match, no changes will be made.

        .EXAMPLE
        Update-CloudFlareDynamicDns -Token 1234567893feefc5f0q5000bfo0c38d90bbeb -Email example@example.com -Zone example.com -Record homelab -UseDns -V6
        
		Checks ipify.org for current external IPv6 address. Checks DNS for current IPv6 address of homelab.example.com. Beware of cached entries.
		
		If AAAA record for homelab.example.com doesn't exist within CloudFlare, it will be created. If record exists, but does not match to current external IP, the record will be updated. If the external IP and the CloudFlare IP match, no changes will be made.

		.EXAMPLE
		Update-CloudFlareDynamicDns -Token 1234567893feefc5f0q5000bfo0c38d90bbeb -Email example@example.com -Zone example.com -Record homelab -Ip "2a02:8172:41d1:2422:eca4:dead:beef:affe"

		Updates the AAAA record for homelab.example.com to 2a02:8172:41d1:2422:eca4:dead:beef:affe. The record will be created if needed.

		
        .NOTES
        Authors: Chrissy LeMaire (@cl), netnerds.net; Martin F. Schumann (@mfs)
		Version: 1.1.0
        Updated: 06/22/2019

        .LINK
        https://netnerds.net
    #>
    [cmdletbinding()]
    param
    (
        [Parameter(mandatory = $true)]
        [string]$Token,

        [Parameter(mandatory = $true)]
        [ValidatePattern("[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?")]
        [string]$Email,

        [Parameter(mandatory = $true)]
        [string]$Zone,

        [Parameter(mandatory = $false)]
        [string]$Record,
		
		[Parameter(mandatory = $false)]
		[switch]$UseDns,
		
		[Parameter(mandatory = $false)]
		[ValidateScript({$_ -match [ipaddress]$_})]
		[string]$Ip,

		[Parameter(mandatory = $false)]
		[switch]$V6
    )
	if ($record) {
		$hostname = "$record.$zone"
	} else {
		$hostname = "$zone"
	}
	$headers = @{
		'X-Auth-Key' = $token
		'X-Auth-Email' = $email
	}

	if ($Ip -and ([ipaddress]$Ip).AddressFamily -eq [System.Net.Sockets.AddressFamily]"InterNetworkV6") {
		$V6 = $true
	}

	if ($V6) {
		$externalIPresolver = "https://api6.ipify.org?format=json"
		$addrType = [System.Net.Sockets.AddressFamily]"InterNetworkV6"
		$recordType = "AAAA"
	} else {
		$externalIPresolver = "https://api.ipify.org?format=json"
		$addrType = [System.Net.Sockets.AddressFamily]"InterNetwork"
		$recordType = "A"
	}


	if ($Ip) {
		Write-Output "Using external IP $Ip"
		$ipaddr = $Ip
	} else {
		Write-Output "Resolving external IP"
		try { $ipaddr = Invoke-RestMethod $externalIPresolver | Select-Object -ExpandProperty ip }
		catch { throw "Can't get external IP Address. Quitting." }

		if ($null -eq $ipaddr) { throw "Can't get external IP Address. Quitting." }
		Write-Output "External IP is $ipaddr"
	}

	Write-Output "Getting Zone information from CloudFlare"
	$baseurl = "https://api.cloudflare.com/client/v4/zones"
	$zoneurl = "$baseurl/?name=$zone"

	try { $cfzone = Invoke-RestMethod -Uri $zoneurl -Method Get -Headers $headers } 
	catch { throw $_.Exception }

	if ($cfzone.result.count -gt 0) { $zoneid = $cfzone.result.id } else { throw "Zone $zone does not exist" }
	
	Write-Output "Getting current IP for $hostname"
	$recordurl = "$baseurl/$zoneid/dns_records/?name=$hostname"
	
	if ($usedns -eq $true) { 
		try { 
			$cfipaddr = ([System.Net.Dns]::GetHostEntry($hostname).AddressList | Where-Object {$_.AddressFamily -eq $addrType})[0].IPAddressToString
			Write-Output "$hostname resolves to $cfipaddr"
		} catch {
			$new = $true
			Write-Output "Hostname does not currently exist or cannot be resolved"
		}
	} else {
		try { $dnsrecord = Invoke-RestMethod -Headers $headers -Method Get -Uri $recordurl } 
		catch { throw $_.Exception }
		
		[array]$dnsrecord.result = $dnsrecord.result | Where-Object {$_.Type -eq $recordType}
		if ($dnsrecord.result.count -gt 0) {
			$cfipaddr = $dnsrecord.result.content
			Write-Output "$hostname resolves to $cfipaddr"
		} else {
			$new = $true
			Write-Output "Hostname does not currently exist"
		}
	}
	
	# If nothing has changed, quit
	if ($cfipaddr -eq $ipaddr) {
		Write-Output "No updates required"
		return
	} elseif ($new -ne $true) {
		Write-Output "IP has changed, initiating update"
	}
	
	# If the ip has changed or didn't exist, update or add
	if ($usedns) {
		Write-Output "Getting CloudFlare Info"
		try { 
			$dnsrecord = Invoke-RestMethod -Headers $headers -Method Get -Uri $recordurl 
			[array]$dnsrecord.result = $dnsrecord.result | Where-Object {$_.Type -eq $recordType};
		} 
		catch { throw $_.Exception }
	}
	
	# if the record exists, then udpate it. Otherwise, add a new record.
	if ($dnsrecord.result.count -gt 0) {
		Write-Output "Updating CloudFlare record for $hostname"
		$recordid = $dnsrecord.result.id
		$dnsrecord.result | Add-Member "content"  $ipaddr -Force 
		$body = $dnsrecord.result | ConvertTo-Json
		
		$updateurl = "$baseurl/$zoneid/dns_records/$recordid" 
		$result = Invoke-RestMethod -Headers $headers -Method Put -Uri $updateurl -Body $body -ContentType "application/json"
		$newip = $result.result.content
		Write-Output "Updated IP to $newip"
	} else {
		Write-Output "Adding $hostname to CloudFlare"
		$newrecord = @{
			"type" = $recordType
			"name" =  $hostname
			"content" = $ipaddr
		}
		
		$body = ConvertTo-Json -InputObject $newrecord
		$newrecordurl = "$baseurl/$zoneid/dns_records"
		
		try {
			Invoke-RestMethod -Uri $newrecordurl -Method Post -Headers $headers -Body $body -ContentType "application/json";
			Write-Output "Done! $hostname will now resolve to $ipaddr."
		} catch {
			Write-Warning "Couldn't update :("
			throw $_.Exception
		}
	}
}
