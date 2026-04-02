<#
.SYNOPSIS
    Parses SAP Business One SDK HTML documentation into a JavaScript data file.
.DESCRIPTION
    Reads all .htm files from the SAP B1 SDK Help folder, extracts table structures,
    columns, relations, constraints, and keys, then outputs a JS data file.
.PARAMETER SdkHelpPath
    Path to the SAP B1 SDK Help output_folder. Defaults to standard install location.
.PARAMETER OutputPath
    Path for the generated JavaScript file. Defaults to sap-b1-data.js in the script directory.
#>
param(
    [string]$SdkHelpPath = "C:\Program Files (x86)\SAP\SAP Business One SDK\Help\output_folder",
    [string]$OutputPath = (Join-Path $PSScriptRoot "sap-b1-data.js")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $SdkHelpPath)) {
    Write-Error "SDK Help path not found: $SdkHelpPath"
    exit 1
}

Write-Host "Parsing SAP B1 SDK documentation from: $SdkHelpPath"

$categories = Get-ChildItem -Path $SdkHelpPath -Directory | Select-Object -ExpandProperty Name
$tables = @{}
$totalFiles = 0
$parsedFiles = 0

function Get-CleanText {
    param([string]$html)
    $text = $html -replace '&nbsp;|&#160;', ''
    $text = $text -replace '<[^>]+>', ''
    $text = $text -replace '&amp;', '&'
    $text = $text -replace '&lt;', '<'
    $text = $text -replace '&gt;', '>'
    $text = $text -replace '&quot;', '"'
    return $text.Trim()
}

function Get-TableType {
    param([string]$tableName)
    if ($tableName -match '^O[A-Z]') {
        return "header"
    }
    if ($tableName -match '^A[A-Z]') {
        return "history"
    }
    if ($tableName -match '\d+$') {
        $level = [regex]::Match($tableName, '(\d+)$').Groups[1].Value
        return "line"
    }
    return "other"
}

function Get-LineLevel {
    param([string]$tableName)
    if ($tableName -match '(\d+)$') {
        return [int]$Matches[1]
    }
    return $null
}

function Get-BaseTable {
    param([string]$tableName)
    if ($tableName -match '^(.+?)(\d+)$') {
        return $Matches[1]
    }
    return $null
}

foreach ($category in $categories) {
    $categoryPath = Join-Path $SdkHelpPath $category
    $htmFiles = Get-ChildItem -Path $categoryPath -Filter "*.htm" -File -ErrorAction SilentlyContinue

    foreach ($htmFile in $htmFiles) {
        $totalFiles++
        $tableName = [System.IO.Path]::GetFileNameWithoutExtension($htmFile.Name)

        try {
            $content = Get-Content -Path $htmFile.FullName -Encoding UTF8 -Raw

            # Extract table description from <p>Table Description: ...</p>
            $tableDesc = ""
            if ($content -match '<p>Table Description:\s*(.+?)</p>') {
                $tableDesc = Get-CleanText $Matches[1]
            }

            # Extract title from <h1>
            $title = ""
            if ($content -match '<h1>(.+?)</h1>') {
                $title = Get-CleanText $Matches[1]
            }

            # Split content into column table and key table
            $autoNumber1Match = [regex]::Match($content, '(?s)<table id="AutoNumber1"[^>]*>(.*?)</table>')
            $autoNumber2Match = [regex]::Match($content, '(?s)<table id="AutoNumber2"[^>]*>(.*?)</table>')

            $columns = @()
            $keys = @()
            $relatedTables = @()

            # Parse column table
            if ($autoNumber1Match.Success) {
                $tableHtml = $autoNumber1Match.Groups[1].Value
                $rowMatches = [regex]::Matches($tableHtml, '(?s)<tr>(.*?)</tr>')

                $currentColumn = $null
                $isHeader = $true

                foreach ($rowMatch in $rowMatches) {
                    $rowHtml = $rowMatch.Groups[1].Value
                    $cellMatches = [regex]::Matches($rowHtml, '(?s)<td[^>]*>(.*?)</td>')
                    $cells = @()
                    foreach ($cellMatch in $cellMatches) {
                        $cells += $cellMatch.Groups[1].Value
                    }

                    if ($cells.Count -lt 2) { continue }

                    # Skip header row
                    if ($isHeader) {
                        $firstCell = Get-CleanText $cells[0]
                        if ($firstCell -eq 'Field') {
                            $isHeader = $false
                            continue
                        }
                    }

                    $fieldName = Get-CleanText $cells[0]

                    if ([string]::IsNullOrWhiteSpace($fieldName)) {
                        # Continuation row - add constraints to current column
                        if ($null -ne $currentColumn -and $cells.Count -ge 8) {
                            $constraintVal = Get-CleanText $cells[6]
                            $constraintLabel = Get-CleanText $cells[7]
                            if (-not [string]::IsNullOrWhiteSpace($constraintVal)) {
                                $currentColumn.constraints += @{
                                    value = $constraintVal
                                    label = $constraintLabel
                                }
                            }
                        }
                    }
                    else {
                        # New column
                        $description = if ($cells.Count -gt 1) { Get-CleanText $cells[1] } else { "" }
                        $colType = if ($cells.Count -gt 2) { Get-CleanText $cells[2] } else { "" }
                        $size = if ($cells.Count -gt 3) { Get-CleanText $cells[3] } else { "" }

                        # Extract related table - check for <a href> link
                        $relatedTable = $null
                        if ($cells.Count -gt 4) {
                            $relatedCell = $cells[4]
                            if ($relatedCell -match '<a[^>]*>([^<]+)</a>') {
                                $relatedTable = $Matches[1].Trim()
                                if ($relatedTable -ne '-' -and -not [string]::IsNullOrWhiteSpace($relatedTable)) {
                                    if ($relatedTable -notin $relatedTables) {
                                        $relatedTables += $relatedTable
                                    }
                                }
                                else {
                                    $relatedTable = $null
                                }
                            }
                            else {
                                $relText = Get-CleanText $relatedCell
                                if ($relText -ne '-' -and -not [string]::IsNullOrWhiteSpace($relText)) {
                                    $relatedTable = $relText
                                    if ($relatedTable -notin $relatedTables) {
                                        $relatedTables += $relatedTable
                                    }
                                }
                                else {
                                    $relatedTable = $null
                                }
                            }
                        }

                        $defaultVal = if ($cells.Count -gt 5) { Get-CleanText $cells[5] } else { "" }

                        $constraints = @()
                        if ($cells.Count -ge 8) {
                            $constraintVal = Get-CleanText $cells[6]
                            $constraintLabel = Get-CleanText $cells[7]
                            if (-not [string]::IsNullOrWhiteSpace($constraintVal)) {
                                $constraints += @{
                                    value = $constraintVal
                                    label = $constraintLabel
                                }
                            }
                        }

                        $currentColumn = @{
                            field       = $fieldName
                            description = $description
                            type        = $colType
                            size        = $size
                            related     = $relatedTable
                            defaultValue = $defaultVal
                            constraints = $constraints
                        }
                        $columns += $currentColumn
                    }
                }
            }

            # Parse key table
            if ($autoNumber2Match.Success) {
                $keyTableHtml = $autoNumber2Match.Groups[1].Value
                $keyRowMatches = [regex]::Matches($keyTableHtml, '(?s)<tr>(.*?)</tr>')

                $currentKey = $null
                $isHeader = $true

                foreach ($keyRowMatch in $keyRowMatches) {
                    $rowHtml = $keyRowMatch.Groups[1].Value
                    $cellMatches = [regex]::Matches($rowHtml, '(?s)<td[^>]*>(.*?)</td>')
                    $cells = @()
                    foreach ($cellMatch in $cellMatches) {
                        $cells += $cellMatch.Groups[1].Value
                    }

                    if ($cells.Count -lt 3) { continue }

                    if ($isHeader) {
                        $firstCell = Get-CleanText $cells[0]
                        if ($firstCell -eq 'Key') {
                            $isHeader = $false
                            continue
                        }
                    }

                    $keyName = Get-CleanText $cells[0]
                    $fieldName = Get-CleanText $cells[2]

                    if ([string]::IsNullOrWhiteSpace($keyName)) {
                        # Continuation - add field to current key
                        if ($null -ne $currentKey -and -not [string]::IsNullOrWhiteSpace($fieldName)) {
                            $currentKey.fields += $fieldName
                        }
                    }
                    else {
                        $unique = (Get-CleanText $cells[1]) -eq 'Yes'
                        $currentKey = @{
                            name   = $keyName
                            unique = $unique
                            fields = @()
                        }
                        if (-not [string]::IsNullOrWhiteSpace($fieldName)) {
                            $currentKey.fields += $fieldName
                        }
                        $keys += $currentKey
                    }
                }
            }

            $tableType = Get-TableType $tableName
            $lineLevel = Get-LineLevel $tableName
            $baseTable = Get-BaseTable $tableName

            $tables[$tableName] = @{
                name         = $tableName
                description  = $tableDesc
                title        = $title
                category     = $category
                type         = $tableType
                lineLevel    = $lineLevel
                baseTable    = $baseTable
                columns      = $columns
                keys         = $keys
                relatedTables = $relatedTables
            }

            $parsedFiles++
        }
        catch {
            Write-Warning "Failed to parse $($htmFile.FullName): $_"
        }
    }
}

Write-Host "Parsed $parsedFiles of $totalFiles files across $($categories.Count) categories."

# Compute incoming relations
$incomingRelations = @{}
foreach ($tName in $tables.Keys) {
    $table = $tables[$tName]
    foreach ($related in $table.relatedTables) {
        if (-not $incomingRelations.ContainsKey($related)) {
            $incomingRelations[$related] = @()
        }
        if ($tName -notin $incomingRelations[$related]) {
            $incomingRelations[$related] += $tName
        }
    }
}

# Generate JavaScript output
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("// SAP Business One Database Schema")
[void]$sb.AppendLine("// Auto-generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$sb.AppendLine("// Source: $SdkHelpPath")
[void]$sb.AppendLine("// Tables: $parsedFiles")
[void]$sb.AppendLine("")

# Categories
[void]$sb.AppendLine("const SAP_B1_CATEGORIES = [")
foreach ($cat in ($categories | Sort-Object)) {
    $catCount = ($tables.Values | Where-Object { $_.category -eq $cat }).Count
    $displayName = $cat -replace '_', ' '
    [void]$sb.AppendLine("  { id: `"$cat`", name: `"$displayName`", tableCount: $catCount },")
}
[void]$sb.AppendLine("];")
[void]$sb.AppendLine("")

function ConvertTo-JsString {
    param([string]$s)
    if ($null -eq $s) { return 'null' }
    # In .NET regex replacement, \ is literal (only $ is special).
    # So we use '\\' as replacement to produce two chars: \\
    $s = $s -replace '\\', '\\'
    $s = $s -replace '"', '\"'
    $s = $s -replace "`n", '\n'
    $s = $s -replace "`r", ''
    return "`"$s`""
}

[void]$sb.AppendLine("const SAP_B1_TABLES = {")

$sortedTables = $tables.Keys | Sort-Object
foreach ($tName in $sortedTables) {
    $t = $tables[$tName]
    $incoming = if ($incomingRelations.ContainsKey($tName)) { $incomingRelations[$tName] } else { @() }

    [void]$sb.AppendLine("  $(ConvertTo-JsString $tName): {")
    [void]$sb.AppendLine("    name: $(ConvertTo-JsString $t.name),")
    [void]$sb.AppendLine("    description: $(ConvertTo-JsString $t.description),")
    [void]$sb.AppendLine("    title: $(ConvertTo-JsString $t.title),")
    [void]$sb.AppendLine("    category: $(ConvertTo-JsString $t.category),")
    [void]$sb.AppendLine("    type: $(ConvertTo-JsString $t.type),")

    if ($null -ne $t.lineLevel) {
        [void]$sb.AppendLine("    lineLevel: $($t.lineLevel),")
    }
    else {
        [void]$sb.AppendLine("    lineLevel: null,")
    }

    if ($null -ne $t.baseTable) {
        [void]$sb.AppendLine("    baseTable: $(ConvertTo-JsString $t.baseTable),")
    }
    else {
        [void]$sb.AppendLine("    baseTable: null,")
    }

    # Columns
    [void]$sb.AppendLine("    columns: [")
    foreach ($col in $t.columns) {
        [void]$sb.Append("      { field: $(ConvertTo-JsString $col.field)")
        [void]$sb.Append(", description: $(ConvertTo-JsString $col.description)")
        [void]$sb.Append(", type: $(ConvertTo-JsString $col.type)")
        [void]$sb.Append(", size: $(ConvertTo-JsString $col.size)")
        if ($null -ne $col.related) {
            [void]$sb.Append(", related: $(ConvertTo-JsString $col.related)")
        }
        else {
            [void]$sb.Append(", related: null")
        }
        [void]$sb.Append(", defaultValue: $(ConvertTo-JsString $col.defaultValue)")

        if ($col.constraints.Count -gt 0) {
            [void]$sb.Append(", constraints: [")
            $first = $true
            foreach ($c in $col.constraints) {
                if (-not $first) { [void]$sb.Append(", ") }
                [void]$sb.Append("{ value: $(ConvertTo-JsString $c.value), label: $(ConvertTo-JsString $c.label) }")
                $first = $false
            }
            [void]$sb.Append("]")
        }
        else {
            [void]$sb.Append(", constraints: []")
        }

        [void]$sb.AppendLine(" },")
    }
    [void]$sb.AppendLine("    ],")

    # Keys
    [void]$sb.AppendLine("    keys: [")
    foreach ($key in $t.keys) {
        $uniqueStr = if ($key.unique) { "true" } else { "false" }
        $fieldsStr = ($key.fields | ForEach-Object { ConvertTo-JsString $_ }) -join ", "
        [void]$sb.AppendLine("      { name: $(ConvertTo-JsString $key.name), unique: $uniqueStr, fields: [$fieldsStr] },")
    }
    [void]$sb.AppendLine("    ],")

    # Relations
    $outStr = ($t.relatedTables | ForEach-Object { ConvertTo-JsString $_ }) -join ", "
    $inStr = ($incoming | Sort-Object | ForEach-Object { ConvertTo-JsString $_ }) -join ", "
    [void]$sb.AppendLine("    relations: { outgoing: [$outStr], incoming: [$inStr] },")

    [void]$sb.AppendLine("  },")
}

[void]$sb.AppendLine("};")

$jsContent = $sb.ToString()
[System.IO.File]::WriteAllText($OutputPath, $jsContent, [System.Text.Encoding]::UTF8)

Write-Host "Generated: $OutputPath"
Write-Host "Total tables: $parsedFiles"
Write-Host "Total categories: $($categories.Count)"
