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

        .EXAMPLE
        Update-CloudFlareDynamicDns -Token 1234567893feefc5f0q5000bfo0c38d90bbeb -Email example@example.com -Zone example.com
        
		Checks ipinfo.io for current external IP address. Checks CloudFlare's API for current IP of example.com. (Root Domain)
		
		If record doesn't exist within CloudFlare, it will be created. If record exists, but does not match to current external IP, the record will be updated. If the external IP and the CloudFlare IP match, no changes will be made.

        .EXAMPLE
        Update-CloudFlareDynamicDns -Token 1234567893feefc5f0q5000bfo0c38d90bbeb -Email example@example.com -Zone example.com -Record homelab
        
		Checks ipinfo.io for current external IP address. Checks CloudFlare's API for current IP of homelab.example.com.
		
		If record doesn't exist within CloudFlare, it will be created. If record exists, but does not match to current external IP, the record will be updated. If the external IP and the CloudFlare IP match, no changes will be made.

        .EXAMPLE
        Update-CloudFlareDynamicDns -Token 1234567893feefc5f0q5000bfo0c38d90bbeb -Email example@example.com -Zone example.com -Record homelab -UseDns
        
		Checks ipinfo.io for current external IP address. Checks DNS for current IP of homelab.example.com. Beware of cached entries.
		
		If record doesn't exist within CloudFlare, it will be created. If record exists, but does not match to current external IP, the record will be updated. If the external IP and the CloudFlare IP match, no changes will be made.
		
        .NOTES
        Author: Chrissy LeMaire (@cl), netnerds.net
		Version: 1.0.0
        Updated: 12/27/2015

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
        [switch]$UseDns
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

	Write-Output "Resolving external IP"
	try { $ipaddr = Invoke-RestMethod http://ipinfo.io/json | Select-Object -ExpandProperty ip }
	catch { throw "Can't get external IP Address. Quitting." }

	if ($ipaddr -eq $null) { throw "Can't get external IP Address. Quitting." }
	Write-Output "External IP is $ipaddr"
	
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
			$cfipaddr = [System.Net.Dns]::GetHostEntry($hostname).AddressList[0].IPAddressToString
			Write-Output "$hostname resolves to $cfipaddr"
		} catch {
			$new = $true
			Write-Output "Hostname does not currently exist or cannot be resolved"
		}
	} else {
		try { $dnsrecord = Invoke-RestMethod -Headers $headers -Method Get -Uri $recordurl } 
		catch { throw $_.Exception }
		
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
		try { $dnsrecord = Invoke-RestMethod -Headers $headers -Method Get -Uri $recordurl } 
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
			"type" = "A"
			"name" =  $hostname
			"content" = $ipaddr
		}
		
		$body = ConvertTo-Json -InputObject $newrecord
		$newrecordurl = "$baseurl/$zoneid/dns_records"
		
		try {
			$request = Invoke-RestMethod -Uri $newrecordurl -Method Post -Headers $headers -Body $body -ContentType "application/json"
			Write-Output "Done! $hostname will now resolve to $ipaddr."
		} catch {
			Write-Warning "Couldn't update :("
			throw $_.Exception
		}
	}
}
