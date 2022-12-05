function ConvertFrom-FixedWidth {
  [CmdletBinding()]
  Param(
    [Parameter(ValueFromPipeline)]
    [string]$InputObject    
  )

End {
  [string]$FirstLine = $INPUT[0]

  if([string]::IsNullOrWhiteSpace($FirstLine)) {
    throw 'The first line of input is blank.'
    return
  }


  $HeaderFirstNonSpaceIndex, $HeaderLastNonSpaceIndex = 
    (0..($FirstLine.Length-1)).Where({-not[char]::IsSeparator($FirstLine,$_)})[0,-1]
  $MaxLength = ($INPUT|measure -max Length).Maximum

  Write-Debug "First non-space header index: $HeaderFirstNonSpaceIndex"

  if($null -eq $HeaderFirstNonSpaceIndex) {
    throw 'The first line of input does not contain any column headers.'
    return
  }

  # Make a list of columns where we'd be willing to break the data into columns
  $ColumnsWithOnlySpaces = [Collections.Generic.HashSet[int]]@(
    -1                                                  # always break at the start
    $HeaderFirstNonSpaceIndex..$HeaderLastNonSpaceIndex # exclude leading and trailing whitespace columns in the header row
    $MaxLength                                          # always break at the end
  )

  # remove columns where we won't break because the column contains data
  foreach($s in $INPUT){
    if($s.Length -eq 0) { continue }
    $ColumnsWithOnlySpaces.ExceptWith( [int[]](0..($s.Length-1)).Where({-not[char]::IsSeparator($s,$_)}) )
  }

  # find groups of contiguous columns that contain only spaces, then
  # the actual data is between those groups.
  $ix = 0
  $ColumnBoundaries =
    $ColumnsWithOnlySpaces |
    Sort-Object |
    Group-Object {$_-((gv ix -Scope 1).Value++)} | # silly hack to group together contiguous sequences
    Sort-Object {+$_.Name} |
    Select-Object -pv prior `
           @{n='StartIndex';e={$prior.NextStartIndex}},
           @{n='EndIndex';e={($_.Group|measure -min).Minimum-1}},
           @{n='NextStartIndex';e={($_.Group|Measure -max).Maximum+1}} |
    Where-Object EndIndex -ge 0 |
    # these could be static members, but the next loop's debug is sane if they're live.
    Add-Member Length -MemberType ScriptProperty -Value {1+$this.EndIndex-$this.StartIndex} -PassThru |
    Add-Member Caption -MemberType ScriptProperty -Value {$FirstLine.Substring($this.StartIndex, [Math]::Min($FirstLine.Length-$this.StartIndex, $this.Length)).Trim()} -PassThru

  $ColumnBoundaries | ft | Out-String -Stream | Write-Debug

  # eliminate columns that don't contain a caption
  $CaptionedColumnBoundaries = 
    $ColumnBoundaries |
    ForEach-Object -ov CaptionedColumnBoundaries {
      # if the column has a caption, output it. Otherwise, extend the previous column.
      if(-not [string]::IsNullOrWhiteSpace($_.Caption)) {
        Write-Debug "outputting $($_)"
        $_
      }
      else {
        Write-Debug "updating prior with endindex from $($_)"
        $CaptionedColumnBoundaries[-1].EndIndex = $_.EndIndex
        Write-Debug "prior now: $($CaptionedColumnBoundaries[-1])"
      }
    } |
    Sort-Object StartIndex | # hack to make sure all objects have been processed before Select-Object runs
    Select-Object * # convert ScriptProperties to NoteProperties

  # rename columns with the same header, to prevent conflicts
  do {
    $AnyColumnsRenamed = $false
    $CaptionedColumnBoundaries | Group-Object Caption | Where-Object Count -gt 1 |
      ForEach-Object {
        $AnyColumnsRenamed = $true
        for($i=0; $i-lt $_.Count; $i++) { $_.Group[$i].Caption += $i }
      }
  } while ($AnyColumnsRenamed)

  $CaptionedColumnBoundaries | Format-Table | Out-String -Stream | Write-Debug

  $ColumnExpressions = foreach($cb in $CaptionedColumnBoundaries) {
    @{
      Name = [string]$cb.Caption
      Expression = {
        if($cb.StartIndex -lt $_.Length) {
          $Length = [Math]::Min($_.Length - $cb.StartIndex, $cb.Length)
          $_.Substring($cb.StartIndex,$Length).Trim()
        }
      }.GetNewClosure()
    }
  }

  $ColumnExpressions |%{[pscustomobject]$_} | Format-Table -Wrap | Out-String -Stream | Write-Debug

  $INPUT | Select-Object -Skip 1 $ColumnExpressions
}
}
