properties {
  $base_dir  = resolve-path .
  $lib_dir = "$base_dir\SharedLibs"
  $build_dir = "$base_dir\build"
  $buildartifacts_dir = "$build_dir\"
  $sln_file = "$base_dir\zzz_RavenDB_Release.sln"
  $version = "1.0"
  $tools_dir = "$base_dir\Tools"
  $release_dir = "$base_dir\Release"
  $uploader = "..\Uploader\S3Uploader.exe"
  
  $web_dlls = @( "Raven.Abstractions.???","Raven.Web.???", (Get-DependencyPackageFiles NLog), (Get-DependencyPackageFiles Newtonsoft.Json), 
				"Lucene.Net.???", "Lucene.Net.Contrib.Spatial.???", "Lucene.Net.Contrib.SpellChecker.???","BouncyCastle.Crypto.???",
				"ICSharpCode.NRefactory.???", "Rhino.Licensing.???", "Esent.Interop.???", "Raven.Database.???", "Raven.Storage.Esent.???", 
				"Raven.Storage.Managed.???", "Raven.Munin.???" ) |
		ForEach-Object { 
			if ([System.IO.Path]::IsPathRooted($_)) { return $_ }
			return "$build_dir\$_"
		}
    
  $web_files = @("Raven.Studio.xap", "..\DefaultConfigs\web.config" )
    
  $server_files = @( "Raven.Server.exe", "Raven.Studio.xap", (Get-DependencyPackageFiles NLog), (Get-DependencyPackageFiles Newtonsoft.Json), "Lucene.Net.???",
                     "Lucene.Net.Contrib.Spatial.???", "Lucene.Net.Contrib.SpellChecker.???", "ICSharpCode.NRefactory.???", "Rhino.Licensing.???", "BouncyCastle.Crypto.???",
                    "Esent.Interop.???", "Raven.Abstractions.???", "Raven.Database.???", "Raven.Storage.Esent.???",
                    "Raven.Storage.Managed.???", "Raven.Munin.???" ) |
		ForEach-Object { 
			if ([System.IO.Path]::IsPathRooted($_)) { return $_ }
			return "$build_dir\$_"
		}
    
  $client_dlls_3_5 = @( (Get-DependencyPackageFiles NLog -FrameworkVersion net35), (Get-DependencyPackageFiles Newtonsoft.Json -FrameworkVersion net35), "Raven.Abstractions-3.5.???", "Raven.Client.Lightweight-3.5.???") |
		ForEach-Object { 
			if ([System.IO.Path]::IsPathRooted($_)) { return $_ }
			return "$build_dir\$_"
		}
     
  $client_dlls = @( (Get-DependencyPackageFiles NLog), "Raven.Client.MvcIntegration.???", (Get-DependencyPackageFiles Newtonsoft.Json),
					"Raven.Abstractions.???", "Raven.Client.Lightweight.???", "Raven.Client.Debug.???", "AsyncCtpLibrary.???" ) |
		ForEach-Object { 
			if ([System.IO.Path]::IsPathRooted($_)) { return $_ }
			return "$build_dir\$_"
		}
  
  $silverlight_dlls = @( "Raven.Client.Silverlight.???", "AsyncCtpLibrary_Silverlight.???", "MissingBitFromSilverlight.???", 
						(Get-DependencyPackageFiles Newtonsoft.Json -FrameworkVersion sl4), (Get-DependencyPackageFiles Newtonsoft.Json -FrameworkVersion sl4)) |
		ForEach-Object { 
			if ([System.IO.Path]::IsPathRooted($_)) { return $_ }
			return "$build_dir\$_"
		}
 
  $all_client_dlls = @( "Raven.Client.MvcIntegration.???", "Raven.Client.Lightweight.???", "Raven.Client.Embedded.???", "Raven.Abstractions.???", "Raven.Database.???", "BouncyCastle.Crypto.???",
						  "Esent.Interop.???", "ICSharpCode.NRefactory.???", "Lucene.Net.???", "Lucene.Net.Contrib.Spatial.???",
						  "Lucene.Net.Contrib.SpellChecker.???", (Get-DependencyPackageFiles NLog), (Get-DependencyPackageFiles Newtonsoft.Json),
						  "Raven.Storage.Esent.???", "Raven.Storage.Managed.???", "Raven.Munin.???", "AsyncCtpLibrary.???", "Raven.Studio.xap"  ) |
		ForEach-Object { 
			if ([System.IO.Path]::IsPathRooted($_)) { return $_ }
			return "$build_dir\$_"
		}
      
  $test_prjs = @("Raven.Tests.dll", "Raven.Client.VisualBasic.Tests.dll", "Raven.Bundles.Tests.dll"  )
}
include .\psake_ext.ps1

task default -depends OpenSource,Release

task Verify40 {
	if( (ls "$env:windir\Microsoft.NET\Framework\v4.0*") -eq $null ) {
		throw "Building Raven requires .NET 4.0, which doesn't appear to be installed on this machine"
	}
}


task Clean {
  remove-item -force -recurse $buildartifacts_dir -ErrorAction SilentlyContinue
  remove-item -force -recurse $release_dir -ErrorAction SilentlyContinue
}

task Init -depends Verify40, Clean {

	if($env:BUILD_NUMBER -ne $null) {
		$env:buildlabel  = $env:BUILD_NUMBER
	}
	if($env:buildlabel -eq $null) {
		$env:buildlabel = "13"
	}
	
	$projectFiles = ls -path $base_dir -include *.csproj -recurse | 
					Where { $_ -notmatch [regex]::Escape($lib_dir) } | 
					Where { $_ -notmatch [regex]::Escape($tools_dir) }
	
	$notclsCompliant = @("Raven.Silverlight.Client", "Raven.Studio", "Raven.Tests.Silverlight")
	
	foreach($projectFile in $projectFiles) {
		
		$projectDir = [System.IO.Path]::GetDirectoryName($projectFile)
		$projectName = [System.IO.Path]::GetFileName($projectDir)
		$asmInfo = [System.IO.Path]::Combine($projectDir, [System.IO.Path]::Combine("Properties", "AssemblyInfo.cs"))
		
		$clsComliant = "true"
		
		if([System.Array]::IndexOf($notclsCompliant, $projectName) -ne -1) {
			$clsComliant = "false"
		}
		
		Generate-Assembly-Info `
			-file $asmInfo `
			-title "$projectName $version.0.0" `
			-description "A linq enabled document database for .NET" `
			-company "Hibernating Rhinos" `
			-product "RavenDB $version.0.0" `
			-version "$version.0" `
			-fileversion "$version.$env:buildlabel.0" `
			-copyright "Copyright � Hibernating Rhinos 2004 - $((Get-Date).Year)" `
			-clsCompliant $clsComliant
		
		git update-index --assume-unchanged $asmInfo
	}
	
	new-item $release_dir -itemType directory -ErrorAction SilentlyContinue
	new-item $build_dir -itemType directory -ErrorAction SilentlyContinue
	
	copy $tools_dir\xUnit\*.* $build_dir
	
	if($global:commercial) {
		exec { .\Utilities\Binaries\Raven.ProjectRewriter.exe commercial }
		cp "..\RavenDB_Commercial.snk" "Raven.Database\RavenDB.snk"
	}
	else {
		exec { .\Utilities\Binaries\Raven.ProjectRewriter.exe }
		cp "Raven.Database\Raven.Database.csproj" "Raven.Database\Raven.Database.g.csproj"
	}
}

task BeforeCompile {
	$dat = "$base_dir\..\BuildsInfo\RavenDB\Settings.dat"
	$datDest = "$base_dir\Raven.Studio\Settings.dat"
	echo $dat
	if (Test-Path $dat) {
		Copy-Item $dat $datDest -force
	}
	else {
		New-Item $datDest -type file -force
	}
}

task AfterCompile {
	#new-item "$base_dir\Raven.Studio\Settings.dat" -type file -force
}

task Compile -depends Init {
	
	$v4_net_version = (ls "$env:windir\Microsoft.NET\Framework\v4.0*").Name
    
    try { 
		ExecuteTask("BeforeCompile")
		exec { &"C:\Windows\Microsoft.NET\Framework\$v4_net_version\MSBuild.exe" "$sln_file" /p:OutDir="$buildartifacts_dir\" }
	} catch {
		Throw
	} finally { 
		ExecuteTask("AfterCompile")
	}
      
  exec { & "C:\Windows\Microsoft.NET\Framework\$v4_net_version\MSBuild.exe" "$base_dir\Bundles\Raven.Bundles.sln" /p:OutDir="$buildartifacts_dir\" }
  exec { & "C:\Windows\Microsoft.NET\Framework\$v4_net_version\MSBuild.exe" "$base_dir\Samples\Raven.Samples.sln" /p:OutDir="$buildartifacts_dir\" }  
}

task Test -depends Compile{
  $old = pwd
  cd $build_dir
  Write-Host $test_prjs
  foreach($test_prj in $test_prjs) {
    Write-Host "Testing $build_dir\$test_prj"
    exec { &"$build_dir\xunit.console.clr4.exe" "$build_dir\$test_prj" } 
  }
  cd $old
}

task TestSilverlight {
	
	try{
    start "$build_dir\Raven.Server.exe" "--ram --set=Raven/Port==8079"
    exec { 
      & ".\Tools\StatLight\StatLight.exe" "-x=.\build\Raven.Tests.Silverlight.xap" "--OverrideTestProvider=MSTestWithCustomProvider" "--ReportOutputFile=.\Raven.Tests.Silverlight.Results.xml"
    }
	}
	finally{
    ps "Raven.Server" | kill
	}
}

task TestStackoverflowSampleBuilds {

	$v4_net_version = (ls "$env:windir\Microsoft.NET\Framework\v4.0*").Name

    exec { & "C:\Windows\Microsoft.NET\Framework\$v4_net_version\MSBuild.exe" "$base_dir\ETL\Raven.Etl.sln" /p:RavenIncludesPath="$buildartifacts_dir\" /p:OutDir="$buildartifacts_dir\Raven.Etl\" }
}

task ReleaseNoTests -depends OpenSource,DoRelease {

}

task Commercial {
	$global:commercial = $true
	$global:uploadCategory = "RavenDB-Commercial"
}

task Unstable {
	$global:commercial = $false
	$global:uploadCategory = "RavenDB-Unstable"
}

task OpenSource {
	$global:commercial = $false
	$global:uploadCategory = "RavenDB"
}

task Release -depends Test,TestSilverlight,TestStackoverflowSampleBuilds,DoRelease { 
}

task CopySamples {
	$samples = @("Raven.Sample.ShardClient", "Raven.Sample.Failover", "Raven.Sample.Replication", `
               "Raven.Sample.EventSourcing", "Raven.Bundles.Sample.EventSourcing.ShoppingCartAggregator", `
               "Raven.Samples.IndexReplication", "Raven.Samples.Includes", "Raven.Sample.SimpleClient", `
               "Raven.Sample.ComplexSharding", "Raven.Sample.MultiTenancy", "Raven.Sample.Suggestions", `
               "Raven.Sample.LiveProjections", "Raven.Sample.FullTextSearch")
	$exclude = @("bin", "obj", "Data", "Plugins")
	
	foreach ($sample in $samples) {
      echo $sample 
      
      Delete-Sample-Data-For-Release "$base_dir\Samples\$sample"
      
      cp "$base_dir\Samples\$sample" "$build_dir\Output\Samples" -recurse -force
      
      Delete-Sample-Data-For-Release "$build_dir\Output\Samples\$sample" 
	}
	
	cp "$base_dir\Samples\Raven.Samples.sln" "$build_dir\Output\Samples" -force
	cp "$base_dir\Samples\Samples.ps1" "$build_dir\Output\Samples" -force
      
	exec { .\Utilities\Binaries\Raven.Samples.PrepareForRelease.exe "$build_dir\Output\Samples\Raven.Samples.sln" "$build_dir\Output" }
}

task CreateOutpuDirectories -depends CleanOutputDirectory {
	New-Item $build_dir\Output -Type directory | Out-Null
	New-Item $build_dir\Output\Web -Type directory | Out-Null
	New-Item $build_dir\Output\Web\bin -Type directory | Out-Null
	New-Item $build_dir\Output\Server -Type directory | Out-Null
	New-Item $build_dir\Output\EmbeddedClient -Type directory | Out-Null
	New-Item $build_dir\Output\Silverlight -Type directory | Out-Null
	New-Item $build_dir\Output\Client -Type directory | Out-Null
	New-Item $build_dir\Output\Client-3.5 -Type directory | Out-Null
	New-Item $build_dir\Output\Bundles -Type directory | Out-Null
	New-Item $build_dir\Output\Samples -Type directory | Out-Null
	New-Item $build_dir\Output\Smuggler -Type directory | Out-Null
	New-Item $build_dir\Output\Backup -Type directory | Out-Null
}

task CleanOutputDirectory { 
	Remove-Item $build_dir\Output -Recurse -Force  -ErrorAction SilentlyContinue
}

task CopyEmbeddedClient { 
	$all_client_dlls | ForEach-Object { Copy-Item "$_" $build_dir\Output\EmbeddedClient }
}

task CopySilverlight{ 
	$silverlight_dlls | ForEach-Object { Copy-Item "$_" $build_dir\Output\Silverlight }
}

task CopySmuggler {
	cp $build_dir\Raven.Abstractions.??? $build_dir\Output\Smuggler
	Copy-Item (Get-DependencyPackageFiles Newtonsoft.Json) $build_dir\Output\Smuggler
	cp $build_dir\Raven.Smuggler.??? $build_dir\Output\Smuggler
}

task CopyBackup {
	cp $build_dir\Raven.Backup.??? $build_dir\Output\Backup
	Copy-Item (Get-DependencyPackageFiles Newtonsoft.Json) $build_dir\Output\Backup
}

task CopyClient {
	$client_dlls | ForEach-Object { Copy-Item "$_" $build_dir\Output\Client }
}

task CopyClient35 {
	$client_dlls_3_5 | ForEach-Object { Copy-Item "$_" $build_dir\Output\Client-3.5 }
}

task CopyWeb {
	$web_dlls | ForEach-Object { Copy-Item "$_" $build_dir\Output\Web\bin }
	$web_files | ForEach-Object { Copy-Item "$build_dir\$_" $build_dir\Output\Web }
}

task CopyBundles {
	cp $build_dir\Raven.Bundles.*.??? $build_dir\Output\Bundles
	cp $build_dir\Raven.Client.*.??? $build_dir\Output\Bundles
	del $build_dir\Output\Bundles\Raven.Bundles.Tests.???
}

task CopyServer {
	$server_files | ForEach-Object { Copy-Item "$_" $build_dir\Output\Server }
	Copy-Item $base_dir\DefaultConfigs\RavenDb.exe.config $build_dir\Output\Server\Raven.Server.exe.config
}

task CreateDocs {
	$v4_net_version = (ls "$env:windir\Microsoft.NET\Framework\v4.0*").Name
	
	if($env:buildlabel -eq 13)
	{
      return 
	}
     
  # we expliclty allows this to fail
  & "C:\Windows\Microsoft.NET\Framework\$v4_net_version\MSBuild.exe" "$base_dir\Raven.Docs.shfbproj" /p:OutDir="$buildartifacts_dir\"
}

task CopyRootFiles -depends CreateDocs {
	cp $base_dir\license.txt $build_dir\Output\license.txt
	cp $base_dir\Scripts\Start.cmd $build_dir\Output\Start.cmd
	cp $base_dir\Scripts\Raven-UpdateBundles.ps1 $build_dir\Output\Raven-UpdateBundles.ps1
	cp $base_dir\Scripts\Raven-GetBundles.ps1 $build_dir\Output\Raven-GetBundles.ps1
	cp $base_dir\readme.txt $build_dir\Output\readme.txt
	cp $base_dir\Help\Documentation.chm $build_dir\Output\Documentation.chm  -ErrorAction SilentlyContinue
	cp $base_dir\acknowledgments.txt $build_dir\Output\acknowledgments.txt
}

task ZipOutput {
	
	if($env:buildlabel -eq 13)
	{
      return 
	}

	$old = pwd
	
	cd $build_dir\Output
	
	$file = "$release_dir\$global:uploadCategory-Build-$env:buildlabel.zip"
		
	exec { 
		& $tools_dir\zip.exe -9 -A -r `
			$file `
			EmbeddedClient\*.* `
			Client\*.* `
			Samples\*.* `
			Smuggler\*.* `
			Backup\*.* `
			Client-3.5\*.* `
			Web\*.* `
			Bundles\*.* `
			Web\bin\*.* `
			Server\*.* `
			*.*
	}
	
    cd $old

}

task ResetBuildArtifcats {
    git checkout "Raven.Database\RavenDB.snk"
}


task DoRelease -depends Compile, `
	CleanOutputDirectory,`
	CreateOutpuDirectories, `
	CopyEmbeddedClient, `
	CopySmuggler, `
	CopyBackup, `
	CopyClient, `
	CopySilverlight, `
	CopyClient35, `
	CopyWeb, `
	CopyBundles, `
	CopyServer, `
	CopyRootFiles, `
	CopySamples, `
	ZipOutput, `
	CreateNugetPackage, `
	ResetBuildArtifcats {	
	Write-Host "Done building RavenDB"
}


task Upload -depends DoRelease {
	Write-Host "Starting upload"
	if (Test-Path $uploader) {
		$log = $env:push_msg 
		if($log -eq $null -or $log.Length -eq 0) {
		  $log = git log -n 1 --oneline		
		}
		
		$log = $log.Replace('"','''') # avoid problems because of " escaping the output
		
		$file = "$release_dir\$global:uploadCategory-Build-$env:buildlabel.zip"
		write-host "Executing: $uploader '$global:uploadCategory' $file ""$log"""
		&$uploader "$uploadCategory" $file "$log"
			
		if ($lastExitCode -ne 0) {
			write-host "Failed to upload to S3: $lastExitCode"
			throw "Error: Failed to publish build"
		}
	}
	else {
		Write-Host "could not find upload script $uploadScript, skipping upload"
	}
	
	
}

task UploadCommercial -depends Commercial, DoRelease, Upload {
		
}	

task UploadOpenSource -depends OpenSource, DoRelease, Upload {
		
}	

task UploadUnstable -depends Unstable, DoRelease, Upload {
		
}	

task CreateNugetPackage {
  
	Remove-Item $base_dir\RavenDB*.nupkg
	Remove-Item $build_dir\NuPack -force -recurse -erroraction silentlycontinue
	New-Item $build_dir\NuPack -Type directory | Out-Null
	New-Item $build_dir\NuPack\content -Type directory | Out-Null
	New-Item $build_dir\NuPack\lib -Type directory | Out-Null
	New-Item $build_dir\NuPack\lib\net35 -Type directory | Out-Null
	New-Item $build_dir\NuPack\lib\net40 -Type directory | Out-Null
	New-Item $build_dir\NuPack\lib\sl40 -Type directory | Out-Null
	New-Item $build_dir\NuPack\tools -Type directory | Out-Null
	New-Item $build_dir\NuPack\server -Type directory | Out-Null

	# package for RavenDB embedded is separate and requires .NET 4.0
	Remove-Item $build_dir\NuPack-Embedded -force -recurse -erroraction silentlycontinue
	New-Item $build_dir\NuPack-Embedded -Type directory | Out-Null
	New-Item $build_dir\NuPack-Embedded\content -Type directory | Out-Null
	New-Item $build_dir\NuPack-Embedded\lib -Type directory | Out-Null
	New-Item $build_dir\NuPack-Embedded\lib\net40 -Type directory | Out-Null
	New-Item $build_dir\NuPack-Embedded\tools -Type directory | Out-Null
	
	$client_dlls_3_5 | ForEach-Object { Copy-Item "$_" $build_dir\NuPack\lib\net35 }
	$client_dlls | ForEach-Object { Copy-Item "$_" $build_dir\NuPack\lib\net40 }
	$silverlight_dlls | ForEach-Object { Copy-Item "$_" $build_dir\NuPack\lib\sl40 }
	$all_client_dlls | ForEach-Object { Copy-Item "$_" $build_dir\NuPack-Embedded\lib\net40 }

	# Remove files that are obtained as dependencies
	Remove-Item $build_dir\NuPack\lib\*\Newtonsoft.Json.* -Recurse
	Remove-Item $build_dir\NuPack\lib\*\NLog.* -Recurse

	# The Server folder is used as a tool, and therefore needs the dependency DLLs in it (can't depend on Nuget for that)
	$server_files | ForEach-Object { Copy-Item "$_" $build_dir\NuPack\server }
	
	cp $base_dir\DefaultConfigs\RavenDb.exe.config $build_dir\NuPack\server\Raven.Server.exe.config

	cp $base_dir\DefaultConfigs\Nupack.Web.config $build_dir\NuPack\content\Web.config.transform
	cp $base_dir\DefaultConfigs\Nupack.Web.config $build_dir\NuPack-Embedded\content\Web.config.transform

	cp $build_dir\Raven.Smuggler.??? $build_dir\NuPack\Tools
	cp $build_dir\Raven.Smuggler.??? $build_dir\NuPack-Embedded\Tools

	cp $build_dir\Raven.Backup.??? $build_dir\NuPack\Tools
	cp $build_dir\Raven.Backup.??? $build_dir\NuPack-Embedded\Tools  

########### First pass - RavenDB.nupkg

  $nupack = [xml](get-content $base_dir\RavenDB.nuspec)
  $label = "$version.$env:buildlabel"
  $nupack.package.metadata.version = "$version.$env:buildlabel"
  if ($global:uploadCategory -and $global:uploadCategory.EndsWith("-Unstable")){
    $nupack.package.metadata.version += "-Unstable"
    $label += "-Unstable"
  }

  $writerSettings = new-object System.Xml.XmlWriterSettings
  $writerSettings.OmitXmlDeclaration = $true
  $writerSettings.NewLineOnAttributes = $true
  $writerSettings.Indent = $true
	
  $writer = [System.Xml.XmlWriter]::Create("$build_dir\Nupack\RavenDB.nuspec", $writerSettings)
	
  $nupack.WriteTo($writer)
  $writer.Flush()
  $writer.Close()
  
  & "$tools_dir\nuget.exe" pack $build_dir\NuPack\RavenDB.nuspec


########### Second pass - RavenDB-Embedded.nupkg

  $nupack = [xml](get-content $base_dir\RavenDB-Embedded.nuspec)
	
  $nupack.package.metadata.version = "$version.$env:buildlabel"
  if ($global:uploadCategory -and $global:uploadCategory.EndsWith("-Unstable")){
    $nupack.package.metadata.version += "-Unstable"
  }
  $writerSettings = new-object System.Xml.XmlWriterSettings
  $writerSettings.OmitXmlDeclaration = $true
  $writerSettings.NewLineOnAttributes = $true
  $writerSettings.Indent = $true
	
  $writer = [System.Xml.XmlWriter]::Create("$build_dir\Nupack-Embedded\RavenDB-Embedded.nuspec", $writerSettings)
	
  $nupack.WriteTo($writer)
  $writer.Flush()
  $writer.Close()
  
  & "$tools_dir\nuget.exe" pack $build_dir\NuPack-Embedded\RavenDB-Embedded.nuspec
  
	$accessPath = "$base_dir\..\Nuget-Access-Key.txt"
	if ( (Test-Path $accessPath) ) {
		$accessKey = Get-Content $accessPath
		$accessKey = $accessKey.Trim()
		
		# Push to nuget repository
		& "$tools_dir\nuget.exe" push "RavenDB.$label.nupkg" $accessKey
		& "$tools_dir\nuget.exe" push "RavenDB-Embedded.$label.nupkg" $accessKey
		
		# This is prune to failure since the previous package may not exists
  
		#$prevVersion = ($env:buildlabel - 1)
		# & "$tools_dir\nuget.exe" delete RavenDB "$version.$prevVersion" $accessKey -source http://packages.nuget.org/v1/ -NoPrompt
	}
	else {
		Write-Host "Nuget-Access-Key.txt does not exit. Cannot publish the nuget package." -ForegroundColor Yellow
	}
}