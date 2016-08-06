import-module pathutils
import-module publishmap 

function get-slndependencies {
    [CmdletBinding(DefaultParameterSetName = "sln")]
    param(
        [Parameter(Mandatory=$true, ParameterSetName="sln",Position=0)][Sln]$sln,
        [Parameter(Mandatory=$true, ParameterSetName="slnfile",Position=0)][string]$slnfile
    )
    if ($sln -eq $null) { $sln = import-sln $slnfile }
    $projects = get-slnprojects $sln | ? { $_.type -eq "csproj" }
    $deps = $projects | % {
        if (test-path $_.fullname) {
            $p = import-csproj $_.fullname
            $refs = @()
            $refs += @($p | get-projectreferences)
            $refs += @($p | get-nugetreferences)
            
        } else {
            $p = $null
            $refs = $null
        }
        return new-object -type pscustomobject -property @{ project = $_; csproj = $p; refs = $refs }
    }
    
    $result = @()
    foreach($p in $deps) {
        
        if ($p.refs -ne $null -and $p.refs.length -gt 0) {
            foreach($r in $p.refs) {
                $path = $r.path
                $path = join-path (split-path -parent $p.project.fullname) $r.path
                $slnrel = get-relativepath (split-path -parent $sln.fullname) $path
                $slnproj = $projects | ? { $_.path -eq $slnrel }
                $existsInSln = $slnproj -ne $null 
                $exists = test-path $path
                #$null = $r | add-property -name "Valid" -value $existsInSln
                if ($r.type -eq "project") {
                    $r.IsValid = $r.IsValid -and $existsInSln 
                }
                $props = [ordered]@{ project = $p.project; ref = $r; refType = $r.type; IsProjectValid = $true }
                $result += new-object -type pscustomobject -property $props 
            }
        } else {
            $isvalid = $true
            if ($p.csproj -eq $null) { $isvalid = $false }
            $props = [ordered]@{ project = $p.project; ref = $null; refType = $null; IsProjectValid = $isvalid }
            $result += new-object -type pscustomobject -property $props 
        }
    }
    
    return $result
    
}

function test-sln {
    [CmdletBinding(DefaultParameterSetName = "sln")]
    param(
        [Parameter(Mandatory=$false, ParameterSetName="sln",Position=0)][Sln]$sln,
        [Parameter(Mandatory=$false, ParameterSetName="slnfile",Position=0)][string]$slnfile,
        [switch][bool] $missing,
        [switch][bool] $validate,
        $filter = $null
    )    
    if ($sln -eq $null) {
        if ([string]::IsNullOrEmpty($slnfile)) {
            $slns = @(get-childitem "." -Filter "*.sln")
            if ($slns.Length -eq 1) {
                $slnfile = $slns[0].fullname
            }
            else {
                if ($slns.Length -eq 0) {
                    throw "no sln file given and no *.sln found in current directory"
                }
                else {
                    throw "no sln file given and more than one *.sln file found in current directory"
                }
            }
        }
        if ($slnfile -eq $null) { throw "no sln file given and no *.sln found in current directory" }
        $sln = import-sln $slnfile
    }
    
    
    $deps = get-slndependencies $sln

    if ($filter -ne $null) {
        $deps = $deps | ? {
                if (!($_.ref.ShortName -match $filter)) { write-verbose "$($_.ref.ShortName) does not match filter:$filter" } 
                return $_.ref.ShortName -match $filter 
        }
    }

    $missingdeps = @($deps | ? { $_.IsProjectValid -eq $false -or ($_.ref -ne $null -and $_.ref.IsValid -eq $false) })
    if ($missing) {        
        return $missingdeps
    }
    if ($validate) {
        return $missingdeps.length -eq 0
    }
    
    return $deps
}

function test-slndependencies {
     [CmdletBinding(DefaultParameterSetName = "sln")]
    param(
        [Parameter(Mandatory=$true, ParameterSetName="sln",Position=0)][Sln]$sln,
        [Parameter(Mandatory=$true, ParameterSetName="slnfile",Position=0)][string]$slnfile
    )
    if ($sln -eq $null) { $sln = import-sln $slnfile }
  
   $deps = get-slndependencies $sln
    
    $valid = $true
    $missing = @()
    
    foreach($d in $deps) {      
        if ($d.ref -ne $null -and $d.ref.IsValid -eq $false) {
            $valid = $false
            $missing += new-object -type pscustomobject -property @{ Ref = $d.ref; In = $d.project.fullname  }
        }
        if ($d.isprojectvalid -eq $false) {
            $valid = $false
            $missing += new-object -type pscustomobject -property @{ Ref = $d.project; In = $sln.fullname  }
        }
    }
    
   

    return $valid,$missing
}


function find-reporoot($path = ".") {
        $found = find-upwards ".git",".hg" -path $path
        if ($found -ne $null) { return split-path -Parent $found }
        else { return $null } 
}

function find-globaljson($path = ".") {
    return find-upwards "global.json" -path $path    
}


function find-matchingprojects {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]$missing,
        [Parameter(Mandatory=$true)]$reporoot
        )
    if (test-path (join-path $reporoot ".projects.json")) {
        $script:projects = get-content (join-path $reporoot ".projects.json") | out-string | convertfrom-jsonnewtonsoft 
        $csprojs = $script:projects.GetEnumerator() | ? {
                #ignore non-existing projects from ".projects.json" 
                test-path (join-path $reporoot $_.value.path) 
        } | % {
            get-item (join-path $reporoot $_.value.path)
        }
    } else { 
        $csprojs = get-childitem "$reporoot" -Filter "*.csproj" -Recurse
    }
    #$csprojs | select -expandproperty name | format-table | out-string | write-verbose
    $packagesdir = find-packagesdir $reporoot
    write-verbose "found $($csprojs.length) csproj files in repo root '$reporoot' and subdirs. pwd='$(pwd)'. Packagesdir = '$packagesdir'"
    $missing = $missing | % {
        $m = $_
        $matching = $null
        if ($m.ref.type -eq "project" -or $m.ref.type -eq "csproj") {
            $matching = @($csprojs | ? { [System.io.path]::GetFilenameWithoutExtension($_.Name) -eq $m.ref.Name })
            $null = $m | add-property -name "matching" -value $matching
            #write-verbose "missing: $_.Name matching: $matching"
        }
        if ($m.ref.type -eq "nuget") {
            if ($m.ref.path -match "^(?<packages>.*packages[/\\])(?<pkg>.*)") {
                $matchingpath = join-path $packagesdir $matches["pkg"]
                if (test-path $matchingpath) {
                    $matching = get-item $matchingpath
                } else {
                    $matching = new-object -type pscustomobject -property @{
                        fullname = $matchingpath
                    }
                }
                $null = $m | add-property -name "matching" -value $matching
                #write-verbose "missing: $_.Name matching: $matching"
            }
        }
        if ($matching -eq $null) {
            write-verbose "no project did match '$($m.ref.Name)' reference of type $($m.ref.type)"
        } else {
            write-verbose "found  $(@($matching).Length) matching projects for '$($m.ref.Name)' reference of type $($m.ref.type):"
            $matching | % {
                write-verbose "    $($_.fullname)"
            }
        }
        
        
        return $m
    }
    
    
    
    
    return $missing
}


function repair-slnpaths {
    [CmdletBinding(DefaultParameterSetName = "sln")]
    param(
        [Parameter(Mandatory=$false, ParameterSetName="sln",Position=0)][Sln]$sln,
        [Parameter(Mandatory=$false, ParameterSetName="slnfile",Position=0)][string]$slnfile,
        [Parameter(Position=1)] $reporoot,
        [Parameter(Position=2)] $filter = $null,
        [switch][bool] $tonuget,
        [switch][bool] $insln,
        [switch][bool] $incsproj,
        [switch][bool] $removemissing,
        [switch][bool] $prerelease
    )
     if ($sln -eq $null) {
        if ([string]::IsNullOrEmpty($slnfile)) {
            $slns = @(get-childitem "." -Filter "*.sln")
            if ($slns.Length -eq 1) {
                $slnfile = $slns[0].fullname
            }
            else {
                if ($slns.Length -eq 0) {
                    throw "no sln file given and no *.sln found in current directory"
                }
                else {
                    throw "no sln file given and more than one *.sln file found in current directory"
                }
            }
        }
        if ($slnfile -eq $null) { throw "no sln file given and no *.sln found in current directory" }
        $sln = import-sln $slnfile
    }

  
    if ($insln -or !$insln.IsPresent) {
        $valid,$missing = test-slndependencies $sln 
        
        write-verbose "SLN: found $($missing.length) missing projects"
        if ($reporoot -eq $null) {
            $reporoot = find-reporoot $sln.fullname
            if ($reporoot -ne $null) {
                write-host "auto-detected repo root at $reporoot"
            }
        }
        
        if ($reporoot -eq $null) {
            throw "No repository root given and none could be detected"
        }

        write-host "Fixing SLN..."
        
        write-verbose "looking for csprojs in reporoot..."
        $missing = find-matchingprojects $missing $reporoot
        if ($filter -ne $null) {
        $missing = $missing | ? {
                #if (!($_.ref.ShortName -match $filter)) { write-verbose "$($_.ref.ShortName) does not match filter:$filter" } 
                return $_.ref.ShortName -match $filter 
        }
    }

        

        $fixed = @{}

        $missing | % {
            if ($fixed.ContainsKey($_.ref.name)) {
                write-verbose "skipping fixed reference $($_.ref.name)"
                continue
            }
            write-verbose "trying to fix missing SLN reference '$($_.ref.name)'"
            if ($_.matching -eq $null -or $_.matching.length -eq 0) {
                write-warning "no matching project found for SLN item $($_.ref.name)"
                if ($removemissing) {
                    write-warning "removing $($_.ref.Path)"
                    remove-slnproject $sln $($_.ref.Name) -ifexists
                    $sln.Save()
                }
            }
            else {
                $matching = $_.matching
                if (@($matching).length -gt 1) {
                    write-host "found $($matching.length) matching projects for $($_.ref.name). Choose one:"
                    $i = 1
                    $matching = $matching | sort FullName                                        
                    $matching | % {
                        write-host "  $i. $($_.fullname)"
                        $i++
                    }
                    $c = read-host 
                    $matching = $matching[[int]$c-1]
                }
                if ($_.ref -is [slnproject]) {
                    $relpath = get-relativepath $sln.fullname  $matching.fullname
                    write-host "Fixing bad SLN reference: $($_.ref.Path) => $relpath"
                    $_.ref.Path = $relpath
                    update-slnproject $sln $_.ref
                    $fixed[$_.ref.name] = $true
                }
                elseif ($_.ref -isnot [referencemeta]) {
                    $relpath = get-relativepath $sln.fullname  $matching.fullname
                    write-host "Adding missing SLN reference:  $($_.ref.Path) => $relpath"
                    $csp = import-csproj  $matching.fullname
                    add-slnproject $sln -name $csp.Name -path $relpath -projectguid $csp.guid
                    $fixed[$_.ref.name] = $true
                } else {
                    $relpath = get-relativepath $sln.fullname  $matching.fullname
                    write-host "Adding missing SLN reference:  $($_.ref.Path) => $relpath"
                    $csp = import-csproj  $matching.fullname
                    add-slnproject $sln -name $csp.Name -path $relpath -projectguid $csp.guid
                    $fixed[$_.ref.name] = $true
                    #write-warning "Don't know what to do with $($_.ref) of type $($_.ref.GetType())"
                }
            }
        }
        
       
        write-host "saving sln"
        $sln.Save()
    }
    if ($insln) {
        return 
    }
    
    write-host "Fixing CSPROJs..."

    $projects = get-slnprojects $sln | ? { $_.type -eq "csproj" }
    
    ipmo nupkg
    
     if ($tonuget) {
        $pkgdir =(find-packagesdir $reporoot)
        if (!(test-path $pkgdir)) {
            $null = new-item -type Directory $pkgdir
        }
        $missing = test-sln $sln -missing 
        $missing = @($missing | ? { $_.ref.type -eq "project"})
        $missing = $missing | % { $_.ref.name } | sort -Unique
        
        $missing | % {
            try {
                write-host "replacing $_ with nuget"
                $found = find-nugetPath $_ $pkgdir 
                if ($found -eq $null) {
                    write-host "installing package $_"
                nuget install $_ -out $pkgdir -pre
                }                    
                convert-referencestonuget $sln -projectName $_ -packagesDir $pkgdir -filter $filer
            } catch {
                write-error $_
            }
        }
    }
    
    $null = $projects | % {
        if (test-path $_.fullname) {
            $csproj = import-csproj $_.fullname
            
            if (!$tonuget) {
                $null = repair-csprojpaths $csproj -reporoot $reporoot -prerelease:$prerelease
            }            
        }
    }
    
    
#    $valid,$missing = test-slndependencies $sln
#    $valid | Should Be $true
    
}


function get-csprojdependencies {
     [CmdletBinding(DefaultParameterSetName = "csproj")]
    param(
        [Parameter(Mandatory=$true, ParameterSetName="csproj",Position=0)][Csproj]$csproj,
        [Parameter(Mandatory=$true, ParameterSetName="csprojfile",Position=0)][string]$csprojfile
    )

    if ($csproj -eq $null) { $csproj = import-csproj $csprojfile }
   
    $refs = @()
    $refs += get-projectreferences $csproj
    $refs += get-nugetreferences $csproj
    
    $refs = $refs | % {
        $r = $_
        $props = [ordered]@{ ref = $r; refType = $r.type; path = $r.path }
        return new-object -type pscustomobject -property $props 
    }
    
    return $refs
}


function repair-csprojpaths {
     [CmdletBinding(DefaultParameterSetName = "csproj")]
    param(
        [Parameter(Mandatory=$true, ParameterSetName="csproj",Position=0)][Csproj]$csproj,
        [Parameter(Mandatory=$true, ParameterSetName="csprojfile",Position=0)][string]$csprojfile,
        $reporoot = $null,
        [switch][bool] $prerelease
    )
    if ($csproj -eq $null) { $csproj = import-csproj $csprojfile }
  
    $deps = get-csprojdependencies $csproj
    $missing = @($deps | ? { $_.ref.IsValid -eq $false })
     
    write-verbose "CSPROJ $($csproj.Name) found $($missing.length) missing projects"
    if ($reporoot -eq $null) {
        $reporoot = find-reporoot $csproj.fullname
        if ($reporoot -ne $null) {
            write-verbose "auto-detected repo root at $reporoot"
        }
    }
    
    if ($reporoot -eq $null) {
        throw "No repository root given and none could be detected"
    }

    $missing = find-matchingprojects $missing $reporoot
    
    $missing | % {
        if ($_.matching -eq $null -or $_.matching.length -eq 0) {
            write-warning "no matching project found for CSPROJ reference $($_.ref.Path)"
        }
        else {
            $relpath = get-relativepath $csproj.fullname $_.matching.fullname
            
            $_.ref.Path = $relpath
            if ($_.ref.type -eq "project" -and $_.ref.Node.Include -ne $null) {
                write-verbose "fixing CSPROJ reference in $($csproj.name): $($_.ref.Path) => $relpath"
                $_.ref.Node.Include = $relpath
            } 
            if ($_.ref.type -eq "nuget" -and $_.ref.Node.HintPath -ne $null) {
                write-verbose "fixing NUGET reference in $($csproj.name): $($_.ref.Path) => $relpath"
                $_.ref.Node.HintPath = $relpath                
            }
        }

    }

    $csproj.Save()

    $dir = split-path -parent $csproj.FullName
    if (test-path (Join-Path $dir "packages.config")) {
        write-verbose "checking packages.config"
        $pkgs = get-packagesconfig (Join-Path $dir "packages.config") 
        $pkgs = $pkgs.packages
        
        if ((get-command "install-package" -Module nuget -errorAction Ignore) -ne $null) {
            write-verbose "detected Nuget module. using Nuget/install-package"
            foreach($dep in $pkgs) {
                nuget\install-package -ProjectName $csproj.name -id $dep.id -version $dep.version -prerelease:$prerelease
            }
        } else {
            "cannot verify if all references from packages.config are installed. run this script inside Visual Studio!"
        }
    }
    
#    $valid,$missing = test-slndependencies $sln
#    $valid | Should Be $true
    
}


new-alias fix-sln repair-slnpaths
new-alias fixsln fix-sln
new-alias fix-csproj repair-csprojpaths
new-alias fixcsproj fix-csproj 