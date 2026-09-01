#!/bin/sh

set -eu

branch_name="adam-testing"
remote_name="origin"
remote_ref="refs/remotes/${remote_name}/${branch_name}"
remote_branch="refs/heads/${branch_name}"

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

fail() {
    printf 'Adam test push blocked: %s\n' "$1" >&2
    exit 1
}

current_branch=$(git branch --show-current)
[ "$current_branch" = "$branch_name" ] || \
    fail "switch to ${branch_name} before using this workflow"

upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
[ "$upstream" = "${remote_name}/${branch_name}" ] || \
    fail "${branch_name} must track ${remote_name}/${branch_name}"

git_dir=$(git rev-parse --git-dir)
[ ! -f "$git_dir/MERGE_HEAD" ] || fail "finish the current merge first"
[ ! -d "$git_dir/rebase-merge" ] || fail "finish the current rebase first"
[ ! -d "$git_dir/rebase-apply" ] || fail "finish the current rebase first"

[ -z "$(git status --porcelain --untracked-files=normal)" ] || \
    fail "commit or remove every remaining worktree change first"

git fetch --quiet "$remote_name" \
    "${remote_branch}:${remote_ref}" || \
    fail "could not refresh ${remote_name}/${branch_name}"

git merge-base --is-ancestor "$remote_ref" HEAD || \
    fail "the remote branch has commits that are not in this checkout; integrate them without force-pushing"

ahead_count=$(git rev-list --count "${remote_ref}..HEAD")
if [ "$ahead_count" -eq 0 ]; then
    printf 'Adam testing is already up to date at %s.\n' "$(git rev-parse --short HEAD)"
    exit 0
fi

if git rev-list --min-parents=2 "${remote_ref}..HEAD" | grep -q .; then
    fail "merge commits require a manual review and push"
fi

invalid_paths=`
    git diff --name-only "${remote_ref}..HEAD" | while IFS= read -r path; do
        case "$path" in
            AdamVoice/*) : ;;
            HermesGlasses.xcodeproj/project.pbxproj) : ;;
            HermesGlasses/Models/AssistantConversation.swift) : ;;
            HermesGlasses/Services/HermesAudioManager.swift) : ;;
            HermesGlasses/Services/HermesAPIClient.swift) : ;;
            HermesGlasses/Services/HermesSpeechRecognizer.swift) : ;;
            HermesGlasses/Services/HermesSpeechSynthesizer.swift) : ;;
            HermesGlasses/Services/VoiceLocale.swift) : ;;
            HermesGlasses/Services/WakeWordGate.swift) : ;;
            HermesGlasses/Services/HermesEndpointPolicy.swift) : ;;
            HermesGlasses/Services/BridgeCredentials.swift) : ;;
            HermesGlasses/Services/AdamSpeechSignal.swift) : ;;
            HermesGlasses/Services/AdamSoundscapeWaveform.swift) : ;;
            HermesGlasses/Services/AdamSoundscapeManager.swift) : ;;
            HermesGlasses/ViewModels/HermesSessionViewModel.swift) : ;;
            HermesGlasses/Views/AssistantConversationSurface.swift) : ;;
            HermesGlasses/Views/ContentView.swift) : ;;
            HermesGlasses/Views/HermesDesign.swift) : ;;
            Config/AdamVoice.xcconfig) : ;;
            Config/AdamVoice.example.xcconfig) : ;;
            README.md) : ;;
            docs/ADAM_VOICE_SETUP.md) : ;;
            scripts/push-adam-testing.sh) : ;;
            tests/adam-signal/*) : ;;
            tests/adam-soundscape/*) : ;;
            tests/assistant-conversation/*) : ;;
            tests/endpoint/*) : ;;
            tests/speech-voice/*) : ;;
            tests/voice-locale/*) : ;;
            tests/wake-word/*) : ;;
            *)
                printf '%s\n' "$path"
                ;;
        esac
    done
`

[ -z "$invalid_paths" ] || {
    printf 'Adam test push blocked: commit contains paths outside the Adam test allowlist:\n%s\n' \
        "$invalid_paths" >&2
    exit 1
}

printf 'Verifying AdamVoice before push...\n'
xcodebuild \
    -project HermesGlasses.xcodeproj \
    -scheme AdamVoice \
    -destination 'generic/platform=iOS' \
    build \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

printf 'Pushing %s verified commit(s) to %s/%s...\n' \
    "$ahead_count" "$remote_name" "$branch_name"
git push --porcelain "$remote_name" "HEAD:${remote_branch}"

local_head=$(git rev-parse HEAD)
remote_head=$(git ls-remote "$remote_name" "$remote_branch" | awk 'NR == 1 { print $1 }')
[ "$local_head" = "$remote_head" ] || \
    fail "remote verification did not return the local commit"

printf 'Adam testing is ready at %s.\n' "$(git rev-parse --short HEAD)"
