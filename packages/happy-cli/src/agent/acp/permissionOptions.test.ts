import { describe, expect, it } from 'vitest';
import { buildPermissionInputFromRawInput, selectAcpPermissionOptionId } from './permissionOptions';

// Exactly what `opencode acp` 1.19 offers in session/request_permission.
const OPENCODE_OPTIONS = [
  { kind: 'allow_once', name: 'Allow once', optionId: 'once' },
  { kind: 'allow_always', name: 'Always allow', optionId: 'always' },
  { kind: 'reject_once', name: 'Reject', optionId: 'reject' },
];

const GEMINI_OPTIONS = [
  { kind: 'allow_always', name: 'Allow All Edits', optionId: 'proceed_always' },
  { kind: 'allow_once', name: 'Allow', optionId: 'proceed_once' },
  { kind: 'reject_once', name: 'Reject', optionId: 'cancel' },
];

describe('selectAcpPermissionOptionId', () => {
  it('maps decisions onto OpenCode option ids by kind', () => {
    expect(selectAcpPermissionOptionId(OPENCODE_OPTIONS, 'approved')).toBe('once');
    expect(selectAcpPermissionOptionId(OPENCODE_OPTIONS, 'approved_for_session')).toBe('always');
    expect(selectAcpPermissionOptionId(OPENCODE_OPTIONS, 'denied')).toBe('reject');
    expect(selectAcpPermissionOptionId(OPENCODE_OPTIONS, 'abort')).toBe('reject');
  });

  it('keeps Gemini option ids working', () => {
    expect(selectAcpPermissionOptionId(GEMINI_OPTIONS, 'approved')).toBe('proceed_once');
    expect(selectAcpPermissionOptionId(GEMINI_OPTIONS, 'approved_for_session')).toBe('proceed_always');
    expect(selectAcpPermissionOptionId(GEMINI_OPTIONS, 'denied')).toBe('cancel');
  });

  it('falls back to legacy ids and names when kinds are missing', () => {
    const legacy = [
      { optionId: 'proceed_once', name: 'Proceed once' },
      { optionId: 'proceed_always', name: 'Proceed always' },
      { optionId: 'cancel', name: 'Cancel' },
    ];
    expect(selectAcpPermissionOptionId(legacy, 'approved')).toBe('proceed_once');
    expect(selectAcpPermissionOptionId(legacy, 'approved_for_session')).toBe('proceed_always');
    expect(selectAcpPermissionOptionId(legacy, 'denied')).toBe('cancel');
  });

  it('approves once when no always option exists', () => {
    expect(selectAcpPermissionOptionId(OPENCODE_OPTIONS.filter((o) => o.kind !== 'allow_always'), 'approved_for_session')).toBe('once');
  });

  it('defaults when the agent offered nothing', () => {
    expect(selectAcpPermissionOptionId([], 'approved')).toBe('proceed_once');
    expect(selectAcpPermissionOptionId([], 'denied')).toBe('cancel');
  });
});

describe('buildPermissionInputFromRawInput', () => {
  it('carries rawInput and the title for the app tool views', () => {
    expect(buildPermissionInputFromRawInput({
      kind: 'execute',
      title: 'echo hi > out.txt',
      rawInput: { command: 'echo hi > out.txt' },
    })).toEqual({
      command: 'echo hi > out.txt',
      toolCall: { title: 'echo hi > out.txt', kind: 'execute' },
    });
  });

  it('returns null without an object rawInput', () => {
    expect(buildPermissionInputFromRawInput({ kind: 'execute' })).toBeNull();
    expect(buildPermissionInputFromRawInput({ rawInput: ['x'] })).toBeNull();
  });
});
