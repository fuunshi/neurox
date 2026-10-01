#Requires -Version 5.1
#
# The whole pipeline, from one command -- on Windows.
#
#   .\neurox.ps1           what you can run
#   .\neurox.ps1 up        build and start everything, then say where it is
#
# This is the Windows counterpart of the Makefile in this directory: the same
# commands, the same order, the same output, because two entry points that drift
# apart are worse than one that is slightly awkward to type.
#
# `make.bat` beside this file forwards here, so `make up` still works from
# cmd.exe if that is the muscle memory you already have.
#
# **Why a script and not a Makefile.** GNU Make is not part of Windows, and the
# copy you can install is a second thing to get working before the first thing
# works. PowerShell is already on the machine, and everything the Makefile does
# -- generating secrets, probing services, deciding whether to install Docker --
# is a few lines here.
#
# **ASCII only, deliberately.** Windows PowerShell 5.1, the one that is already
# installed, reads a .ps1 with no byte-order mark as ANSI. An em dash typed on a
# Linux machine then arrives as mojibake in the help text. Nothing in this file
# is outside ASCII, so that cannot happen.
#
# Every command shells out to Docker Compose. There is no other entry point, so
# there is no second way to start the stack that could drift from this one.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help'
)

# $ErrorActionPreference is left alone on purpose. Setting it to 'Stop' makes a
# native command that writes to stderr a terminating error on Windows PowerShell
# 5.1 -- and `pg_isready` on a database that is not up yet, and docker whenever it
# has something to say, both do exactly that. Every probe in `health` would blow
# up instead of reporting "NOT READY". The one call that wants an exception
# (Invoke-WebRequest) asks for it by name.

# Invoke-WebRequest draws a progress bar per probe, and on 5.1 the bar alone can
# cost more than the request does. Nothing here is slow enough to need it.
$ProgressPreference = 'SilentlyContinue'

# The compose file, in one variable for the same reason the Makefile has one: so
# that no two commands can end up talking to different projects.
$ComposeFile = 'docker-compose.yml'

# ------------------------------------------------------------------ output --- #

function Write-Step {
    param([string]$Message)
    Write-Host '==> ' -NoNewline -ForegroundColor Green
    Write-Host $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host "warning: $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "error: $Message" -ForegroundColor Red
}

# ---------------------------------------------------------------- checking --- #

# `docker info` rather than `docker --version`: the CLI being on PATH says
# nothing about whether the daemon is running, and on Windows an installed
# Docker Desktop says nothing about whether it is *started*. Those are the two
# things that actually break `up`.
function Test-DockerDaemon {
    docker info *> $null
    return $LASTEXITCODE -eq 0
}

function Test-ComposePlugin {
    docker compose version *> $null
    return $LASTEXITCODE -eq 0
}

# `curl` is not used here. In PowerShell it is an alias for Invoke-WebRequest,
# and where it is not, it is the real curl -- so the same line means two
# different things depending on the machine. Invoke-WebRequest with an explicit
# timeout behaves the same on Windows PowerShell 5.1 and on 7.
#
# `-UseBasicParsing` is not optional: without it, 5.1 hands the response to the
# Internet Explorer engine, which fails on a machine where IE has never been
# opened. On 7 it is accepted and ignored.
function Test-Http {
    param(
        [string]$Url,
        [int]$TimeoutSec = 10
    )
    try {
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
    } catch {
        return $false
    }
}

function Assert-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Fail 'Docker is not installed (or not on PATH).'
        Write-Fail 'Run `.\neurox.ps1 docker` and it will offer to install Docker Desktop.'
        exit 1
    }
    if (-not (Test-DockerDaemon)) {
        # By far the most common state on Windows, and it is not a broken
        # install -- it is a closed application.
        Write-Fail 'Docker is installed but the daemon is not answering.'
        Write-Fail 'That means Docker Desktop is not running: open it from the Start menu, wait'
        Write-Fail 'for the whale to stop animating, and run this again.'
        exit 1
    }
    if (-not (Test-ComposePlugin)) {
        Write-Fail '`docker compose` is missing. Docker Desktop ships Compose v2, which is what this'
        Write-Fail 'script uses; the standalone `docker-compose` v1 binary is a different thing and'
        Write-Fail 'is not a substitute here.'
        exit 1
    }
}

# Every compose invocation goes through here: one place that knows the file, one
# place that asks whether Docker is usable, and one place that turns a failed
# command into a failed script.
#
# Make fails a target when a recipe line exits non-zero; PowerShell does not. A
# native command that failed just sets $LASTEXITCODE and carries on, so without
# the check below `down` could fail and the script would still report success.
#
# The readiness check is here rather than in each branch for a second reason:
# when Docker is missing, the error a first-time Windows user would otherwise
# meet is PowerShell's "The term 'docker' is not recognized" -- in red, with a
# stack trace pointing at a line of this file -- instead of the one that says to
# start Docker Desktop.
function Invoke-Compose {
    param([Parameter(Mandatory)][string[]]$Arguments)
    Assert-DockerReady
    docker compose -f $ComposeFile @Arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# `up` deliberately does not install Docker for you, the way `make up` does on
# Linux. Installing Docker Desktop means a winget download, a licence, an
# approval prompt and often a reboot -- not something to start from inside
# another command. `.\neurox.ps1 docker` is the one that does it, and this is
# what points you there.
function Invoke-DockerSetup {
    if ((Get-Command docker -ErrorAction SilentlyContinue) -and (Test-DockerDaemon)) {
        $version = (docker --version) -replace '^Docker version ', '' -replace ',.*$', ''
        Write-Step "Docker $version is installed and the daemon is running."

        if (-not (Test-ComposePlugin)) {
            Write-Warn 'The Compose v2 plugin is missing. Docker Desktop includes it; without it'
            Write-Warn 'nothing in this repository can run.'
            exit 1
        }

        Write-Step "Compose $(docker compose version --short) is available. Nothing to install."
        return
    }

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Warn 'Docker is installed but the daemon is not answering.'
        Write-Warn 'On Windows that is Docker Desktop not running, not a broken install. Open it'
        Write-Warn 'from the Start menu and wait for the whale to stop animating; the first start'
        Write-Warn 'also sets up the WSL2 backend, which can take a few minutes.'
        exit 1
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn 'Docker is not installed, and winget is not available to install it.'
        Write-Warn 'Get Docker Desktop from https://www.docker.com/products/docker-desktop/'
        Write-Warn 'and run this again.'
        exit 1
    }

    Write-Step 'Docker is not installed. Docker Desktop can be installed with winget.'
    Write-Host '  Docker Desktop is free for personal use and for small businesses; larger'
    Write-Host '  companies need a paid subscription. That is a licensing question rather than'
    Write-Host '  a technical one, and this script cannot answer it for you.'
    $reply = Read-Host 'Install Docker Desktop now? [y/N]'
    if ($reply -notmatch '^\s*(y|yes)\s*$') {
        Write-Host 'Cancelled. Install it yourself, then run this again.'
        exit 1
    }

    winget install --id Docker.DockerDesktop -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "winget exited $LASTEXITCODE, so nothing was installed."
        exit 1
    }

    Write-Step 'Docker Desktop installed.'
    # Same honesty as the shell script's "the docker group applies to new
    # sessions only": nothing here can claim the stack is ready to run, because
    # the freshly installed Docker has never been started.
    Write-Warn 'It has to be started once, and Windows may ask you to sign out or restart for'
    Write-Warn 'the WSL2 backend. Start it from the Start menu, wait for the whale, then run:'
    Write-Warn '    .\neurox.ps1 up'
    exit 0
}

# ------------------------------------------------------------------- .env ---- #

# `.env` holds JWT_SECRET and TOKEN_HASH_SECRET, which are committed nowhere and
# generated nowhere. Without them the API cannot sign a token -- it fails at
# container start with "auth.jwtSecret is required", which is a clear message
# but a confusing one to meet for the first time.
#
# Created from the template on first use, with the two secrets replaced by
# random ones. The file is gitignored, so this happens once per checkout and the
# generated secrets then persist across `up` cycles -- which matters, because
# regenerating them would invalidate every session on every restart.
function Initialize-EnvFile {
    $path = Join-Path $PSScriptRoot '.env'
    if (Test-Path -LiteralPath $path) { return }

    $template = Join-Path $PSScriptRoot 'neurox-backend\.env.template'
    if (-not (Test-Path -LiteralPath $template)) {
        Write-Fail 'neurox-backend\.env.template is missing; cannot build a .env'
        exit 1
    }

    Write-Step 'Creating .env from neurox-backend\.env.template with generated secrets'
    $text = [System.IO.File]::ReadAllText($template)

    # Normalized to LF and written as UTF-8 with no byte-order mark, whatever the
    # template arrived as. Git on Windows checks files out with CRLF by default,
    # and this file is then read by Compose and by Linux containers. A byte-order
    # mark or a stray carriage return inside a secret is not something to find
    # out about through an authentication bug.
    $text = $text -replace "`r`n", "`n"

    foreach ($key in 'JWT_SECRET', 'TOKEN_HASH_SECRET') {
        if ($text -notmatch "(?m)^$key=") {
            Write-Fail "$key is not in the template, so the generated .env would have none."
            Write-Fail 'Refusing to write a file the API cannot start from.'
            exit 1
        }
    }

    $text = [regex]::Replace($text, '(?m)^JWT_SECRET=.*$', "JWT_SECRET=$(New-HexSecret)")
    $text = [regex]::Replace($text, '(?m)^TOKEN_HASH_SECRET=.*$', "TOKEN_HASH_SECRET=$(New-HexSecret)")
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host '    Wrote .env -- edit it if you want real SMTP credentials.'
}

# 32 random bytes, hex encoded -- the same shape as `openssl rand -hex 32` on the
# shell side, so a .env generated on either platform looks the same. openssl is
# not on Windows, which is the whole reason this exists.
function New-HexSecret {
    $bytes = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    return $hex
}

# ------------------------------------------------------------------- up ----- #

function Start-Stack {
    Assert-DockerReady
    Initialize-EnvFile

    Write-Step 'Building and starting the stack -- the first run takes a few minutes'
    Invoke-Compose -Arguments @('up', '--build', '-d')

    Write-Host
    Show-Health
    Write-Host
    Write-Host '  Frontend     http://localhost:3001'
    Write-Host '  API          http://localhost:3232'
    Write-Host '  API docs     http://localhost:3232/api/docs'
    Write-Host '  NLP service  http://localhost:8000/health'
    Write-Host '  Mailpit      http://localhost:8026'
    Write-Host '  Postgres     localhost:55432  (user/pass/db: neurox)'
    Write-Host
    Write-Host '  Logs:  .\neurox.ps1 logs      Stop:  .\neurox.ps1 down'
}

# ------------------------------------------------------------------ clean --- #

function Remove-Everything {
    Write-Host "This deletes the database, the Redis data, the RabbitMQ data and the brain's corpus."
    $reply = Read-Host 'Continue? [y/N]'
    if ($reply -notmatch '^\s*(y|yes)\s*$') {
        Write-Host 'Cancelled.'
        exit 0
    }
    Invoke-Compose -Arguments @('down', '-v')
    Write-Host "Volumes removed. 'up' will start from an empty database."
}

# ------------------------------------------------------------------ tools --- #

# The demo account: admin@neurox.ai, with decks, review history, a streak and
# completed quizzes, for showing the product without first having to use it.
#
# **Deliberately not part of `up`.** It creates an account whose password is in
# the Makefile and in this file, and it wipes that account's data every time it
# runs. Both are fine on a laptop and neither belongs in a stack somebody else
# might be using.
function Initialize-DemoAccount {
    Invoke-Compose -Arguments @('exec', '-T', 'neurox-backend', 'node', 'dist/seeder/seed.js')
}

function Assert-Pnpm {
    if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
        Write-Fail 'pnpm is not on PATH.'
        Write-Fail 'Node 16.13 and later ship it: run `corepack enable pnpm` once, or'
        Write-Fail '`npm install -g pnpm`.'
        exit 1
    }
}

# ----------------------------------------------------------------- health --- #

# Probes each service the way its own client would, so a green line means the
# thing actually answers rather than that the container exists.
function Show-Probe {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Note = 'NOT READY'
    )
    Write-Host ('  {0,-24}' -f $Name) -NoNewline
    if ($Ok) { Write-Host 'ok' -ForegroundColor Green }
    else { Write-Host $Note -ForegroundColor Red }
}

function Show-Health {
    # Not through Invoke-Compose: this one wants each probe's exit code rather
    # than an exit on the first failure, so it checks Docker itself and then
    # calls compose directly.
    Assert-DockerReady

    docker compose -f $ComposeFile exec -T postgres pg_isready -U neurox -d neurox *> $null
    Show-Probe 'postgres' ($LASTEXITCODE -eq 0)

    docker compose -f $ComposeFile exec -T redis redis-cli ping *> $null
    Show-Probe 'redis' ($LASTEXITCODE -eq 0)

    docker compose -f $ComposeFile exec -T rabbitmq rabbitmq-diagnostics -q ping *> $null
    Show-Probe 'rabbitmq' ($LASTEXITCODE -eq 0)

    Show-Probe 'neurox-brain' (Test-Http 'http://localhost:8000/health') 'NOT READY (the model takes ~30s on first start)'
    Show-Probe 'neurox-backend' (Test-Http 'http://localhost:3232/health')
    Show-Probe 'neurox-web' (Test-Http 'http://localhost:3001/')
}

# ------------------------------------------------------------------- test --- #

# Unlike the Makefile's `test`, a real failure here is reported as one. The
# Makefile pipes stderr to /dev/null and prints "(no pytest suite yet)" for
# anything that goes wrong, which also swallows a failing test; this says what
# is actually missing (a venv nobody has created yet) and fails on the rest.
function Invoke-Tests {
    $failed = $false

    Write-Host '== neurox-brain =='
    $python = Join-Path $PSScriptRoot 'neurox-brain\.venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $python) {
        Push-Location (Join-Path $PSScriptRoot 'neurox-brain')
        & $python -m pytest -q
        if ($LASTEXITCODE -ne 0) { $failed = $true }
        Pop-Location
    } else {
        Write-Host '  skipped: no virtualenv at neurox-brain\.venv\Scripts\python.exe'
    }

    Assert-Pnpm
    foreach ($project in 'neurox-backend', 'neurox-web') {
        Write-Host "== $project =="
        Push-Location (Join-Path $PSScriptRoot $project)
        & pnpm test
        if ($LASTEXITCODE -ne 0) { $failed = $true }
        Pop-Location
    }

    if ($failed) { exit 1 }
}

function Invoke-Checks {
    Assert-Pnpm
    $failed = $false

    Write-Host '== neurox-backend =='
    Push-Location (Join-Path $PSScriptRoot 'neurox-backend')
    & pnpm lint
    if ($LASTEXITCODE -ne 0) { $failed = $true }
    # `pnpm exec` rather than the Makefile's `npx`: it uses the copy of tsc that
    # is already in node_modules, and unlike npx it will never decide to fetch
    # one over the network mid-check.
    & pnpm exec tsc --noEmit -p tsconfig.json
    if ($LASTEXITCODE -ne 0) { $failed = $true }
    Pop-Location

    Write-Host '== neurox-web =='
    Push-Location (Join-Path $PSScriptRoot 'neurox-web')
    & pnpm lint
    if ($LASTEXITCODE -ne 0) { $failed = $true }
    & pnpm typecheck
    if ($LASTEXITCODE -ne 0) { $failed = $true }
    Pop-Location

    if ($failed) { exit 1 }
}

# ------------------------------------------------------------------- help --- #

function Show-Help {
    $help = @'
neurox -- the whole pipeline, locally (Windows)

  .\neurox.ps1 up             Build and start everything (first run takes a few minutes)
  .\neurox.ps1 down           Stop everything, keeping your data
  .\neurox.ps1 logs           Follow the logs from every service
  .\neurox.ps1 ps             What is running
  .\neurox.ps1 health         Probe every service and say whether it answered
  .\neurox.ps1 clean          Stop and DELETE all data (database, redis, corpus)

  .\neurox.ps1 docker         Install Docker Desktop if it is missing
  .\neurox.ps1 migrate        Apply pending database migrations
  .\neurox.ps1 seed           Install the syllabus (idempotent)
  .\neurox.ps1 seed:demo      Seed the demo account (admin@neurox.ai) -- for demos
  .\neurox.ps1 psql           Open a psql shell on the running database
  .\neurox.ps1 shell-backend  A shell inside the API container
  .\neurox.ps1 shell-brain    A shell inside the NLP container
  .\neurox.ps1 test           Run the test suites for all three projects
  .\neurox.ps1 check          Typecheck and lint the two Node projects

make.bat in this directory forwards here, so `make up` works too.

If PowerShell refuses to run this file, the policy is the reason. Either:
    powershell -ExecutionPolicy Bypass -File .\neurox.ps1 up
or, once, in a shell you own:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
'@
    Write-Host $help
}

# ------------------------------------------------------------------ dispatch - #

# Everything below assumes it is being run from the repository root: Compose
# resolves `-f docker-compose.yml` and every build context against the current
# directory. Rather than require a `cd` first, move there and put the caller
# back afterwards. The restore is not decoration -- the current location is a
# property of the session, not of the script, so without it `.\neurox.ps1` run
# from somewhere else would quietly leave that shell sitting in this directory.
$origin = (Get-Location).Path
Set-Location -LiteralPath $PSScriptRoot
try {
    switch ($Command) {
        'help'   { Show-Help }
        'docker' { Invoke-DockerSetup }

        'up'      { Start-Stack }
        'down'    { Invoke-Compose -Arguments @('down') }
        'restart' { Invoke-Compose -Arguments @('restart') }
        'stop'    { Invoke-Compose -Arguments @('stop') }
        'start'   { Invoke-Compose -Arguments @('start') }
        'logs'    { Invoke-Compose -Arguments @('logs', '-f', '--tail=100') }
        'ps'      { Invoke-Compose -Arguments @('ps') }
        'clean'   { Remove-Everything }
        'health'  { Show-Health }

        # `-T` on the seed and migration commands because they are not
        # interactive: without it, Compose asks for a terminal it may not have
        # and fails with "the input device is not a TTY" when this is run from a
        # task runner or a CI job. psql and the shells keep their TTY, which is
        # the point of them.
        'migrate' { Invoke-Compose -Arguments @('exec', '-T', 'neurox-backend', 'node_modules/.bin/mikro-orm', 'migration:up') }
        'seed'    { Invoke-Compose -Arguments @('exec', '-T', 'neurox-backend', 'node', 'dist/seeder/curriculum.js') }

        # Two spellings: the Makefile's `seed:demo`, and `seed-demo` for anyone
        # who would rather not type a colon.
        'seed:demo' { Initialize-DemoAccount }
        'seed-demo' { Initialize-DemoAccount }

        'psql'          { Invoke-Compose -Arguments @('exec', 'postgres', 'psql', '-U', 'neurox', '-d', 'neurox') }
        'shell-backend' { Invoke-Compose -Arguments @('exec', 'neurox-backend', 'sh') }
        'shell-brain'   { Invoke-Compose -Arguments @('exec', 'neurox-brain', 'sh') }

        'test'  { Invoke-Tests }
        'check' { Invoke-Checks }

        default {
            Write-Fail "no such command: $Command"
            Write-Host
            Show-Help
            exit 1
        }
    }
} finally {
    Set-Location -LiteralPath $origin
}

exit 0
