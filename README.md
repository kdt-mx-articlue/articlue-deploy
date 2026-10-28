# Articlue — 배포 / 오케스트레이션

AI 커리어 매칭 플랫폼 **Articlue** 의 3개 서비스 repo 를 git submodule 로 묶어
Docker Compose 한 번으로 전체 스택을 띄우고, GitHub Actions 로 자동 빌드·배포합니다.

| 서비스 | repo | 역할 |
|--------|------|------|
| `articlue-frontend` | [articlue-frontend](https://github.com/kdt-mx-articlue/articlue-frontend) | React(Vite) + Nginx, `/api` 리버스 프록시 — **외부 공개 포트는 이것뿐** |
| `articlue-backend` | [articlue-backend](https://github.com/kdt-mx-articlue/articlue-backend) | Express API, Oracle 연결(Thin 모드) |
| `articlue-migrate` | (backend 이미지) | 백엔드 기동 전 DB 마이그레이션 1회 실행 |
| `articlue-ai` | [articlue-ai](https://github.com/kdt-mx-articlue/articlue-ai) | FastAPI + LangChain + ChromaDB |
| `oracle` | `gvenzl/oracle-xe:21-slim-faststart` | Oracle XE 21c |

```
브라우저 ─▶ frontend(Nginx :80) ─/api/─▶ backend(:3000) ─▶ ai(:5000)
                                              │
                         migrate(1회) ─▶ oracle(:1521, 내부망 전용)
```

## 1. 로컬 실행

```bash
git clone --recurse-submodules https://github.com/kdt-mx-articlue/articlue-deploy.git articlue
cd articlue
cp .env.example .env        # OPENAI_API_KEY, ORACLE_* 비밀번호 채우기
docker compose up -d --build
docker compose ps           # 전부 healthy / migrate 는 Exited (0) 이면 정상
```

- 접속: `http://localhost` (기본 `127.0.0.1:80`. 80 을 다른 프로그램이 쓰면 `.env` 에 `HTTP_PORT=8080` + `PUBLIC_ORIGIN=http://localhost:8080`)
- 최초 기동 시
  - Oracle 초기화 ~1분 → `articlue-migrate` 가 스키마 + 기업/공고 데이터 적재
  - AI 서버가 채용공고 484건을 LLM 으로 파싱해 벡터 DB 생성 (수 분, OpenAI 소액 과금). 결과는 볼륨에 저장되어 이후엔 생략
- 이메일 회원가입/로그인은 소셜 키 없이 바로 동작합니다.

### 작업 흐름 — 병합은 웹, 로컬은 받아오기만

1. 서비스 repo 에서 `기능 브랜치 → dev → main` PR 을 **GitHub 웹에서** 병합
2. main 병합이 끝나면 그 서비스 repo 의 CI 가 이미지를 빌드·push 하고 서버 배포까지 요청합니다 (아래 4장)
3. 로컬은 받아오기만 합니다 (커밋·push 없음)

```bash
./scripts/sync-local.sh        # 래퍼 main pull + 서비스 repo 3개 main 으로 전환·pull
docker compose up -d --build   # main 최신 코드로 다시 띄우기
```

- 작업 중인 변경이 있는 repo 는 건드리지 않고 알려 줍니다.
- **이 repo 는 배포 환경과 항상 같아야 합니다.** 서브모듈 포인터 = 각 서비스 repo `main` 최신 = 서버가 쓰는 이미지 `:SHA` 태그.
  서비스 repo `main` 이 바뀌면 이 repo `main` 에 포인터 갱신 커밋을 올립니다 (`chore: 서브모듈을 서비스 main 으로 갱신`).
- 동기화 후 래퍼 `git status` 에 서브모듈이 `M` 으로 보이면 포인터가 서비스 `main` 보다 뒤처진 것이니 위처럼 갱신합니다.

## 2. 환경변수

모든 값은 루트 `.env` 하나로 관리하고, `docker-compose.yml` 이 서비스별로 나눠 전달합니다. 자세한 설명은 [.env.example](.env.example) 참고.

| 변수 | 필수 | 설명 |
|------|:---:|------|
| `PUBLIC_ORIGIN` | ✅ | 브라우저 접속 주소 (`http://<서버IP>` 또는 `https://도메인`). CORS·OAuth Redirect 에 사용 |
| `ORACLE_SYS_PASSWORD` / `ORACLE_USER` / `ORACLE_PASSWORD` | ✅ | DB 관리자 / 앱 계정 |
| `OPENAI_API_KEY` | ✅ | 이력서 분석·자소서·면접 |
| `ELEVENLABS_API_KEY`, `ELEVENLABS_TTS_VOICE_ID` | | 보이스 면접 |
| `KAKAO_*`, `NAVER_*`, `GITHUB_CLIENT_ID` | | 소셜 로그인 (미설정 시 비활성) |
| `IMAGE_REGISTRY`, `IMAGE_TAG` | | 서버에서 pull 할 이미지 위치 |
| `HTTP_BIND`, `HTTP_PORT` | | 외부 공개 범위·포트. 기본 `127.0.0.1` / `80` (아래 4장 "외부 공개 방식") |
| `COMPOSE_PROFILES`, `CLOUDFLARE_TUNNEL_TOKEN` | | `tunnel` 이면 Cloudflare Tunnel 함께 실행 |

> 서비스 repo 내부의 `.env` 는 필요 없습니다. compose 가 컨테이너 환경변수로 직접 주입합니다.

## 3. DB 마이그레이션

스키마는 `articlue-backend/db/migrations/V<번호>__설명.sql` 로 관리됩니다 ([상세 문서](articlue-backend/db/README.md)).
새 파일을 추가해 배포하면 `articlue-migrate` 가 미적용분만 실행합니다.

```bash
docker compose run --rm articlue-migrate node ./scripts/migrate.js status   # 적용 현황
docker compose run --rm articlue-migrate                                    # 수동 적용
```

## 4. 클라우드 서버 배포 (CI/CD)

### 서버 1회 준비 (Ubuntu 기준, **RAM 4GB 이상 권장** — Oracle XE ~2GB + AI ~1GB)

```bash
curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER   # 재접속 필요
git clone --recurse-submodules https://github.com/kdt-mx-articlue/articlue-deploy.git ~/articlue
cd ~/articlue && cp .env.example .env && vi .env   # PUBLIC_ORIGIN=http://<서버 공인 IP>
```

### 외부 공개 방식 — `.env` 만 바꾸면 됩니다 (compose 수정 불필요)

| 방식 | `.env` | 방화벽/보안그룹 | HTTPS |
|------|--------|----------------|-------|
| **Cloudflare Tunnel** (노트북·VM 공통, 기본 추천) | `COMPOSE_PROFILES=tunnel`, `CLOUDFLARE_TUNNEL_TOKEN=…` (HTTP_BIND 는 기본 `127.0.0.1`) | 22 만 (집 노트북은 아무것도 안 열어도 됨) | Cloudflare 가 처리 |
| 클라우드 VM 직접 공개 | `HTTP_BIND=0.0.0.0` | 80 (+ 22) | 앞단에 Caddy/Nginx + Let's Encrypt, 또는 클라우드 로드밸런서 |
| 클라우드 로드밸런서 뒤 | `HTTP_BIND=0.0.0.0`, 보안그룹으로 LB 에서 오는 요청만 허용 | 80 (LB 만) | LB 인증서 |

- 터널: Cloudflare Zero Trust → Networks → Tunnels → 터널 생성 → 토큰을 `.env` 에. Public Hostname 의 서비스 주소는 `http://articlue-frontend:80` (같은 Docker 네트워크라 호스트 포트와 무관).
- 어느 방식이든 `PUBLIC_ORIGIN` 은 브라우저 주소 그대로 (`https://articlue.example.com`) — OAuth Redirect 가 이 값으로 계산됩니다.
- `COMPOSE_PROFILES` 를 `.env` 에 두면 `docker compose up`·`scripts/deploy.sh` 가 자동으로 터널까지 띄웁니다.
- 관리형 서비스(ECS·Cloud Run·Kubernetes)로 옮길 때는 compose 대신 같은 Docker Hub 이미지와 환경변수를 씁니다. Oracle·벡터 볼륨은 관리형 DB·영구 디스크로 옮겨야 합니다.
- OCI 무료 ARM 서버는 이미지가 `linux/amd64` 뿐이라 그대로 못 뜹니다 (CI 를 `linux/amd64,linux/arm64` 로 빌드 + Oracle 이미지를 `gvenzl/oracle-free:23` 으로).

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
| Variable | `KAKAO_REST_API_KEY`, `NAVER_CLIENT_ID` | (frontend, 선택) 번들에 들어가는 공개 키 |

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
2. `deploy` 워크플로가 SSH 로 서버에서 [`scripts/deploy.sh`](scripts/deploy.sh) 실행 → 이미지 pull → migrate → 컨테이너 교체
3. 이 repo 의 compose·스크립트 변경이 `main` 에 병합돼도 바로 배포
4. 수동 배포: Actions → **deploy → Run workflow**

롤백 (커밋 SHA 태그)
- 전체: Actions → deploy → Run workflow → `image_tag` 에 SHA, 또는 서버에서 `IMAGE_TAG=<SHA> ./scripts/deploy.sh`
- 서비스 하나만: 서버에서 `BACKEND_IMAGE_TAG=<SHA> ./scripts/deploy.sh` (`AI_` / `BACKEND_` / `FRONTEND_IMAGE_TAG`)

## 5. 운영 메모

```bash
docker compose logs -f articlue-backend          # 로그
docker compose restart articlue-ai               # 재시작
docker compose down                              # 중지 (데이터 유지)
docker compose down -v                           # ⚠️ DB·벡터 데이터까지 삭제
```

- 데이터 볼륨: `oracle-data`(DB), `ai-vectors`(벡터 DB), `backend-storage`(크롤링 아티클)
- 백엔드의 DBR 크롤링은 Playwright/Chrome 이 없어 에러 로그가 날 수 있으나 서비스에는 영향 없습니다.
- HTTPS 는 Cloudflare Tunnel 이 가장 간단합니다 (4장 "외부 공개 방식"). 직접 공개라면 앞단에 Caddy/Nginx + Let's Encrypt 를 두고 `PUBLIC_ORIGIN` 을 `https://...` 로 바꾸세요.
