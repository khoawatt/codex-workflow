#!/usr/bin/env node
import {
  closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync,
  writeFileSync, writeSync,
} from 'node:fs'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'
import { execFileSync } from 'node:child_process'
import { advanceLoginStability, classifyGeminiSession } from './session-auth.mjs'

const home = homedir()
const bridgeDir = process.env.CODEX_WORK_GEMINI_DIR || join(home, '.config', 'codex-work', 'gemini-web')
const profileDir = join(bridgeDir, 'profile')
const librariesDir = join(bridgeDir, 'libs')
const chatsFile = join(bridgeDir, 'chats.json')
const configFile = join(bridgeDir, 'bridge-config.json')
const lockFile = join(bridgeDir, '.lock')
const geminiUrl = 'https://gemini.google.com/app'
const command = process.argv[2]
const commandArgs = process.argv.slice(3)
const defaultConfig = { max_chars: 120000, max_turns: 20, max_age_hours: 48 }

if (existsSync(librariesDir)) {
  process.env.LD_LIBRARY_PATH = `${librariesDir}${process.env.LD_LIBRARY_PATH ? `:${process.env.LD_LIBRARY_PATH}` : ''}`
}

const promptSelectors = [
  '.ql-editor[contenteditable="true"]',
  'div[contenteditable="true"][role="textbox"]',
  'rich-textarea div[contenteditable="true"]',
  'textarea[aria-label*="prompt" i]',
]
const sendSelectors = [
  'button[aria-label*="Send message" i]',
  'button[aria-label="Send"]',
  'button.send-button',
  'button[mattooltip*="Send" i]',
]
const stopSelector = [
  'button[aria-label*="Stop response" i]',
  'button[aria-label*="Stop generating" i]',
  'button[mattooltip*="Stop" i]',
].join(', ')
const responseSelectors = [
  'model-response .model-response-text',
  'model-response',
  '[data-test-id="model-response"]',
  '.model-response-text',
]
const signedOutSelectors = [
  'a[href*="accounts.google.com/ServiceLogin"]',
  'a[href*="accounts.google.com/v3/signin"]',
  'a[href*="accounts.google.com/signin"]',
  'a[href*="accounts.google.com/AccountChooser"]',
]
const accountIdentitySelectors = [
  'a[href*="accounts.google.com/SignOutOptions"]',
  'a[href^="https://myaccount.google.com/"][aria-label]',
  'a[aria-label^="Google Account:"]',
  'button[aria-label^="Google Account:"]',
]

function usage() {
  process.stderr.write('Usage: gemini-consult <login|status|ask|reset> [options]\n\n')
  process.stderr.write('ask options: --new --headless --timeout=SECONDS --file=PATH\n')
}

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)) }

function loadJson(path, fallback) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return fallback }
}

function saveJson(path, value) {
  mkdirSync(bridgeDir, { recursive: true, mode: 0o700 })
  const temp = `${path}.${process.pid}.tmp`
  writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
  renameSync(temp, path)
}

function repoKey() {
  try {
    const root = execFileSync('git', ['rev-parse', '--show-toplevel'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    let branch = 'default'
    try {
      branch = execFileSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], {
        encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
      }).trim()
    } catch {}
    return `${root}:${branch}`
  } catch {
    return `${basename(process.cwd())}:default`
  }
}

function stale(chat, config) {
  if (!chat) return true
  if ((chat.turns || 0) >= config.max_turns) return true
  if ((chat.chars || 0) >= config.max_chars) return true
  return Boolean(chat.last_used_at && Date.now() - chat.last_used_at > config.max_age_hours * 3600000)
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true } catch { return false }
}

async function acquireLock(timeoutSeconds = 300) {
  mkdirSync(bridgeDir, { recursive: true, mode: 0o700 })
  const deadline = Date.now() + timeoutSeconds * 1000
  while (true) {
    try {
      const fd = openSync(lockFile, 'wx', 0o600)
      writeSync(fd, String(process.pid)); closeSync(fd); return
    } catch (error) {
      if (error.code !== 'EEXIST') throw error
    }
    let owner = 0
    try { owner = Number.parseInt(readFileSync(lockFile, 'utf8').trim(), 10) } catch {}
    if (owner && !pidAlive(owner)) {
      try { unlinkSync(lockFile) } catch {}
      continue
    }
    if (Date.now() >= deadline) {
      throw new Error(`another gemini-consult process holds the browser profile lock (pid=${owner || 'unknown'})`)
    }
    await sleep(1000)
  }
}

function releaseLock() { try { unlinkSync(lockFile) } catch {} }

async function launch(headless) {
  const { chromium } = await import('playwright')
  return chromium.launchPersistentContext(profileDir, {
    headless,
    args: ['--no-sandbox', '--disable-blink-features=AutomationControlled'],
    viewport: { width: 1280, height: 900 },
  })
}

async function input(page, attempts = 30) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    for (const selector of promptSelectors) {
      const locator = page.locator(selector).first()
      if (await locator.count() && await locator.isVisible().catch(() => false)) return locator
    }
    await sleep(1000)
  }
  return null
}

async function anyVisible(page, selectors) {
  for (const selector of selectors) {
    const matches = page.locator(selector)
    for (let index = 0; index < await matches.count(); index += 1) {
      if (await matches.nth(index).isVisible().catch(() => false)) return true
    }
  }
  return false
}

async function anyPresent(page, selectors) {
  for (const selector of selectors) {
    if (await page.locator(selector).count()) return true
  }
  return false
}

async function sessionState(page) {
  let onGeminiOrigin = false
  try { onGeminiOrigin = new URL(page.url()).hostname === 'gemini.google.com' } catch {}
  const cookies = await page.context().cookies([
    'https://gemini.google.com/',
    'https://accounts.google.com/',
  ])
  return classifyGeminiSession({
    onGeminiOrigin,
    explicitSignedOut: await anyPresent(page, signedOutSelectors),
    identityEvidence: await anyVisible(page, accountIdentitySelectors),
    canAsk: Boolean(await input(page, 2)),
    cookieNames: cookies.map((cookie) => cookie.name),
  })
}

async function signedIn(page) {
  return (await sessionState(page)).loggedIn
}

function conversationId(url) {
  const match = url.match(/gemini\.google\.com\/app\/([^/?#]+)/i)
  return match ? match[1] : null
}

async function openConversation(page, id) {
  if (!id) return false
  await page.goto(`${geminiUrl}/${encodeURIComponent(id)}`, { waitUntil: 'domcontentloaded', timeout: 60000 })
  return Boolean(await input(page, 15)) && conversationId(page.url()) === id
}

function responseLocator(page) {
  return page.locator(responseSelectors.join(', '))
}

async function send(page, prompt) {
  const composer = await input(page)
  if (!composer) throw new Error('Gemini prompt input was not found; login may be required or the web UI changed; no prompt was sent')
  await composer.click()
  await composer.fill(prompt)
  for (const selector of sendSelectors) {
    const button = page.locator(selector).first()
    if (await button.count() && await button.isVisible().catch(() => false)) {
      await button.click(); return
    }
  }
  throw new Error('Gemini Send button was not found; the web UI may have changed; no prompt was sent')
}

async function reply(page, timeoutSeconds, previousCount) {
  const deadline = Date.now() + timeoutSeconds * 1000
  while (Date.now() < deadline) {
    const responses = responseLocator(page)
    const count = await responses.count()
    if (count > previousCount && (await page.locator(stopSelector).count()) === 0) {
      const text = (await responses.nth(count - 1).innerText()).trim()
      if (text) return text
    }
    await sleep(1500)
  }
  throw new Error(`timeout after ${timeoutSeconds}s waiting for Gemini Web`)
}

async function login() {
  const context = await launch(false)
  try {
    const page = context.pages()[0] || await context.newPage()
    let documentVersion = 0
    let observedDocumentVersion = 0
    let lastNavigationAt = Date.now()
    let stableChecks = 0
    page.on('framenavigated', (frame) => {
      if (frame === page.mainFrame()) {
        documentVersion += 1
        lastNavigationAt = Date.now()
      }
    })
    await page.goto(geminiUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
    observedDocumentVersion = documentVersion
    process.stderr.write('Browser opened. Sign in to Gemini with your Google account in that window.\n')
    for (let attempt = 0; attempt < 600; attempt += 1) {
      try {
        if (page.isClosed()) throw new Error('browser window was closed before login completed')
        const state = await sessionState(page)
        const sameDocument = documentVersion === observedDocumentVersion
        const documentSettled = Date.now() - lastNavigationAt >= 5000
        stableChecks = advanceLoginStability(stableChecks, state, sameDocument, documentSettled)
        observedDocumentVersion = documentVersion
        if (stableChecks >= 3) {
          process.stderr.write('Login verified. Browser profile saved locally.\n')
          return
        }
      } catch (error) {
        stableChecks = 0
        observedDocumentVersion = documentVersion
        if (page.isClosed()) throw error
      }
      await sleep(1000)
    }
    throw new Error('timed out after 20 minutes waiting for Gemini login')
  } finally { await context.close() }
}

async function status() {
  if (!existsSync(profileDir)) {
    process.stdout.write('{"profileExists":false,"loggedIn":false}\n'); return
  }
  const context = await launch(true)
  try {
    const page = context.pages()[0] || await context.newPage()
    await page.goto(geminiUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
    const state = await sessionState(page)
    process.stdout.write(`${JSON.stringify({
      profileExists: true,
      loggedIn: state.loggedIn,
      guestAvailable: state.guestAvailable,
    })}\n`)
  } finally { await context.close() }
}

async function ask() {
  let prompt = ''
  let timeoutSeconds = 300
  let headless = false
  let forceNew = false
  for (const option of commandArgs) {
    if (option === '--new') forceNew = true
    else if (option === '--headless') headless = true
    else if (option.startsWith('--timeout=')) timeoutSeconds = Number.parseInt(option.slice(10), 10)
    else if (option.startsWith('--file=')) prompt = readFileSync(option.slice(7), 'utf8')
    else throw new Error(`unknown ask option: ${option}`)
  }
  if (!prompt) prompt = readFileSync(0, 'utf8')
  prompt = prompt.trim()
  if (!prompt) throw new Error('empty prompt; pipe a sanitized request to stdin')
  if (!Number.isFinite(timeoutSeconds) || timeoutSeconds < 1) throw new Error('timeout must be a positive number of seconds')

  const config = { ...defaultConfig, ...loadJson(configFile, {}) }
  const state = loadJson(chatsFile, { chats: {} })
  if (!state.chats || typeof state.chats !== 'object') state.chats = {}
  const key = repoKey()
  let current = state.chats[key]
  if (forceNew || stale(current, config)) current = null

  const context = await launch(headless)
  try {
    const page = context.pages()[0] || await context.newPage()
    await page.goto(geminiUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
    if (!(await signedIn(page))) throw new Error('Gemini Web is not signed in; run gemini-consult login first')
    const reused = current ? await openConversation(page, current.id) : false
    if (!reused) {
      current = null
      await page.goto(geminiUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
      if (!(await input(page, 15))) throw new Error('Gemini prompt input was not found; no prompt was sent')
    }
    const previousCount = await responseLocator(page).count()
    await send(page, prompt)
    const response = await reply(page, timeoutSeconds, previousCount)
    const now = Date.now()
    const id = conversationId(page.url())
    if (id) {
      state.chats[key] = {
        id,
        turns: (current?.turns || 0) + 1,
        chars: (current?.chars || 0) + prompt.length + response.length,
        created_at: current?.created_at || now,
        last_used_at: now,
      }
      saveJson(chatsFile, state)
    }
    process.stdout.write(`${response}\n`)
  } finally { await context.close() }
}

async function reset() {
  const state = loadJson(chatsFile, { chats: {} })
  if (!state.chats || typeof state.chats !== 'object') state.chats = {}
  const key = repoKey()
  const existed = Boolean(state.chats[key])
  delete state.chats[key]
  saveJson(chatsFile, state)
  process.stdout.write(existed ? `Reset Gemini conversation mapping for ${key}.\n` : `No saved Gemini conversation for ${key}.\n`)
}

async function main() {
  if (!['login', 'status', 'ask', 'reset'].includes(command)) { usage(); process.exitCode = 2; return }
  if (commandArgs.length && command !== 'ask') throw new Error(`${command} does not accept options`)
  await acquireLock()
  try {
    if (command === 'login') await login()
    else if (command === 'status') await status()
    else if (command === 'ask') await ask()
    else await reset()
  } finally { releaseLock() }
}

main().catch((error) => {
  process.stderr.write(`gemini-consult: ${error.message}\n`)
  process.exitCode = 1
})
