#!/usr/bin/env bash
set -euo pipefail

NEW_NAME="${1:-}"
if [[ -z "${NEW_NAME}" ]]; then
  echo "Usage: tools/gen_cpp_pr.sh <NEW_NAME>"
  exit 2
fi

BASE_BRANCH="${BASE_BRANCH:-main}"
MAX_CHANGED_LINES="${MAX_CHANGED_LINES:-2000}"   # stop if (adds + dels) exceeds this
MODEL="${MODEL:-gpt-5.2}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Preconditions
command -v gh >/dev/null || { echo "Missing: gh"; exit 2; }
command -v python3 >/dev/null || { echo "Missing: python3"; exit 2; }
command -v git >/dev/null || { echo "Missing: git"; exit 2; }

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "Missing OPENAI_API_KEY in environment."
  exit 2
fi

PROMPT_DIR="prompts/${NEW_NAME}"
SRC_DIR="src/${NEW_NAME}"
TEST_DIR="tests/${NEW_NAME}"
BUILD_DIR="build/${NEW_NAME}"

if [[ ! -d "$PROMPT_DIR" ]]; then
  echo "Prompt directory not found: $PROMPT_DIR"
  exit 2
fi

# Clean tree required
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree not clean. Commit/stash first."
  exit 2
fi

echo "==> Resetting branch '${NEW_NAME}' from origin/${BASE_BRANCH}"
git fetch origin "${BASE_BRANCH}"
git checkout -B "${NEW_NAME}" "origin/${BASE_BRANCH}"

mkdir -p "$SRC_DIR" "$TEST_DIR"

echo "==> Generating C++ sources + gtests from prompts in $PROMPT_DIR"
python3 tools/generate_cpp_from_prompts.py \
  --new-name "${NEW_NAME}" \
  --prompt-dir "${PROMPT_DIR}" \
  --src-dir "${SRC_DIR}" \
  --test-dir "${TEST_DIR}" \
  --model "${MODEL}"

# Normalize formatting (if clang-format exists)
if command -v clang-format >/dev/null; then
  echo "==> clang-format on generated files"
  find "$SRC_DIR" "$TEST_DIR" -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -print0 \
    | xargs -0 clang-format -i
else
  echo "NOTE: clang-format not found; skipping formatting normalization."
fi

# Diff-size guard (adds + dels)
echo "==> Checking diff size vs ${BASE_BRANCH}"
CHANGED_LINES="$(git diff --numstat "origin/${BASE_BRANCH}..HEAD" \
  | awk '{adds+=$1; dels+=$2} END {print adds+dels+0}')"

echo "Changed lines (adds+dels): ${CHANGED_LINES} (limit ${MAX_CHANGED_LINES})"
if (( CHANGED_LINES > MAX_CHANGED_LINES )); then
  echo "STOP: diff too large. Reduce prompts/scope or raise MAX_CHANGED_LINES."
  exit 1
fi

# Configure/build/test (assumes CMake+CTest; adjust commands if your repo differs)
echo "==> Configuring build: ${BUILD_DIR}"
cmake -S . -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=RelWithDebInfo

echo "==> Building: ${BUILD_DIR}"
cmake --build "${BUILD_DIR}" -j

echo "==> Running tests (ctest): ${BUILD_DIR}"
ctest --test-dir "${BUILD_DIR}" --output-on-failure

# If we reach here, tests passed
if [[ -z "$(git status --porcelain)" ]]; then
  echo "No changes produced; exiting."
  exit 0
fi

echo "==> Committing"
git add -A
git commit -m "Generate ${NEW_NAME} C++ module from prompts"

echo "==> Pushing branch"
git push -u origin "${NEW_NAME}"

# Create PR via REST API; use gh CLI to get repo + token
OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"
TOKEN="$(gh auth token)"

echo "==> Creating PR main <- ${NEW_NAME} via GitHub REST API"
PR_JSON="$(curl -sS -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${OWNER}/${REPO}/pulls" \
  -d "$(jq -n \
      --arg title "Generate ${NEW_NAME}" \
      --arg head "${NEW_NAME}" \
      --arg base "${BASE_BRANCH}" \
      --arg body "Automated generation from prompts/${NEW_NAME}/ (compiled + tests passed)." \
      '{title:$title, head:$head, base:$base, body:$body}')" )"

PR_URL="$(echo "$PR_JSON" | jq -r .html_url)"
PR_NUM="$(echo "$PR_JSON" | jq -r .number)"

if [[ "$PR_URL" == "null" || -z "$PR_URL" ]]; then
  echo "ERROR: PR creation failed. Response:"
  echo "$PR_JSON"
  exit 1
fi

echo "✅ Created PR #${PR_NUM}: ${PR_URL}"
