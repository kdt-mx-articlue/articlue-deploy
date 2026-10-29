# Articlue — AI 커리어 매칭 플랫폼

> 이력서 한 번 입력으로 기업 매칭 · 자소서 생성 · AI 모의 면접까지 한 번에

**Articlue** 는 취업 준비생을 위한 AI 기반 올인원 커리어 플랫폼입니다.
커리어 프로필(이력서)을 등록하면 AI 가 채용공고와의 적합도를 분석하고, 기업 맞춤 자소서를 만들고, 실전 모의 면접과 피드백까지 제공합니다.

- 서비스 체험: 회원가입 없이 **"데모로 체험하기"** 로 둘러볼 수 있습니다
- 업데이트 내역: [CHANGELOG.md](CHANGELOG.md) (현재 **v2**, 2026-10-28)
- 실행·배포 가이드: [docs/DEPLOY.md](docs/DEPLOY.md)

---

## 주요 기능

| 기능 | 설명 |
|------|------|
| 커리어 프로필 | 학력·경력·자격증·기술스택·포트폴리오 등록, GitHub 연동 |
| 기업 매칭 | 이력서와 전체 채용공고의 벡터 유사도로 1차 점수, 상위 공고는 GPT 정밀 분석. 경력 요건이 맞지 않는 공고는 감점·배지 표시 |
| 자소서 생성 | 기업·직무 맞춤 자기소개서 자동 생성 |
| AI 모의 면접 | 챗봇 / 보이스(AI 아바타 아티) 모드, 난이도·면접관 성향·질문 수 설정 |
| 면접 리포트 | 5개 역량 점수, **질문별 판정·피드백**, 강점·보완점, 추천 액션 플랜 |
| IT 인사이트 | DBR 아티클을 매일 수집·요약해 대시보드에 큐레이션 |
| 채용공고 최신화 | 원티드·사람인·잡코리아 공고를 **매주 자동 수집**, 신규·변경분만 AI 분석에 반영 |
| 체험 계정 | 가입 없이 샘플 이력서·매칭 결과·샘플 면접 리포트까지 바로 확인 |
| 관리자 | 배치 실행 이력 조회·수동 실행 (`/admin/batch`) |

---

## 아키텍처

```
브라우저 ─▶ Cloudflare Tunnel ─▶ frontend (Nginx) ─/api/─▶ backend (Express) ─▶ ai (FastAPI)
                                       │                        │    │                 └─ ChromaDB (공고·이력서 벡터)
                                       │                        │    └─ 배치 (자식 프로세스): 아티클 매일 · 채용공고 매주
                                       │                        └─ Oracle XE (마이그레이션 자동 적용)
                                       └─ 미디어: Cloudflare R2
```

- 외부에 열리는 포트는 frontend 하나뿐이고, backend·ai·DB 는 Docker 내부망에서만 통신합니다.
- 배치는 API 서버와 프로세스를 분리해, 수집이 실패해도 서비스는 계속 동작합니다.
- 각 서비스 repo 의 `main` 에 병합되면 CI 가 이미지를 빌드해 Docker Hub 에 올리고, 이 repo 가 그 이미지로 배포합니다.

---

## 기술 스택

| 영역 | 사용 기술 |
|------|-----------|
| Frontend | React 19, Vite 8, React Router 7, Tailwind CSS 4, Zustand, Axios |
| Backend | Node.js, Express 5, node-oracledb 6 (Thin 모드), node-cron, Kakao·Naver·GitHub 소셜 로그인 |
| AI | Python 3.12, FastAPI, LangChain, ChromaDB, OpenAI (`gpt-4o-mini`, 면접 리포트 `gpt-4.1-mini`), ElevenLabs (음성 면접) |
| DB | Oracle XE 21c |
| Infra | Docker Compose, GitHub Actions, Docker Hub, Cloudflare Tunnel · R2 |

---

## Repository 구성

이 repo(`articlue-deploy`)는 3개 서비스 repo 를 git submodule 로 묶은 **배포 repo** 입니다.
서브모듈 포인터는 각 서비스 `main` 최신 = 운영 중인 이미지와 항상 같게 유지합니다.

| 경로 | repo | 역할 |
|------|------|------|
| `articlue-frontend/` | [articlue-frontend](https://github.com/kdt-mx-articlue/articlue-frontend) | 화면, Nginx 리버스 프록시 |
| `articlue-backend/` | [articlue-backend](https://github.com/kdt-mx-articlue/articlue-backend) | API, 인증, DB, 배치, 마이그레이션 |
| `articlue-ai/` | [articlue-ai](https://github.com/kdt-mx-articlue/articlue-ai) | 이력서 분석·매칭, 자소서, 면접, 공고 파싱 |
| `docker-compose.yml` | — | 전체 스택 정의 |
| `scripts/` | — | `deploy.sh` (서버 배포), `sync-local.sh` (로컬 동기화) |
| `docs/DEPLOY.md` | — | 실행·환경변수·배치·배포 가이드 |
| `CHANGELOG.md` | — | 버전별 업데이트 내역 |

---

## 빠른 시작

Docker 만 있으면 됩니다.

```bash
git clone --recurse-submodules https://github.com/kdt-mx-articlue/articlue-deploy.git articlue
cd articlue
cp .env.example .env              # OPENAI_API_KEY, ORACLE_* 비밀번호 채우기
docker compose pull && docker compose up -d --no-build
```

`http://localhost` 로 접속합니다. Oracle 초기화에 약 1분 걸리고, 채용공고 벡터 DB 는 이미지에 들어 있어 AI 서버는 바로 뜹니다.
소스로 직접 빌드, 환경변수, 배치 운영, 클라우드 배포는 [docs/DEPLOY.md](docs/DEPLOY.md) 를 보세요.
