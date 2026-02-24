import { sendCommand } from '../socket-client.js';

/**
 * Maps MCP tool calls to HomeKit Bridge socket commands.
 */

export async function handleStatus() {
  return sendCommand('status');
}

export async function handleAccessories(args) {
  const action = args.action || 'list';

  switch (action) {
    case 'list': {
      const socketArgs = {};
      if (args.home_id) socketArgs.home_id = args.home_id;
      if (args.room) socketArgs.room = args.room;
      return sendCommand('list_accessories', socketArgs);
    }

    case 'get': {
      if (!args.accessory_id) throw new Error('accessory_id is required for get action');
      return sendCommand('get_accessory', { id: args.accessory_id });
    }

    case 'search': {
      if (!args.query) throw new Error('query is required for search action');
      const socketArgs = { query: args.query };
      if (args.category) socketArgs.category = args.category;
      return sendCommand('search', socketArgs);
    }

    case 'control': {
      if (!args.accessory_id) throw new Error('accessory_id is required for control action');
      if (!args.characteristic) throw new Error('characteristic is required for control action');
      if (!args.value) throw new Error('value is required for control action');
      return sendCommand('control', {
        id: args.accessory_id,
        characteristic: args.characteristic,
        value: args.value,
      });
    }

    default:
      throw new Error(`Unknown accessories action: ${action}`);
  }
}

export async function handleRooms(args) {
  const socketArgs = {};
  if (args.home_id) socketArgs.home_id = args.home_id;
  return sendCommand('list_rooms', socketArgs);
}

export async function handleScenes(args) {
  const action = args.action || 'list';

  switch (action) {
    case 'list': {
      const socketArgs = {};
      if (args.home_id) socketArgs.home_id = args.home_id;
      return sendCommand('list_scenes', socketArgs);
    }

    case 'trigger': {
      if (!args.scene_id) throw new Error('scene_id is required for trigger action');
      return sendCommand('trigger_scene', { id: args.scene_id });
    }

    default:
      throw new Error(`Unknown scenes action: ${action}`);
  }
}

export async function handleDeviceMap(args) {
  const socketArgs = {};
  if (args.home_id) socketArgs.home_id = args.home_id;
  return sendCommand('device_map', socketArgs);
}

export async function handleConfig(args) {
  const action = args.action || 'get';

  switch (action) {
    case 'get':
      return sendCommand('get_config');

    case 'set': {
      const socketArgs = {};
      if (args.default_home_id === '' || args.default_home_id === 'none') {
        socketArgs.default_home_id = '';
      } else if (args.default_home_id) {
        socketArgs.default_home_id = args.default_home_id;
      }
      if (args.accessory_filter_mode) {
        socketArgs.accessory_filter_mode = args.accessory_filter_mode;
      }
      if (args.allowed_accessory_ids && args.allowed_accessory_ids.length > 0) {
        socketArgs.allowed_accessory_ids = args.allowed_accessory_ids;
      }
      return sendCommand('set_config', socketArgs);
    }

    default:
      throw new Error(`Unknown config action: ${action}`);
  }
}
