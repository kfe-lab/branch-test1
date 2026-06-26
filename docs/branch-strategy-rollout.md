# 브랜치 전략 개편: 시범 구축 결과 및 프로덕션 이행 가이드

> 시범 저장소: `seungjaey/branch-test1` · 최종 수정: 2026-06-26

> 설계 의도·동작 흐름·결정 근거는 **[merge-in-automation.md](./merge-in-automation.md)** 참조.
> 팀장 리뷰용 실행 계획(왜 이 자동화인가)은 **[branch-strategy-execution-plan.md](./branch-strategy-execution-plan.md)** 참조.

## 1. 배경 — 왜 바꾸는가

`release → main` 머지 이후 잔여 `release/*`·`hotfix/*` 브랜치를 **`rebase + force push`**
로 동기화하던 패턴이 근본 원인이었다. force push는 기존 커밋을 덮어써 **커밋 손실**을
일으킨다. 처방은 세 가지다.

1. **(A) 동기화 트리거 제거** — rebase 후 force push하는 습관 자체를 막는다.
2. **(B) merge-in으로 교체** — `rebase + force push` 대신 `main`을 브랜치로 **머지해
   흡수**(merge-in)한다. 기존 커밋 해시가 불변이고 force push가 필요 없다.
3. **(C) 가드레일 4축** — 예방·탐지·표준화·가시성을 자동화로 보장한다.

## 2. 가드레일 4축 — 무엇을 구축했나

| 축 | 목적 | 구현 | 상태 |
|----|------|------|------|
| **예방** | force push·삭제를 플랫폼이 거부 | Branch Rulesets (`non_fast_forward`, `deletion`, `pull_request`) | ✅ |
| **탐지** | 우회 force push 감사 + 미동기화 차단 | `detect-force-push.yml`, `verify-sync.yml` | ✅ |
| **표준화** | merge-in을 자동/반자동으로 수행 | `auto-merge-in.yml`, `resolve-merge-in.yml`, `scripts/sync-release.sh` | ✅ |
| **가시성** | 자동화 결과·이상을 Slack 통보 | 워크플로 내 Slack webhook 스텝 | ✅ (Secret 설정 시 활성) |

### 산출물

```
.github/workflows/detect-force-push.yml   # 축 2 — force push 감사 (이중방어)
.github/workflows/verify-sync.yml         # 축 2 — release→main PR 동기화 검증 (required check)
.github/workflows/auto-merge-in.yml       # 축 3 — main 전진 시 merge-in 자동 처리
.github/workflows/resolve-merge-in.yml   # 축 3 — 충돌 해소 후 sync PR 자동 머지
scripts/sync-release.sh                   # 축 3 — 수동 merge-in 헬퍼
```

## 3. 동작 방식

### 3.1 머지 방식 설계 원칙

| 경로 | 머지 방식 | 이유 |
|------|----------|------|
| **feature → release** | squash | 피처 커밋을 단일 커밋으로 압축, release history 간결 유지 |
| **main → release** | merge commit | git ancestry 보존 → `verify-sync` 단순화, 충돌 해소 경로 확보 |

> **룰셋은 소스 브랜치를 구분하지 못한다.** `release/*` 룰셋은 squash-only로 유지하되,
> `main → release` merge commit은 **GitHub App bypass**로 처리한다.
> feature PR은 App bypass가 없으므로 룰셋에 따라 자동으로 squash만 허용된다.

### 3.2 정상 경로 (충돌 없음)

```
main 커밋 push
  └─ auto-merge-in 워크플로 실행
       └─ 각 release/*, hotfix/* 브랜치에 대해:
            trial merge (로컬 work 브랜치) 시도
            ├─ 충돌 없음 → App 토큰으로 release/* 에 merge commit 직접 push
            │              (App bypass가 squash-only 룰셋을 우회)
            └─ 충돌 있음 → sync/* 브랜치 생성 + PR 열기 + Slack 알림
```

정상 경로는 PR이 없다. merge commit 1개만 생성되며 main이 release/*의 직접 조상이 된다.

### 3.3 충돌 경로

```
충돌 감지
  └─ sync/main-to-<branch> 브랜치 생성 (충돌 마커 포함)
  └─ PR: sync/* → release/* 생성
  └─ Slack 알림

개발자:
  git fetch origin
  git checkout sync/main-to-<branch>
  # 충돌 마커 해소 후:
  git commit -am "resolve conflicts"
  git push

  └─ resolve-merge-in 워크플로 실행
       ├─ 충돌 마커 잔존 검사 (required check — 마커 있으면 차단)
       └─ 마커 없음 → App 토큰으로 PR을 merge commit 머지
```

`sync/*` 브랜치는 보호 대상이 아니므로 개발자가 자유롭게 push할 수 있다.
PR 머지는 App이 merge commit으로 처리하므로 release/*에 직접 push하지 않아도 된다.

### 3.4 verify-sync — ancestry 기반 검증

merge commit은 git ancestry를 보존하므로, `git merge-base --is-ancestor` 한 줄로
검증할 수 있다. 이전 squash 방식의 취약한 "PR 제목 SHA 파싱" 로직을 완전히 제거했다.

```bash
# main이 release/*의 조상이면 merge-in 완료 → 통과
git merge-base --is-ancestor origin/main origin/$HEAD_BRANCH
```

## 4. 검증 결과

| 검증 항목 | 결과 | 증빙 |
|-----------|------|------|
| 보호 브랜치 force push 거부 | ✅ | `GH013: push declined`, 테스트 전부 거부 |
| 보호 브랜치 삭제 거부 | ✅ | deletion 룰 적용 확인 |
| merge-in 무 force push·무손실 | ✅ | merge commit push, force push 0건 |
| 기존 커밋 SHA 불변 | ✅ | release/1·hotfix/1 히스토리 보존 |
| `auto-merge-in` 자동 발화 | ✅ | main 전진 시 release/*, hotfix/* merge commit 자동 push |
| `verify-sync` 통과 | ✅ | ancestry 확인으로 merge-in 완료 검증 |
| `detect-force-push` | ✅ | force push 없어 `skipped` (정상 — 이중방어) |

## 5. 프로덕션 이행 체크리스트

### 5.1 GitHub App 생성 (1회성, org 단위)

- [ ] **GitHub App 생성** (org 소유)
  - App 이름 예시: `release-sync-bot`
  - Repository permissions:
    - Contents: **Read & write**
    - Pull requests: **Read & write**
    - Workflows: **Read & write** ⚠️ (main 머지분에 워크플로 파일 포함 시 필수)
    - Metadata: Read-only (자동)
  - Organization / Account permissions: 전부 **No access**

- [ ] **App 설치** — "Only select repositories"로 대상 저장소들에만 설치

- [ ] **자격증명 저장**
  ```bash
  # App ID (숫자) → org/repo variable
  gh variable set SYNC_APP_ID --body "<app-id>" --org <org>
  # Private key (.pem 내용) → org/repo secret
  gh secret set SYNC_APP_PRIVATE_KEY --body "$(cat app-key.pem)" --org <org>
  ```

### 5.2 룰셋 설정

- [ ] **`release/**`·`hotfix/**` 룰셋**
  - `non_fast_forward` (force push 차단)
  - `deletion` (브랜치 삭제 차단)
  - `pull_request` (직접 push 차단 — PR 필수)
  - `allowed_merge_methods`: **squash-only** 유지 (feature→release squash 강제)
  - **Bypass list에 App 추가**, 모드: **Always**
    - "Always"를 선택해야 PR 밖 직접 push(정상 경로)가 통과된다.
    - "Pull requests only"로는 정상 경로 직접 push가 차단된다.

- [ ] **`main` 룰셋**
  - `non_fast_forward`, `deletion`, `pull_request` 동일 적용
  - Bypass list에 App 추가는 불필요 (App은 main에 push하지 않음)

- [ ] **`sync/**` 브랜치는 보호 대상에서 제외**
  - 개발자가 충돌 해소 후 자유롭게 push할 수 있어야 한다.

### 5.3 저장소 일반 설정

- [ ] **Settings → Actions → General → Workflow permissions**
  - `Read and write` 선택
  - **"Allow GitHub Actions to create and approve pull requests" 체크**
  - CLI: `gh api -X PUT repos/<org>/<repo>/actions/permissions/workflow --field default_workflow_permissions=write --field can_approve_pull_request_reviews=true`

- [ ] **Settings → General → "Allow auto-merge" 활성화**
  - CLI: `gh api -X PATCH repos/<org>/<repo> --field allow_auto_merge=true`

### 5.4 워크플로 이식 및 required check 등록

- [ ] 워크플로 5종 복사: `detect-force-push.yml`, `verify-sync.yml`, `auto-merge-in.yml`, `resolve-merge-in.yml`, `scripts/sync-release.sh`

- [ ] `verify-sync`의 `check` job을 `main` 룰셋의 **required status check**로 등록
  ```bash
  # integration_id 15368 = GitHub Actions
  gh api -X PUT repos/<org>/<repo>/rulesets/<main-ruleset-id> \
    --input - <<'JSON'
  {
    "rules": [
      {
        "type": "required_status_checks",
        "parameters": {
          "required_status_checks": [{ "context": "check", "integration_id": 15368 }],
          "strict_required_status_checks_policy": false
        }
      }
    ]
  }
  JSON
  ```
  > ⚠️ 이 API 호출은 룰셋 전체를 덮어쓴다. 기존 규칙을 함께 포함해야 한다.

- [ ] `resolve-merge-in`의 `conflict-check` job을 `release/**`·`hotfix/**` 룰셋의 **required status check**로 등록
  - context 이름: `conflict-check`
  - sync PR이 충돌 마커 남긴 채 머지되는 것을 차단한다.

### 5.5 가시성

- [ ] `SLACK_WEBHOOK_URL`을 repo/org Secret으로 등록
  - 미등록 시 알림 스텝은 조건부 skip, 워크플로는 정상 동작
  - `gh secret set SLACK_WEBHOOK_URL --body "<webhook-url>" --org <org>`

## 6. end-to-end 검증 순서

프로덕션 이행 전 아래 순서로 테스트 저장소에서 확인한다.

1. **App bypass 확인**: main에 무충돌 커밋 push → `auto-merge-in` 실행 → `release/*`에 merge commit 직접 push 성공 → `git merge-base --is-ancestor origin/main origin/release/*` true
2. **verify-sync pass**: release/*→main PR 생성 → merge-in 후 `check` 통과
3. **충돌 경로**: release/*와 main이 같은 줄을 다르게 수정 → main push → `sync/main-to-*` 브랜치+PR+Slack 확인
4. **충돌 마커 차단**: 마커 미해소 상태로 머지 시도 → `conflict-check` fail로 차단
5. **충돌 해소 자동 머지**: 마커 해소 후 push → `resolve-merge-in` 실행 → App 토큰으로 merge commit 머지 → ancestry 통과
6. **루프 없음**: App이 `release/*`에 push해도 `auto-merge-in`(main 트리거)·`detect-force-push`(forced만) 재실행 없음
7. **squash 강제**: feature→release PR에서 merge commit 버튼 비활성(squash-only 룰셋)

## 7. 미해결 합의 항목

- **`develop` 브랜치 폐지 시점** — dev 환경 배포 대안이 마련돼야 폐지 가능 (`suggest.md` §5). 팀 합의 필요.
- **App 관리 주체** — org 소유 App의 private key 로테이션 주기 및 담당자 지정.

## 8. 주의·한계

### GITHUB_TOKEN으로 생성된 PR의 트리거 제한
GITHUB_TOKEN으로 생성된 PR은 다른 워크플로를 자동으로 트리거하지 않는다
([GitHub 문서](https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication#using-the-github_token-in-a-workflow)).
`resolve-merge-in`은 `push` 트리거(sync 브랜치 push)로 동작하므로 이 제약을 받지 않는다.

### detect-force-push의 실효성
룰셋(`non_fast_forward`)이 이미 force push를 플랫폼 수준에서 막기 때문에 `detect-force-push.yml`은 보호 브랜치에서 거의 발화하지 않는다. **App bypass 사용자 모니터링** 목적으로 유지한다.

### App 토큰 미설정 시 동작
`SYNC_APP_ID` / `SYNC_APP_PRIVATE_KEY`가 없으면:
- 정상 경로(직접 push)가 동작하지 않는다.
- `auto-merge-in`은 sync 브랜치+PR 경로로 fallback한다.
- `resolve-merge-in`은 conflict-check만 동작하고 자동 머지는 skip된다(수동 머지 필요).

### bash 함정 — `jq '// empty'`
`jq '.[0].number // empty'`는 일부 jq 버전에서 exit code 5를 반환한다. `set -eo pipefail` 환경에서는 스크립트 전체가 실패한다. 반드시 `// ""`를 사용한다.

### 인젝션 방지
모든 `${{ github.* }}` 표현식은 `env:` 블록을 경유해 환경 변수로 주입한다. 브랜치명은 셸에서 사용하기 전에 정규식으로 검증한다.

```yaml
# ✅ 올바른 패턴
env:
  HEAD_BRANCH: ${{ github.head_ref }}
run: |
  if ! printf '%s' "$HEAD_BRANCH" | grep -qE '^[a-zA-Z0-9/_-]+$'; then
    echo "::error::Invalid branch name"
    exit 1
  fi
```
