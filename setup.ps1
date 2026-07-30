<#
.SYNOPSIS
    Bootstrap the Lyra workspace: clone (or refresh) the five sub-project repos.

.DESCRIPTION
    The sub-projects are independent Git repos and are NOT tracked by the
    workspace repo (see .gitignore). This script reconstitutes the full tree
    from a bare clone of lyra-workspace.

    Windows counterpart to setup.sh. Requires PowerShell 5.1+ (ships with
    Windows 10/11) or PowerShell 7+ on any platform.

.PARAMETER Pull
    Also fast-forward each existing repo to its upstream.

.PARAMETER Https
    Use https:// remotes instead of git@ (no SSH key required).

.EXAMPLE
    .\setup.ps1
    Clone anything missing, fetch what's already there.

.EXAMPLE
    .\setup.ps1 -Pull -Https
#>

[CmdletBinding()]
param(
    [switch]$Pull,
    [switch]$Https
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OrgSsh   = 'git@github.com:Lyra-Language'
$OrgHttps = 'https://github.com/Lyra-Language'

# Sub-projects, in dependency order (grammar first - the Go module replaces
# into ../tree-sitter-lyra).
$Repos = @('tree-sitter-lyra', 'lyra', 'lyra-vscode-ext', 'lyra-zed-ext', 'lyra-website')

# Repos storing files in Git LFS. Cloning these without git-lfs installed
# silently leaves pointer files behind instead of real content.
$LfsRepos = @('tree-sitter-lyra')

# --- output helpers -------------------------------------------------------

function Write-Ok   { param($m) Write-Host '  ' -NoNewline; Write-Host '+' -ForegroundColor Green  -NoNewline; Write-Host " $m" }
function Write-Warn { param($m) Write-Host '  ' -NoNewline; Write-Host '!' -ForegroundColor Yellow -NoNewline; Write-Host " $m" }
function Write-Err  { param($m) Write-Host '  ' -NoNewline; Write-Host 'x' -ForegroundColor Red    -NoNewline; Write-Host " $m" }
function Write-Note { param($m) Write-Host "    $m" -ForegroundColor DarkGray }

$script:Failed = @()
function Add-Failure { param($name, $msg) Write-Err $msg; $script:Failed += $name }

# Run git without PowerShell treating its stderr chatter as a terminating error.
function Invoke-Git {
    param([string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git @GitArgs 2>&1
        return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = ([string]($out | Out-String)).Trim() }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# --- preflight ------------------------------------------------------------

Set-Location -Path $PSScriptRoot
$Workspace = (Get-Location).Path

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'git is required but was not found on PATH.' -ForegroundColor Red
    exit 1
}

$HaveLfs = [bool](Get-Command git-lfs -ErrorAction SilentlyContinue) -or (Invoke-Git @('lfs', 'version')).Ok
$Base = if ($Https) { $OrgHttps } else { $OrgSsh }

Write-Host 'Lyra workspace' -ForegroundColor White -NoNewline
Write-Host " - $Workspace"
Write-Host "remote base: $Base"
if (-not $HaveLfs) {
    Write-Warn "git-lfs not installed - required by: $($LfsRepos -join ', ')"
    Write-Note "winget install GitHub.GitLFS   then: git lfs install"
}
Write-Host ''

# --- per-repo work --------------------------------------------------------

function Test-RepoRoot {
    # True when $Path is the top level of its own working tree (not merely
    # inside the workspace repo).
    param([string]$Path)
    $r = Invoke-Git @('-C', $Path, 'rev-parse', '--show-toplevel')
    if (-not $r.Ok) { return $false }
    $top = (Resolve-Path -LiteralPath $r.Output -ErrorAction SilentlyContinue)
    $me  = (Resolve-Path -LiteralPath $Path)
    return ($null -ne $top) -and ($top.Path -eq $me.Path)
}

function Invoke-CloneRepo {
    param([string]$Name)
    $url = "$Base/$Name.git"
    Write-Host $Name -ForegroundColor White -NoNewline
    Write-Host ' (cloning)' -ForegroundColor DarkGray

    # git-lfs is a hard prerequisite here, not a nicety: the repo's
    # .gitattributes routes src/parser.c through the lfs filter, so git invokes
    # git-lfs during checkout and the clone dies mid-checkout without it.
    if (($LfsRepos -contains $Name) -and -not $HaveLfs) {
        Add-Failure $Name 'skipped - git-lfs is required to clone this repo'
        Write-Note "install git-lfs, run 'git lfs install', then re-run this script"
        return
    }

    if ((Invoke-Git @('clone', '--quiet', $url, $Name)).Ok) {
        Write-Ok "cloned from $url"
        return
    }

    # A failed clone can leave a partial directory behind (e.g. cloned but
    # checkout failed). Remove it so a re-run retries cleanly instead of
    # treating the wreckage as an existing repo.
    if (Test-Path -LiteralPath $Name) {
        Remove-Item -LiteralPath $Name -Recurse -Force -ErrorAction SilentlyContinue
        Write-Note 'removed partial clone'
    }
    Add-Failure $Name "clone failed: $url"
    if (-not $Https) { Write-Note 'no SSH key for GitHub? re-run with -Https' }
}

function Invoke-RefreshRepo {
    param([string]$Name)
    $br = Invoke-Git @('-C', $Name, 'rev-parse', '--abbrev-ref', 'HEAD')
    $branch = if ($br.Ok) { $br.Output } else { '?' }
    Write-Host $Name -ForegroundColor White -NoNewline
    Write-Host " (on $branch)" -ForegroundColor DarkGray

    if (-not (Invoke-Git @('-C', $Name, 'fetch', '--quiet', '--prune')).Ok) {
        Add-Failure $Name 'fetch failed'
        return
    }

    $status = Invoke-Git @('-C', $Name, 'status', '--porcelain')
    $dirty = if ($status.Ok -and $status.Output) { ' (working tree dirty)' } else { '' }

    $up = Invoke-Git @('-C', $Name, 'rev-parse', '--abbrev-ref', '@{u}')
    if (-not $up.Ok) {
        Write-Warn "no upstream for $branch - fetched only$dirty"
        return
    }
    $upstream = $up.Output

    $counts = Invoke-Git @('-C', $Name, 'rev-list', '--left-right', '--count', "$upstream...HEAD")
    $behind = 0; $ahead = 0
    if ($counts.Ok) {
        $parts = $counts.Output -split '\s+'
        if ($parts.Count -ge 2) { $behind = [int]$parts[0]; $ahead = [int]$parts[1] }
    }

    if ($behind -eq 0 -and $ahead -eq 0) {
        Write-Ok "up to date with $upstream$dirty"
        return
    }

    if ($Pull -and $behind -gt 0 -and $ahead -eq 0 -and -not $dirty) {
        if ((Invoke-Git @('-C', $Name, 'merge', '--quiet', '--ff-only', $upstream)).Ok) {
            Write-Ok "fast-forwarded $behind commit(s) from $upstream"
        } else {
            Add-Failure $Name 'fast-forward failed'
        }
        return
    }

    $msg = "$ahead ahead, $behind behind $upstream$dirty"
    if ($Pull) {
        Write-Warn "$msg - not fast-forwardable, left alone"
    } else {
        Write-Warn $msg
        if ($behind -gt 0) { Write-Note 'run with -Pull to fast-forward' }
    }
}

foreach ($name in $Repos) {
    if (-not (Test-Path -LiteralPath $name)) {
        Invoke-CloneRepo $name
    } elseif (-not (Test-Path -LiteralPath $name -PathType Container)) {
        Add-Failure $name 'exists but is not a directory'
    } elseif (Test-RepoRoot $name) {
        Invoke-RefreshRepo $name
    } else {
        Add-Failure $name 'directory exists but is not a Git repo - move it aside and re-run'
    }
    Write-Host ''
}

# --- summary --------------------------------------------------------------

if ($script:Failed.Count -gt 0) {
    Write-Err "problems with: $($script:Failed -join ' ')"
    exit 1
}

Write-Host 'Workspace ready.' -ForegroundColor Green
Write-Host 'Next: cd lyra; go test ./...' -ForegroundColor DarkGray
