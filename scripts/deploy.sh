#!/usr/bin/env bash
# 서버에서 실행하는 배포 스크립트 (CI가 SSH로 호출, 수동 실행도 가능)
#
#   ./scripts/deploy.sh                    # main 최신 + latest 이미지
#   IMAGE_TAG=<커밋 SHA> ./scripts/deploy.sh   # 특정 버전으로 배포/롤백
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo ".env 가 없습니다. cp .env.example .env 후 값을 채우세요." >&2
  exit 1
fi

echo "==> 소스 갱신"
git fetch --quiet origin main
if [ -n "${DEPLOY_SHA:-}" ]; then
  git checkout --quiet --detach "$DEPLOY_SHA"
else
  git checkout --quiet main
  git pull --quiet --ff-only origin main
fi
git submodule sync --quiet --recursive
git submodule update --init --recursive

echo "==> 이미지 pull (tag: ${IMAGE_TAG:-latest})"
docker compose pull --quiet articlue-ai articlue-backend articlue-frontend

echo "==> 컨테이너 기동 (DB 마이그레이션 → 백엔드 순)"
docker compose up -d --no-build --remove-orphans

echo "==> 미사용 이미지 정리"
docker image prune -f >/dev/null

docker compose ps
