// Verify that the batch file survived a clone/checkout with CRLF intact.
//
// cmd.exe silently truncates an LF-only .bat at a `call :LABEL` boundary, so a
// mangled line ending turns the scheduler into a no-op that reports no error.
// Run this after cloning, or in CI, before trusting a checkout:
//
//   node assets/check-crlf.js
//
// Exits 0 when every .bat/.cmd under assets/ has matching CR and LF counts,
// exits 1 otherwise.

import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ASSETS = join(dirname(fileURLToPath(import.meta.url)), "..", "assets")
const NEEDS_CRLF = /\.(bat|cmd)$/i

const offenders = []
let checked = 0

for (const entry of readdirSync(ASSETS, { withFileTypes: true })) {
  if (!entry.isFile() || !NEEDS_CRLF.test(entry.name)) continue

  const buf = readFileSync(join(ASSETS, entry.name))
  let cr = 0
  let lf = 0
  for (const byte of buf) {
    if (byte === 13) cr++
    else if (byte === 10) lf++
  }

  checked++
  if (cr !== lf || cr === 0) {
    offenders.push(`${entry.name}: CR=${cr} LF=${lf} (expected equal and non-zero)`)
  } else {
    console.log(`ok  ${entry.name}  ${cr} CRLF`)
  }
}

if (checked === 0) {
  console.error('no .bat/.cmd files found under assets/ — nothing verified')
  process.exit(1)
}

if (offenders.length > 0) {
  console.error('\nBROKEN line endings — cmd.exe will truncate these files:')
  for (const line of offenders) console.error(`  ${line}`)
  console.error('\nThe repository pins *.bat and *.cmd to eol=crlf via .gitattributes.')
  console.error('A clone that lost CRLF usually means that file was bypassed.')
  process.exit(1)
}

console.log(`\nall ${checked} batch file(s) carry CRLF`)
