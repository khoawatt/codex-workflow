export const MAX_ROUTE_RECOVERIES = 3
export const OPENAI_AUTH_STUCK_MS = 25000
export const OPENAI_AUTH_HARD_TIMEOUT_MS = 60000
export const OPENAI_AUTH_TRANSACTION_STORAGE_KEY_PATTERN = '(^|[._-])(state|nonce|transaction|transact|pkce|code[_-]?verifier|csrf)([._-]|$)|^a0\\.spajs\\.txs\\.'
export const TOTP_STEP_SEC = 30
export const TOTP_DIGITS_DEFAULT = 6
export const TOTP_MIN_WINDOW_REMAINING_MS = 3000
import { createHmac } from 'node:crypto'

export const ROUTE_RECOVERY_EXHAUSTED_MESSAGE = [
  'Auth0 Route Error vẫn lặp lại sau 3 lần recovery.',
  'Chạy lần lượt:',
  'chatgpt-consult logout',
  'chatgpt-consult login',
].join('\n')

export function isAuth0RouteError(bodyText) {
  return /oops,? an error occurred|route error|invalid content type/i.test(bodyText || '')
}

export function isInteractiveOpenAiChallenge(bodyText, url) {
  const body = String(bodyText || '').toLowerCase()
  const interactiveText = /verify you are human|captcha|challenge|two-?factor|2fa|multi-?factor|mfa|authenticator|verification code|check your email|we sent you|enter.*code|one-time-code|one time code|otp/.test(body)
  const challengeUrl = /__cf_chl|challenges\.cloudflare/.test(String(url || ''))
  return interactiveText || challengeUrl
}

export function detectOpenAiAuthBlocker(bodyText, url) {
  if (!bodyText) return null
  bodyText = String(bodyText).toLowerCase()
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

export function isOpenAiAuthTransactionCookie(cookie) {
  const domain = String(cookie?.domain || '').replace(/^\./, '').toLowerCase()
  const onAuthOrigin = domain === 'auth.openai.com'
    || domain === 'accounts.openai.com'
    || domain === 'auth0.openai.com'
    || domain.endsWith('.auth0.com')
  if (!onAuthOrigin) return false

  const name = String(cookie?.name || '').toLowerCase()
  return isOpenAiAuthTransactionStorageKey(name)
}

export function isOpenAiAuthTransactionStorageKey(key) {
  return new RegExp(OPENAI_AUTH_TRANSACTION_STORAGE_KEY_PATTERN, 'i').test(String(key || ''))
}

export function isOpenAiAuthUrl(url) {
  try {
    const hostname = new URL(url).hostname.toLowerCase()
    return hostname === 'auth.openai.com'
      || hostname === 'accounts.openai.com'
      || hostname === 'auth0.openai.com'
      || hostname.endsWith('.auth0.com')
  } catch {
    return false
  }
}

export function isRecoverableOpenAiRouteError(bodyText, url) {
  return isOpenAiAuthUrl(url) && isAuth0RouteError(bodyText)
}

export function createOpenAiAuthAttempt(maxRecoveries = MAX_ROUTE_RECOVERIES) {
  return {
    maxRecoveries,
    recoveries: 0,
    passwordSubmitted: false,
    totpSubmittedCounter: null,
    totpRetried: false,
  }
}

export function claimPasswordSubmit(attempt) {
  if (attempt.passwordSubmitted) return false
  attempt.passwordSubmitted = true
  return true
}

// Claim one TOTP submission for a given time-step counter. The first claim
// always succeeds; a second claim succeeds only for a strictly advanced
// counter (the single allowed retry) and any further claim fails. This makes
// replaying an already-submitted code impossible by construction.
export function claimTotpSubmit(attempt, counter) {
  if (attempt.totpSubmittedCounter === counter) return false
  if (attempt.totpSubmittedCounter !== null && attempt.totpRetried) return false
  if (attempt.totpSubmittedCounter !== null) attempt.totpRetried = true
  attempt.totpSubmittedCounter = counter
  return true
}

export function claimRouteRecovery(attempt) {
  if (attempt.recoveries >= attempt.maxRecoveries) return false
  attempt.recoveries++
  attempt.passwordSubmitted = false
  return true
}

export async function waitForOpenAiPasswordOutcome({
  observe,
  wait,
  now = Date.now,
  pollMs = 750,
  stuckMs = OPENAI_AUTH_STUCK_MS,
  hardTimeoutMs = OPENAI_AUTH_HARD_TIMEOUT_MS,
}) {
  const startedAt = now()
  while (true) {
    const observation = await observe()
    if (observation.state !== 'pending') return observation

    const elapsed = now() - startedAt
    if (elapsed >= hardTimeoutMs) return { state: 'timeout' }
    if (!observation.busy && elapsed >= stuckMs) return { state: 'stuck' }

    await wait(Math.min(pollMs, hardTimeoutMs - elapsed))
  }
}

// ---------- TOTP (RFC 6238, authenticator-app autofill) ----------
// Pure functions only — no browser, no I/O — so they are unit-testable.
// Errors are generic on purpose: they must never echo the secret.

const BASE32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'

export function normalizeTotpSecret(secret) {
  return String(secret || '').replace(/[\s-]+/g, '').toUpperCase()
}

export function base32Decode(input) {
  const s = normalizeTotpSecret(input)
  if (!s || s.length % 8 !== 0) throw new Error('invalid TOTP secret in .env')
  const padLen = (s.match(/=+$/) || [''])[0].length
  if (![0, 1, 3, 4, 6].includes(padLen)) throw new Error('invalid TOTP secret in .env')
  const body = s.slice(0, s.length - padLen)
  const out = []
  let buffer = 0
  let bitsLeft = 0
  for (const ch of body) {
    const v = BASE32_ALPHABET.indexOf(ch)
    if (v < 0) throw new Error('invalid TOTP secret in .env')
    buffer = (buffer << 5) | v
    bitsLeft += 5
    if (bitsLeft >= 8) {
      bitsLeft -= 8
      out.push((buffer >> bitsLeft) & 0xff)
    }
  }
  if (bitsLeft > 0 && (buffer & ((1 << bitsLeft) - 1)) !== 0) throw new Error('invalid TOTP secret in .env')
  if (out.length === 0) throw new Error('invalid TOTP secret in .env')
  return Buffer.from(out)
}

export function totpCounterAt(timeMs, stepSec = TOTP_STEP_SEC) {
  return Math.floor(Number(timeMs) / 1000 / stepSec)
}

export function totpMsRemainingInWindow(timeMs = Date.now(), stepSec = TOTP_STEP_SEC) {
  const stepMs = stepSec * 1000
  return stepMs - (Number(timeMs) % stepMs)
}

export function totpCode(secret, { timeMs = Date.now(), stepSec = TOTP_STEP_SEC, digits = TOTP_DIGITS_DEFAULT } = {}) {
  const key = base32Decode(secret) // throws generic error, never echoes secret
  const counter = totpCounterAt(timeMs, stepSec)
  const msg = Buffer.alloc(8)
  msg.writeBigUInt64BE(BigInt(counter))
  const mac = createHmac('sha1', key).update(msg).digest()
  const offset = mac[mac.length - 1] & 0x0f
  const code = ((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3]
  return { code: String(code % 10 ** digits).padStart(digits, '0'), counter }
}

// Gate for TOTP autofill. ALL of these must hold:
//  - page is on an OpenAI auth origin (never fill OTP inputs elsewhere),
//  - the page is positively an authenticator-MFA challenge,
//  - the page is NOT an email-code prompt (those have no TOTP secret).
export function isOpenAiAuthenticatorChallenge(bodyText, url) {
  if (!isOpenAiAuthUrl(url)) return false
  const body = String(bodyText || '').toLowerCase()
  if (/check your email|we sent you/.test(body)) return false
  if (/\/mfa-challenge/.test(String(url || ''))) return true
  return /authenticator|one-time authentication code|one-time-code|one time code/.test(body)
}
