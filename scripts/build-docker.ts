#!/usr/bin/env bun
import { execSync } from "child_process";
import { resolve } from "path";

const ROOT = resolve(import.meta.dir, "..");

const args = process.argv.slice(2);
const target = args[0] || 'agents-runner';
const image = args[1] || 'btr-agents:latest';

console.log('Installing dependencies for Docker build...');

execSync('bun install', { stdio: 'inherit', cwd: ROOT });
console.log('Dependencies installed. Now building Docker images...');

const dockerCmd = 'docker build -f Dockerfile.back --target ' + target + ' -t ' + image + ' .';

execSync(dockerCmd, { stdio: 'inherit', cwd: ROOT, env: { ...process.env, DOCKER_BUILDKIT: '1' } });
