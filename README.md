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

- 접속: `http://localhost` (80 포트 고정 — 로컬에서 80을 다른 프로그램이 쓰고 있으면 먼저 종료)
- 최초 기동 시
  - Oracle 초기화 ~1분 → `articlue-migrate` 가 스키마 + 기업/공고 데이터 적재
  - AI 서버가 채용공고 484건을 LLM 으로 파싱해 벡터 DB 생성 (수 분, OpenAI 소액 과금). 결과는 볼륨에 저장되어 이후엔 생략
- 이메일 회원가입/로그인은 소셜 키 없이 바로 동작합니다.

### 작업 흐름 — 병합은 웹, 로컬은 받아오기만

1. 서비스 repo 에서 `기능 브랜치 → dev → main` PR 을 **GitHub 웹에서** 병합
2. 서브모듈 포인터 갱신(배포 반영)도 웹에서: Actions → **build-and-deploy → Run workflow → sync_submodules 체크**
3. 로컬은 받아오기만 합니다 (커밋·push 없음)

```bash
./scripts/sync-local.sh        # 래퍼 main pull + 서비스 repo 3개 main 으로 전환·pull
docker compose up -d --build   # main 최신 코드로 다시 띄우기
```

- 작업 중인 변경이 있는 repo 는 건드리지 않고 알려 줍니다.
- 동기화 후 래퍼 `git status` 에 서브모듈이 `M` 으로 보이면 "포인터보다 main 이 앞선 상태"입니다. 로컬에서 커밋하지 말고 2번(Actions)으로 갱신하세요.

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

방화벽/보안그룹은 **80과 22만** 열면 됩니다.

### GitHub repo 설정 (Settings → Secrets and variables → Actions)

| 종류 | 이름 | 값 |
|------|------|----|
| Secret | `DOCKERHUB_USERNAME` | `scv3114` |
| Secret | `DOCKERHUB_TOKEN` | Docker Hub → Account settings → Personal access tokens (Read & Write) |
| Secret | `DEPLOY_HOST` | 서버 공인 IP |
| Secret | `DEPLOY_USER` | SSH 사용자 (예: `ubuntu`) |
| Secret | `DEPLOY_SSH_KEY` | 배포용 SSH 개인키 (공개키는 서버 `~/.ssh/authorized_keys` 에 등록) |
| Secret | `DEPLOY_PORT` / `DEPLOY_PATH` | (선택) 기본 `22` / `~/articlue` |
| Variable | `DEPLOY_ENABLED` | `true` — 넣기 전까지는 빌드·푸시까지만 수행 |
| Variable | `KAKAO_REST_API_KEY`, `NAVER_CLIENT_ID` | (선택) 프론트 빌드에 들어가는 공개 키 |

### 흐름

1. 이 repo `main` 에 push → `prepare` → 3개 이미지 병렬 빌드 → Docker Hub `scv3114/articlue-*:{portfolio,SHA}` push
   (기존 `:latest` 태그는 덮어쓰지 않음 — 공개 이미지라 서버는 로그인 없이 pull)
2. `deploy` 가 SSH 로 서버에서 [`scripts/deploy.sh`](scripts/deploy.sh) 실행 → pull → migrate → 무중단에 가깝게 컨테이너 교체
3. 서비스 repo 의 최신 코드를 반영하려면 Actions → **build-and-deploy → Run workflow → sync_submodules 체크**
   (서브모듈 포인터를 각 repo `main` 최신으로 올리는 커밋을 CI 가 만들고 그대로 배포 — 포인터는 로컬에서 커밋하지 않음)

롤백: 서버에서 `IMAGE_TAG=<이전 커밋 SHA> ./scripts/deploy.sh`

## 5. 운영 메모

```bash
docker compose logs -f articlue-backend          # 로그
docker compose restart articlue-ai               # 재시작
docker compose down                              # 중지 (데이터 유지)
docker compose down -v                           # ⚠️ DB·벡터 데이터까지 삭제
```

- 데이터 볼륨: `oracle-data`(DB), `ai-vectors`(벡터 DB), `backend-storage`(크롤링 아티클)
- 백엔드의 DBR 크롤링은 Playwright/Chrome 이 없어 에러 로그가 날 수 있으나 서비스에는 영향 없습니다.
- HTTPS 가 필요하면 도메인 연결 후 앞단에 Caddy/Nginx + Let's Encrypt 를 두고 `PUBLIC_ORIGIN` 을 `https://...` 로 바꾸세요.
