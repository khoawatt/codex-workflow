#!/usr/bin/env node
// Shared helper: load bridge credentials (email + password) from a per-bridge
// `.env` file and/or process environment, without ever logging secret values.
//
// Layout (created by install.sh, never committed):
//   ~/.config/opencode/chatgpt-bridge/.env   -> CHATGPT_EMAIL / CHATGPT_PASSWORD
//   ~/.config/opencode/gemini-bridge/.env    -> GEMINI_EMAIL  / GEMINI_PASSWORD
//
// Precedence: process.env wins over the `.env` file (useful for CI containers).
// A custom file path can be forced via CHATGPT_ENV_FILE / GEMINI_ENV_FILE.
// A custom bridge dir (tests / portable installs) via CHATGPT_BRIDGE_DIR /
// GEMINI_BRIDGE_DIR is honoured by resolveBridgeDir().
import { readFileSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'

export function parseDotEnv(text) {
  const out = {}
  for (const rawLine of String(text || '').split('\n')) {
    const line = rawLine.trim()
    if (!line || line.startsWith('#')) continue
    // Allow `export KEY=VALUE` (common in shell-exported .env files).
    const body = line.startsWith('export ') ? line.slice(7).trim() : line
    const eq = body.indexOf('=')
    if (eq <= 0) continue
    const key = body.slice(0, eq).trim()
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue
    const raw = body.slice(eq + 1).trim()
    let value
    if (raw[0] === '"' || raw[0] === "'") {
      // Quoted value: take up to the matching close quote so that
      // `KEY="p#ss word" # comment` keeps the inner # but drops the comment.
      const quote = raw[0]
      let end = -1
      for (let i = 1; i < raw.length; i++) {
        if (raw[i] === quote && raw[i - 1] !== '\\') { end = i; break }
      }
      if (end > 0) {
        value = raw.slice(1, end)
        if (quote === '"') {
          value = value.replace(/\\n/g, '\n').replace(/\\r/g, '\r').replace(/\\t/g, '\t').replace(/\\"/g, '"').replace(/\\\\/g, '\\')
        }
      } else {
        value = raw.slice(1)
      }
    } else {
      // Unquoted: strip inline ` # comment`.
      const hashIdx = raw.indexOf(' #')
      value = (hashIdx >= 0 ? raw.slice(0, hashIdx) : raw).trim()
    }
    out[key] = value
  }
  return out
}

export function loadDotEnvFile(path) {
  try {
    if (!path || !existsSync(path)) return {}
    return parseDotEnv(readFileSync(path, 'utf8'))
  } catch {
    return {}
  }
}

export function resolveBridgeDir(defaultDir, overrideEnvName) {
  const override = overrideEnvName ? (process.env[overrideEnvName] || '').trim() : ''
  return override || defaultDir
}

export function maskEmail(email) {
  const value = String(email || '')
  const at = value.indexOf('@')
  if (at <= 0) return value ? '***' : '(missing)'
  const local = value.slice(0, at)
  const domain = value.slice(at + 1)
  const head = local.slice(0, 2)
  return `${head}***@${domain}`
}

function firstPresent(keys, env, fileVals) {
  for (const key of keys) {
    const fromEnv = (env[key] || '').trim()
    if (fromEnv) return { value: fromEnv, key, source: 'env' }
  }
  for (const key of keys) {
    const fromFile = String(fileVals[key] ?? '').trim()
    if (fromFile) return { value: fromFile, key, source: 'file' }
  }
  return { value: '', key: keys[0] || '', source: 'none' }
}

// Load { email, password } for one bridge.
//   bridgeDir: absolute bridge dir (already resolved via resolveBridgeDir)
//   envFileVar: e.g. 'CHATGPT_ENV_FILE' — when set, overrides `<bridgeDir>/.env`
//   emailKeys / passwordKeys: ordered aliases, first hit wins (env > file)
export function loadBridgeCreds({ bridgeDir, envFileVar, emailKeys, passwordKeys }) {
  const customPath = envFileVar ? (process.env[envFileVar] || '').trim() : ''
  const envPath = customPath || join(bridgeDir, '.env')
  const fileExists = existsSync(envPath)
  const fileVals = loadDotEnvFile(envPath)
  const email = firstPresent(emailKeys, process.env, fileVals)
  const password = firstPresent(passwordKeys, process.env, fileVals)

  const missing = []
  if (!email.value) missing.push(emailKeys[0])
  if (!password.value) missing.push(passwordKeys[0])

  const warnings = []
  if (fileExists) {
    try {
      const mode = statSync(envPath).mode & 0o777
      if (mode & 0o077) {
        warnings.push(`insecure permissions ${mode.toString(8)} on ${envPath} — run: chmod 600 "${envPath}"`)
      }
    } catch {}
  }

  return {
    email: email.value,
    password: password.value,
    emailKey: email.key,
    passwordKey: password.key,
    emailSource: email.source,
    passwordSource: password.source,
    envPath,
    fileExists,
    configured: missing.length === 0,
    missing,
    warnings,
  }
}

export function credsHelp({ bridgeLabel, envPath, emailKeys, passwordKeys, exampleEmail }) {
  const example = exampleEmail || (String(bridgeLabel || '').toLowerCase().includes('gemini') || String(bridgeLabel || '').toLowerCase().includes('google') ? 'you@gmail.com' : 'you@example.com')
  return [
    `${bridgeLabel} auto-login needs credentials in its .env file (or process env).`,
    ``,
    `  1. Edit:  ${envPath}`,
    `     ${emailKeys[0]}=${example}`,
    `     ${passwordKeys[0]}=your-password`,
    `     chmod 600 "${envPath}"`,
    `  2. Or export in your shell (takes precedence over the file):`,
    `     export ${emailKeys[0]}=${example} ${passwordKeys[0]}=your-password`,
    `  3. Re-run with:  login --auto   (or just run "ask" — it auto-logs in when creds exist)`,
    ``,
    `Accepted keys: ${[...emailKeys].join(' / ')}  and  ${[...passwordKeys].join(' / ')}.`,
    `Secrets are never printed; only a masked email (e.g. ${maskEmail('ab@example.com')}) appears in logs.`,
  ].join('\n')
}

export const CHATGPT_KEYS = {
  emailKeys: ['CHATGPT_EMAIL', 'OPENAI_EMAIL', 'CHATGPT_USERNAME'],
  passwordKeys: ['CHATGPT_PASSWORD', 'OPENAI_PASSWORD'],
}

export const GEMINI_KEYS = {
  emailKeys: ['GEMINI_EMAIL', 'GOOGLE_EMAIL', 'GOOGLE_USERNAME', 'GEMINI_USERNAME'],
  passwordKeys: ['GEMINI_PASSWORD', 'GOOGLE_PASSWORD'],
}
