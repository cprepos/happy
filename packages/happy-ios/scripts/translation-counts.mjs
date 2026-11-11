#!/usr/bin/env node
// Ours: the counts TranslationCatalogTests pins, worked out from what
// generate-translations.mjs wrote and from HappyUI's Strings sources, so
// the test reads them instead of numbers kept by hand. Run after the
// generator (make -C packages/happy-i18n translations does both).
// Writes Tests/HappyCoreTests/Fixtures/translation-counts.json.
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { readCatalog } from '../../happy-i18n/catalogs.mjs';

const root = new URL('../', import.meta.url);
const fixture = name => new URL(`Tests/HappyCoreTests/Fixtures/${name}`, root);

// Every vector, in every language: what the vector test checks.
const vectors = JSON.parse(readFileSync(fixture('translation-vectors.json'), 'utf8'));
const vectorCount = Object.values(vectors).reduce((sum, list) => sum + list.length, 0);

// English's keys, without the native ones the app adds itself.
const keys = Object.keys(readCatalog('en').entries).filter(key => !key.startsWith('native.')).length;

// Each Strings file's localized() calls, as the test counts them: a
// string has its English as a literal, a function's values come second.
const plain = /localized\("([A-Za-z0-9_.]+)", "((?:[^"\\]|\\.)*)"\)/g;
const call = /localized\("([A-Za-z0-9_.]+)"/g;
const ui = new URL('Sources/HappyUI/', root);
const files = [new URL('Strings.swift', ui)]
    .concat(readdirSync(new URL('Strings/', ui)).sort().map(name => new URL(`Strings/${name}`, ui)));
const localized = {};
for (const file of files) {
    const name = decodeURIComponent(file.pathname.split('/').at(-1));
    if (!name.endsWith('.swift') || name === 'Localized.swift') continue;
    const source = readFileSync(file, 'utf8');
    const strings = [...source.matchAll(plain)].length;
    const calls = [...source.matchAll(call)].length;
    // A file with no catalog calls isn't listed; the test checks that too.
    if (calls) localized[name] = { strings, functions: calls - strings };
}

// One file to a line, so a change shows as that line.
const entries = Object.entries(localized).map(([name, value]) => `    ${JSON.stringify(name)}: ${JSON.stringify(value)}`);
writeFileSync(fixture('translation-counts.json'),
    `{\n  "vectors": ${vectorCount},\n  "keys": ${keys},\n  "localized": {\n${entries.join(',\n')}\n  }\n}\n`);
console.log(`translation counts: ${vectorCount} vectors, ${keys} keys, ${Object.keys(localized).length} Strings files`);
