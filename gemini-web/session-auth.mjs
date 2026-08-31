const googleAuthCookieNames = new Set([
  'SID', 'HSID', 'SSID', 'APISID', 'SAPISID',
  '__Secure-1PSID', '__Secure-3PSID',
  '__Secure-1PAPISID', '__Secure-3PAPISID',
])

export function hasGoogleSessionCookie(cookieNames) {
  return cookieNames.some((name) => googleAuthCookieNames.has(name))
}

export function classifyGeminiSession({
  onGeminiOrigin,
  explicitSignedOut,
  identityEvidence,
  canAsk,
  cookieNames = [],
}) {
  const googleSessionCookie = hasGoogleSessionCookie(cookieNames)
  // Cookies are corroborating diagnostics only. A Google session may belong to
  // another product/account flow while Gemini itself is still signed out.
  const loggedIn = onGeminiOrigin && !explicitSignedOut && identityEvidence
  return {
    loggedIn,
    canAsk,
    guestAvailable: !loggedIn && canAsk,
    googleSessionCookie,
  }
}

export function advanceLoginStability(previousCount, state, sameDocument, documentSettled = true) {
  if (!documentSettled || !state || !state.loggedIn || !state.canAsk) return 0
  return sameDocument ? previousCount + 1 : 1
}
