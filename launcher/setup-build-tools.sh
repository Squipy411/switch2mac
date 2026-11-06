#!/bin/zsh
set -eu
cd "${0:A:h}/.."

python=${SWITCH2MAC_PYTHON:-}
if [[ -z "$python" ]]; then
  for candidate in .venv/bin/python python3.14 python3.13 python3.12 python3; do
    if "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 12))' 2>/dev/null; then
      python=$candidate
      break
    fi
  done
fi
if [[ -z "$python" ]] || ! "$python" -c 'import sys; raise SystemExit(sys.version_info < (3, 12))'; then
  print -u2 "Install Python 3.12 or newer, or set SWITCH2MAC_PYTHON to its path."
  exit 1
fi
"$python" switch2mac.py setup

if [[ ${1:-} != --with-nx2apple ]]; then exit 0; fi
repo="$PWD/.tools/nx2apple"
venv="$PWD/.tools/nx2apple-venv"
pin=f8a69d9226f6d12ebdb9c350aeb52b7444efcb54
if [[ ! -e "$repo" ]]; then
  mkdir -p "$PWD/.tools"
  staging=$(mktemp -d "$PWD/.tools/.nx2apple.XXXXXXXX")
  trap 'rm -rf -- "$staging"' EXIT
  git -C "$staging" init -q
  git -C "$staging" remote add origin https://github.com/LNPANDY/NX2Apple.git
  git -C "$staging" fetch --depth=1 origin "$pin"
  git -C "$staging" checkout --detach FETCH_HEAD
  mv "$staging" "$repo"
fi
if [[ $(git -C "$repo" rev-parse HEAD) != "$pin" ]]; then
  print -u2 "The existing NX2Apple checkout uses a different revision. It was left in place."
  exit 1
fi
if [[ ! -x "$venv/bin/python" ]]; then "$python" -m venv "$venv"; fi
"$venv/bin/python" -m pip install lz4==4.4.5 capstone==5.0.9 fonttools==4.68.0 zbic==1.0.1.post1 nsz==5.0.0 \
  'backports.zstd==1.8.0; python_version < "3.14"'
"$venv/bin/python" "$repo/tools/engine.py" sync
print "NX2Apple is ready at $repo"
