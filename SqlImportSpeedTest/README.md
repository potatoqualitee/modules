SqlImportSpeedTest
--------------
Some SQL Server professionals are under the impression that PowerShell is slow. This module was created to demonstrate PowerShell's performance capabilities.

This module has imported over 240,000 rows per second with ten-column customer CSV datasets and 580,000 rows per second with two-column CSV datasets. This performance is on-par with bcp.exe, a command line utility known for it's super fast import speeds.


Examples
----- 
    Test-SqlImportSpeed -SqlServer sqlserver2014a

Imports a million row dataset filled with longitude and latitude data. Once it's downloaded and extracted, you can find it in Documents\longlats.csv

    Test-SqlImportSpeed -SqlServer sqlserver2014a -Dataset Customers

Just another million row dataset, but this one contains a classic customer table. Once it's downloaded and extracted, you can find it in Documents\customers.csv

    $cred = Get-Credential
    Test-SqlImport -SqlServer sqlserver2014a -SqlCredential $cred -MinRunspaces 5 -MaxRunspaces 10 -BatchSize 50000

This allows you to login using SQL auth, and sets the MinRunspaces to 5 and the MaxRunspaces to 10. Sets the batchsize to 50000 rows.

    $cred = Get-Credential
    Test-SqlImport -SqlServer sqlserver2014a -Dataset supersmall

Imports the a small, two column (int, varchar(10)) dataset.