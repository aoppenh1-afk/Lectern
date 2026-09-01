import Foundation

guard ThinkingLevel.chatOptions(
    profileID: "opencode",
    advertised: []
) == ThinkingLevel.generationDefaults else {
    fputs("FAIL: OpenCode chat hid the thinking selector without per-model metadata\n", stderr)
    exit(1)
}

guard ThinkingLevel.chatOptions(
    profileID: "codex",
    advertised: []
).isEmpty else {
    fputs("FAIL: unsupported agents were given invented thinking levels\n", stderr)
    exit(1)
}

print("PASS: OpenCode chat always exposes supported thinking levels")
