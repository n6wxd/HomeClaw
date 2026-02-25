/**
 * HomeClaw — OpenClaw plugin entry point for HomeKit Bridge.
 *
 * This plugin discovers the homekit-cli binary and registers it with
 * OpenClaw for HomeKit smart home control.
 *
 * Binary discovery order:
 * 1. Plugin config `binDir`
 * 2. HOMEKIT_BRIDGE_BIN_DIR environment variable
 * 3. App bundle (/Applications/HomeKit Bridge.app/Contents/MacOS/)
 * 4. Standard locations (~/.local/bin/, /usr/local/bin/)
 * 5. Build output (.build/debug/, .build/release/)
 */

import { existsSync } from 'node:fs';

export const TOOL_PREFIX = 'homekit';

export function discoverBinary(configBinDir?: string): string | null {
  const candidates: string[] = [];

  // 1. Plugin config
  if (configBinDir) {
    candidates.push(`${configBinDir}/homekit-cli`);
  }

  // 2. Environment variable
  const envDir = process.env.HOMEKIT_BRIDGE_BIN_DIR;
  if (envDir) {
    candidates.push(`${envDir}/homekit-cli`);
  }

  // 3. Standard locations
  const home = process.env.HOME || '';
  candidates.push(
    '/Applications/HomeKit Bridge.app/Contents/MacOS/homekit-cli',
    `${home}/.local/bin/homekit-cli`,
    '/usr/local/bin/homekit-cli',
    `${home}/GitHub/HomeClaw/.build/debug/homekit-cli`,
    `${home}/GitHub/HomeClaw/.build/release/homekit-cli`,
  );

  for (const path of candidates) {
    if (existsSync(path)) {
      return path;
    }
  }
  return null;
}

/**
 * OpenClaw plugin entry point.
 *
 * Called by the OpenClaw gateway when the plugin loads. Validates that the
 * homekit-cli binary is discoverable and logs a warning if not found.
 */
export function register(api: any): void {
  const config = api.getConfig?.() ?? {};
  const binPath = discoverBinary(config.binDir);

  if (binPath) {
    api.log?.('info', `HomeClaw: using homekit-cli at ${binPath}`);
  } else {
    api.log?.('warn', 'HomeClaw: homekit-cli not found. Install HomeKit Bridge.app or set binDir in plugin config.');
  }
}
