# Pure foreground identity checks: no windows, sessions or account data are accessed.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'NotifyBridge.Common.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-NotifyPopupForegroundIdentity' }, $true)
if ($null -eq $functionAst) { throw 'Foreground identity function missing.' }
. ([scriptblock]::Create($functionAst.Extent.Text))

$pi = [string][char]0x03c0
$dot = [string][char]0x00b7
$unicodeName = -join @([char]0x4F1A, [char]0x8BDD, [char]0x4E00)
$cases = @(
    @{ Name='empty identity never dismisses'; Args=@{}; Expected=$false }
    @{ Name='missing observed title does not dismiss'; Args=@{SourceTabTitle='tab 1'}; Expected=$false }
    @{ Name='selected exact title matches'; Args=@{SelectedTabTitle='tab 1'; SourceTabTitle='tab 1'}; Expected=$true }
    @{ Name='selected exact comparison ignores case'; Args=@{SelectedTabTitle='TAB 1'; SourceTabTitle='tab 1'}; Expected=$true }
    @{ Name='metadata whitespace is normalized'; Args=@{SelectedTabTitle=' tab 1 '; SourceTabTitle=' tab 1 '}; Expected=$true }
    @{ Name='tab 1 never matches tab 10'; Args=@{SelectedTabTitle='tab 10'; SourceTabTitle='tab 1'}; Expected=$false }
    @{ Name='source title cannot be a selected title prefix'; Args=@{SelectedTabTitle='tab 1'; SourceTabTitle='tab 10'}; Expected=$false }
    @{ Name='selected tab overrides stale window title'; Args=@{SelectedTabTitle='tab 2'; WindowTitle='tab 1'; SourceTabTitle='tab 1'}; Expected=$false }
    @{ Name='exact mismatch never falls back to shared cwd'; Args=@{SelectedTabTitle='tab 2 - proj'; WindowTitle='tab 1 - proj'; SourceTabTitle='tab 1 - proj'; CwdBase='proj'}; Expected=$false }
    @{ Name='window exact title is used without a selected tab'; Args=@{WindowTitle='tab 1'; SourceTabTitle='tab 1'}; Expected=$true }
    @{ Name='known Windows Terminal suffix is allowed on window'; Args=@{WindowTitle='tab 1 - Windows Terminal'; SourceTabTitle='tab 1'}; Expected=$true }
    @{ Name='window full title is accepted even when it contains the known suffix'; Args=@{WindowTitle='tab 1 - Windows Terminal'; SourceTabTitle='tab 1 - Windows Terminal'}; Expected=$true }
    @{ Name='unknown window suffix is rejected'; Args=@{WindowTitle='tab 1 - another app'; SourceTabTitle='tab 1'}; Expected=$false }
    @{ Name='window title prefix is rejected'; Args=@{WindowTitle='prefix tab 1'; SourceTabTitle='tab 1'}; Expected=$false }
    @{ Name='selected tab does not strip window decorations'; Args=@{SelectedTabTitle='tab 1 - Windows Terminal'; SourceTabTitle='tab 1'}; Expected=$false }
    @{ Name='unicode exact title matches'; Args=@{SelectedTabTitle=$unicodeName; SourceTabTitle=$unicodeName}; Expected=$true }
    @{ Name='bare cwd matches a complete name'; Args=@{SelectedTabTitle='proj'; CwdBase='proj'}; Expected=$true }
    @{ Name='similar project name never matches'; Args=@{SelectedTabTitle='project'; CwdBase='proj'}; Expected=$false }
    @{ Name='hyphenated project name never matches prefix'; Args=@{SelectedTabTitle='proj-other'; CwdBase='proj'}; Expected=$false }
    @{ Name='cwd-only uses selected tab over stale window'; Args=@{SelectedTabTitle='other'; WindowTitle='proj'; CwdBase='proj'}; Expected=$false }
    @{ Name='final Pi cwd field matches'; Args=@{SelectedTabTitle=($pi+' - session - proj '+$dot+' #012345abcdef'); CwdBase='proj'}; Expected=$true }
    @{ Name='session field is not treated as cwd'; Args=@{SelectedTabTitle=($pi+' - proj - other '+$dot+' #012345abcdef'); CwdBase='proj'}; Expected=$false }
    @{ Name='Unix path leaf matches'; Args=@{SelectedTabTitle='/work/proj'; CwdBase='proj'}; Expected=$true }
    @{ Name='Unix parent directory never matches'; Args=@{SelectedTabTitle='/work/proj/child'; CwdBase='proj'}; Expected=$false }
    @{ Name='Windows path leaf matches'; Args=@{SelectedTabTitle='C:\work\proj'; CwdBase='proj'}; Expected=$true }
    @{ Name='Windows parent directory never matches'; Args=@{SelectedTabTitle='C:\work\proj\child'; CwdBase='proj'}; Expected=$false }
    @{ Name='path leaf permits a trailing separator'; Args=@{SelectedTabTitle='C:\work\proj\'; CwdBase='proj'}; Expected=$true }
    @{ Name='path leaf preserves spaces and hyphens'; Args=@{SelectedTabTitle='C:\work\foo - bar'; CwdBase='foo - bar'}; Expected=$true }
    @{ Name='hyphen inside a path leaf is not a field separator'; Args=@{SelectedTabTitle='C:\work\foo - proj'; CwdBase='proj'}; Expected=$false }
    @{ Name='Unicode cwd field matches'; Args=@{SelectedTabTitle=($pi+' - '+$unicodeName); CwdBase=$unicodeName}; Expected=$true }
    @{ Name='regex characters are literal directory characters'; Args=@{SelectedTabTitle='C:\work\proj[1]+.x'; CwdBase='proj[1]+.x'}; Expected=$true }
    @{ Name='regex dot cannot wildcard another character'; Args=@{SelectedTabTitle='projAx'; CwdBase='proj.x'}; Expected=$false }
    @{ Name='cwd window fallback handles known suffix'; Args=@{WindowTitle='C:\work\proj - Windows Terminal'; CwdBase='proj'}; Expected=$true }
    @{ Name='empty cwd does not match nonempty observed title'; Args=@{SelectedTabTitle='proj'; CwdBase=''}; Expected=$false }
)

foreach ($case in $cases) {
    $arguments = $case.Args
    $actual = Test-NotifyPopupForegroundIdentity @arguments
    if ($actual -ne $case.Expected) { throw ("FAIL {0}: expected {1}, got {2}" -f $case.Name, $case.Expected, $actual) }
    Write-Output ('PASS ' + $case.Name)
}
Write-Output ("Popup identity tests passed: {0}" -f $cases.Count)
