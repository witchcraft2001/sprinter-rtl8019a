// Shared helpers for the actual-EXE test suites.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');

let cases = 0;
function count(n = 1) { cases += n; }
function caseCount() { return cases; }

function checkCleanup(result) {
  assert.deepStrictEqual(result.cleanup, { isaClosed: true, pagesFreed: true, filesClosed: true });
  count();
}

// For CLAIM_RUNTIME_PAGE-style apps (win2page.asm): the process's single
// runtime page is deliberately never explicitly FREEMEM'd -- real DSS
// EXEC/LEAVE reclaims it on exit -- so cleanup.pagesFreed is not asserted.
function checkCleanupClaimedPage(result) {
  assert.strictEqual(result.cleanup.isaClosed, true);
  assert.strictEqual(result.cleanup.filesClosed, true);
  count();
}

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function inetChecksum(bytes) {
  let sum = 0;
  for (let i = 0; i < bytes.length; i += 2) {
    sum += (bytes[i] << 8) | (bytes[i + 1] || 0);
    sum = (sum & 0xffff) + (sum >>> 16);
  }
  return (~sum) & 0xffff;
}

module.exports = { count, caseCount, checkCleanup, checkCleanupClaimedPage, crc32, inetChecksum };
