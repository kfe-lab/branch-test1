# 브랜치 전략 개편: 자동화 설계 원칙과 도입 계획

> 팀장 리뷰용 · 최종 수정: 2026-06-26

---

## 핵심 원칙: 시스템이 강제해야 한다

브랜치 전략은 **사람이 지켜야 하는 약속이 아니라 시스템이 강제하는 규칙**이어야 한다.
사람은 실수한다. 급할 때, 피곤할 때, 절차를 몰랐을 때 잘못된 git 명령을 실행한다.
이 문서는 **어떤 실수가 가능한가 → 시스템이 어떻게 막는가** 순서로 설계를 기술한다.

---

## 막아야 할 실수와 그 대응 시스템

### 실수 1 — force push로 동료 커밋 덮어쓰기

**어떤 실수인가**
`release/*`가 `main`보다 뒤처지면 개발자는 로컬에서 `git rebase main && git push --force`로
따라잡으려 한다. 로컬이 origin보다 오래된 상태이면 그 사이 동료가 push한 커밋이 유실된다.
이것이 현재 커밋 누락 사고의 근본 원인이다.

**시스템 대응**

| 수단 | 동작 | 왜 이 방식인가 |
|------|------|---------------|
| **GitHub Ruleset** — `Block force pushes` | `main`·`release/**`·`hotfix/**` 전체에 force push 시 플랫폼이 거부 | 의도·권한과 무관하게 작동. 관리자도 못 한다. |
| **GitHub Ruleset** — `Restrict deletions` | 보호 브랜치 삭제 차단 | 실수로 운영 브랜치를 지우는 경로를 제거 |

> Ruleset은 코드 리뷰나 관례가 아니다. push 자체를 플랫폼이 거부한다.

---

### 실수 2 — `main`이 전진했는데 `release/*`가 동기화되지 않은 채 PR 생성

**어떤 실수인가**
개발자가 `release/*` → `main` PR을 생성할 때 이미 다른 배포로 `main`이 전진한 상태일 수 있다.
이 상태로 머지하면 `main`에 최근 변경이 포함되지 않은 채 배포된다.

**시스템 대응**

| 수단 | 동작 | 왜 이 방식인가 |
|------|------|---------------|
| **`verify-sync.yml`** | `release/*`·`hotfix/*` → `main` PR 생성 시, `git merge-base --is-ancestor origin/main origin/$HEAD` 로 merge-in 완료 여부를 자동 검증 | PR 작성자가 확인하지 않아도 CI가 차단 |
| **Required status check** (`check` job) | 검증 통과 전까지 Merge 버튼 비활성 | "확인했습니다" 같은 수동 체크리스트 불필요 |

> `main`이 전진하지 않았으면 자동으로 pass. 전진했다면 merge-in 완료 전까지 PR 머지 불가.

---

### 실수 3 — `release/*` 동기화를 사람이 수동으로 해야 한다

**어떤 실수인가**
`main`에 신규 커밋이 생길 때마다 개발자가 "아, `release/1.2`에도 머지해야 하는데…"를 기억해야 한다면
반드시 빠뜨리는 브랜치가 생긴다. 잊는 게 실수가 아니다. 기억에 의존하는 설계가 실수다.

**시스템 대응**

| 수단 | 동작 | 왜 이 방식인가 |
|------|------|---------------|
| **`auto-merge-in.yml`** | `main`에 커밋이 push될 때마다 모든 활성 `release/*`·`hotfix/*`에 자동으로 merge commit을 직접 push | 사람이 기억할 필요가 없다 |
| **직렬화** (`concurrency: cancel-in-progress: false`) | 연속 push가 발생해도 순서대로 처리 | 레이스 컨디션으로 merge commit이 꼬이는 경로 제거 |
| **merge commit 방식** | squash가 아닌 merge commit 사용 | git ancestry가 보존되어 `verify-sync`가 단순한 `--is-ancestor` 한 줄로 동작 |

---

### 실수 4 — 충돌이 발생했을 때 해소할 방법이 없어 `release/*`에 직접 push

**어떤 실수인가**
`release/*`는 PR 필수 룰로 직접 push가 차단된다. 충돌이 발생하면 개발자가 갈 곳이 없다.
결국 "잠깐만 룰 풀고 올릴게요"가 생기는 구조가 문제다.

**시스템 대응**

| 수단 | 동작 | 왜 이 방식인가 |
|------|------|---------------|
| **`auto-merge-in.yml`** — 충돌 경로 | 충돌 감지 시 `sync/main-to-<branch>` (비보호) 브랜치를 자동 생성 + PR + Slack 알림 | 개발자에게 명확한 작업 공간을 제공 |
| **`resolve-merge-in.yml`** | `sync/*` push 시 충돌 마커 잔존 여부를 자동 검사 (required check) | 마커가 남은 채 PR 머지하는 실수를 차단 |
| **App bypass** | 충돌 해소 완료 후 App이 merge commit으로 PR 자동 머지 | 개발자가 merge 방식을 잘못 선택(squash로 머지)하는 실수를 제거 |

> `sync/*`는 보호 대상이 아니므로 개발자가 자유롭게 push 가능.
> 충돌 해소 후 push → CI가 마커 검사 → 통과하면 App이 자동 머지. 사람이 버튼을 누를 필요 없다.

---

### 실수 5 — feature → release가 merge commit으로 머지되어 히스토리가 오염

**어떤 실수인가**
개발자가 feature PR에서 "Merge commit"을 선택하면 release history에 feature 커밋이 낱낱이 노출된다.
이 선택은 실수이지만 UI에서 쉽게 발생한다.

**시스템 대응**

| 수단 | 동작 | 왜 이 방식인가 |
|------|------|---------------|
| **Ruleset** — `Allow merge methods: Squash` | `release/**` PR에서 Merge commit 버튼 자체가 비활성 | UI에서 선택지 자체를 없앤다 |

> `main → release`는 App bypass가 squash-only 룰을 우회해 merge commit으로 처리.
> feature → release는 bypass가 없으므로 룰셋에 따라 squash만 허용.
> **같은 룰이 경로마다 다르게 작동한다 — 이것이 App bypass 도입 이유다.**

---

### 실수 6 — 잘못된 브랜치 베이스에서 release/hotfix 생성

**어떤 실수인가**
개발자가 `git checkout -b release/2026.07.07.01`을 어떤 브랜치에 있는 상태에서 실행하느냐에 따라
베이스가 달라진다. `develop`이나 `feature`에서 분기하면 의도하지 않은 커밋이 포함된다.

**시스템 대응**

| 수단 | 동작 | 왜 이 방식인가 |
|------|------|---------------|
| **`create-branch.yml`** (신규) | `workflow_dispatch` 입력값 브랜치명 검증 후, 항상 **`origin/main` HEAD** 기준으로 새 ref 생성 | 실행 주체의 로컬 상태와 무관하게 항상 main 기준 |
| 브랜치명 정규식 강제 | `^(release\|hotfix)/[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}$` 불합치 시 실패 | 네이밍 규칙 이탈 자체를 차단 |

> 로컬에서 `git checkout -b` 하는 대신 GitHub Actions 워크플로를 실행.
> 브랜치 생성 경로가 단일화되면 "어디서 분기했는지"가 더 이상 사람의 기억에 달리지 않는다.

---

### 실수 7 — 정기배포 브랜치 생성을 잊음

**어떤 실수인가**
매 화요일 정기배포 후 담당자가 차주 브랜치를 생성해야 한다고 기억하고 있지만
외근, 휴가, 업무 집중 중에 잊을 수 있다. "누가 만들어야 해요?" 도 반복된다.

**시스템 대응**

| 수단 | 동작 | 왜 이 방식인가 |
|------|------|---------------|
| **`auto-create-release-branch.yml`** (신규) | `release/*` → `main` PR 머지 이벤트 + KST 화요일 조건 → 차주 `release/YYYY.MM.DD.01` 자동 생성 | 담당자 없이, 알림 없이, 자동 |
| 멱등성 보장 | 같은 화요일 복수 머지 시 중복 생성 없음 | 자동화 자체가 부작용을 만들지 않음 |
| **수동 fallback** | 화요일 머지 조건 미충족 시 `create-branch.yml`로 수동 생성 가능 | 자동화 실패를 사람이 보완하는 경로 유지 |

---

### 실수 8 — 미머지 브랜치를 실수로 삭제

**어떤 실수인가**
개발자가 작업 완료 후 브랜치를 정리하다 아직 main에 머지되지 않은 브랜치를 지운다.

**시스템 대응**

| 수단 | 동작 | 왜 이 방식인가 |
|------|------|---------------|
| **`delete-branch.yml`** | 삭제 전 머지 여부 자동 검증 (squash 머지도 PR 이력으로 확인). 미머지이면 `force=true` 재실행 요구 | 실수 삭제와 의도적 삭제를 구분하는 마찰(friction)을 의도적으로 추가 |
| `main` 하드코드 거부 | `branch` 입력이 `main`이면 즉시 실패 | 코드 검토 없이 원천 차단 |

---

## 도입 단계 (의존성 기준)

```
Phase 1 — 기반 잠금 (2026.06.29)
│
├── 0. develop-only 커밋 정리 + develop 브랜치 폐지 계획 수립
│   └─ dev 배포 대안 확정 전까지 실제 삭제는 보류 (§미해결 #1)
│
├── 1. GitHub App 생성·설치·시크릿 등록
│   └─ ⚠️ 이 단계가 완료되기 전에 Ruleset을 켜면 merge-in이 즉시 차단됨
│
├── 2. Rulesets 활성화 (main / release/** / hotfix/**)
│   └─ App bypass "Always" 등록과 동시에 진행
│
└── 3. Required status checks 등록 (check, conflict-check)
    └─ Ruleset과 동시 등록 — 누락 시 미동기화 PR이 그대로 머지 가능

  ↓ Phase 1 완료 후 2026.06.29~07.03 동안 시범 검증

Phase 2 — 자동화 확장
│
├── 4. merge-in 자동화 전 저장소 적용 (워크플로 이식)
│
├── 5. 브랜치 생성 워크플로 (create-branch.yml) 도입
│
├── 6. 정기배포 자동생성 (auto-create-release-branch.yml) 도입
│
└── 7. develop 브랜치 정식 폐지 (dev 배포 대안 확정 후)
```

---

## 미해결 결정 (팀장 합의 필요)

| # | 결정 항목 | 현재 제안 | 이유 |
|---|-----------|-----------|------|
| 1 | **dev 배포 대안** | release 직접 배포 / 전용 파이프라인 중 선택 | develop 폐지의 선결조건 |
| 2 | **develop 폐지 시점** | dev 배포 대안 확정 후 | 대안 없이 폐지하면 dev 배포 불가 |
| 3 | **브랜치 생성 워크플로 구조** | 단일 파라미터화(1파일) 권장 | release·hotfix prefix만 다르고 로직 동일 |
| 4 | **정기배포 자동생성 fallback** | 수동 워크플로 유지 | 지연 머지 시 차주 브랜치 미생성 보완 |
| 5 | **App private key 로테이션** | 6개월 주기, 담당자 지정 | 미지정 시 key 노출·만료 시 전 자동화 정지 |

---

## 관련 문서

| 문서 | 참조 시점 |
|------|----------|
| [suggest.md](./suggest.md) | 커밋 누락 근본 원인·전략 배경 이해 시 |
| [branch-strategy-rollout.md](./branch-strategy-rollout.md) | GitHub App 생성·Ruleset 설정·required check 등록 절차 |
| [merge-in-automation.md](./merge-in-automation.md) | merge-in 설계 상세 (merge commit vs squash, App bypass 선택 근거) |

---

## 변경 이력

| 날짜 | 내용 |
|------|------|
| 2026-06-26 | 최초 작성. "막아야 할 실수 → 시스템 대응" 구조로 전면 재작성. |
