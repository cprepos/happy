import { describe, expect, it } from 'vitest';

import { buildAgyArgs, extractAgyResumeFlag } from './cliArgs';

describe('buildAgyArgs', () => {
  it('uses --sandbox for non-skip permission modes and puts the prompt last', () => {
    const args = buildAgyArgs({ prompt: 'hello world', permissionMode: 'default' });

    expect(args).toContain('--sandbox');
    expect(args).not.toContain('--dangerously-skip-permissions');
    expect(args.slice(-2)).toEqual(['--print', 'hello world']);
  });

  it('asks for stream-json output, whose result names the conversation agy used', () => {
    const args = buildAgyArgs({ prompt: 'p', permissionMode: 'default' });
    expect(args[args.indexOf('--output-format') + 1]).toBe('stream-json');
  });

  it('uses --dangerously-skip-permissions for yolo-style modes', () => {
    for (const mode of ['yolo', 'safe-yolo', 'bypassPermissions', 'acceptEdits'] as const) {
      const args = buildAgyArgs({ prompt: 'p', permissionMode: mode });
      expect(args).toContain('--dangerously-skip-permissions');
      expect(args).not.toContain('--sandbox');
    }
  });

  it('passes the model via --model', () => {
    const args = buildAgyArgs({ prompt: 'p', permissionMode: 'default', model: 'Gemini 3.8 Flash (Medium)' });
    const idx = args.indexOf('--model');
    expect(idx).toBeGreaterThanOrEqual(0);
    expect(args[idx + 1]).toBe('Gemini 3.8 Flash (Medium)');
  });

  it('resumes a conversation via --conversation when an id is given', () => {
    const args = buildAgyArgs({ prompt: 'p', permissionMode: 'default', conversationId: 'cid-123' });
    const idx = args.indexOf('--conversation');
    expect(idx).toBeGreaterThanOrEqual(0);
    expect(args[idx + 1]).toBe('cid-123');
  });

  it('omits --conversation for a fresh conversation', () => {
    expect(buildAgyArgs({ prompt: 'p', permissionMode: 'default' })).not.toContain('--conversation');
    expect(buildAgyArgs({ prompt: 'p', permissionMode: 'default', conversationId: null })).not.toContain('--conversation');
  });

  it('adds a repeatable --add-dir for each directory', () => {
    const args = buildAgyArgs({ prompt: 'p', permissionMode: 'default', addDirs: ['/a', '/b'] });
    expect(args.filter((a) => a === '--add-dir')).toHaveLength(2);
    expect(args).toContain('/a');
    expect(args).toContain('/b');
  });

  it('passes --print-timeout when provided', () => {
    const args = buildAgyArgs({ prompt: 'p', permissionMode: 'default', printTimeout: '10m' });
    const idx = args.indexOf('--print-timeout');
    expect(idx).toBeGreaterThanOrEqual(0);
    expect(args[idx + 1]).toBe('10m');
  });
});

describe('extractAgyResumeFlag', () => {
  it('returns null and preserves args when resume flag is absent', () => {
    const parsed = extractAgyResumeFlag(['--started-by', 'terminal']);

    expect(parsed.resumeConversationId).toBeNull();
    expect(parsed.args).toEqual(['--started-by', 'terminal']);
  });

  it('extracts an explicit resume conversation ID', () => {
    const parsed = extractAgyResumeFlag(['--resume', 'conv-123', '--started-by', 'daemon']);

    expect(parsed.resumeConversationId).toBe('conv-123');
    expect(parsed.args).toEqual(['--started-by', 'daemon']);
  });

  it('accepts the short alias', () => {
    const parsed = extractAgyResumeFlag(['-r', 'conv-789']);

    expect(parsed.resumeConversationId).toBe('conv-789');
    expect(parsed.args).toEqual([]);
  });

  it('supports equals syntax', () => {
    const parsed = extractAgyResumeFlag(['--resume=conv-456', '--started-by', 'terminal']);

    expect(parsed.resumeConversationId).toBe('conv-456');
    expect(parsed.args).toEqual(['--started-by', 'terminal']);
  });

  it('throws when resume flag is missing a conversation ID', () => {
    expect(() => extractAgyResumeFlag(['--resume'])).toThrow(
      'Agy resume requires a conversation ID: happy agy --resume <conversation-id>',
    );
    expect(() => extractAgyResumeFlag(['--resume', '--started-by', 'daemon'])).toThrow(
      'Agy resume requires a conversation ID',
    );
    expect(() => extractAgyResumeFlag(['--resume='])).toThrow('Agy resume requires a conversation ID');
    expect(() => extractAgyResumeFlag(['--resume', ''])).toThrow('Agy resume requires a conversation ID');
    expect(() => extractAgyResumeFlag(['--resume', '   '])).toThrow('Agy resume requires a conversation ID');
    expect(() => extractAgyResumeFlag(['--resume=   '])).toThrow('Agy resume requires a conversation ID');
  });

  it('throws when the resume flag is given twice', () => {
    expect(() => extractAgyResumeFlag(['--resume', 'a', '--resume=b'])).toThrow(
      'Agy resume flag can only be provided once.',
    );
  });
});
