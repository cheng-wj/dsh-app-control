#!/usr/bin/env node
/**
 * list-plugins.js - print direct plugin dependencies and their installed versions.
 *
 * Called by dsh-tools.bat status. Kept as a separate file because embedding
 * this as a `node -e` one-liner inside a .bat requires escaping layers of
 * quotes for cmd, batch and JavaScript at once, which is unmaintainable.
 *
 * Usage: node list-plugins.js <profileDir>
 */

'use strict';

const path = require('path');
const fs = require('fs');

const profileDir = process.argv[2];

if (!profileDir) {
    console.error('usage: node list-plugins.js <profileDir>');
    process.exit(2);
}

const pkgPath = path.join(profileDir, 'package.json');

if (!fs.existsSync(pkgPath)) {
    console.log('  [not found] ' + pkgPath);
    process.exit(1);
}

let pkg;
try {
    pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
} catch (err) {
    console.log('  [unreadable] ' + pkgPath + ' :: ' + err.message);
    process.exit(1);
}

const deps = pkg.dependencies || {};
const names = Object.keys(deps).sort();

if (names.length === 0) {
    console.log('  (no direct dependencies declared)');
    process.exit(0);
}

const rows = names.map((name) => {
    const manifest = path.join(profileDir, 'node_modules', name, 'package.json');
    let installed = 'MISSING';

    if (fs.existsSync(manifest)) {
        try {
            installed = JSON.parse(fs.readFileSync(manifest, 'utf8')).version || '?';
        } catch (err) {
            installed = 'UNREADABLE';
        }
    }

    let flag = '';
    if (installed === 'MISSING') {
        flag = '  <-- declared but not installed';
    } else if (deps[name] !== installed) {
        // ranges like ^1.2.3 will almost always differ from the resolved version;
        // only flag exact pins that drifted.
        const declared = deps[name];
        const looksExact = /^\d+\.\d+\.\d+/.test(declared);
        if (looksExact && declared !== installed) {
            flag = '  <-- declared ' + declared + ', installed differs';
        }
    }

    return '  ' + name.padEnd(40) + installed + flag;
});

console.log(rows.join('\n'));
