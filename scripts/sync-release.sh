#!/usr/bin/env bash
# 수동 merge-in 헬퍼
#
# 사용법: bash scripts/sync-release.sh <branch>
# 예시:   bash scripts/sync-release.sh release/2024.07.01.1
#
# auto-merge-in.yml 워크플로가 자동 처리하지 못한 경우 이 스크립트를 실행합니다.
# (예: 워크플로 실패, 수동 재동기화 필요 등)
#
# ── 동작 방식 ────────────────────────────────────────────────────────────
# 개인 계정은 release/* ruleset bypass 권한이 없으므로 항상 sync/* 브랜치 경유 PR을 사용합니다.
# 충돌 없음 → sync/* 브랜치 + PR 생성 (CI auto-merge 또는 수동 머지)
# 충돌 있음 → sync/* 브랜치에 마커 남김 + PR 생성 → 로컬에서 마커 해소 후 push
#
# ── release/* 직접 push가 막히는 이유 ────────────────────────────────────
# release/* ruleset은 squash-only + PR 필수로 설정돼 있습니다.
# 직접 push는 App bypass 권한이 있는 GitHub App(SYNC_APP)만 가능합니다.

set -euo pipefail

BRANCH="${1:-}"

# --- 입력 검증 ---
if [ -z "$BRANCH" ]; then
  echo "사용법: bash scripts/sync-release.sh <branch>"
  echo "예시:   bash scripts/sync-release.sh release/2024.07.01.1"
  exit 1
fi

if ! printf '%s' "$BRANCH" | grep -qE '^(release|hotfix)/[a-zA-Z0-9._-]+$'; then
  echo "❌ 오류: 브랜치명은 release/* 또는 hotfix/* 형식이어야 합니다."
  echo "   입력값: $BRANCH"
  exit 1
fi

# --- gh CLI 확인 ---
if ! command -v gh &>/dev/null; then
  echo "❌ 오류: gh CLI가 설치돼 있지 않습니다."
  echo "   설치: https://cli.github.com"
  exit 1
fi

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
if [ -z "$REPO" ]; then
  echo "❌ 오류: gh CLI가 저장소에 연결돼 있지 않습니다. 'gh auth login'을 실행하세요."
  exit 1
fi

# --- 원격 최신화 ---
echo "🔄 원격 최신화 중..."
git fetch origin main "$BRANCH" --quiet

# --- 동기화 필요 여부 확인 ---
DIFF_COUNT=$(git rev-list --count "origin/$BRANCH..origin/main")
if [ "$DIFF_COUNT" -eq 0 ]; then
  echo "✅ '$BRANCH'는 이미 main과 동기화돼 있습니다. 작업 불필요."
  exit 0
fi
echo "ℹ️  main이 '$BRANCH'보다 $DIFF_COUNT 커밋 앞서 있습니다."

# --- sync 브랜치명 결정 ---
SAFE_NAME=$(echo "$BRANCH" | tr '/' '-')
SYNC_BRANCH="sync/main-to-$SAFE_NAME"
MAIN_SHA=$(git rev-parse origin/main)
SHORT_SHA="${MAIN_SHA:0:7}"

# --- 기존 open sync PR 확인 ---
EXISTING=$(gh pr list \
  --repo "$REPO" \
  --base "$BRANCH" \
  --head "$SYNC_BRANCH" \
  --state open \
  --limit 1 \
  --json number,url \
  | jq -r '.[0] | "\(.number) \(.url)"' 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
  PR_NUM=$(echo "$EXISTING" | cut -d' ' -f1)
  PR_URL=$(echo "$EXISTING" | cut -d' ' -f2)
  echo "⚠️  이미 open sync PR #$PR_NUM 이 있습니다: $PR_URL"
  echo "   충돌이 있는 경우 아래 방법으로 해소하세요:"
  echo ""
  echo "   git fetch origin"
  echo "   git checkout $SYNC_BRANCH"
  echo "   # 충돌 마커 수정 후:"
  echo "   git commit -am 'resolve conflicts'"
  echo "   git push"
  exit 0
fi

# --- sync 브랜치 생성 및 main 머지 시도 ---
echo "🔀 sync 브랜치 생성 중: $SYNC_BRANCH"
git checkout -B "$SYNC_BRANCH" "origin/$BRANCH"

MERGE_OK=true
git merge --no-ff "origin/main" 2>/dev/null || MERGE_OK=false

if [ "$MERGE_OK" = "false" ]; then
  echo "⚠️  충돌 발생 — 충돌 마커를 남긴 채 커밋합니다."
  git add -A
  git commit -m "merge main into $BRANCH @ $SHORT_SHA — CONFLICTS, resolve before merge" || true
fi

# --- sync 브랜치 push ---
echo "📤 sync 브랜치 push 중..."
git push origin "$SYNC_BRANCH"

# --- PR 생성 ---
echo "📬 merge-in PR 생성 중..."

if [ "$MERGE_OK" = "true" ]; then
  PR_TITLE="[sync] main → $BRANCH @ $SHORT_SHA"
  PR_BODY=$(jq -rn \
    --arg branch "$BRANCH" \
    --arg sha "$MAIN_SHA" \
    --arg short "$SHORT_SHA" \
    '"## 수동 merge-in\n\nmain의 신규 커밋을 `\($branch)`로 흡수합니다.\n\n- main SHA: `\($sha)` (`\($short)`)\n- 동기화 방식: merge commit (App bypass)\n\n> 충돌 없음 — CI가 자동으로 merge commit 머지합니다."')
else
  PR_TITLE="[sync] main → $BRANCH @ $SHORT_SHA (CONFLICTS)"
  PR_BODY=$(jq -rn \
    --arg branch "$BRANCH" \
    --arg sha "$MAIN_SHA" \
    --arg short "$SHORT_SHA" \
    --arg sync "$SYNC_BRANCH" \
    '"## ⚠️ 수동 merge-in (충돌)\n\nmain을 `\($branch)`로 흡수하는 과정에서 충돌이 발생했습니다.\n\n**충돌 해소 방법:**\n```bash\ngit fetch origin\ngit checkout \($sync)\n# 충돌 마커 수정 후:\ngit commit -am \"resolve conflicts\"\ngit push\n```\n\n- main SHA: `\($sha)` (`\($short)`)\n- 동기화 방식: merge commit (App bypass)\n\n> 충돌 마커가 남아 있으면 required check가 차단합니다."')
fi

PR_URL=$(gh pr create \
  --repo "$REPO" \
  --base "$BRANCH" \
  --head "$SYNC_BRANCH" \
  --title "$PR_TITLE" \
  --body "$PR_BODY")

echo "✅ PR 생성됨: $PR_URL"
echo ""

if [ "$MERGE_OK" = "true" ]; then
  echo "다음 단계:"
  echo "  CI(resolve-merge-in)가 자동으로 merge commit으로 머지합니다."
  echo "  App 토큰이 미설정된 경우 PR을 수동으로 머지하세요 (merge commit 방식)."
else
  echo "다음 단계:"
  echo "  1. 아래 명령으로 충돌을 해소하세요:"
  echo "     git fetch origin"
  echo "     git checkout $SYNC_BRANCH"
  echo "     # 충돌 마커 수정 후:"
  echo "     git commit -am 'resolve conflicts'"
  echo "     git push"
  echo "  2. CI(resolve-merge-in)가 자동으로 merge commit으로 머지합니다."
fi
