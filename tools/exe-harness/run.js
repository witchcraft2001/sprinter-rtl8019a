#!/usr/bin/env node
// CLI wrapper for the actual DSS EXE harness.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const fs = require('fs');
const { runExe } = require('./harness.js');

if (process.argv.length < 3) {
  console.error('usage: run.js EXE [command-line] [scenario.json]');
  process.exit(2);
}
const scenario = process.argv[4] ? JSON.parse(fs.readFileSync(process.argv[4], 'utf8')) : {};
const result = runExe(process.argv[2], process.argv[3] || '', scenario);
process.stdout.write(JSON.stringify(result, null, 2) + '\n');
process.exit(result.exitCode === 0 ? 0 : 1);
