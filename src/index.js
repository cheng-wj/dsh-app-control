/**
 * dsh-app-control — restart / update / inspect the DeepSeek Harness desktop app
 * from inside a DSH session, exposed as model-facing tools.
 *
 * WHY THIS PLUGIN EXISTS
 * ----------------------
 * Restarting DSH from inside a DSH session is a trap with four independent
 * failure modes, every one of which was hit for real while building this:
 *
 *  1. `taskkill /T` kills the caller. If the scheduler is a child of the DSH
 *     process tree it destroys itself half way through, and DSH ends up
 *     closed with nothing left to reopen it.
 *
 *  2. `start "" "app.exe"` is not detached. The relaunched GUI inherits the
 *     cmd console, so closing that console sends CTRL_CLOSE_EVENT and
 *     Electron exits — the app dies when the helper window is closed.
 *
 *  3. A .bat file MUST be CRLF. With LF-only endings cmd.exe's byte-offset
 *     bookkeeping for `call :LABEL` goes wrong and the script silently stops
 *     part way: it prints "[1/2] all DSH processes are gone" and never
 *     reaches "[2/2] starting DSH". The app is closed and never reopened,
 *     with no error printed anywhere.
 *
 *  4. cmd.exe treats '=' as an argument separator, so `--delay=5` arrives at
 *     the batch as TWO arguments, "--delay" and "5". A parser that only looks
 *     for the literal "--delay=" never matches and the option is silently
 *     ignored — or, worse, in update mode the number is installed as if it
 *     were a package name.
 *
 * Fixes: (1)+(2) launch through WMI (`Win32_Process.Create`), which parents
 * the new process to WmiPrvSE.exe — no shared console, survives `taskkill /T`.
 * (3) the CRLF guard in ensureCrlf(). (4) one shared option loop in the batch
 * file, plus --delay/--profile always passed explicitly on the command line
 * because a WMI-created process does not inherit our environment.
 *
 * WHAT THIS PLUGIN DELIBERATELY DOES NOT DO
 * -----------------------------------------
 * It does not reimplement the shutdown in Node. Doing the kill from the plugin
 * would put us straight back into failure mode 1: the plugin runs inside the
 * very process tree being killed. The proven PowerShell/batch scheduler ships
 * in assets/ and this module only stages and drives it.
 */
import { spawn } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const ASSETS = join(PACKAGE_ROOT, 'assets')

/**
 * DSH home. The plugin's working copy of the scripts lives here rather than in
 * node_modules, which may be read-only, replaced on update, or cleaned.
 */
const DSH_HOME = process.env.DSH_HOME || join(homedir(), '.dsh')

const WORK_DIR = join(DSH_HOME, 'dsh-app-control')
const SCRIPT_DIR = join(WORK_DIR, 'scripts')
const LOG_DIR = join(WORK_DIR, 'logs')

/** Files copied out of assets/ into SCRIPT_DIR before every run. */
const STAGED_FILES = ['dsh-tools.bat', 'launch-app.ps1', 'launch-detached.ps1', 'run-visible.ps1', 'list-plugins.js']

export const name = 'dsh-app-control'

/** `tools` is the only hard requirement. */
export const inject = ['tools']

/**
 * The row Config surface, when this deployment can supply a schema.
 *
 * WHY THIS IS RESOLVED LAZILY AND LEFT OPTIONAL
 * ---------------------------------------------
 * `@deepseek-ai/schemastery` is a PEER: plain Node cannot resolve it from this
 * package — only the host's own resolution supplies it. A STATIC import would
 * fail on any deployment whose resolution lacks it, and the Loader treats a
 * failed plugin import as a NON-FATAL SKIP (it logs one error and creates no
 * fiber). The row then silently never mounts while every other plugin keeps
 * working: no stacked scripts, no tools, no visible symptom.
 *
 * This is not hypothetical. The first version of this file exported `Config` as
 * a PLAIN OBJECT. cordis treats a row Config as a schema and CALLS it, so that
 * object was invoked as a function, threw during mount, and the row was skipped
 * — `apply()` never ran once. Diagnosed by importing the module and checking
 * what cordis would do with the export.
 *
 * So: resolve the module if we can, and export NO Config at all when we cannot
 * (cordis then passes the row's raw config through untouched). The tools do not
 * depend on the schema, so a missing peer costs only the settings surface.
 */
let Schema = null
try {
    const mod = await import('@deepseek-ai/schemastery')
    Schema = mod.default ?? mod.z ?? mod
} catch {
    Schema = null
}

/**
 * Second chance at the schema peer, resolved from the PROFILE directories.
 *
 * A `link:` install points node_modules/dsh-app-control at the source directory, so
 * the bare specifier above resolves against the SOURCE tree rather than the
 * profile — and the peer is hoisted into the profile, not the source. Resolving
 * from each profile directory recovers the settings surface for linked installs
 * without reintroducing the static-import hazard: any failure here is still just
 * a missing Config.
 */
if (Schema === null) {
    try {
        const { createRequire } = await import('node:module')
        const { readdirSync: readdir } = await import('node:fs')
        const profiles = join(DSH_HOME, 'profiles')
        for (const entry of readdir(profiles)) {
            try {
                const req = createRequire(join(profiles, entry, 'noop.cjs'))
                const mod = req('@deepseek-ai/schemastery')
                Schema = mod.default ?? mod.z ?? mod
                break
            } catch { /* this profile does not have it */ }
        }
    } catch { /* no profiles dir — fall through with no Config */ }
}

/**
 * `defineTool`, the harness-side stamp for a tool definition — OPTIONAL.
 *
 * Resolved at module scope because `apply()` is synchronous. Absent is fine: a
 * plain object is a complete definition and the registry validates it against
 * the declared schema either way. Resolving it from the profile directories too
 * is what makes a `link:` install behave like a normal one.
 */
let defineTool = null
try {
    const mod = await import('@deepseek-ai/dsh-tools')
    defineTool = mod.defineTool ?? null
} catch {
    try {
        const { createRequire } = await import('node:module')
        const { readdirSync: readdir } = await import('node:fs')
        const profiles = join(DSH_HOME, 'profiles')
        for (const entry of readdir(profiles)) {
            try {
                const req = createRequire(join(profiles, entry, 'noop.cjs'))
                defineTool = req('@deepseek-ai/dsh-tools').defineTool ?? null
                if (defineTool) break
            } catch { /* this profile does not have it */ }
        }
    } catch { /* no profiles dir — plain objects will be used */ }
}

export const Config = typeof Schema?.object === 'function'
    ? Schema.object({
        /** Seconds between the countdown starting and DSH being closed. */
        delaySeconds: Schema.number().default(10).description('Seconds to wait before closing DSH, so the user can still abort.'),
        /** Default profile for the update tool. */
        profile: Schema.string().default('desktop').description('DSH profile that dsh_update targets by default.'),
    })
    : undefined

/**
 * Count CR and LF bytes.
 *
 * Raw bytes, not text: normalising line endings on read is exactly what hides
 * the bug this guard exists to catch. POSIX tools are no help either —
 * `awk '/\r$/'` matches a literal 'r', not a carriage return, so it happily
 * reports "no CR" on a perfectly good CRLF file.
 */
function crlfCounts(file) {
    const buf = readFileSync(file)
    let cr = 0
    let lf = 0
    for (const byte of buf) {
        if (byte === 13) cr++
        else if (byte === 10) lf++
    }
    return { cr, lf }
}

/**
 * Repair a file to CRLF if it is not already.
 *
 * Repairs rather than refuses: a stray LF copy is still valid source, and
 * failing here would leave the user unable to restart the app at all — the
 * exact situation the guard is meant to prevent.
 */
function ensureCrlf(file) {
    if (!existsSync(file)) return
    const { cr, lf } = crlfCounts(file)
    if (lf === 0 || cr === lf) return
    const text = readFileSync(file, 'latin1').replace(/\r\n/g, '\n').replace(/\n/g, '\r\n')
    writeFileSync(file, text, 'latin1')
}

/**
 * Copy the shipped scripts into the work dir and enforce CRLF.
 *
 * Staging keeps node_modules untouched and means a plugin update refreshes the
 * scripts while logs in the sibling logs/ directory survive.
 */
function stageScripts() {
    mkdirSync(SCRIPT_DIR, { recursive: true })
    mkdirSync(LOG_DIR, { recursive: true })
    for (const file of STAGED_FILES) {
        const from = join(ASSETS, file)
        if (!existsSync(from)) continue
        const to = join(SCRIPT_DIR, file)
        copyFileSync(from, to)
        // Only the .bat needs CRLF; the .ps1 files are fine either way.
        if (file.endsWith('.bat') || file.endsWith('.cmd')) ensureCrlf(to)
    }
}

/** Run a PowerShell script, capturing both streams. */
function runPowerShell(scriptPath, args, timeoutMs) {
    return new Promise((resolvePromise) => {
        const child = spawn('powershell.exe', [
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', scriptPath,
            ...args,
        ], { windowsHide: true })

        let stdout = ''
        let stderr = ''
        let settled = false
        const finish = (value) => {
            if (settled) return
            settled = true
            clearTimeout(timer)
            resolvePromise(value)
        }
        const timer = setTimeout(() => {
            try { child.kill() } catch { /* already gone */ }
            finish({ code: null, stdout, stderr, timedOut: true })
        }, timeoutMs)

        child.stdout?.on('data', (d) => { stdout += String(d) })
        child.stderr?.on('data', (d) => { stderr += String(d) })
        child.on('error', (err) => finish({ code: null, stdout, stderr: stderr + String(err), timedOut: false }))
        child.on('close', (code) => finish({ code, stdout, stderr, timedOut: false }))
    })
}

/** Newest log file in LOG_DIR, or '' when there is none. */
function newestLog() {
    try {
        const files = readdirSync(LOG_DIR)
            .filter((f) => f.endsWith('.log'))
            .map((f) => join(LOG_DIR, f))
            .filter((f) => statSync(f).isFile())
        if (files.length === 0) return ''
        files.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)
        return files[0]
    }
    catch {
        return ''
    }
}

export function apply(ctx, config = {}) {
    const delaySeconds = Number.isFinite(config?.delaySeconds) ? config.delaySeconds : 10
    const defaultProfile = typeof config?.profile === 'string' && config.profile ? config.profile : 'desktop'

    // Apply-time tracing. Everything below runs inside the HOST process, where
    // a thrown error is invisible: the row already mounted, so the Loader has
    // nothing to report, and the only symptom is tools that never appear. Every
    // step writes to the log dir so a silent failure becomes diagnosable.
    const trace = []
    const log = (msg) => {
        trace.push(`${new Date().toISOString()} ${msg}`)
        try {
            mkdirSync(LOG_DIR, { recursive: true })
            writeFileSync(join(LOG_DIR, 'apply-trace.log'), trace.join('\n') + '\n', 'utf8')
        } catch { /* tracing must never break apply */ }
    }
    log(`apply() entered; config=${JSON.stringify(config)}`)
    log(`ctx keys=${Object.keys(ctx).join(',')} tools=${typeof ctx.tools} register=${typeof ctx.tools?.register}`)

    // Stage up front so the first call is not the one that discovers a missing
    // script; also re-stage per call, since a reinstall can wipe the work dir.
    const ensureStaged = () => {
        stageScripts()
        const script = join(SCRIPT_DIR, 'launch-detached.ps1')
        if (!existsSync(script)) {
            throw new Error(`dsh-app-control: scheduler missing at ${script} — the plugin assets were not staged`)
        }
        return script
    }

    try { stageScripts(); log('stageScripts OK') } catch (e) { log(`stageScripts FAILED: ${e?.message}`) }

    /** Drive the scheduler and normalise its outcome into a canonical value. */
    const launch = async (mode, extraArgs, delay) => {
        const script = ensureStaged()
        const args = [mode, '--delay', String(delay), ...extraArgs]
        // The scheduler only spawns a detached process and returns, so this
        // timeout bounds the hand-off, not the restart itself.
        const result = await runPowerShell(script, args, 30_000)

        if (result.code !== 0) {
            const log = newestLog()
            const detail = result.stderr.trim() || result.stdout.trim()
                || (log ? readFileSync(log, 'utf8').trim() : '')
            throw new Error(`dsh-app-control: scheduler exited with code ${result.code}${detail ? `\n${detail}` : ''}`)
        }

        return {
            mode,
            delaySeconds: delay,
            logFile: newestLog(),
            schedulerOutput: result.stdout.trim(),
        }
    }

    /** Every tool agrees on this output shape, so one renderer serves them all. */
    const output = (summary) => ({
        schema: {
            type: 'object',
            additionalProperties: false,
            properties: {
                mode: { type: 'string', required: true },
                delaySeconds: { type: 'number', required: true },
                logFile: { type: 'string', required: true },
                schedulerOutput: { type: 'string', required: true },
            },
        },
        render: (_args, value) => [{
            type: 'text',
            text: summary(value),
        }],
    })

    log(`defineTool: ${typeof defineTool}`)
    const define = (spec) => (typeof defineTool === 'function' ? defineTool(spec) : spec)

    const tools = [
        define({
            name: 'dsh_restart',
            description:
                'Restart the DeepSeek Harness desktop app cleanly, including the window this session is running in. '
                + 'Closes every DSH process, waits for them to exit, then relaunches through WMI so the new app is not '
                + 'attached to any console and survives the helper window being closed. '
                + 'The restart runs detached with a countdown, so this call returns long before the app actually goes '
                + 'away. Warn the user and let them save work BEFORE calling it — this interrupts the conversation. '
                + 'Use after installing or updating a plugin, or when the app is misbehaving.',
            parameters: {
                delaySeconds: {
                    type: 'number',
                    description: 'Seconds to wait before closing DSH, so the user can still abort. Defaults to the plugin config. Use 0 to restart immediately.',
                },
            },
            output: output((v) => `DSH will restart in ${v.delaySeconds}s and reopen automatically. Progress: ${v.logFile || '(log unavailable)'}`),
            execute: async (args) => {
                const delay = Number.isFinite(args?.delaySeconds) ? args.delaySeconds : delaySeconds
                return launch('restart', [], delay)
            },
        }),
        define({
            name: 'dsh_update',
            description:
                'Install one or more DSH plugin versions and then restart the app. Runs '
                + '`dsh plugin --profile <profile> add <pkg>@<version>` for each package from a process detached from '
                + 'the DSH tree, then restarts. This is the fix for the dshmarket in-app update bug that reports '
                + '{"code":"already-installed"} and leaves the version unchanged. '
                + 'Confirm the exact package names and versions with the user first, then warn them the app will reopen.',
            parameters: {
                packages: {
                    type: 'string',
                    required: true,
                    description: 'Space-separated package@version specs, e.g. "dshmarket@1.66.44 dsh-whale-widget@0.4.3".',
                },
                profile: {
                    type: 'string',
                    description: 'DSH profile to update. Defaults to the plugin config (desktop).',
                },
                delaySeconds: {
                    type: 'number',
                    description: 'Seconds to wait before closing DSH. Defaults to the plugin config.',
                },
            },
            output: output((v) => `Updating ${v.schedulerOutput || v.mode} and restarting DSH. Progress: ${v.logFile || '(log unavailable)'}`),
            execute: async (args) => {
                const spec = String(args?.packages ?? '').trim()
                if (!spec) throw new Error('dsh-app-control: packages is required')
                const profile = String(args?.profile ?? defaultProfile).trim() || defaultProfile
                const delay = Number.isFinite(args?.delaySeconds) ? args.delaySeconds : delaySeconds
                const packages = spec.split(/\s+/)
                const value = await launch('update', ['--profile', profile, ...packages], delay)
                return { ...value, schedulerOutput: packages.join(' ') }
            },
        }),
        define({
            name: 'dsh_status',
            description:
                'Report the running DeepSeek Harness processes, the memory-bridge python process, and the installed '
                + 'plugin versions checked against the latest published ones. '
                + 'Read-only and safe to call at any time: it never closes or restarts anything. '
                + 'Use it to diagnose a plugin that is not loading, or to check whether updates are available.',
            parameters: {},
            output: {
                schema: {
                    type: 'object',
                    additionalProperties: false,
                    properties: {
                        running: { type: 'boolean', required: true },
                        processCount: { type: 'number', required: true },
                        report: { type: 'string', required: true },
                    },
                },
                render: (_args, value) => [{ type: 'text', text: value.report }],
            },
            execute: async () => {
                const script = ensureStaged()
                const result = await runPowerShell(script, ['status'], 60_000)

                // The scheduler prefixes its own launch banner and a verbose log
                // path before the actual status table. Strip all of it so the
                // model receives the report itself rather than our plumbing.
                let report = (result.stdout || result.stderr).trim()
                const marker = report.indexOf('--- detached output ---')
                if (marker !== -1) report = report.slice(marker + '--- detached output ---'.length)
                report = report.trim()

                if (!report) {
                    throw new Error('dsh-app-control: status produced no output; the scheduler may have failed to start')
                }
                // Count DATA ROWS of the tasklist table, not raw name matches:
                // the exe name also appears in the header and in the echoed
                // filter line, so a plain match over-counts.
                const processCount = report
                    .split('\n')
                    .filter((line) => /^\s*DeepSeek Harness\.exe\s+\d+\s/.test(line))
                    .length
                return { running: processCount > 0, processCount, report }
            },
        }),
    ]

    // Registration is wrapped because a throw here is INVISIBLE in the app: the
    // row has already mounted by this point, so the Loader reports nothing, and
    // the only symptom is tools that never show up. Persisting the stack to the
    // log dir turns that silent failure into something diagnosable.
    log(`registering ${tools.length} tools: ${tools.map((t) => t.name).join(', ')}`)
    const disposers = []
    try {
        for (const tool of tools) {
            log(`registering ${tool.name} ...`)
            const dispose = ctx.tools.register(tool)
            log(`registered ${tool.name}; disposer=${typeof dispose}`)
            if (typeof dispose === 'function') disposers.push(dispose)
        }
        log(`all tools registered; ${disposers.length} disposers`)
        ctx.logger?.info?.(`dsh-app-control: registered ${tools.map((t) => t.name).join(', ')}`)
    } catch (error) {
        log(`REGISTER THREW: ${error?.stack ?? String(error)}`)
        try {
            mkdirSync(LOG_DIR, { recursive: true })
            writeFileSync(
                join(LOG_DIR, 'apply-error.log'),
                `${new Date().toISOString()}\n${error?.stack ?? String(error)}\n`,
                'utf8',
            )
        } catch { /* nothing more we can do */ }
        ctx.logger?.error?.(`dsh-app-control: tool registration failed: ${error?.message ?? error}`)
    }

    // Hand the unregister functions to the plugin scope so a reload or update
    // disposes the tools instead of leaving stale registrations behind.
    if (typeof ctx.effect === 'function') {
        ctx.effect(() => () => {
            for (const dispose of disposers) {
                try { dispose() } catch { /* scope already gone */ }
            }
        })
    }
}
