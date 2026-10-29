# Articlue 실행·배포 가이드

전체 스택 실행, 환경변수, 배치 운영, DB 마이그레이션, 외부 공개, CI/CD, 운영 명령을 정리한 문서입니다.
프로젝트 소개는 [README](../README.md), 버전별 변경은 [CHANGELOG](../CHANGELOG.md) 를 보세요.

> **이 repo = 배포 환경.** 서브모듈 포인터 = 각 서비스 repo `main` 최신 = 서버가 쓰는 Docker Hub 이미지 `:SHA`.

## 1. 빠른 시작

```bash
git clone --recurse-submodules https://github.com/kdt-mx-articlue/articlue-deploy.git articlue
cd articlue
cp .env.example .env        # OPENAI_API_KEY, ORACLE_* 비밀번호 채우기 (2장)
```

**A. 배포 이미지 그대로 띄우기 (권장 — 운영 서버와 동일)**

```bash
docker compose pull
docker compose up -d --no-build
docker compose ps           # 전부 healthy / migrate 는 Exited (0) 이면 정상
```

**B. 서브모듈 소스로 직접 빌드**

```bash
docker compose up -d --build
```

- 접속: `http://localhost` (기본 `127.0.0.1:80`. 80 을 다른 프로그램이 쓰면 `.env` 에 `HTTP_PORT=8080` + `PUBLIC_ORIGIN=http://localhost:8080`)
- 최초 기동
  - Oracle 초기화 약 1분 → `articlue-migrate` 가 스키마 + 기업·공고 시드 데이터 적재
  - AI 서버는 이미지에 들어 있는 채용공고 벡터 DB 를 그대로 사용 → **LLM 파싱 없이 수 초 만에 기동**
    (벡터 DB 가 없을 때만 전체 파싱 — 수 분, OpenAI 소액 과금)
- 이메일 회원가입/로그인과 "데모로 체험하기"는 소셜 키 없이 바로 동작합니다.

**클론해서 확인할 때 알아 둘 것**
- `.env` 는 git 에 없습니다. 키·비밀번호는 안전한 경로로 따로 옮기세요.
- DB·벡터 데이터는 Docker 볼륨에 있어 새 환경은 시드 데이터로 시작합니다. 수집 공고는 관리자 화면에서 채용공고 배치를 수동 실행하면 채워집니다 (3장).
- 클론 직후 서브모듈은 detached HEAD 입니다. 개발하려면 `./scripts/sync-local.sh` 로 `main` 에 맞추세요.
- B 방식으로 빌드하면 Hub 와 같은 이름(`:portfolio`)으로 로컬 이미지가 덮어써집니다. 배포 이미지로 돌아가려면 A 방식을 다시 실행하세요.

## 2. 환경변수

모든 값은 루트 `.env` 하나로 관리하고, `docker-compose.yml` 이 서비스별로 나눠 전달합니다. 자세한 설명은 [.env.example](../.env.example) 참고.

| 변수 | 필수 | 설명 |
|------|:---:|------|
| `PUBLIC_ORIGIN` | ✅ | 브라우저 접속 주소 (`http://<서버IP>` 또는 `https://도메인`). CORS·OAuth Redirect 에 사용 |
| `ORACLE_SYS_PASSWORD` / `ORACLE_USER` / `ORACLE_PASSWORD` | ✅ | DB 관리자 / 앱 계정 |
| `OPENAI_API_KEY` | ✅ | 이력서 분석·자소서·면접·공고 파싱 |
| `OPENAI_MODEL`, `INTERVIEW_REPORT_MODEL` | | 기본 모델 / 면접 최종 리포트 전용 모델 (기본 `gpt-4o-mini` / `gpt-4.1-mini`) |
| `MATCH_TOP_K` | | 1차 매칭 점수를 계산할 공고 수 (기본 `0` = 전체, 바꾸지 않는 것을 권장) |
| `ELEVENLABS_API_KEY`, `ELEVENLABS_TTS_VOICE_ID` | | 보이스 면접 |
| `KAKAO_*`, `NAVER_*`, `GITHUB_CLIENT_ID` | | 소셜 로그인 (미설정 시 비활성) |
| `ADMIN_TOKEN` | | 관리자 배치 화면 접속 토큰 (비우면 관리자 기능 비활성) |
| `BATCH_ENABLED`, `JOB_CRAWL_*` | | 배치 on/off, 채용공고 수집 주기·사이트·키워드·사이트당 최대 건수 |
| `INTERVIEW_FREE_LIMIT`, `DEMO_INTERVIEW_LIMIT` | | 모의 면접 이용 한도 (일반 / 체험 계정) |
| `HTTP_BIND`, `HTTP_PORT` | | 외부 공개 범위·포트. 기본 `127.0.0.1` / `80` (6장) |
| `COMPOSE_PROFILES`, `CLOUDFLARE_TUNNEL_TOKEN` | | `tunnel` 이면 Cloudflare Tunnel 함께 실행 |
| `VITE_MEDIA_BASE_URL` | | (소스 빌드 시) 로딩 영상 등 미디어 주소. 기본 `https://media.donghwan.cloud` |
| `IMAGE_REGISTRY`, `IMAGE_TAG`, `AI_/BACKEND_/FRONTEND_IMAGE_TAG` | | pull 할 이미지 위치·태그 (롤백용) |

> 서비스 repo 내부의 `.env` 는 필요 없습니다. compose 가 컨테이너 환경변수로 직접 주입합니다.
> 카카오 REST 키·네이버 Client ID 는 **프론트 빌드 시점**에 번들에 들어갑니다. CI 이미지는 frontend repo 의 GitHub Variables 값을 씁니다 (7장).

## 3. 배치 운영

| 배치 | 주기 (KST) | 내용 |
|------|-----------|------|
| DBR 아티클 | 매일 00:00 | 공개 영역 HTTP 수집 → 요약 → 화면용 파일 갱신 |
| 채용공고 수집 | 매주 월 04:00 (`JOB_CRAWL_CRON`) | 원티드·사람인·잡코리아 → 신규·변경 공고만 DB 저장 + AI 벡터 반영 |

- 배치는 백엔드의 **자식 프로세스**로 실행돼 실패해도 API 서버는 계속 동작합니다.
- 실행 결과는 `BATCH_RUN` 테이블에 SUCCESS / PARTIAL / FAILED 로 남습니다.
- 관리자 화면: `${PUBLIC_ORIGIN}/admin/batch` → `ADMIN_TOKEN` 입력 → 이력 확인·수동 실행
- 실패한 배치는 코드 수정 후 재배포하면 기동 시 자동 보충 실행되고, 수동 실행도 가능합니다.
- 설계 배경은 backend repo 문서와 트러블슈팅 기록(`02_DESIGN-job-crawl-batch.md`) 참고.

## 4. DB 마이그레이션

스키마는 `articlue-backend/db/migrations/V<번호>__설명.sql` 로 관리됩니다 ([상세 문서](../articlue-backend/db/README.md)).
새 파일을 추가해 배포하면 `articlue-migrate` 가 미적용분만 실행합니다.

```bash
docker compose run --rm articlue-migrate node ./scripts/migrate.js status   # 적용 현황
docker compose run --rm articlue-migrate                                    # 수동 적용
```

## 5. 작업 흐름 — 병합은 웹, 로컬은 받아오기만

1. 서비스 repo 에서 `기능 브랜치 → dev → main` PR 을 **GitHub 웹에서** 병합 (merge commit)
2. main 병합이 끝나면 그 서비스 repo 의 CI 가 이미지를 빌드·push 하고 서버 배포까지 요청합니다 (7장)
3. 로컬은 받아오기만 합니다

```bash
./scripts/sync-local.sh        # 래퍼 main pull + 서비스 repo 3개 main 으로 전환·pull
docker compose pull && docker compose up -d --no-build   # 배포 이미지로 다시 띄우기
```

- 작업 중인 변경이 있는 repo 는 건드리지 않고 알려 줍니다.
- 서비스 repo `main` 이 바뀌면 이 repo `main` 에 포인터 갱신 커밋을 올립니다 (`chore: 서브모듈을 서비스 main 으로 갱신`).
  동기화 후 래퍼 `git status` 에 서브모듈이 `M` 으로 보이면 포인터가 뒤처진 것입니다.
- 새 버전을 올리면 [CHANGELOG](../CHANGELOG.md) 에 한 항목을 추가합니다.

## 6. 외부 공개 방식 — `.env` 만 바꾸면 됩니다 (compose 수정 불필요)

| 방식 | `.env` | 방화벽/보안그룹 | HTTPS |
|------|--------|----------------|-------|
| **Cloudflare Tunnel** (노트북·VM 공통, 기본 추천) | `COMPOSE_PROFILES=tunnel`, `CLOUDFLARE_TUNNEL_TOKEN=…` (HTTP_BIND 는 기본 `127.0.0.1`) | 22 만 (집 노트북은 아무것도 안 열어도 됨) | Cloudflare 가 처리 |
| 클라우드 VM 직접 공개 | `HTTP_BIND=0.0.0.0` | 80 (+ 22) | 앞단에 Caddy/Nginx + Let's Encrypt, 또는 클라우드 로드밸런서 |
| 클라우드 로드밸런서 뒤 | `HTTP_BIND=0.0.0.0`, 보안그룹으로 LB 에서 오는 요청만 허용 | 80 (LB 만) | LB 인증서 |

- 터널: Cloudflare Zero Trust → Networks → Tunnels → 터널 생성 → 토큰을 `.env` 에. Public Hostname 의 서비스 주소는 `http://articlue-frontend:80` (같은 Docker 네트워크라 호스트 포트와 무관).
  호스트에 설치한 `cloudflared` 를 쓴다면 서비스 주소는 `http://127.0.0.1:80` 이고 profile 은 켜지 않습니다.
- 어느 방식이든 `PUBLIC_ORIGIN` 은 브라우저 주소 그대로 (`https://articlue.example.com`) — OAuth Redirect 가 이 값으로 계산됩니다.
- 관리형 서비스(ECS·Cloud Run·Kubernetes)로 옮길 때는 compose 대신 같은 Docker Hub 이미지와 환경변수를 씁니다. Oracle·벡터 볼륨은 관리형 DB·영구 디스크로 옮겨야 합니다.
- OCI 무료 ARM 서버는 이미지가 `linux/amd64` 뿐이라 그대로 못 뜹니다 (CI 를 `linux/amd64,linux/arm64` 로 빌드 + Oracle 이미지를 `gvenzl/oracle-free:23` 으로).

## 7. 클라우드 서버 배포 (CI/CD)

### 서버 1회 준비 (Ubuntu 기준, **RAM 4GB 이상 권장** — Oracle XE ~2GB + AI ~1GB)

```bash
curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER   # 재접속 필요
git clone --recurse-submodules https://github.com/kdt-mx-articlue/articlue-deploy.git ~/articlue
cd ~/articlue && cp .env.example .env && vi .env   # PUBLIC_ORIGIN=http://<서버 공인 IP>
./scripts/deploy.sh
```

### 구조 — 각 서비스 repo 가 자기 이미지를 빌드

```
서비스 repo (ai / backend / frontend)          articlue-deploy (이 repo)          서버
  main 병합 → docker-image 워크플로             deploy 워크플로                    scripts/deploy.sh
             이미지 빌드 → Docker Hub push ──▶  (repository_dispatch) ── SSH ──▶  docker compose pull → up
             scv3114/<서비스>:portfolio, :SHA
```

- 서버는 서비스 소스 없이 이미지만 씁니다. 서브모듈 포인터는 그 이미지의 `:SHA` 와 같은 커밋으로 맞춰 둡니다 (어떤 코드가 배포됐는지 이 repo 에서 바로 확인).
- 기존 `:latest` 태그는 팀 서버가 쓸 수 있어 덮어쓰지 않습니다. 공개 이미지라 서버는 로그인 없이 pull 합니다.

### GitHub 설정 (Settings → Secrets and variables → Actions)

**서비스 repo 3개** (organization 단위 Secrets/Variables 로 한 번에 넣어도 됩니다)

| 종류 | 이름 | 값 |
|------|------|----|
| Secret | `DOCKERHUB_USERNAME` | `scv3114` |
| Secret | `DOCKERHUB_TOKEN` | Docker Hub → Account settings → Personal access tokens (Read & Write) |
| Secret | `DEPLOY_DISPATCH_TOKEN` | (선택) GitHub Fine-grained PAT — 대상 `articlue-deploy`, 권한 Contents: Read and write. 없으면 이미지만 올리고 배포는 수동 |
| Variable | `KAKAO_REST_API_KEY`, `NAVER_CLIENT_ID` | (frontend) 번들에 들어가는 공개 키. **Secrets 가 아니라 Variables 탭.** 바꾸면 Actions → docker-image → Run workflow 로 다시 빌드 |

**이 repo (articlue-deploy)**

| 종류 | 이름 | 값 |
|------|------|----|
| Secret | `DEPLOY_HOST` | 서버 공인 IP |
| Secret | `DEPLOY_USER` | SSH 사용자 (예: `ubuntu`) |
| Secret | `DEPLOY_SSH_KEY` | 배포용 SSH 개인키 (공개키는 서버 `~/.ssh/authorized_keys` 에 등록) |
| Secret | `DEPLOY_PORT` / `DEPLOY_PATH` | (선택) 기본 `22` / `~/articlue` |
| Variable | `DEPLOY_ENABLED` | `true` — 넣기 전까지는 배포 워크플로가 실행되지 않음 |

### 흐름

1. 서비스 repo `main` 에 PR 병합 → 그 repo 의 `docker-image` 워크플로가 이미지 빌드·push → `articlue-deploy` 에 배포 요청
2. `deploy` 워크플로가 SSH 로 서버에서 [`scripts/deploy.sh`](../scripts/deploy.sh) 실행 → 이미지 pull → migrate → 컨테이너 교체
3. 이 repo 의 compose·스크립트 변경이 `main` 에 반영돼도 바로 배포
4. 수동 배포: Actions → **deploy → Run workflow**

롤백 (커밋 SHA 태그)
- 전체: Actions → deploy → Run workflow → `image_tag` 에 SHA, 또는 서버에서 `IMAGE_TAG=<SHA> ./scripts/deploy.sh`
- 서비스 하나만: 서버에서 `BACKEND_IMAGE_TAG=<SHA> ./scripts/deploy.sh` (`AI_` / `BACKEND_` / `FRONTEND_IMAGE_TAG`)

## 8. 운영 메모

```bash
docker compose logs -f articlue-backend          # 로그
docker compose restart articlue-ai               # 재시작
docker compose down                              # 중지 (데이터 유지)
docker compose down -v                           # ⚠️ DB·벡터·수집 데이터까지 삭제
```

- 데이터 볼륨: `oracle-data`(DB), `ai-vectors`(벡터 DB — 최초 생성 시 이미지의 벡터 DB 로 채워짐), `backend-storage`(아티클·트렌드 결과)
- 지금 떠 있는 이미지가 배포 이미지인지 확인: `docker inspect -f '{{.Image}}' articlue-frontend` 결과를 Docker Hub `:portfolio` digest 와 비교
- HTTPS 는 Cloudflare Tunnel 이 가장 간단합니다 (6장). 직접 공개라면 앞단에 Caddy/Nginx + Let's Encrypt 를 두고 `PUBLIC_ORIGIN` 을 `https://...` 로 바꾸세요.
