// Compatibility entry point for existing npm build commands; the app is Swift-only.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
execFileSync('python3', [fileURLToPath(new URL('./build-desktop.py', import.meta.url))], { stdio: 'inherit' });
