<#
.SYNOPSIS
    Parses AL source files to extract metadata for code coverage mapping
.DESCRIPTION
    Extracts object definitions, procedure boundaries, and line mappings from .al source files
    to enable accurate Cobertura output with proper filenames and method names.
#>

<#
.SYNOPSIS
    Parses an app.json file to extract app metadata
.PARAMETER AppJsonPath
    Path to the app.json file
.OUTPUTS
    Object with Id, Name, Publisher, Version properties
#>
function Read-AppJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppJsonPath
    )
    
    if (-not (Test-Path $AppJsonPath)) {
        Write-Warning "app.json not found at: $AppJsonPath"
        return $null
    }
    
    $appJson = Get-Content -Path $AppJsonPath -Raw | ConvertFrom-Json
    
    return [PSCustomObject]@{
        Id        = $appJson.id
        Name      = $appJson.name
        Publisher = $appJson.publisher
        Version   = $appJson.version
    }
}

<#
.SYNOPSIS
    Scans a directory for .al files and extracts object definitions
.PARAMETER SourcePath
    Root path to scan for .al files
.OUTPUTS
    Hashtable mapping "ObjectType.ObjectId" to file and metadata info
#>
function Get-ALObjectMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )
    
    $objectMap = @{}
    
    if (-not (Test-Path $SourcePath)) {
        Write-Warning "Source path not found: $SourcePath"
        return $objectMap
    }
    
    # Normalize source path to resolve .\, ..\, and ensure consistent format
    $normalizedSourcePath = [System.IO.Path]::GetFullPath($SourcePath).TrimEnd('\', '/')
    
    $alFiles = Get-ChildItem -Path $SourcePath -Filter "*.al" -Recurse -File
    
    foreach ($file in $alFiles) {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        
        # Parse object definition: type ID name
        # Examples:
        #   codeunit 50100 "My Codeunit"
        #   table 50100 "My Table"
        #   pageextension 50100 "My Page Ext" extends "Customer Card"
        
        $objectPattern = '(?im)^\s*(codeunit|table|page|report|query|xmlport|enum|interface|permissionset|tableextension|pageextension|reportextension|enumextension|permissionsetextension|profile|controladdin)\s+(\d+)\s+("([^"]+)"|([^\s]+))'
        
        $match = [regex]::Match($content, $objectPattern)
        
        if ($match.Success) {
            $objectType = $match.Groups[1].Value
            $objectId = [int]$match.Groups[2].Value
            $objectName = if ($match.Groups[4].Value) { $match.Groups[4].Value } else { $match.Groups[5].Value }
            
            # Normalize object type to match BC internal naming
            $normalizedType = Get-NormalizedObjectType $objectType
            $key = "$normalizedType.$objectId"
            
            # Parse procedures in this file
            $procedures = Get-ALProcedures -Content $content
            
            # Get executable line information
            $executableInfo = Get-ALExecutableLines -Content $content
            
            # Calculate relative path (normalizedSourcePath is already normalized at function start)
            $relativePath = $file.FullName.Substring($normalizedSourcePath.Length + 1)
            
            $objectMap[$key] = [PSCustomObject]@{
                ObjectType            = $normalizedType
                ObjectTypeAL          = $objectType.ToLower()
                ObjectId              = $objectId
                ObjectName            = $objectName
                FilePath              = $file.FullName
                RelativePath          = $relativePath
                Procedures            = $procedures
                TotalLines            = ($content -split "`n").Count
                ExecutableLines       = $executableInfo.ExecutableLines
                ExecutableLineNumbers = $executableInfo.ExecutableLineNumbers
            }
        }
    }
    
    Write-Host "Mapped $($objectMap.Count) AL objects from $SourcePath"
    return $objectMap
}

<#
.SYNOPSIS
    Normalizes AL object type names to match BC internal naming
.PARAMETER ObjectType
    The object type as written in AL code
.OUTPUTS
    Normalized type name
#>
function Get-NormalizedObjectType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectType
    )
    
    $typeMap = @{
        'codeunit'                   = 'Codeunit'
        'table'                      = 'Table'
        'page'                       = 'Page'
        'report'                     = 'Report'
        'query'                      = 'Query'
        'xmlport'                    = 'XMLport'
        'enum'                       = 'Enum'
        'interface'                  = 'Interface'
        'permissionset'              = 'PermissionSet'
        'tableextension'             = 'TableExtension'
        'pageextension'              = 'PageExtension'
        'reportextension'            = 'ReportExtension'
        'enumextension'              = 'EnumExtension'
        'permissionsetextension'     = 'PermissionSetExtension'
        'profile'                    = 'Profile'
        'controladdin'               = 'ControlAddIn'
    }
    
    $lower = $ObjectType.ToLower()
    if ($typeMap.ContainsKey($lower)) {
        return $typeMap[$lower]
    }
    return $ObjectType
}

<#
.SYNOPSIS
    Extracts procedure definitions from AL source content
.PARAMETER Content
    The AL source file content
.OUTPUTS
    Array of procedure objects with Name, StartLine, EndLine
#>
function Get-ALProcedures {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )
    
    $procedures = @()
    $lines = $Content -split "`n"
    
    # Track procedure boundaries
    # Patterns for procedure definitions:
    #   procedure Name()
    #   local procedure Name()
    #   internal procedure Name()
    #   [attribute] procedure Name()
    
    $procedurePattern = '(?i)^\s*(?:local\s+|internal\s+|protected\s+)?(procedure|trigger)\s+("([^"]+)"|([^\s(]+))'
    
    $currentProcedure = $null
    $braceDepth = 0
    $inProcedure = $false
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNum = $i + 1  # 1-based line numbers
        
        # Check for procedure start
        $match = [regex]::Match($line, $procedurePattern)
        if ($match.Success -and -not $inProcedure) {
            $procType = $match.Groups[1].Value
            $procName = if ($match.Groups[3].Value) { $match.Groups[3].Value } else { $match.Groups[4].Value }
            
            $currentProcedure = @{
                Name      = $procName
                Type      = $procType
                StartLine = $lineNum
                EndLine   = $lineNum
            }
            $inProcedure = $true
            $braceDepth = 0
        }
        
        # Track braces for procedure end
        if ($inProcedure) {
            # Count AL block boundaries (word-boundary anchored to avoid matching variable names)
            $openBraces = ([regex]::Matches($line, '\bbegin\b', 'IgnoreCase')).Count
            $closeBraces = ([regex]::Matches($line, '\bend\b\s*;?\s*$', 'IgnoreCase')).Count
            
            $braceDepth += $openBraces
            $braceDepth -= $closeBraces
            
            # Check if procedure ended
            if ($braceDepth -le 0 -and $line -match '\bend\b\s*;?\s*$') {
                $currentProcedure.EndLine = $lineNum
                $procedures += [PSCustomObject]$currentProcedure
                $currentProcedure = $null
                $inProcedure = $false
            }
        }
    }
    
    # Handle unclosed procedure (shouldn't happen in valid AL)
    if ($currentProcedure) {
        $currentProcedure.EndLine = $lines.Count
        $procedures += [PSCustomObject]$currentProcedure
    }
    
    return $procedures
}

<#
.SYNOPSIS
    Finds which procedure contains a given line number
.PARAMETER Procedures
    Array of procedure objects
.PARAMETER LineNo
    The line number to find
.OUTPUTS
    The procedure object containing the line, or $null
#>
function Find-ProcedureForLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Procedures,
        
        [Parameter(Mandatory = $true)]
        [int]$LineNo
    )
    
    foreach ($proc in $Procedures) {
        if ($LineNo -ge $proc.StartLine -and $LineNo -le $proc.EndLine) {
            return $proc
        }
    }
    return $null
}

<#
.SYNOPSIS
    Finds all source folders in a project directory
.PARAMETER ProjectPath
    Path to the project root
.OUTPUTS
    Array of paths to folders containing .al files
#>
function Find-ALSourceFolders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath
    )
    
    $sourceFolders = @()
    
    # Common AL project structures:
    # - src/ folder
    # - app/ folder  
    # - Root folder with .al files
    # - Multiple app folders
    
    $commonFolders = @('src', 'app', 'Source', 'App')
    
    foreach ($folder in $commonFolders) {
        $path = Join-Path $ProjectPath $folder
        if (Test-Path $path) {
            $sourceFolders += $path
        }
    }
    
    # If no common folders found, check for .al files in root
    if ($sourceFolders.Count -eq 0) {
        $alFiles = Get-ChildItem -Path $ProjectPath -Filter "*.al" -File -ErrorAction SilentlyContinue
        if ($alFiles.Count -gt 0) {
            $sourceFolders += $ProjectPath
        }
    }
    
    # Also look for subfolders that contain app.json (multi-app repos)
    $appJsonFiles = Get-ChildItem -Path $ProjectPath -Filter "app.json" -Recurse -File -Depth 2 -ErrorAction SilentlyContinue
    foreach ($appJson in $appJsonFiles) {
        $appFolder = $appJson.DirectoryName
        if ($appFolder -ne $ProjectPath -and $sourceFolders -notcontains $appFolder) {
            $sourceFolders += $appFolder
        }
    }
    
    return $sourceFolders | Select-Object -Unique
}

<#
.SYNOPSIS
    Counts executable lines in AL source content
.DESCRIPTION
    Identifies lines that are executable code statements vs non-executable
    (comments, blank lines, declarations, keywords like begin/end, etc.)
.PARAMETER Content
    The AL source file content
.OUTPUTS
    Object with TotalLines, ExecutableLines, and ExecutableLineNumbers array
#>
function Get-ALExecutableLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )
    
    $lines = $Content -split "`n"
    $executableLineNumbers = @()
    $inMultiLineComment = $false
    $inProcedureBody = $false
    $braceDepth = 0
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineNum = $i + 1
        $line = $lines[$i].Trim()
        
        # Skip empty lines
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        
        # Handle multi-line comments /* */
        if ($line -match '/\*') {
            $inMultiLineComment = $true
        }
        if ($inMultiLineComment) {
            if ($line -match '\*/') {
                $inMultiLineComment = $false
            }
            continue
        }
        
        # Skip single-line comments
        if ($line -match '^//') {
            continue
        }
        
        # Remove inline comments for analysis
        $lineNoComment = $line -replace '//.*$', ''
        $lineNoComment = $lineNoComment.Trim()
        
        if ([string]::IsNullOrWhiteSpace($lineNoComment)) {
            continue
        }
        
        # Skip non-executable constructs
        # Object declarations
        if ($lineNoComment -match '(?i)^(codeunit|table|page|report|query|xmlport|enum|interface|permissionset|tableextension|pageextension|reportextension|enumextension)\s+\d+') {
            continue
        }
        
        # Field/column definitions (in tables)
        if ($lineNoComment -match '(?i)^field\s*\(\s*\d+\s*;') {
            continue
        }
        
        # Property assignments (Name = value; at object level)
        if ($lineNoComment -match '(?i)^(Caption|Description|DataClassification|Access|Subtype|TableRelation|OptionMembers|OptionCaption)\s*=') {
            continue
        }
        
        # Procedure/trigger declarations (the signature line itself)
        if ($lineNoComment -match '(?i)^(local\s+|internal\s+|protected\s+)?(procedure|trigger)\s+') {
            $inProcedureBody = $true
            $braceDepth = 0
            continue
        }
        
        # Variable declarations
        if ($lineNoComment -match '(?i)^var\s*$') {
            continue
        }
        if ($lineNoComment -match '(?i)^\w+\s*:\s*(Record|Code|Text|Integer|Decimal|Boolean|Date|Time|DateTime|Option|Enum|Codeunit|Page|Report|Query|Guid|BigInteger|Blob|Media|MediaSet|RecordRef|FieldRef|JsonObject|JsonArray|JsonToken|JsonValue|HttpClient|HttpContent|HttpRequestMessage|HttpResponseMessage|List|Dictionary|TextBuilder|OutStream|InStream|File|Char|Byte|Duration|Label|DotNet)') {
            continue
        }
        
        # Keywords that are structural, not executable
        if ($lineNoComment -match '(?i)^(begin|end;?|keys|fieldgroups|actions|area|group|repeater|layout|requestpage|dataset|column|dataitem|labels|trigger\s+OnRun|trigger\s+On\w+)\s*$') {
            # Track begin/end for procedure body detection
            if ($lineNoComment -match '(?i)^begin\s*$') {
                $braceDepth++
            }
            if ($lineNoComment -match '(?i)^end;?\s*$') {
                $braceDepth--
                if ($braceDepth -le 0) {
                    $inProcedureBody = $false
                }
            }
            continue
        }
        
        # At this point, if we're in a procedure body, it's likely executable
        if ($inProcedureBody -or $braceDepth -gt 0) {
            $executableLineNumbers += $lineNum
        }
        # Also count lines that look like statements (assignments, calls, control flow)
        elseif ($lineNoComment -match '(?i)(:=|if\s+|else|for\s+|foreach\s+|while\s+|repeat|until|case\s+|exit\(|error\(|message\(|\.\w+\(|;$)') {
            $executableLineNumbers += $lineNum
        }
    }
    
    return [PSCustomObject]@{
        TotalLines           = $lines.Count
        ExecutableLines      = $executableLineNumbers.Count
        ExecutableLineNumbers = $executableLineNumbers
    }
}

Export-ModuleMember -Function @(
    'Read-AppJson',
    'Get-ALObjectMap',
    'Get-NormalizedObjectType',
    'Get-ALProcedures',
    'Find-ProcedureForLine',
    'Find-ALSourceFolders',
    'Get-ALExecutableLines'
)
