Function Show-SystemColors {
<# 
	 .SYNOPSIS
	  Shows a visual representation (grid with color block, name, and hex code)) of system colors.
		
	 .NOTES
		Author  : Chrissy LeMaire
		Requires: 	PowerShell 3.0
		Version: 1.0
		DateUpdated: 2015-Sep-16

	 .LINK 
		https://gallery.technet.microsoft.com/scriptcenter/Get-SystemColors-using-WPF-d7c31a8c
		
	 .EXAMPLE   
		Show-SystemColors
		
		This example returns a grid of system colors. It's the only thing you can do.
	 
	#> 
	[xml]$script:xaml = '
	<Window 
		xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
		xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
		Title="System.Windows.SystemColor" Height="500" Width="375">
	<Grid>
	<DataGrid Name="datagrid" AutoGenerateColumns="False" GridLinesVisibility="Vertical">
		<DataGrid.Columns>
			<DataGridTemplateColumn Header="Color" Width="100">
				<DataGridTemplateColumn.CellTemplate>
					<DataTemplate>
						<TextBlock Margin="5">
							<TextBlock.Background>
								<SolidColorBrush Color="{Binding Color}" />
							</TextBlock.Background>
						</TextBlock>
					</DataTemplate>
				</DataGridTemplateColumn.CellTemplate>
			</DataGridTemplateColumn>
			<DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="Auto"/>
			<DataGridTextColumn Header="Hex" Binding="{Binding Hex}" Width="Auto"/>
		</DataGrid.Columns>
	</DataGrid>
	</Grid>
	</Window>'

	try { Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase,System.Windows.Forms,PresentationFramework.Luna } 
	catch { throw "Failed to load Windows Presentation Framework assemblies." }

	$script:form = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
	$xaml.SelectNodes("//*[@Name]") | ForEach-Object { Set-Variable -Name ($_.Name) -Value $form.FindName($_.Name) -Scope Script }

	$properties = [System.Windows.SystemColors].GetProperties()
	$colorlist = $properties | Where-Object { $_.PropertyType.Name -eq "Color" }

	$colorcollection = @()

	foreach ($color in $colorlist.name) {
		$colorgrid = {} | Select Color, Name, Hex
		$systemcolor = [System.Windows.SystemColors]::$color
		$colorgrid.Color = $systemcolor
		$colorgrid.Name = $color
		$colorgrid.Hex = $systemcolor
		$colorcollection += $colorgrid
	}

	$datagrid.ItemsSource = @($colorcollection)
	  
	$form.ShowDialog() | Out-Null
}

