Function Import-CsvToSql {
<# 
	.SYNOPSIS
	Efficiently imports very large (and small) CSV files into SQL Server.
	
	.DESCRIPTION
	Uses OleDbConnection and SqlBulkCopy to efficiently import CSV files into SQL Server (up to 700,000 records a minute). 
	The -Query parameter be used to import only data returned from a SQL Query executed against the CSV file(s). 
	
	If the table specified does not exist, it will be automatically created using (datatypes are best guess). In addition, 
	the destination table can be truncated prior to import. 
	
	Both the truncation and the import occur within a transaction, so if a failure occurs, no changes will persist. 

	While StreamReader and batched datatables is the fastest way to import CSV files, OleDbConnection was chosen 
	because it works consistently.
	
	.PARAMETER CSV
	The location of the CSV file(s) to be imported. Multiple files are allowed, so long as they all support the same 
	SQL query, and delimiter.

	.PARAMETER FirstRowColumnNames
	This parameter specifies whether the first row contains column names. If the first row does not contain column 
	names and -Query is specified, use field names "F1, F2, F3" and so on.
	
	.PARAMETER Delimiter
	Optional. If you do not pass a Delimiter, then a comma will be used. Valid Delimiters include: tab "`t", pipe "|", 
	semicolon ";", and space " ".

	.PARAMETER Query
	Optional. If you want to import just the results of a specific query from your CSV file, use this parameter.
	To make command line queries easy, this module will convert the word "csv" to the actual CSV formatted table name. 
	If the FirstRowColumnNames switch is not used, the query engine automatically names the columns or "fields", 
	F1, F2, F3 and so on.

	Example: select F1, F2, F3, F4 from csv where F1 > 5
	Example: select artist from csv
	Example: select top 1000000 from csv

	See EXAMPLES for more example syntax.

	.PARAMETER SqlServer
	The destination SQL Server.

	.PARAMETER Database
	The name of the database where the CSV will be imported into.

	.PARAMETER Table
	SQL table or view where CSV will be imported into. If table does not currently exist, it will created. 
	Datatypes are determined from the first row of the CSV that contains data (skips first row if -FirstRowColumnNames). 
	
	Data types used are: bigint, numeric, datetime and varchar(MAX). 

	.PARAMETER Truncate
	Truncate table prior to import.
	
	.PARAMETER CheckConstraints
	SqlBulkCopy option. Per Microsoft "Check constraints while data is being inserted. By default, constraints are not checked."
	
	.PARAMETER Default
	SqlBulkCopy option. Per Microsoft "Use the default values for all options."
	
	.PARAMETER FireTriggers
	SqlBulkCopy option. Per Microsoft "When specified, cause the server to fire the insert triggers for the rows being inserted 
	into the database."
	
	.PARAMETER KeepIdentity
	SqlBulkCopy option. Per Microsoft "Preserve source identity values. When not specified, identity values are assigned by 
	the destination."
	
	.PARAMETER KeepNulls
	SqlBulkCopy option. Per Microsoft "Preserve null values in the destination table regardless of the settings for default 
	values. When not specified, null values are replaced by default values where applicable."
	
	.PARAMETER TableLock
	SqlBulkCopy option. Per Microsoft "Obtain a bulk update lock for the duration of the bulk copy operation. When not 
	specified, row locks are used."

	.PARAMETER UseInternalTransaction
	SqlBulkCopy option. Per Microsoft "When specified, each batch of the bulk-copy operation will occur within a transaction."
	
	.PARAMETER shellswitch
	Internal parameter.
		
	.NOTES
	Author: Chrissy LeMaire
	Requires: PowerShell 3.0
	Version: 1.0
	DateUpdated: 2015-June-12

	.LINK 
	https://gallery.technet.microsoft.com/scriptcenter/Import-Large-CSVs-into-SQL-fa339046

	.EXAMPLE   
	Import-CsvToSql -Csv C:\temp\housing.csv -SqlServer sql001 -Database markets -Table housing
	
	Imports the comma delimited housing.csvs to the SQL  "housing" table within 
	the "markets" database on a SQL Server named sql001. The first row is not skipped, as 
	it does not contain column names.

	.EXAMPLE   
	Import-CsvToSql -Csv C:\temp\housing.csv, .\housing2.csv -SqlServer sql001 -Database markets -Table `
	housing -Delimiter "`t" -query "select top 100000 F1, F3 * from csv" -Truncate
	
	Truncates the "housing" table, then imports columns 1 and 3 of the first 100000 rows of the tab-delimited 
	housing.csv in the C:\temp directory, and housing2.csv in the current directory. Since the query is executed against
	both files, a total of 200,000 rows will be imported.

	.EXAMPLE   
	Import-CsvToSql -Csv C:\temp\housing.csv -SqlServer sql001 -Database markets -Table housing -query `
	"select * from csv where state = 'Louisiana'" -FirstRowColumnNames -Truncate -TableLock -FireTriggers
	
	Uses the first line to determine CSV column names. Truncates the "housing" table on the SQL Server, 
	then imports all records from housing.csv where the state equals Louisiana.
	
	Obtains a bulk update lock for the duration of the bulk copy operation and causes the server to fire the insert 
	triggers for the rows being inserted.

	#>
	[CmdletBinding()] 
	Param(
		[Parameter(Mandatory=$true)] 
		[ValidateScript({Test-Path $_})] 
		[string[]]$Csv,
		[Parameter(Mandatory=$true)] 
		[string]$SqlServer,
		[Parameter(Mandatory=$true)] 
		[string]$Database,
		[Parameter(Mandatory=$true)] 
		[string]$Table,		
		[string]$Delimiter = ",",
		[switch]$FirstRowColumnNames,
		[string]$Query = "select * from csv",
		[int]$BatchSize = 75000,
		[int]$NotifyAfter = 75000,
		[switch]$Truncate,
		[switch]$TableLock,
		[switch]$CheckConstraints,
		[switch]$Default,
		[switch]$FireTriggers,
		[switch]$KeepIdentity,
		[switch]$KeepNulls,
		[switch]$UseInternalTransaction,
		[switch]$shellswitch
		)
		
	BEGIN {
		
		if ($shellswitch -eq $false) { Write-Host "Script started at $(Get-Date)`n" }
		$elapsed = [System.Diagnostics.Stopwatch]::StartNew() 
		
		# Getting the total rows copied is a challenge. Use SqlBulkCopyExtension.
		# http://stackoverflow.com/questions/1188384/sqlbulkcopy-row-count-when-complete
		$source = 'namespace System.Data.SqlClient
			{    
				using Reflection;

				public static class SqlBulkCopyExtension
				{
					const String _rowsCopiedFieldName = "_rowsCopied";
					static FieldInfo _rowsCopiedField = null;

					public static int RowsCopiedCount(this SqlBulkCopy bulkCopy)
					{
						if (_rowsCopiedField == null) _rowsCopiedField = typeof(SqlBulkCopy).GetField(_rowsCopiedFieldName, BindingFlags.NonPublic | BindingFlags.GetField | BindingFlags.Instance);            
						return (int)_rowsCopiedField.GetValue(bulkCopy);
					}
				}
			}
		'
		Add-Type -ReferencedAssemblies 'System.Data.dll' -TypeDefinition $source -ErrorAction SilentlyContinue
		[void][Reflection.Assembly]::LoadWithPartialName("System.Data")
		[void][Reflection.Assembly]::LoadWithPartialName("Microsoft.VisualBasic")
		
		# If more than one csv specified, check to ensure number of columns match
		if ($csv -is [system.array]){ 
			try {
				$numberofcolumns = ((Get-Content $csv[0] -First 1 -ErrorAction Stop) -Split $delimiter).Count
			} catch { throw "$csv is in use by another process." }
			
			foreach ($file in $csv) {
				try {
					$firstline = Get-Content $file -First 1 -ErrorAction Stop
					$newnumcolumns = ($firstline -Split $Delimiter).Count
					if ($newnumcolumns -ne $numberofcolumns) { throw "Multiple csv file mismatch. Do both use the same delimiter and have the same number of columns?" }
				} catch { throw "$file is in use by another process" }
			}
		}
		
		# Check for drivers. First, ACE (Access), then JET
		$provider = (New-Object System.Data.OleDb.OleDbEnumerator).GetElements() | Where-Object { $_.SOURCES_NAME -like "Microsoft.ACE.OLEDB.*" }
		
		if ($provider -eq $null) {
			$provider = (New-Object System.Data.OleDb.OleDbEnumerator).GetElements() | Where-Object { $_.SOURCES_NAME -like "Microsoft.Jet.OLEDB.*" }	
		}
		
		# If a suitable provider cannot be found (If x64 and Access hasn't been installed) 
		# switch to x86, because it natively supports JET
		if ($provider -ne $null) { 
			if ($provider -is [system.array]) { $provider = $provider[$provider.GetUpperBound(0)].SOURCES_NAME } else {  $provider = $provider.SOURCES_NAME }
		}
		
		# In order to ensure consistent results, a schema.ini file must be created.
		# If a schema.ini already exists, it will be moved to TEMP temporarily.
		if ($shellswitch -eq $false) {
			$resolvedcsv = @()
			foreach ($file in $csv) { $resolvedcsv += (Resolve-Path $file).Path }
			$csv = $resolvedcsv
			
			# Create columns based on first data row of first csv.
			$movedschemaini = @{}
			foreach ($file in $csv) {
				$directory = Split-Path $file
				$schemaexists = Test-Path "$directory\schema.ini"
				if ($schemaexists -eq $true) {
					$newschemaname = "$env:TEMP\$(Split-Path $file -leaf)-schema.ini"
					$movedschemaini.Add($newschemaname,"$directory\schema.ini")
					Move-Item "$directory\schema.ini" $newschemaname -Force
				}
			}
			
			Write-Output "Calculating column names and datatypes"
				
			# TextFieldParser will be used instead of an OleDbConnection.
			# This is because the OleDbConnection driver may not exist on x64.
			$columnparser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($resolvedcsv[0])
			$columnparser.TextFieldType = "Delimited"
			$columnparser.SetDelimiters($Delimiter)
			$rawcolumns = $columnparser.ReadFields()
			$line = $columnparser.ReadLine()
			$datatypes = $columnparser.ReadFields()
			
			if ($firstRowColumnNames -eq $true) { 
				$columns = ($rawcolumns | ForEach-Object { $_ -Replace '"' } | 
				Select-Object -Property @{Name="name"; Expression = {"[$_]"}}).name
			} else {
				$columns  = @()
				foreach ($number in 1..$rawcolumns.count ) { $columns += "[column$number]" }  
			}
			
			$columnparser.Close()
			$columnparser.Dispose()
			
			Write-Output "Creating schema.ini"
			foreach ($file in $csv) {	
				# Unfortunately, passing delimiter within the connection string is unreliable, so we'll use schema.ini instead
				# The default delimiter in Windows changes depending on country, so we'll do this for every delimiter, even commas.
				$filename = Split-Path $file -leaf; $directory = Split-Path $file
				Add-Content -Path "$directory\schema.ini" -Value "[$filename]"
				Add-Content -Path "$directory\schema.ini" -Value "Format=Delimited($Delimiter)"
				Add-Content -Path "$directory\schema.ini" -Value "ColNameHeader=$FirstRowColumnNames"
				
				# Get OLE datatypes and SQL datatypes by best guess on first data row
				$sqldatatypes = @(); $index = 0 
				$olecolumns = ($columns | ForEach-Object { $_ -Replace "\[|\]", '"' })
				
				foreach ($datatype in $datatypes) {
					$olecolumnname = $olecolumns[$index]
					$sqlcolumnname = $columns[$index]
					$index++
					
					# switch doesn't work here :(
					if ([int64]::TryParse($datatype,[ref]0) -eq $true) { $oledatatype = "Long"; $sqldatatype = "bigint" }
					elseif ([double]::TryParse($datatype,[ref]0) -eq $true) { $oledatatype = "Double"; $sqldatatype = "numeric" }
					elseif ([datetime]::TryParse($datatype,[ref]0) -eq $true) { $oledatatype = "DateTime"; $sqldatatype = "datetime" }
					else { $oledatatype = "Memo"; $sqldatatype = "varchar(MAX)" }
					
					Add-Content -Path "$directory\schema.ini" -Value "Col$($index)`=$olecolumnname $oledatatype"
					$sqldatatypes += "$sqlcolumnname $sqldatatype"
				}
			}
			# Ensure database and table exist on SQL Server
			$sqlconn = New-Object System.Data.SqlClient.SqlConnection
			$sqlconn.ConnectionString = "Data Source=$sqlserver;Integrated Security=True;Initial Catalog=$Database"
			try { $sqlconn.Open() } catch { throw "Could not open SQL Server connection." }
			
			try {
				$sqlcmd = New-Object System.Data.SqlClient.SqlCommand($null, $sqlconn)
				$sql = "select count(*) from master.dbo.sysdatabases where name = '$database'"
				$sqlcmd.CommandText = $sql
			} catch { throw "Could not create SQL command." }

			$exists = $sqlcmd.ExecuteScalar()
			if ($exists -eq $false) { throw "Database does not exist on $sqlserver" }
			Write-Output "Database exists"
			
			$sqlcmd = New-Object System.Data.SqlClient.SqlCommand($null, $sqlconn)
			$sql = "select count(*) from $database.sys.tables where name = '$table'"
			$sqlcmd.CommandText = $sql
			$exists = $sqlcmd.ExecuteScalar()

			if ($exists -eq $false) {
				Write-Output "Table does not exist"
				Write-Output "Creating table"
				
				$sql = "BEGIN CREATE TABLE [$table] ($($sqldatatypes -join ',')) END"
				$sqlcmd.CommandText = $sql
				try { $null = $sqlcmd.ExecuteNonQuery()} catch { throw "Failed to execute $sql" }
				
				Write-Output "Successfully created table with the following column definitions: $($sqldatatypes -join ', ')"
				Write-Warning "All columns are created using a best guess from the first line, and use their maximum datatype."
				Write-Warning "This is inefficient but allows for the script to import without issues."
				Write-Warning "Consider creating the table first using best practices if the data will be used in production."
			} else { Write-Output "Table exists" }

			# Clean up
			$sqlcmd.Dispose()
			$sqlconn.Close()
			$sqlconn.Dispose()
		}
	}

	PROCESS {
		# Keep an array of SqlBulkCopyOptions for later use
		$options = "TableLock","CheckConstraints","FireTriggers","KeepIdentity","KeepNulls","UseInternalTransaction","Default","Truncate","FirstRowColumnNames"
		
		# Try hard to find a suitable provider; switch to x86 if necessary.
		# Encode the SQL string, since some characters may mess up aftrer being passed a second time.
		if ($provider -eq $null) {
			$bytes  = [System.Text.Encoding]::UTF8.GetBytes($query)
			$query = [System.Convert]::ToBase64String($bytes)
			
			# While Install-Module takes care of installing modules to x86 and x64, Import-Module doesn't.
			# Because of this, the Module must be exported, written to file, and imported in the x86 shell.
			$definition = (Get-Command Import-CsvToSql).Definition
			$function = "Function Import-CsvToSql { $definition }"
			Set-Content "$env:TEMP\Import-CsvToSql.psm1" $function
			
			# Put switches back into proper format
			$switches = @()
			foreach ($option in $options) {
				$optionValue = Get-Variable $option -ValueOnly -ErrorAction SilentlyContinue
				if ($optionValue -eq $true) { $switches += "-$option" }
			}
			
			# Perform the actual switch, which removes any registered Import-CsvToSql modules
			# Then imports, and finally re-executes the command. 
			$csv = $csv -join ",";  $switches = $switches -join " "
			
			$command = "Import-CsvToSql -Csv $csv -SqlServer '$sqlserver' -Database '$database' -Table '$table' -Delimiter '$Delimiter' -Query '$query' -Batchsize $BatchSize -NotifyAfter $NotifyAfter $switches -shellswitch" 
	
			Write-Verbose "Switching to x86 shell, then switching back." 
			&"$env:windir\syswow64\windowspowershell\v1.0\powershell.exe" "Set-ExecutionPolicy Bypass; Remove-Module Import-CsvToSql -ErrorAction SilentlyContinue;Import-Module $env:TEMP\Import-CsvToSql.psm1; $command"
			return
		}
		
		# If the shell has switched, decode the $query string.
		if ($shellswitch -eq $true) {
			$bytes  = [System.Convert]::FromBase64String($Query)
			$query = [System.Text.Encoding]::UTF8.GetString($bytes)
			$csv = $csv -Split ","
		}
		
		# Check for proper SQL syntax, which for the purposes of this module must include the word "table"
		if ($query.ToLower() -notmatch "\bcsv\b") {
			throw "SQL statement must contain the word 'csv'. Please see this module's documentation for more details."
		}
		
		# Does first line contain the specified delimiter?
		foreach ($file in $csv) {
			try { $firstline = Get-Content $file -First 1 -ErrorAction Stop } catch { throw "$file is in use." }
			if (($firstline -match $delimiter) -eq $false) {  throw "Delimiter $delimiter not found in first row of $file." }
		}
				
		# Setup bulk copy options
		$bulkCopyOptions = @()
		foreach ($option in $options) {
			$optionValue = Get-Variable $option -ValueOnly -ErrorAction SilentlyContinue
			if ($optionValue -eq $true) { $bulkCopyOptions += "$option" }
		}
		$bulkCopyOptions = $bulkCopyOptions -join " & "
		
		# Go through each file
		foreach ($file in $csv) {
			# Setup the connection string. Data Source is the directory that contains the csv.
			# The file name is also the table name, but with a "#" instead of a "."
			$datasource = Split-Path $file
			$tablename = (Split-Path $file -leaf).Replace(".","#")
			$connstring = "Provider=$provider;Data Source=$datasource;Extended Properties='text';"
			
			# To make command line queries easier, let the user just specify "csv" instead of the
			# OleDbconnection formatted name (file.csv -> file#csv)
			$sql = $Query -replace "\bcsv\b"," [$tablename]"
			
			# Setup the OleDbconnection
			$conn = New-Object System.Data.OleDb.OleDbconnection
			$conn.ConnectionString = $connstring
			try { $conn.Open() } catch { throw "Could not open OLEDB connection." }
			
			# Setup the OleDBCommand
			try {
				$cmd = New-Object System.Data.OleDB.OleDBCommand
				$cmd.Connection = $conn
				$cmd.CommandText = $sql
			} catch { throw "Could not create OLEDB command." }
		
			# Setup bulk copy
			Write-Output "Prepping bulk copy for $(Split-Path $file -Leaf)"
			$connectionstring = "Data Source=$sqlserver;Integrated Security=True;Initial Catalog=$Database"
			$sqlconn = New-Object System.Data.SqlClient.SqlConnection
			$sqlconn.Connectionstring = $connectionstring
			$sqlconn.Open()
			
			# All or none.
			$transaction = $sqlconn.BeginTransaction() 
			
			if ($truncate -eq $true) {
				Write-Output "Truncating table"
				$sql = "TRUNCATE TABLE $table"
				$sqlcmd = New-Object System.Data.SqlClient.SqlCommand($sql, $sqlconn, $transaction)
				try { $null = $sqlcmd.ExecuteNonQuery() } catch { Write-Warning "Could not truncate $table" }
			}

			# Create SqlBulkCopy using default options, or options specified in command line.
			if ($bulkCopyOptions.count -gt 1) { 
				$bulkcopy = New-Object Data.SqlClient.SqlBulkCopy($connstring, $bulkCopyOptions, $transaction) 
			} else { $bulkcopy = New-Object Data.SqlClient.SqlBulkCopy($sqlconn,"Default",$transaction) }

			$bulkcopy.DestinationTableName = $table
			$bulkcopy.bulkcopyTimeout = 0 
			$bulkCopy.BatchSize = $BatchSize
			$bulkCopy.NotifyAfter = $NotifyAfter
			# Thanks for simplifying this, CookieMonster!
			$bulkCopy.Add_SqlRowscopied({ $global:totalrows = $args[1].RowsCopied; Write-Host "$($global:totalrows) rows copied" })
			
			try{
				# Write to server :D
				$elapsed = [System.Diagnostics.Stopwatch]::StartNew() 
				$null = $bulkCopy.WriteToServer($cmd.ExecuteReader("CloseConnection"))
				$null = $transaction.Commit()
				$finished = $true
			} catch {
				$errormessage = $_.Exception.Message.ToString()
				if ($errormessage -like "*for one or more required parameters*") {
						Write-Error "Looks like your SQL syntax may be invalid. `nCheck the documentation for more information or start with a simple -Query 'select top 10 * from csv'"
				} elseif ($errormessage -match "invalid column length") {
					# Get more information about malformed CSV input
					$pattern = @("\d+")
					$match = [regex]::matches($errormessage, @("\d+"))
					$index = [int]($match.groups[1].Value)-1
					
					$sql = "select name, max_length from sys.columns where object_id = object_id('$table') and column_id = $index"
					$sqlcmd = New-Object System.Data.SqlClient.SqlCommand($sql, $sqlconn)
					
					$datatable = New-Object System.Data.DataTable
					$datatable.load($sqlcmd.ExecuteReader())
					$column = $datatable.name
					$length = $datatable.max_length

					Write-Warning "Column $index ($column) contains data with a length greater than $length"
					Write-Warning "SqlBulkCopy makes it pretty much impossible to know which row caused the issue, but it's somewhere after row $($global:totalrows)."
					
					Write-Error "Some of the data is invalid, and the current transaction was rolled back." 
				
				} elseif ($errormessage -match "does not allow DBNull" -or $errormessage -match "The given value of type") {
					$sql = "select name from sys.columns where object_id = object_id('$table') order by column_id"
					$sqlcmd = New-Object System.Data.SqlClient.SqlCommand($sql, $sqlconn, $transaction)
					$datatable = New-Object System.Data.DataTable
					$datatable.Load($sqlcmd.ExecuteReader())		
					$olecolumns = ($columns | ForEach-Object { $_ -Replace "\[|\]" }) -join ', '
					$errormsg = "$errormessage`nThis could be because the order of the columns within the CSV/SQL statement"
					$errormsg += " do not line up with the order of the table within the SQL Server."
					if ($FirstRowColumnNames -eq $true) { $errormsg += "`nCSV order: $olecolumns`n" }
					$errormsg += "`nSQL table order: $($datatable.rows.name -join ', ')"
					$errormsg += "`nIf this is the case, you can reorder columns by using the -Query parameter or execute the import against a view."
					Write-Error $errormsg
				} else { Write-Error $errormessage }
			}
				
			if ($finished -eq $true) {
				# "Note: This count does not take into consideration the number of rows actually inserted when Ignore Duplicates is set to ON."
				$total = [System.Data.SqlClient.SqlBulkCopyExtension]::RowsCopiedCount($bulkcopy)
				Write-Output "$total total rows copied"
			} else { Write-Output "Transaction rolled back. 0 rows committed." }
		}
	}

	END {
		# Close everything just in case & ignore errors
		try { $null = $sqlconn.close(); $null = $sqlconn.Dispose(); $null = $conn.close; $null = $cmd.Dispose(); 
		$null = $conn.Dispose(); $null = $bulkCopy.close(); $null = $bulkcopy.dispose() } catch {}
		if ($shellswitch -eq $false) {
			# Delete new schema files
			Write-Output "Removing automatically generated schema.ini"
			foreach ($file in $csv) {
				$directory = Split-Path $file
				Remove-Item "$directory\schema.ini" -Force -ErrorAction SilentlyContinue | Out-Null
			}
			
			Remove-Item "$env:TEMP\Import-CsvToSql.psm1" -Force -ErrorAction SilentlyContinue | Out-Null
			
			# Move original schema.ini's back if they existed
			if ($movedschemaini.count -gt 0) {
				foreach ($item in $movedschemaini) {
					Write-Output "Moving $($item.keys) back to $($item.values)"
					Move-Item $item.keys $item.values -Force -ErrorAction SilentlyContinue	
				}
			}
			
			# Script is finished. Show elapsed time.
			$totaltime = [math]::Round($elapsed.Elapsed.TotalSeconds,2)
			Write-Output "`nTotal Elapsed Time: $totaltime seconds."
		}
	}
}