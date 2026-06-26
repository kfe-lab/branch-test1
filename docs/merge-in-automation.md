# merge-in 자동화 설계 문서

> `main → release/*`·`hotfix/*` 자동 merge-in의 **설계 의도·동작 흐름·결정 근거**를 정리한 문서입니다.
> 설정 절차와 프로덕션 이행 체크리스트는 [branch-strategy-rollout.md](./branch-strategy-rollout.md)를 참조하세요.

---

## 1. 한 줄 요약

> `main`에 커밋이 push될 때마다, 모든 활성 `release/*`·`hotfix/*` 브랜치에
> main을 **merge commit**으로 자동 흡수한다.
> 충돌이 없으면 직접 push, 충돌이 있으면 `sync/*` PR + Slack 알림 → 해소 후 자동 머지.

---

## 2. 핵심 설계 결정

| 결정 항목 | 선택 | 근거 |
|-----------|------|------|
| `main → release` 머지 방식 | **merge commit** | git ancestry 보존 → `verify-sync` 단순화, 충돌 해소 경로 확보 |
| `feature → release` 머지 방식 | **squash** | release history 간결, 룰셋이 자동으로 squash 강제 |
| 소스 브랜치 구분 불가 문제 | **GitHub App bypass** | 룰셋은 target 브랜치 기준만 적용 → App이 merge commit을 bypass로 처리 |
| bypass 주체 | **org 소유 GitHub App** | `github-actions[bot]`은 GitHub가 의도적으로 bypass 불가로 막음 |
| App 적용 범위 | **특정 저장소만** | App "Only select repositories" 설치로 범위 최소화 |
| 충돌 해소 위치 | **`sync/*` 비보호 브랜치** | `release/*` 직접 push는 룰셋이 차단 → 개발자가 자유롭게 push 가능한 중간 브랜치 필요 |
| `verify-sync` 검증 방식 | **`git merge-base --is-ancestor`** | merge commit이라 ancestry 성립, 취약한 PR 제목 SHA 파싱 제거 |

### 왜 squash가 아닌 merge commit인가

squash는 main 커밋을 새로운 단일 커밋으로 압축하므로 **git ancestry가 깨진다**.
이 때문에 기존 `verify-sync`는 PR 제목에서 SHA를 파싱하는 fragile한 방식을 사용했다.
merge commit으로 전환하면 main의 커밋 해시가 그대로 부모 링크에 남아
`git merge-base --is-ancestor origin/main origin/<branch>` 한 줄로 검증이 가능하다.

### 왜 `github-actions[bot]`이 아닌 GitHub App인가

GitHub는 `github-actions[bot]`을 ruleset bypass 목록에 추가하는 것을 의도적으로 막는다.
(보안 정책 — CI 봇이 모든 보호 규칙을 우회하면 보호 자체가 의미를 잃는다.)
org 소유 GitHub App은 bypass 목록에 추가 가능하며, "Always" 모드로 등록하면
App 토큰으로 squash-only 룰셋이 적용된 `release/*`에 merge commit을 직접 push할 수 있다.

---

## 3. 전체 동작 흐름

### 3.1 정상 경로 (충돌 없음)

```
main 커밋 push
  └─ auto-merge-in 워크플로 트리거 (concurrency: 직렬화)
       └─ 각 release/*, hotfix/* 브랜치에 대해:
            ├─ 이미 동기화됨 → skip
            ├─ open sync PR 존재 → skip (충돌 해소 중)
            └─ trial merge (work/ 임시 브랜치)
                 ├─ 충돌 없음 → App 토큰으로 release/*에 merge commit 직접 push
                 │              (squash-only 룰셋을 App bypass가 우회)
                 └─ 충돌 있음 → 충돌 경로로 전환 ↓
```

결과: PR 없음. merge commit 1개만 생성. `main`이 `release/*`의 직접 조상이 된다.

### 3.2 충돌 경로

```
trial merge 충돌 감지
  └─ sync/main-to-<branch> 브랜치 생성 (충돌 마커 포함 커밋)
  └─ PR: sync/* → release/* 생성
  └─ Slack 알림

개발자 로컬 작업:
  git fetch origin
  git checkout sync/main-to-<branch>
  # 충돌 마커(<<<<<<<, =======, >>>>>>>) 해소 후:
  git commit -am "resolve conflicts"
  git push

  └─ resolve-merge-in 워크플로 트리거 (sync/* push)
       ├─ conflict-check (required status check)
       │    ├─ 마커 잔존 → fail (PR 머지 차단)
       │    └─ 마커 없음 → pass
       └─ auto-merge
            └─ App 토큰으로 PR을 merge commit 머지 (--merge)
                 → sync/* 브랜치 삭제
```

### 3.3 git 토폴로지 — sync 경유해도 ancestry 성립

```
main:     A─B─C─D
                └─── (merge commit) ───► release/*
                                          (main이 release/*의 조상)
```

sync/* 경유 시에도 merge commit의 부모 링크가 보존된다:
```
main:     A─B─C─D
                └─── (sync/* 경유 merge commit) ─► release/*
                         개발자 push (resolve)
```
어느 경로든 결과 토폴로지는 동일: `git merge-base --is-ancestor origin/main origin/release/*` → `true`

### 3.4 verify-sync — PR 머지 전 검증

`release/*` → `main` PR이 열릴 때 동작:

```bash
# main이 분기 이후 전진했는가?
MAIN_AHEAD=$(git rev-list --count "$MERGE_BASE..origin/main")

if [ "$MAIN_AHEAD" -eq 0 ]; then
  # main이 전진하지 않음 → merge-in 불필요 → pass
else
  # main이 전진함 → ancestry 확인
  git merge-base --is-ancestor origin/main origin/$HEAD_BRANCH
  # false → fail (merge-in 미완료)
  # true  → pass (merge-in 완료)
fi
```

---

## 4. 구성 요소

| 파일 | 트리거 | 역할 |
|------|--------|------|
| `.github/workflows/auto-merge-in.yml` | `push` to `main`, `workflow_dispatch` | 브랜치별 merge-in 루프. 정상/충돌 경로 분기. |
| `.github/workflows/resolve-merge-in.yml` | `push` to `sync/**` | `conflict-check` (required) + `auto-merge` (App bypass). |
| `.github/workflows/verify-sync.yml` | `pull_request` to `main` | `release/*`·`hotfix/*` → main PR 시 ancestry 검증 (required check `check`). |
| `.github/workflows/detect-force-push.yml` | `push` (forced) | App bypass 사용자 포함 force push 감사. 이중방어. |
| `scripts/sync-release.sh` | 수동 실행 | 개인 계정용 수동 merge-in 헬퍼. 항상 `sync/*` PR 경로 사용. |

### Required Status Checks 등록 대상

| check job 이름 | 룰셋 | 역할 |
|---------------|------|------|
| `check` | `main` 룰셋 | release → main PR 시 merge-in 완료 강제 |
| `conflict-check` | `release/**`·`hotfix/**` 룰셋 | sync PR 머지 전 충돌 마커 잔존 차단 |

---

## 5. 안전장치

### 5.1 인젝션 방지

`${{ github.* }}` 표현식을 `run:` 스크립트에 직접 인터폴레이션하지 않는다.
반드시 `env:` 블록 경유 + 정규식 검증 패턴을 사용한다.

```yaml
# ✅ 올바른 패턴
env:
  HEAD_BRANCH: ${{ github.head_ref }}
  APP_TOKEN: ${{ steps.app-token.outputs.token }}
run: |
  if ! printf '%s' "$HEAD_BRANCH" | grep -qE '^[a-zA-Z0-9/_-]+$'; then
    echo "::error::Invalid branch name"
    exit 1
  fi
```

### 5.2 루프 없음

`auto-merge-in.yml`은 `push` to `main`만 트리거.
App이 `release/*`에 push해도 워크플로가 재실행되지 않는다.
`detect-force-push.yml`은 `forced: true`인 push에만 동작하므로 merge commit push에 발화하지 않는다.

### 5.3 직렬화

```yaml
concurrency:
  group: auto-merge-in
  cancel-in-progress: false
```
main에 연속으로 커밋이 push되어도 merge-in은 직렬로 처리된다.
(race condition 방지)

### 5.4 충돌 마커 차단

`conflict-check` job이 `release/**`·`hotfix/**` 룰셋의 required status check로 등록됨.
충돌 마커(`<<<<<<<`, `=======`, `>>>>>>>`)가 파일에 남아 있으면 job이 fail하여 PR 머지가 차단된다.

### 5.5 App 토큰 미설정 시 동작

| 경로 | App 토큰 있음 | App 토큰 없음 |
|------|-------------|--------------|
| 정상 경로 (충돌 없음) | App 토큰으로 직접 push | sync PR fallback (경고 출력) |
| 충돌 경로 | App 토큰으로 PR merge commit | conflict-check만 동작, 수동 머지 필요 |

`SYNC_APP_ID`·`SYNC_APP_PRIVATE_KEY`가 설정되지 않아도 워크플로는 오류 없이 동작.
단, 직접 push 및 자동 머지 기능은 비활성 상태.

---

## 6. GitHub App 권한

| 권한 | 분류 | 수준 |
|------|------|------|
| Contents | Repository | Read & write |
| Pull requests | Repository | Read & write |
| Workflows | Repository | Read & write ⚠️ |
| Metadata | Repository | Read-only (자동) |
| Organization 전체 | Organization | No access |
| Account 전체 | Account | No access |

> ⚠️ **Workflows R&W 필수**: main 커밋에 `.github/workflows/` 변경이 포함될 경우,
> 이 권한이 없으면 App 토큰으로 push할 때 `refusing to allow a GitHub App to create or update workflow` 오류가 발생한다.

**Bypass 설정** (룰셋과 별개):
- `release/**`·`hotfix/**` 룰셋 → Bypass list에 App 추가 → 모드 **Always**
- "Always"여야 PR 없는 직접 push(정상 경로)가 통과된다. "Pull requests only"로는 동작하지 않는다.

상세 설정 절차는 [branch-strategy-rollout.md § 5.1](./branch-strategy-rollout.md) 참조.

---

## 7. 변경 이력

| 날짜 | 내용 |
|------|------|
| 2026-06-26 | 최초 작성. `auto-merge-in` squash → merge commit 전환, GitHub App bypass 도입, `verify-sync` ancestry 기반 단순화, `resolve-merge-in` 신규, `sync-release.sh` sync/* 경로 전환. |
