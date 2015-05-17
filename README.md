CsvSqlcmd
--------------
Invoke-CsvSqlcmd will enable you to natively query a CSV file using SQL syntax using Microsoft's Text Driver. The syntax is as simple as:

    Invoke-CsvSqlcmd -csv file.csv -sql "select * from table"
	
To make command line queries easier, this script will convert the word "table" within the -sql parameter to the actual CSV formatted table name.   If the FirstRowColumnNames switch is not used, the query engine automatically names the columns or "fields", F1, F2, F3, etc.

If you are running Invoke-CsvSqlcmd.ps1 on a 64-bit system, and the 64-bit Text Driver is not installed, the script will automatically switch to a 32-bit shell and execute the query. It will then communicate the data results to the 64-bit shell using Export-Clixml/Import-Clixml. 

While the shell switch process is rather quick, you can avoid this step by running the script within a 32-bit  PowerShell shell ("$env:windir\syswow64\windowspowershell\v1.0\powershell.exe")

Other examples
-----
    Invoke-CsvSqlcmd -csv C:\temp\housingmarket.csv -sql "select address from table where price < 250000" -FirstRowColumnNames

This example return all rows with a price less than 250000 to the screen. The first row of the CSV file, C:\temp\housingmarket.csv, contains column names.

    Invoke-CsvSqlcmd -csv C:\temp\unstructured.csv -sql "select F1, F2, F3 from table where F3 > 7" 

This example will return the first three columns of all rows within the CSV file C:\temp\unstructured.csv to the screen. 
Since the -FirstRowColumnNames switch was not used, the query engine automatically names the columns or "fields", F1, F2, F3 and so on.

    $datatable = Invoke-CsvSqlcmd -csv C:\temp\unstructured.csv -sql "select F1, F2, F3 from table"  
    $datatable.rows.count

Invoke-CsvSqlcmd.ps1 returns rows of a datatable, and in this case, we create a datatable by assigning the output of the script to a variable, instead of to the screen.
