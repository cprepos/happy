/**
 * ACP permission option selection
 *
 * Maps Happy's permission decision onto one of the options an ACP agent offered
 * in `session/request_permission`. The ACP spec gives every option a `kind`
 * (`allow_once`, `allow_always`, `reject_once`, `reject_always`) while the
 * `optionId` is agent-defined: Gemini uses `proceed_once`/`proceed_always`/
 * `cancel`, OpenCode uses `once`/`always`/`reject`. Matching on `kind` first
 * keeps a denial from being sent as an id the agent never offered.
 */

export type AcpPermissionOption = {
  optionId?: string;
  name?: string;
  kind?: string;
};

export type AcpPermissionDecision = 'approved' | 'approved_for_session' | 'denied' | 'abort';

function findOption(
  options: AcpPermissionOption[],
  kinds: string[],
  legacyId: string,
  nameHint: string,
): AcpPermissionOption | undefined {
  return options.find((opt) => typeof opt.kind === 'string' && kinds.includes(opt.kind))
    ?? options.find((opt) => opt.optionId === legacyId || opt.name?.toLowerCase().includes(nameHint) === true);
}

/**
 * Pick the optionId to answer an ACP permission request with.
 *
 * Approvals prefer the "always" option for `approved_for_session` and fall back
 * to "once", then to the first option. Denials pick a reject option and fall
 * back to `cancel`, which is what agents without reject options expect.
 */
export function selectAcpPermissionOptionId(
  options: AcpPermissionOption[],
  decision: AcpPermissionDecision,
): string {
  if (decision === 'approved' || decision === 'approved_for_session') {
    const always = findOption(options, ['allow_always'], 'proceed_always', 'always');
    const once = findOption(options, ['allow_once'], 'proceed_once', 'once');
    if (decision === 'approved_for_session' && always?.optionId) {
      return always.optionId;
    }
    if (once?.optionId) {
      return once.optionId;
    }
    return options[0]?.optionId ?? 'proceed_once';
  }

  const reject = findOption(options, ['reject_once', 'reject_always'], 'cancel', 'cancel')
    ?? findOption(options, [], 'reject', 'reject');
  return reject?.optionId ?? 'cancel';
}

type PermissionToolCall = {
  title?: unknown;
  kind?: unknown;
  rawInput?: unknown;
};

/**
 * Tool input shown in the app's permission card.
 *
 * Spec-compliant agents (OpenCode) put the tool arguments in `rawInput` and a
 * human-readable summary in `title`. The app's ACP tool views read the title
 * from `input.toolCall.title`, so it is carried along with the arguments.
 */
export function buildPermissionInputFromRawInput(toolCall: PermissionToolCall): Record<string, unknown> | null {
  const rawInput = toolCall.rawInput;
  if (!rawInput || typeof rawInput !== 'object' || Array.isArray(rawInput)) {
    return null;
  }
  return {
    ...(rawInput as Record<string, unknown>),
    toolCall: {
      ...(typeof toolCall.title === 'string' ? { title: toolCall.title } : {}),
      ...(typeof toolCall.kind === 'string' ? { kind: toolCall.kind } : {}),
    },
  };
}
