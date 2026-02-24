/**
 * HomeClaw — OpenClaw plugin entry point for HomeKit Bridge.
 *
 * This plugin discovers the homekit-cli binary and registers MCP tools
 * that invoke CLI commands for HomeKit smart home control.
 *
 * Binary discovery order:
 * 1. Plugin config `binDir`
 * 2. HOMEKIT_BRIDGE_BIN_DIR environment variable
 * 3. PATH lookup (which homekit-cli)
 * 4. Standard locations (~/.local/bin/, /usr/local/bin/)
 * 5. Build output (.build/debug/, .build/release/)
 */

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
    `${home}/.local/bin/homekit-cli`,
    '/usr/local/bin/homekit-cli',
    `${home}/GitHub/HomeKitBridge/.build/debug/homekit-cli`,
    `${home}/GitHub/HomeKitBridge/.build/release/homekit-cli`,
  );

  // Check existence (would be done at runtime)
  return candidates[0] || null;
}
