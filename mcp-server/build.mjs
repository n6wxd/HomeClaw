import { build } from 'esbuild';

await build({
  entryPoints: ['mcp-server/server.js'],
  bundle: true,
  platform: 'node',
  target: 'node20',
  format: 'esm',
  outfile: 'mcp-server/dist/server.js',
  banner: {
    js: 'import { createRequire } from "module"; const require = createRequire(import.meta.url);',
  },
  external: [],
});

console.log('Built mcp-server/dist/server.js');
