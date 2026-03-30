export async function loadDefaultAgentInstructionsBundle(_role: string): Promise<Record<string, string>> {
  return {};
}

export function resolveDefaultAgentInstructionsBundleRole(_role: string): string {
  return "default";
}
