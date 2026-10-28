#!/usr/bin/env bash
# 로컬 동기화 — 웹(GitHub)에서 PR 병합이 끝난 뒤 변경사항을 받아오기만 한다.
#   커밋·push 는 하지 않는다. 서브모듈 포인터도 커밋하지 않는다
#   (배포는 각 서비스 repo CI 가 만든 이미지 기준이라 포인터는 배포와 무관).
#
#   ./scripts/sync-local.sh
#     1. 래퍼 repo: main 을 fast-forward 로 pull
#     2. 서비스 repo 3개: fetch 후 main 으로 전환해 fast-forward pull
#        (작업 중인 변경이 있거나 main 으로 fast-forward 가 안 되면 건드리지 않고 알려 줌)
#
#   이후 docker compose up -d --build 하면 각 서비스 main 최신 코드로 뜬다.
set -uo pipefail

cd "$(dirname "$0")/.."

SUBMODULES=(articlue-ai articlue-backend articlue-frontend)
problems=0

echo "==> 래퍼 repo (articlue)"
if [ -n "$(git status --porcelain --ignore-submodules=all)" ]; then
  echo "    작업 중인 변경이 있어 pull 을 건너뜁니다. (git status 확인)"
  problems=$((problems + 1))
else
  git fetch --quiet origin
  if git checkout --quiet main && git pull --quiet --ff-only origin main; then
    echo "    main 최신: $(git log -1 --format='%h %s')"
  else
    echo "    main fast-forward 실패 — 로컬 main 에 원격에 없는 커밋이 있습니다."
    problems=$((problems + 1))
  fi
fi

git submodule sync --quiet --recursive

for repo in "${SUBMODULES[@]}"; do
  echo "==> $repo"

  # 처음 받은 경우에만 초기화 (이미 있는 서브모듈은 작업 중인 브랜치를 건드리지 않음)
  if [ ! -e "$repo/.git" ]; then
    git submodule update --init --quiet "$repo"
  fi

  git -C "$repo" fetch --quiet --prune origin

  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    echo "    작업 중인 변경이 있어 건너뜁니다. (현재: $(git -C "$repo" rev-parse --abbrev-ref HEAD))"
    problems=$((problems + 1))
    continue
  fi

  current=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  if [ "$current" != "main" ]; then
    # 병합이 끝난 기능 브랜치인지 알려 줌 (브랜치는 지우지 않음)
    if git -C "$repo" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
      echo "    $current → main 에 병합됨, main 으로 전환"
    else
      echo "    $current 에 main 에 아직 없는 커밋이 있습니다 (PR 미병합). main 으로 전환은 하되 브랜치는 그대로 둡니다."
    fi
  fi

  if git -C "$repo" checkout --quiet main 2>/dev/null || git -C "$repo" checkout --quiet -b main origin/main; then
    if git -C "$repo" pull --quiet --ff-only origin main; then
      echo "    main 최신: $(git -C "$repo" log -1 --format='%h %s')"
    else
      echo "    main fast-forward 실패 — 로컬 main 에 원격에 없는 커밋이 있습니다."
      problems=$((problems + 1))
    fi
  else
    echo "    main 으로 전환하지 못했습니다."
    problems=$((problems + 1))
  fi
done

echo
if [ "$problems" -gt 0 ]; then
  echo "확인이 필요한 항목 ${problems}건 (위 메시지 참고). 커밋·push 는 하지 않았습니다."
  exit 1
fi
echo "동기화 완료. 커밋·push 는 하지 않았습니다."
echo "래퍼 git status 에 서브모듈이 'M' 으로 보여도 정상 — 포인터는 배포와 무관하니 커밋하지 않습니다."
