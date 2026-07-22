# installed by herdr
# managed by herdr; reinstalling or updating the integration overwrites this file.
# add custom hooks beside this file instead of editing it.
# HERDR_INTEGRATION_ID=claude
# HERDR_INTEGRATION_VERSION=9
param([string]$Action = "")
if ($Action -ne "session" -and $Action -ne "title") { exit 0 }
if ($env:HERDR_ENV -ne "1") { exit 0 }
if ([string]::IsNullOrWhiteSpace($env:HERDR_PANE_ID)) { exit 0 }

$inputText = [Console]::In.ReadToEnd()
try {
    $payload = if ([string]::IsNullOrWhiteSpace($inputText)) { $null } else { $inputText | ConvertFrom-Json }
} catch {
    exit 0
}
if (-not [string]::IsNullOrWhiteSpace($payload.agent_id)) { exit 0 }
if ($payload.hook_event_name -eq "SubagentStop") { exit 0 }

function Summarize-Title([string]$Prompt) {
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $null }
    $text = $null
    foreach ($raw in ($Prompt -split "`r?`n")) {
        $line = ($raw -replace "\s+", " ").Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith("#") -or $line.StartsWith("//") -or $line.StartsWith("```")) { continue }
        $text = $line
        break
    }
    if ($null -eq $text) { $text = ($Prompt -replace "\s+", " ").Trim() }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text = [regex]::Replace($text, '^/[A-Za-z0-9_-]+\s+', '')
    $text = ($text -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $maxLen = 72
    if ($text.Length -le $maxLen) { return $text }
    $slice = $text.Substring(0, $maxLen - 1)
    $cut = [Math]::Max($slice.LastIndexOf(" "), [Math]::Max($slice.LastIndexOf("/"), $slice.LastIndexOf("-")))
    $base = if ($cut -ge 24) { $slice.Substring(0, $cut) } else { $slice }
    return ($base.TrimEnd() + [char]0x2026)
}


function Get-TitleStatePath([string]$SessionKey) {
    $base = $env:HERDR_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:XDG_RUNTIME_DIR }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TMPDIR }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [System.IO.Path]::GetTempPath() }
    $safePane = (($env:HERDR_PANE_ID -replace '[^A-Za-z0-9._-]+', '_') + '')
    if ($safePane.Length -gt 80) { $safePane = $safePane.Substring(0, 80) }
    $safeSession = if ([string]::IsNullOrWhiteSpace($SessionKey)) { 'unknown' } else { ($SessionKey -replace '[^A-Za-z0-9._-]+', '_') }
    if ($safeSession.Length -gt 80) { $safeSession = $safeSession.Substring(0, 80) }
    $directory = Join-Path $base 'herdr-integration-title-state'
    try {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    } catch {
        return $null
    }
    return (Join-Path $directory ($safePane + '__' + $safeSession + '.flag'))
}
function Test-HeuristicTitleReported([string]$SessionKey) {
    $path = Get-TitleStatePath $SessionKey
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    return (Test-Path -LiteralPath $path)
}
function Set-HeuristicTitleReported([string]$SessionKey) {
    $path = Get-TitleStatePath $SessionKey
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try { Set-Content -LiteralPath $path -Value '1' -Encoding ascii } catch {}
}
function Clear-HeuristicTitleState([string]$SessionKey) {
    $path = Get-TitleStatePath $SessionKey
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch {}
}

$seq = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
try {
    if ($Action -eq "session") {
        $sessionId = $payload.session_id
        if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }
        $args = @(
            "pane", "report-agent-session", $env:HERDR_PANE_ID,
            "--source", "herdr:claude",
            "--agent", "claude",
            "--seq", "$seq",
            "--agent-session-id", "$sessionId"
        )
        if ($payload.transcript_path -is [string] -and -not [string]::IsNullOrWhiteSpace($payload.transcript_path)) {
            $args += @("--agent-session-path", "$($payload.transcript_path)")
        }
        if ($payload.hook_event_name -eq "SessionStart" -and $payload.source -is [string] -and -not [string]::IsNullOrWhiteSpace($payload.source)) {
            $args += @("--session-start-source", "$($payload.source)")
        }
        & herdr @args 2>$null | Out-Null
        if ($payload.hook_event_name -eq "SessionStart") {
            $clearArgs = @(
                "pane", "report-metadata", $env:HERDR_PANE_ID,
                "--source", "herdr:claude",
                "--agent", "claude",
                "--seq", "$($seq + 1)",
                "--clear-title",
                "--agent-session-id", "$sessionId"
            )
            if ($payload.transcript_path -is [string] -and -not [string]::IsNullOrWhiteSpace($payload.transcript_path)) {
                $clearArgs += @("--agent-session-path", "$($payload.transcript_path)")
            }
            & herdr @clearArgs 2>$null | Out-Null
        }
    } elseif ($Action -eq "title") {
        if ($payload.hook_event_name -ne "UserPromptSubmit") { exit 0 }
        $sessionId = $payload.session_id
        # Once per session only — prefer existing harness/chat names over later prompts.
        if (Test-HeuristicTitleReported ([string]$sessionId)) { exit 0 }
        $title = Summarize-Title ([string]$payload.prompt)
        if ([string]::IsNullOrWhiteSpace($title)) { exit 0 }
        $args = @(
            "pane", "report-metadata", $env:HERDR_PANE_ID,
            "--source", "herdr:claude",
            "--agent", "claude",
            "--seq", "$seq",
            "--title", "$title"
        )
        if ($payload.session_id -is [string] -and -not [string]::IsNullOrWhiteSpace($payload.session_id)) {
            $args += @("--agent-session-id", "$($payload.session_id)")
        }
        if ($payload.transcript_path -is [string] -and -not [string]::IsNullOrWhiteSpace($payload.transcript_path)) {
            $args += @("--agent-session-path", "$($payload.transcript_path)")
        }
        & herdr @args 2>$null | Out-Null
    }
} catch {
}
