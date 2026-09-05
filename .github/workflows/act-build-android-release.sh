#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
for command_name in act docker python3; do
  command -v "$command_name" >/dev/null || { printf 'Missing command: %s\n' "$command_name" >&2; exit 1; }
done
: "${ANDROID_KEYSTORE_PATH:?Set ANDROID_KEYSTORE_PATH to your signing keystore}"
: "${ANDROID_KEY_ALIAS:?Set ANDROID_KEY_ALIAS}"
: "${ANDROID_KEY_PASSWORD:?Set ANDROID_KEY_PASSWORD (store and key password)}"
[[ -f "$ANDROID_KEYSTORE_PATH" ]] || { printf 'Signing keystore not found\n' >&2; exit 1; }
export ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD
ANDROID_KEY_BASE64="$(python3 -c 'import base64,sys; print(base64.b64encode(open(sys.argv[1], "rb").read()).decode())' "$ANDROID_KEYSTORE_PATH")"
export ANDROID_KEY_BASE64
trap 'unset ANDROID_KEY_BASE64 ANDROID_KEY_PASSWORD' EXIT

output_dir="${ACT_OUTPUT_DIR:-$repo_root/build/act-android-artifacts}"
mkdir -p "$output_dir"
read -r -a abis <<< "${ACT_ANDROID_ABIS:-arm64-v8a armeabi-v7a x86_64}"
for abi in "${abis[@]}"; do
  case "$abi" in arm64-v8a|armeabi-v7a|x86_64) ;; *) printf 'Unsupported Flutter ABI: %s\n' "$abi" >&2; exit 1;; esac
  act push -C "$repo_root" -W "$script_dir/build-mobile.yml" -j android \
    --matrix "abi:$abi" --container-architecture linux/amd64 \
    -P "ubuntu-latest=${ACT_RUNNER_IMAGE:-catthehacker/ubuntu:act-latest}" \
    --artifact-server-path "$output_dir" \
    --secret ANDROID_KEY_ALIAS --secret ANDROID_KEY_BASE64 --secret ANDROID_KEY_PASSWORD
done
printf 'Workflow artifacts: %s\n' "$output_dir"
