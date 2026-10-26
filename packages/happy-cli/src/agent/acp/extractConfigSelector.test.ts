import { describe, expect, it } from 'vitest';
import type { SessionConfigOption } from '@agentclientprotocol/sdk';
import { extractConfigSelector } from './runAcp';

// The order and shape `opencode acp` 1.19 returns from session/new.
const OPENCODE_CONFIG_OPTIONS = [
  {
    id: 'model',
    name: 'Model',
    category: 'model',
    type: 'select',
    currentValue: 'coder/coder',
    options: [{ value: 'coder/coder', name: 'Coder/Qwen' }, { value: 'opencode/big-pickle', name: 'OpenCode Zen/Big Pickle' }],
  },
  {
    id: 'mode',
    name: 'Session Mode',
    category: 'mode',
    type: 'select',
    currentValue: 'build',
    options: [{ value: 'build', name: 'build' }, { value: 'plan', name: 'plan' }],
  },
] as unknown as SessionConfigOption[];

describe('extractConfigSelector', () => {
  it('does not mistake a model option listed first for the mode selector', () => {
    expect(extractConfigSelector(OPENCODE_CONFIG_OPTIONS, 'mode')).toEqual({
      configId: 'mode',
      currentCode: 'build',
      options: [{ code: 'build', value: 'build' }, { code: 'plan', value: 'plan' }],
    });
    expect(extractConfigSelector(OPENCODE_CONFIG_OPTIONS, 'model')?.configId).toBe('model');
  });

  it('falls back to id heuristics when no category is declared', () => {
    const uncategorized = OPENCODE_CONFIG_OPTIONS.map(({ category: _category, ...rest }) => rest) as unknown as SessionConfigOption[];
    expect(extractConfigSelector(uncategorized, 'mode')?.configId).toBe('mode');
    expect(extractConfigSelector(uncategorized, 'model')?.configId).toBe('model');
  });
});
