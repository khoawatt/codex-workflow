#!/usr/bin/env node
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
  writeSync,
} from 'node:fs'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'
import { execFileSync } from 'node:child_process'
import { loadBridgeCreds, credsHelp, maskEmail, resolveBridgeDir, CHATGPT_KEYS } from './bridge-env.mjs'

const home = homedir()
const bridgeDir = resolveBridgeDir(process.env.CODEX_WORK_CHATGPT_DIR || process.env.CHATGPT_BRIDGE_DIR || join(home, '.config', 'codex-work', 'chatgpt-web'), 'CODEX_WORK_CHATGPT_DIR')
const profileDir = join(bridgeDir, 'profile')
const librariesDir = join(bridgeDir, 'libs')
const chatsFile = join(bridgeDir, 'chats.json')
const projectsFile = join(bridgeDir, 'projects.json')
const configFile = join(bridgeDir, 'bridge-config.json')
const lockFile = join(bridgeDir, '.lock')
const chatUrl = 'https://chatgpt.com/'
const command = process.argv[2]
const commandArgs = process.argv.slice(3)

if (existsSync(librariesDir)) {
  process.env.LD_LIBRARY_PATH = `${librariesDir}${process.env.LD_LIBRARY_PATH ? `:${process.env.LD_LIBRARY_PATH}` : ''}`
}

const defaultConfig = {
  mode: 'single',
  max_chars: 120000,
  max_turns: 20,
  max_age_hours: 48,
  project_mode: {},
}
const promptSelectors = [
  '#prompt-textarea',
  '[id="prompt-textarea"]',
  'div[contenteditable="true"][role="textbox"]',
  'textarea[data-id="prompt-textarea"]',
  'div[data-testid="prompt-textarea"]',
]
const sendSelectors = [
  '[data-testid="send-button"]',
  '[data-testid="composer-send-button"]',
  'button[aria-label*="Send"]',
  '[aria-label="Send prompt"]',
]
const stopSelector = [
  '[data-testid="stop-button"]',
  '[data-testid="composer-stop-button"]',
  'button[aria-label*="Stop"]',
].join(', ')
const assistantSelector = '[data-message-author-role="assistant"]'
const newProjectSelectors = ['button[aria-label="New project"]']
const projectNameSelector = '#project-name, input[name="projectName"]'
const createProjectSelectors = [
  '[data-testid="create-new-project-form"] button[type="submit"]',
  'button:has-text("Create project")',
  '[data-testid="modal-new-project-enhanced"] button:has-text("Create project")',
]
const allowedVerdicts = new Set(['approve', 'approve-with-changes', 'request-changes', 'reject'])

function usage() {
  process.stderr.write(`Usage: chatgpt-consult <login|status|ask|chats|reset|approval|project> [options]\n\n`)
  process.stderr.write(`  chatgpt-consult login [--auto] [--switch] [--wait=SECONDS]   Open a visible browser so you can sign in to ChatGPT once.\n`)
  process.stderr.write(`  chatgpt-consult ask            Read prompt from stdin (or --file=FILE), send to ChatGPT, print reply.\n`)
  process.stderr.write(`  chatgpt-consult status         Check whether a signed-in profile exists.\n`)
  process.stderr.write(`  chatgpt-consult chats          List per-repo conversation state.\n`)
  process.stderr.write(`  chatgpt-consult reset          Drop the saved conversation mapping for the current repo+branch.\n`)
  process.stderr.write(`\nLOGIN OPTIONS:\n`)
  process.stderr.write(`  --auto / --from-env / --env   Sign in automatically with credentials from .env (no manual typing).\n`)
  process.stderr.write(`  --switch              Keep browser open to switch account (waits for session token to change; does not auto-close if already logged in).\n`)
  process.stderr.write(`  --wait=SECONDS        After a new login is detected, keep browser open for SECONDS (default 0; implies --switch).\n`)
  process.stderr.write(`  --keep-open / --stay-open   Alias for --switch.\n`)
  process.stderr.write(`\nask options: --new --headless --timeout=SECONDS --file=PATH --project[=NAME] --no-project --no-auto-login\n`)
  process.stderr.write(`approval: get | set VERDICT HEAD_SHA [PR] | clear\n`)
  process.stderr.write(`project (experimental): list | create [NAME] | attach NAME | detach | resolve\n`)
  process.stderr.write(`\nENV FILE (~/.config/codex-work/chatgpt-web/.env, mode 600, never committed):\n`)
  process.stderr.write(`  CHATGPT_EMAIL=you@example.com\n`)
  process.stderr.write(`  CHATGPT_PASSWORD=your-password\n`)
  process.stderr.write(`  # aliases: OPENAI_EMAIL / OPENAI_PASSWORD. Shell env overrides the file.\n`)
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function loadJson(path, fallback) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    return fallback
  }
}

function saveJson(path, value) {
  mkdirSync(bridgeDir, { recursive: true, mode: 0o700 })
  const temp = `${path}.${process.pid}.tmp`
  writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
  renameSync(temp, path)
}

function repoContext() {
  let root = process.cwd()
  let branch = 'default'
  try {
    root = execFileSync('git', ['rev-parse', '--show-toplevel'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    branch = execFileSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
  } catch {}
  let identity = root
  try {
    const remote = execFileSync('git', ['remote', 'get-url', 'origin'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    const match = remote.match(/(?:github\.com[:/])([^/]+\/[^/]+?)(?:\.git)?$/i)
    if (match) identity = match[1]
  } catch {}
  return {
    root,
    name: basename(root),
    branch,
    identity,
    key: `${identity}:${branch}`,
    legacy_key: `${basename(root)}:${branch}`,
  }
}

function normalizeState(value) {
  return value && typeof value === 'object' && value.chats && typeof value.chats === 'object'
    ? value
    : { chats: {} }
}

function loadChats() {
  return normalizeState(loadJson(chatsFile, { chats: {} }))
}

function loadProjects() {
  const value = loadJson(projectsFile, { projects: {} })
  return value && typeof value === 'object' && value.projects && typeof value.projects === 'object'
    ? value
    : { projects: {} }
}

function projectEnabled(config, repoName) {
  return config.mode === 'project' || config.project_mode?.[repoName] === true
}

function projectUrl(project) {
  return `https://chatgpt.com/g/${project.slug}/project`
}

function chatId(url) {
  const match = url.match(/\/c\/([0-9a-f-]{8,})/i)
  return match ? match[1] : null
}

function stale(chat, config) {
  if (!chat) return true
  if ((chat.turns || 0) >= config.max_turns) return true
  if ((chat.chars || 0) >= config.max_chars) return true
  return Boolean(chat.last_used_at && Date.now() - chat.last_used_at > config.max_age_hours * 3600000)
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

async function acquireLock(timeoutSeconds = 300) {
  mkdirSync(bridgeDir, { recursive: true, mode: 0o700 })
  const deadline = Date.now() + timeoutSeconds * 1000
  while (true) {
    try {
      const fd = openSync(lockFile, 'wx', 0o600)
      writeSync(fd, String(process.pid))
      closeSync(fd)
      return
    } catch (error) {
      if (error.code !== 'EEXIST') throw error
    }
    let owner = 0
    try {
      owner = Number.parseInt(readFileSync(lockFile, 'utf8').trim(), 10)
    } catch {}
    if (owner && !pidAlive(owner)) {
      try { unlinkSync(lockFile) } catch {}
      continue
    }
    if (Date.now() >= deadline) {
      throw new Error(`another chatgpt-consult process holds the browser profile lock (pid=${owner || 'unknown'})`)
    }
    await sleep(1000)
  }
}

function releaseLock() {
  try { unlinkSync(lockFile) } catch {}
}

async function launch(headless) {
  const { chromium } = await import('playwright')
  return chromium.launchPersistentContext(profileDir, {
    headless,
    args: ['--no-sandbox', '--disable-blink-features=AutomationControlled'],
    viewport: { width: 1280, height: 900 },
  })
}

async function signedIn(context) {
  const cookies = await context.cookies(chatUrl)
  return cookies.some((cookie) => cookie.name.startsWith('__Secure-next-auth.session-token'))
}

async function input(page, attempts = 20) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    for (const selector of promptSelectors) {
      const locator = page.locator(selector).first()
      if (await locator.count()) return locator
    }
    await sleep(1000)
  }
  return null
}

async function openChat(page, id) {
  if (!id) return false
  await page.goto(`${chatUrl}c/${id}`, { waitUntil: 'domcontentloaded', timeout: 60000 })
  await input(page, 15)
  return page.url().includes(`/c/${id}`)
}

async function waitForInput(page, attempts = 20) {
  return Boolean(await input(page, attempts))
}

async function handleCloudflare(page) {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (!/(__cf_chl|challenges\.cloudflare)/.test(page.url())) return
    await sleep(2000)
  }
  throw new Error('ChatGPT Web remained behind a Cloudflare challenge')
}
async function pageBodyText(page) {
  try { return String(await page.evaluate(() => document.body ? document.body.innerText.slice(0, 4000) : '')).toLowerCase() } catch { return '' }
}

function detectChatgptBlocker(bodyText, url) {
  if (!bodyText) return null
  if (/wrong (email|password)|incorrect.*password|invalid.*credentials|wrong.*credentials/.test(bodyText)) {
    return 'ChatGPT báo sai email/password — kiểm tra lại .env rồi thử lại.'
  }
  if (/verify you are human|captcha|challenge|unusual activity|suspicious|verify.*identity/.test(bodyText)) {
    return 'ChatGPT yêu cầu xác minh người thật (CAPTCHA/Cloudflare) — hoàn thành 1 lần bằng `login` thủ công, các lần sau dùng session đã lưu.'
  }
  if (/two-?factor|2fa|multi-?factor|mfa|authenticator|verification code|check your email|we sent you|enter.*code/.test(bodyText)) {
    return 'Tài khoản bật 2FA/mã xác minh qua email — auto-login không thể tự qua bước này. Đăng nhập thủ công 1 lần (`login`), session sẽ được tái dùng.'
  }
  if (/this browser or app may not be secure|browser.*not.*secure|couldn.t sign you in/.test(bodyText)) {
    return 'ChatGPT/Google chặn trình duyệt tự động — đăng nhập thủ công 1 lần (`login`) để lưu session.'
  }
  if (/rate.?limit|too many (attempts|requests)|try again later/.test(bodyText)) {
    return 'Bị giới hạn số lần đăng nhập — đợi vài phút rồi thử lại.'
  }
  if (url.includes('__cf_chl') || url.includes('challenges.cloudflare')) {
    return 'Đang kẹt ở Cloudflare challenge — thử lại ở môi trường có display (headful) hoặc login thủ công 1 lần.'
  }
  return null
}

function loadChatgptCreds() {
  const envFileVar = (process.env.CODEX_WORK_CHATGPT_ENV_FILE || '').trim() ? 'CODEX_WORK_CHATGPT_ENV_FILE' : 'CHATGPT_ENV_FILE'
  return loadBridgeCreds({ bridgeDir, envFileVar, emailKeys: CHATGPT_KEYS.emailKeys, passwordKeys: CHATGPT_KEYS.passwordKeys })
}

async function hasRealBox(el) {
  try { const box = await el.boundingBox(); return !!box && box.width >= 2 && box.height >= 2 } catch { return false }
}
async function fillFirstVisible(page, selectors, value, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    for (const sel of selectors) {
      try {
        const loc = page.locator(sel)
        const n = await loc.count()
        for (let i = 0; i < n; i++) {
          const el = loc.nth(i)
          try {
            if (!(await hasRealBox(el))) continue
            if (!(await el.isVisible().catch(()=>false))) continue
            await el.click({timeout:2000}).catch(()=>{})
            await el.fill(value, {timeout:5000})
            return sel
          } catch {}
        }
      } catch {}
    }
    await sleep(500)
  }
  return null
}
async function clickFirstVisible(page, selectors, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    for (const sel of selectors) {
      try {
        const loc = page.locator(sel)
        const n = await loc.count()
        for (let i = 0; i < n; i++) {
          const el = loc.nth(i)
          try {
            if (!(await hasRealBox(el))) continue
            if (!(await el.isVisible().catch(()=>false))) continue
            await el.click({timeout:3000})
            return sel
          } catch {}
        }
      } catch {}
    }
    await sleep(500)
  }
  return null
}
async function anyRealVisible(page, selectors) {
  for (const sel of selectors) {
    try {
      const loc = page.locator(sel)
      const n = await loc.count()
      for (let i = 0; i < n; i++) {
        const el = loc.nth(i)
        if ((await hasRealBox(el)) && (await el.isVisible().catch(()=>false))) return true
      }
    } catch {}
  }
  return false
}
const CHATGPT_LOGIN_BTN = ['button[data-testid="login-button"]','a[data-testid="login-button"]','button:text-is("Log in")','a:text-is("Log in")','button:has-text("Log in")','a:has-text("Log in")','[data-testid="login-link"]']
const CHATGPT_EMAIL_INPUT = ['input[type="email"]','input[name="username"]','input[name="email"]','#email-input','input[id*="email"]','input[autocomplete="username"]']
const CHATGPT_PASSWORD_INPUT = ['input[type="password"]','input[name="password"]','#password','input[autocomplete="current-password"]']
const CHATGPT_CONTINUE_BTN = ['button[type="submit"]','button:has-text("Continue")','button:has-text("Log in")','button:has-text("Sign in")']
const GOOGLE_ID_INPUT = ['#identifierId','input[name="identifier"]','input[autocomplete*="username"]']
const GOOGLE_ID_NEXT = ['#identifierNext','button:text-is("Next")','button:has-text("Next")']
const GOOGLE_PW_INPUT = ['input[name="Passwd"]','input[type="password"]']
const GOOGLE_PW_NEXT = ['#passwordNext','button:text-is("Next")','button:has-text("Next")']
const GOOGLE_ALLOW_BTN = ['#submit_approve_access','button:text-is("Allow")','button:text-is("Continue")']
const OPENAI_CODE_INPUT = ['input[autocomplete="one-time-code"]','input[name="code"]']

async function fillFieldAndSubmit(page, selectors, value, fallbackBtns, timeoutMs = 6000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      for (const sel of selectors) {
        const loc = page.locator(sel)
        const n = await loc.count()
        for (let i = 0; i < n; i++) {
          const el = loc.nth(i)
          try {
            if (!(await hasRealBox(el))) continue
            if (!(await el.isVisible().catch(()=>false))) continue
            await el.click({timeout:2000}).catch(()=>{})
            await el.fill(value, {timeout:5000})
            await page.waitForTimeout(400)
            try {
              const scoped = el.locator('xpath=ancestor::form//button[@type="submit"]').first()
              if ((await scoped.count())>0 && (await hasRealBox(scoped)) && (await scoped.isVisible().catch(()=>false))) {
                await scoped.click({timeout:3000})
                return true
              }
            } catch {}
            if (await clickFirstVisible(page, fallbackBtns, 4000)) return true
            return true
          } catch {}
        }
      }
    } catch {}
    await sleep(500)
  }
  return false
}

async function tryAutoLoginChatGPT(page, creds, { timeoutSec = 150 } = {}) {
  const context = page.context()
  const isLoggedIn = async () => (await context.cookies(chatUrl)).some(c=>c.name.startsWith('__Secure-next-auth.session-token'))
  if (await isLoggedIn()) return true
  process.stderr.write(`[bridge] auto-login as ${maskEmail(creds.email)} (from ${creds.emailSource==='env'?'env':creds.envPath})…\n`)
  await page.goto(chatUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
  await handleCloudflare(page)
  for (let i=0;i<5;i++){ if(await isLoggedIn()) return true; await sleep(1000) }
  const onGoogle = () => page.url().includes('accounts.google.com')
  const onAuthHost = () => /auth\.openai\.com|auth0\.com|accounts\.openai\.com/.test(page.url())
  const deadline = Date.now() + timeoutSec*1000
  let acted = false
  while (Date.now() < deadline) {
    if (await isLoggedIn()) return true
    const url = page.url()
    const body = await pageBodyText(page)
    if (await anyRealVisible(page, OPENAI_CODE_INPUT)) {
      const pwOpt = page.locator('button:text-is("Continue with password")').first()
      try {
        if ((await pwOpt.count())>0 && (await hasRealBox(pwOpt))) {
          process.stderr.write('[bridge] email-code screen — switching to password login…\n')
          await pwOpt.click({timeout:3000})
          acted = true
          await page.waitForTimeout(2500)
          continue
        }
      } catch {}
      throw new Error('ChatGPT gửi mã xác minh về email (tài khoản chưa có password) — nhập mã thủ công 1 lần (`login`), hoặc bấm "Continue with password" trong bản web. Auto-login không đọc được inbox.')
    }
    const blocker = detectChatgptBlocker(body, url)
    if (blocker && acted) throw new Error(blocker)
    if (onGoogle()) {
      if (await anyRealVisible(page, GOOGLE_ALLOW_BTN)) {
        process.stderr.write('[bridge] Google consent — approving…\n')
        await clickFirstVisible(page, GOOGLE_ALLOW_BTN, 5000)
        acted = true
        await page.waitForTimeout(3000)
        continue
      }
      if (await anyRealVisible(page, GOOGLE_PW_INPUT)) {
        process.stderr.write('[bridge] Google password screen…\n')
        if (await fillFieldAndSubmit(page, GOOGLE_PW_INPUT, creds.password, GOOGLE_PW_NEXT, 8000)) acted = true
        await page.waitForTimeout(3000)
        continue
      }
      if (await anyRealVisible(page, GOOGLE_ID_INPUT)) {
        process.stderr.write('[bridge] Google identifier screen…\n')
        if (await fillFieldAndSubmit(page, GOOGLE_ID_INPUT, creds.email, GOOGLE_ID_NEXT, 8000)) acted = true
        await page.waitForTimeout(3000)
        continue
      }
      await sleep(2000)
      continue
    }
    if (onAuthHost()) {
      if (await anyRealVisible(page, CHATGPT_PASSWORD_INPUT)) {
        process.stderr.write('[bridge] ChatGPT password screen…\n')
        if (await fillFieldAndSubmit(page, CHATGPT_PASSWORD_INPUT, creds.password, CHATGPT_CONTINUE_BTN, 8000)) acted = true
        await page.waitForTimeout(3000)
        await handleCloudflare(page)
        continue
      }
      if (await anyRealVisible(page, CHATGPT_EMAIL_INPUT)) {
        if (await fillFieldAndSubmit(page, CHATGPT_EMAIL_INPUT, creds.email, CHATGPT_CONTINUE_BTN, 6000)) acted = true
        await page.waitForTimeout(2500)
        continue
      }
      await sleep(2000)
      continue
    }
    if (await anyRealVisible(page, CHATGPT_EMAIL_INPUT)) {
      process.stderr.write('[bridge] login modal — submitting email…\n')
      if (await fillFieldAndSubmit(page, CHATGPT_EMAIL_INPUT, creds.email, CHATGPT_CONTINUE_BTN, 6000)) acted = true
      await page.waitForTimeout(2500)
      await handleCloudflare(page)
      continue
    }
    await clickFirstVisible(page, CHATGPT_LOGIN_BTN, 4000)
    await page.waitForTimeout(2000)
    await handleCloudflare(page)
  }
  const lastUrl = page.url()
  const lastBody = (await pageBodyText(page)).slice(0,200)
  const finalBlocker = detectChatgptBlocker(await pageBodyText(page), lastUrl)
  throw new Error(finalBlocker || `Timed out after ${timeoutSec}s waiting for ChatGPT login as ${maskEmail(creds.email)} (last url: ${lastUrl.slice(0,80)} — "${lastBody}"). Kiểm tra email/password trong .env hoặc đăng nhập thủ công 1 lần: chatgpt-consult login`)
}

async function ensureChatgptLoggedIn(page, { allowAuto = true } = {}) {
  const context = page.context()
  const isLoggedIn = async () => (await context.cookies(chatUrl)).some(c=>c.name.startsWith('__Secure-next-auth.session-token'))
  for (let i=0;i<6;i++){ if(await isLoggedIn()) return true; await sleep(1000) }
  if (!allowAuto) return false
  const creds = loadChatgptCreds()
  for (const w of creds.warnings) process.stderr.write(`[bridge] WARN: ${w}\n`)
  if (!creds.configured) return false
  process.stderr.write(`[bridge] session hết hạn — tự đăng nhập lại từ .env (${maskEmail(creds.email)})…\n`)
  try { await tryAutoLoginChatGPT(page, creds); return await isLoggedIn() } catch (e) { process.stderr.write(`[bridge] auto-login thất bại: ${e.message}\n`); return false }
}

async function captureProjects(page) {
  // Prefer direct fetch (reliable, no race) — page has auth cookies
  try {
    const data = await page.evaluate(async () => {
      const r = await fetch('/backend-api/gizmos/snorlax/sidebar?owned_only=true&conversations_per_gizmo=5&limit=20', {
        credentials: 'include',
      })
      if (!r.ok) throw new Error('sidebar fetch ' + r.status)
      return r.json()
    })
    if (data && Array.isArray(data.items)) {
      const items = data.items
        .map((item) => {
          const project = item.gizmo?.gizmo
          return { id: project?.id, slug: project?.short_url, name: project?.display?.name }
        })
        .filter((project) => project.id && project.slug && project.name)
      return items
    }
  } catch (e) {
    process.stderr.write(`[bridge] direct sidebar fetch failed: ${e.message} — falling back to response capture\n`)
  }

  // Fallback: capture the in-page response (older method)
  const captureOnce = () =>
    new Promise((resolve) => {
      const handler = async (response) => {
        if (!response.url().includes('/backend-api/gizmos/snorlax/sidebar')) return
        try {
          const payload = await response.json()
          page.off('response', handler)
          resolve(payload)
        } catch {}
      }
      page.on('response', handler)
      setTimeout(() => {
        page.off('response', handler)
        resolve(null)
      }, 20000)
    })
  if (!page.url().includes('chatgpt.com')) await page.goto(chatUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
  // First try: if a sidebar response is already in-flight, capture it
  let data = await captureOnce()
  if (!data) {
    // Second try: start listening BEFORE navigating so we don't miss the request
    const secondCapture = captureOnce()
    await page.goto(chatUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
    await handleCloudflare(page)
    data = await secondCapture
    if (!data) {
      // Last resort: force reload
      const thirdCapture = captureOnce()
      await page.reload({ waitUntil: 'domcontentloaded', timeout: 60000 })
      await handleCloudflare(page)
      data = await thirdCapture
    }
  }
  if (!data) throw new Error('could not fetch projects list from ChatGPT web')
  const items = (data.items || [])
    .map((item) => {
      const project = item.gizmo?.gizmo
      return { id: project?.id, slug: project?.short_url, name: project?.display?.name }
    })
    .filter((project) => project.id && project.slug && project.name)
  return items
}

async function findProject(page, name) {
  const projects = await captureProjects(page)
  return projects.find((project) => project.name.toLowerCase() === String(name).toLowerCase()) || null
}

async function createProject(page, name) {
  await page.goto(chatUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
  await handleCloudflare(page)
  // Ensure sidebar is open — the New project button lives in the expanded sidebar header
  // and the click is ignored when the sidebar is collapsed (repro: dbg3 vs dbg4).
  try {
    const openBtn = page.locator('button[aria-label="Open sidebar"]').first()
    if (await openBtn.count()) {
      const state = await page.locator('#stage-slideover-sidebar').getAttribute('data-state').catch(() => null)
      // data-state="closed" means collapsed; click to expand
      if (state === 'closed' || (await openBtn.isVisible().catch(() => false))) {
        // Only click if the New project button is not yet visible/interactable
        const newProjVisible = await page
          .locator(newProjectSelectors.join(', '))
          .first()
          .isVisible()
          .catch(() => false)
        if (!newProjVisible) {
          await openBtn.click({ force: true })
          await page.waitForTimeout(1500)
        } else if (state === 'closed') {
          // Even if visible in DOM, the collapsed rail may intercept clicks — expand anyway
          await openBtn.click({ force: true })
          await page.waitForTimeout(1200)
        }
      }
    }
  } catch {}

  const button = page.locator(newProjectSelectors.join(', ')).first()
  if (!(await button.count())) throw new Error('ChatGPT New project button was not found; no project was created')
  await button.click({ force: true })
  // Wait for the create form to appear — ChatGPT animates the dialog
  let input = null
  for (let i = 0; i < 15; i++) {
    input = page.locator(projectNameSelector).first()
    if (await input.count()) break
    // Fallback: also check inside the dedicated form container
    input = page.locator('[data-testid="create-new-project-form"] input').first()
    if (await input.count()) break
    await page.waitForTimeout(500)
  }
  input = page.locator(projectNameSelector).first()
  if ((await input.count()) === 0) {
    input = page.locator('[data-testid="create-new-project-form"] input').first()
  }
  if (!(await input.count())) throw new Error('ChatGPT project name input was not found; no project was created')
  await input.fill(String(name))
  await page.waitForTimeout(300)
  let submitted = false
  for (const selector of createProjectSelectors) {
    const submit = page.locator(selector).first()
    if (await submit.count()) {
      await submit.click()
      submitted = true
      break
    }
  }
  if (!submitted) {
    // Fallback: press Enter in the input (covers selector drift)
    await input.press('Enter')
    submitted = true
  }
  await page.waitForTimeout(4000)
  const created = await findProject(page, name)
  if (!created) throw new Error('project creation was submitted but its identity could not be verified')
  return created
}

async function resolveProject(page, name, createIfMissing) {
  const state = loadProjects()
  const saved = state.projects[name]
  if (saved?.slug) return saved
  const resolved = await findProject(page, name) || (createIfMissing ? await createProject(page, name) : null)
  if (resolved) {
    state.projects[name] = { ...resolved, saved_at: new Date().toISOString() }
    saveJson(projectsFile, state)
  }
  return resolved
}

async function openProject(page, project) {
  await page.goto(projectUrl(project), { waitUntil: 'domcontentloaded', timeout: 60000 })
  await handleCloudflare(page)
  return page.url().includes('/project') && await waitForInput(page, 12)
}

async function send(page, prompt) {
  const composer = await input(page)
  if (!composer) throw new Error('ChatGPT prompt input was not found; login may be required or the web UI changed')
  await composer.click()
  await composer.fill(prompt)
  for (const selector of sendSelectors) {
    const button = page.locator(selector).first()
    if (await button.count()) {
      await button.click()
      return
    }
  }
  await composer.press('Enter')
}

async function reply(page, timeoutSeconds, previousCount) {
  const deadline = Date.now() + timeoutSeconds * 1000
  while (Date.now() < deadline) {
    if ((await page.locator(stopSelector).count()) === 0) {
      const messages = page.locator(assistantSelector)
      const count = await messages.count()
      if (count > previousCount) {
        const text = (await messages.nth(count - 1).innerText()).trim()
        if (text.length > 0) return text
      }
    }
    await sleep(1500)
  }
  throw new Error(`timeout after ${timeoutSeconds}s waiting for ChatGPT Web`)
}

async function login() {
  const loginArgs = commandArgs
  const has = (flag) => loginArgs.includes(flag)
  const autoMode = has('--auto') || has('--from-env') || has('--env')
  const waitArg = loginArgs.find((a) => a.startsWith('--wait='))
  let keepOpenSec = 0
  let switchMode = has('--switch') || has('--stay-open') || has('--keep-open') || !!waitArg
  if (waitArg) {
    const v = Number.parseInt(waitArg.slice(7), 10)
    if (!Number.isNaN(v) && v >= 0) keepOpenSec = v
  } else if (has('--wait') || has('--stay-open') || has('--keep-open')) {
    keepOpenSec = 0
  }
  if (autoMode) {
    const creds = loadChatgptCreds()
    for (const w of creds.warnings) process.stderr.write(`[bridge] WARN: ${w}\n`)
    if (!creds.configured) {
      process.stderr.write(credsHelp({ bridgeLabel: 'ChatGPT', envPath: creds.envPath, emailKeys: CHATGPT_KEYS.emailKeys, passwordKeys: CHATGPT_KEYS.passwordKeys }) + '\n')
      process.exit(1)
    }
    const timeoutArg = loginArgs.find((a) => a.startsWith('--timeout='))
    const loginTimeout = timeoutArg ? Number.parseInt(timeoutArg.slice(10), 10) || 150 : 150
    const headless = has('--headless') ? true : false
    const context = await launch(headless)
    const page = context.pages()[0] || await context.newPage()
    try {
      await tryAutoLoginChatGPT(page, creds, { timeoutSec: loginTimeout })
      process.stderr.write('LOGIN OK — session saved (auto-login from .env).\n')
      await context.close()
      return
    } catch (e) {
      process.stderr.write(`Auto-login thất bại: ${e.message}\n`)
      process.stderr.write('Fallback: chạy `chatgpt-consult login` thủ công 1 lần để lưu session (2FA/CAPTCHA không tự qua được).\n')
      try { await context.close() } catch {}
      process.exit(1)
    }
  }
  const context = await launch(false)
  let browserClosed = false
  try {
    const page = context.pages()[0] || await context.newPage()
    context.on('close', () => { browserClosed = true })
    page.on('close', () => { browserClosed = true })
    await page.goto(chatUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
    await handleCloudflare(page)
    process.stderr.write('Browser opened. Sign in to ChatGPT Web in that window.\n')
    if (switchMode) {
      process.stderr.write('Switch mode: browser will stay open. If already logged in, log out in the window and sign in with the new account.\n')
      if (keepOpenSec > 0) {
        process.stderr.write(`Waiting for a new session (up to 20 min), then keeping open ${keepOpenSec}s after login...\n`)
      } else {
        process.stderr.write('Waiting for a new session (up to 20 min)... Press Ctrl+C to abort, or close the window to finish.\n')
      }
    } else {
      process.stderr.write('Waiting for a real signed-in session cookie to appear...\n')
      process.stderr.write('Tip: to switch account, run:  chatgpt-consult login --switch   (keeps browser open)\n')
    }

    // capture initial token to detect account change in switch mode
    let initialToken = null
    try {
      const cookies = await context.cookies(chatUrl)
      const c = cookies.find((cookie) => cookie.name.startsWith('__Secure-next-auth.session-token'))
      initialToken = c ? c.value : null
    } catch {}
    const initiallyLoggedIn = !!initialToken
    if (switchMode && initiallyLoggedIn) {
      process.stderr.write('[switch] already logged in — waiting for you to log out and log in with the other account...\n')
    }

    for (let attempt = 0; attempt < 600; attempt += 1) {
      if (browserClosed) {
        process.stderr.write('Browser was closed by user.\n')
        let tok = null
        try {
          const cookies = await context.cookies(chatUrl)
          const c = cookies.find((cookie) => cookie.name.startsWith('__Secure-next-auth.session-token'))
          tok = c ? c.value : null
        } catch {}
        if (tok) {
          process.stderr.write('Login verified. Browser profile saved locally (browser closed).\n')
          return
        }
        process.stderr.write('No session cookie found — session not saved.\n')
        throw new Error('browser closed without login')
      }
      try {
        const cookies = await context.cookies(chatUrl)
        const c = cookies.find((cookie) => cookie.name.startsWith('__Secure-next-auth.session-token'))
        const token = c ? c.value : null
        const loggedIn = !!token
        if (loggedIn) {
          if (!switchMode) {
            await sleep(2000)
            process.stderr.write('Login verified. Browser profile saved locally.\n')
            return
          }
          // switch mode: require a new token if we started logged in
          if (initiallyLoggedIn) {
            if (token !== initialToken) {
              process.stderr.write('New session detected — LOGIN OK.\n')
              if (keepOpenSec > 0) {
                process.stderr.write(`Keeping browser open for ${keepOpenSec}s so you can verify... (close window to finish early)\n`)
                for (let w = 0; w < keepOpenSec; w++) {
                  if (browserClosed) break
                  await sleep(1000)
                }
              } else {
                await sleep(2000)
              }
              process.stderr.write('Login verified. Browser profile saved locally.\n')
              return
            }
          } else {
            // started logged out — any login is success
            if (keepOpenSec > 0) {
              process.stderr.write(`Login detected — keeping browser open for ${keepOpenSec}s...\n`)
              for (let w = 0; w < keepOpenSec; w++) {
                if (browserClosed) break
                await sleep(1000)
              }
            } else {
              await sleep(2000)
            }
            process.stderr.write('Login verified. Browser profile saved locally.\n')
            return
          }
        }
      } catch {}
      await sleep(2000)
    }
    throw new Error('timed out after 20 minutes waiting for ChatGPT login')
  } finally {
    try { await context.close() } catch {}
  }
}

async function status() {
  const localState = join(profileDir, 'Local State')
  const cookiesFile = join(profileDir, 'Default', 'Cookies')
  const profileExists = existsSync(profileDir)
  const cookiesExist = existsSync(cookiesFile)
  const creds = loadChatgptCreds()
  let loggedIn = false
  if (profileExists && existsSync(localState)) {
    let context
    try {
      context = await launch(false)
      const page = context.pages()[0] || await context.newPage()
      await page.goto(chatUrl, { waitUntil: 'domcontentloaded', timeout: 45000 })
      await handleCloudflare(page)
      for (let i = 0; i < 15; i++) {
        if (await signedIn(context)) { loggedIn = true; break }
        await sleep(2000)
      }
      const url = page.url()
      const title = await page.title().catch(() => '')
      process.stderr.write(`[status] url=${url.slice(0, 60)} title="${title}" loggedIn=${loggedIn}\n`)
    } catch (e) {
      process.stderr.write(`[status] error: ${e.message}\n`)
    } finally {
      if (context) try { await context.close() } catch {}
    }
  }
  process.stdout.write(`${JSON.stringify({ profileExists, cookiesExist, loggedIn, envConfigured: creds.configured, envFileExists: creds.fileExists })}\n`)
}

async function ask() {
  let prompt = ''
  let timeoutSeconds = 300
  let headless = false
  let forceNew = false
  let useProject = null
  let requestedProject = null
  let allowAutoLogin = true
  for (const option of commandArgs) {
    if (option === '--new') forceNew = true
    else if (option === '--headless') headless = true
    else if (option === '--no-auto-login') allowAutoLogin = false
    else if (option.startsWith('--timeout=')) timeoutSeconds = Number.parseInt(option.slice(10), 10)
    else if (option.startsWith('--file=')) prompt = readFileSync(option.slice(7), 'utf8')
    else if (option === '--project') useProject = true
    else if (option === '--no-project') useProject = false
    else if (option.startsWith('--project=')) {
      useProject = true
      requestedProject = option.slice(10)
    }
    else throw new Error(`unknown ask option: ${option}`)
  }
  if (!prompt) prompt = readFileSync(0, 'utf8')
  prompt = prompt.trim()
  if (!prompt) throw new Error('empty prompt; pipe a sanitized task or problem summary to stdin')
  if (!Number.isFinite(timeoutSeconds) || timeoutSeconds < 1) throw new Error('timeout must be a positive number of seconds')

  const config = { ...defaultConfig, ...loadJson(configFile, {}) }
  const state = loadChats()
  const repo = repoContext()
  const key = repo.key
  let current = state.chats[key] || state.chats[repo.legacy_key]
  if (forceNew || stale(current, config)) current = null
  const projectMode = useProject === null ? projectEnabled(config, repo.name) : useProject

  const context = await launch(headless)
  try {
    const page = context.pages()[0] || await context.newPage()
    await page.goto(chatUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
    await handleCloudflare(page)
    {
      const pageForLogin = page
      const loggedIn = await ensureChatgptLoggedIn(pageForLogin, { allowAuto: allowAutoLogin })
      if (!loggedIn) {
        const creds = loadChatgptCreds()
        const hint = creds.configured ? 'Auto-login từ .env thất bại — thử `login --auto` để xem chi tiết, hoặc `login` thủ công 1 lần.' : `ChatGPT not signed in. Chạy thủ công 1 lần:  chatgpt-consult login   — hoặc cấu hình .env rồi chạy:  chatgpt-consult login --auto  (xem --help). File: ${creds.envPath}`
        throw new Error(hint)
      }
    }
    let project = null
    if (projectMode) {
      const projectName = requestedProject || repo.name
      project = requestedProject
        ? await findProject(page, projectName) || await createProject(page, projectName)
        : await resolveProject(page, projectName, true)
      if (!(await openProject(page, project))) {
        throw new Error(`ChatGPT Project '${projectName}' could not be opened; no prompt was sent`)
      }
    }
    const reused = current ? await openChat(page, current.id) : false
    if (!reused) {
      current = null
      if (project) {
        if (!(await openProject(page, project))) throw new Error('saved project could not be reopened; no prompt was sent')
      } else {
        await page.goto(chatUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
      }
    }
    const previousCount = await page.locator(assistantSelector).count()
    await send(page, prompt)
    const response = await reply(page, timeoutSeconds, previousCount)
    const now = Date.now()
    const id = chatId(page.url())
    if (id) {
      delete state.chats[repo.legacy_key]
      state.chats[key] = {
        id,
        turns: (current?.turns || 0) + 1,
        chars: (current?.chars || 0) + prompt.length + response.length,
        created_at: current?.created_at || now,
        last_used_at: now,
        project: project ? { id: project.id, slug: project.slug, name: project.name } : null,
      }
      saveJson(chatsFile, state)
    }
    process.stdout.write(`${response}\n`)
  } finally {
    await context.close()
  }
}

async function reset() {
  const state = loadChats()
  const repo = repoContext()
  const key = repo.key
  const existed = Boolean(state.chats[key] || state.chats[repo.legacy_key])
  delete state.chats[key]
  delete state.chats[repo.legacy_key]
  saveJson(chatsFile, state)
  process.stdout.write(existed ? `Reset conversation mapping for ${key}.\n` : `No saved conversation for ${key}.\n`)
}

async function chats() {
  const state = loadChats()
  const current = repoContext()
  process.stdout.write(`${JSON.stringify({
    current_key: current.key,
    current: state.chats[current.key] || state.chats[current.legacy_key] || null,
    all: state.chats,
  }, null, 2)}\n`)
}

async function approval() {
  const action = commandArgs[0] || 'get'
  const repo = repoContext()
  const state = loadChats()
  const entry = state.chats[repo.key] || state.chats[repo.legacy_key] || {}
  if (action === 'get') {
    process.stdout.write(`${JSON.stringify(entry.approval || null)}\n`)
    return
  }
  if (action === 'clear') {
    delete entry.approval
    if (Object.keys(entry).length) state.chats[repo.key] = entry
    else delete state.chats[repo.key]
    delete state.chats[repo.legacy_key]
    saveJson(chatsFile, state)
    process.stdout.write(`Cleared approval for ${repo.key}.\n`)
    return
  }
  if (action !== 'set') throw new Error('approval usage: get | set VERDICT HEAD_SHA [PR] | clear')
  const [verdict, headSha, rawPr = 'none'] = commandArgs.slice(1)
  if (!allowedVerdicts.has(verdict)) throw new Error(`invalid verdict: ${verdict || '(missing)'}`)
  if (!/^[0-9a-f]{40}$/i.test(headSha || '')) throw new Error('HEAD_SHA must be a full 40-character hexadecimal Git commit')
  const pr = rawPr === 'none' ? null : Number.parseInt(rawPr, 10)
  if (pr !== null && (!Number.isSafeInteger(pr) || pr < 1 || String(pr) !== rawPr)) {
    throw new Error('PR must be a positive integer or none')
  }
  entry.approval = {
    verdict,
    head_sha: headSha.toLowerCase(),
    pr,
    repo: repo.identity,
    branch: repo.branch,
    reviewer: 'chatgpt-consult',
    reviewed_at: new Date().toISOString(),
  }
  state.chats[repo.key] = entry
  delete state.chats[repo.legacy_key]
  saveJson(chatsFile, state)
  process.stdout.write(`${JSON.stringify({ key: repo.key, approval: entry.approval }, null, 2)}\n`)
}

async function project() {
  const action = commandArgs[0] || 'list'
  const repo = repoContext()
  const config = { ...defaultConfig, ...loadJson(configFile, {}) }
  const context = await launch(false)
  try {
    const page = context.pages()[0] || await context.newPage()
    await page.goto(chatUrl, { waitUntil: 'domcontentloaded', timeout: 60000 })
    await handleCloudflare(page)
    if (!(await signedIn(context))) throw new Error('ChatGPT Web is not signed in; run chatgpt-consult login first')
    if (action === 'list') {
      process.stdout.write(`${JSON.stringify(await captureProjects(page), null, 2)}\n`)
    } else if (action === 'create') {
      const name = commandArgs[1] || repo.name
      const created = await createProject(page, name)
      const state = loadProjects()
      state.projects[repo.name] = { ...created, saved_at: new Date().toISOString() }
      saveJson(projectsFile, state)
      process.stdout.write(`${JSON.stringify(created, null, 2)}\n`)
    } else if (action === 'attach') {
      const name = commandArgs[1]
      if (!name) throw new Error('project attach requires a project name')
      const found = await findProject(page, name)
      if (!found) throw new Error(`ChatGPT Project '${name}' was not found`)
      const state = loadProjects()
      state.projects[repo.name] = { ...found, saved_at: new Date().toISOString() }
      saveJson(projectsFile, state)
      process.stdout.write(`Attached ${repo.name} to ChatGPT Project '${found.name}'.\n`)
    } else if (action === 'detach') {
      const state = loadProjects()
      const existed = Boolean(state.projects[repo.name])
      delete state.projects[repo.name]
      saveJson(projectsFile, state)
      process.stdout.write(existed ? `Detached ${repo.name}.\n` : `No project was attached to ${repo.name}.\n`)
    } else if (action === 'resolve') {
      const state = loadProjects()
      process.stdout.write(`${JSON.stringify({
        repo: repo.name,
        enabled: projectEnabled(config, repo.name),
        saved: state.projects[repo.name] || null,
      }, null, 2)}\n`)
    } else {
      throw new Error('project usage: list | create [NAME] | attach NAME | detach | resolve')
    }
  } finally {
    await context.close()
  }
}

async function main() {
  if (!['login', 'status', 'ask', 'chats', 'reset', 'approval', 'project', 'projects'].includes(command)) {
    usage()
    process.exitCode = 2
    return
  }
  if (commandArgs.length && !['ask', 'approval', 'project', 'projects', 'login'].includes(command)) {
    throw new Error(`${command} does not accept options`)
  }
  if (command === 'login') {
    const allowedLogin = new Set(['--switch', '--stay-open', '--keep-open', '--auto', '--from-env', '--env', '--headless', '--headful'])
    for (const arg of commandArgs) {
      if (allowedLogin.has(arg) || arg.startsWith('--wait=') || arg.startsWith('--timeout=')) continue
      if (arg === '--wait' || arg === '--stay-open' || arg === '--keep-open') continue
      throw new Error(`unknown login option: ${arg} (allowed: --auto, --switch, --wait=SECONDS, --keep-open, --stay-open, --timeout=SECONDS, --headless/--headful)`)
    }
  }
  await acquireLock()
  try {
    if (command === 'login') await login()
    else if (command === 'status') await status()
    else if (command === 'ask') await ask()
    else if (command === 'chats') await chats()
    else if (command === 'reset') await reset()
    else if (command === 'approval') await approval()
    else await project()
  } finally {
    releaseLock()
  }
}

main().catch((error) => {
  process.stderr.write(`chatgpt-consult: ${error.message}\n`)
  process.exitCode = 1
})
