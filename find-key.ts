#!/usr/bin/env bun

import { readFile } from 'fs/promises';

const docs = JSON.parse(await readFile('front/public/compiled-docs/docs.json', 'utf-8'));
const keys = Object.keys(docs).filter(k => k.includes('deployment') || k.includes('upgrades'));
console.log('Matching keys:', keys);
