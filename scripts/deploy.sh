#!/usr/bin/env bash
# 서버에서 실행하는 배포 스크립트 (CI 가 SSH 로 호출, 수동 실행도 가능)
#
#   ./scripts/deploy.sh                          # 각 서비스 main 최신 이미지(:portfolio)
#   IMAGE_TAG=<태그> ./scripts/deploy.sh          # 세 서비스 모두 같은 태그로
#   BACKEND_IMAGE_TAG=<SHA> ./scripts/deploy.sh  # 서비스 하나만 롤백 (AI_ / BACKEND_ / FRONTEND_IMAGE_TAG)
#
# 이미지는 각 서비스 repo CI 가 빌드한다. 서버에는 서비스 소스(서브모듈)가 필요 없다.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo ".env 가 없습니다. cp .env.example .env 후 값을 채우세요." >&2
  exit 1
fi

echo "==> 설정 갱신 (compose·스크립트)"
git fetch --quiet origin main
git checkout --quiet main
git pull --quiet --ff-only origin main

echo "==> 이미지 pull (기본 tag: ${IMAGE_TAG:-portfolio})"
docker compose pull --quiet articlue-ai articlue-backend articlue-frontend

echo "==> 컨테이너 기동 (DB 마이그레이션 → 백엔드 순)"
docker compose up -d --no-build --remove-orphans

echo "==> 사용하지 않는 이미지 정리"
docker image prune -f >/dev/null

docker compose ps
