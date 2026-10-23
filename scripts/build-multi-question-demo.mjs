// Build only the local fixture. The normal production build still uses index.html.
import { build } from 'vite';
import { rename } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
const outDir = path.resolve(process.argv[2] || path.join(os.homedir(), '.cache/heimdall-tests/multi-question-ui-preview'));
await build({ build: { outDir, emptyOutDir: true, rollupOptions: { input: 'multi-question-demo.html' } } });
await rename(path.join(outDir, 'multi-question-demo.html'), path.join(outDir, 'index.html'));
console.log(`Fixture built at ${outDir}`);
