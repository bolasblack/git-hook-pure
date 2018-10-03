#!/bin/bash

hookNames=`cat <<EOF
applypatch-msg
commit-msg
post-applypatch
post-checkout
post-commit
post-merge
post-receive
post-rewrite
post-update
pre-applypatch
pre-auto-gc
pre-commit
pre-push
pre-rebase
pre-receive
prepare-commit-msg
push-to-checkout
sendemail-validate
update
EOF`

templateBannerStart="git-hook-pure start"

templateBannerEnd="git-hook-pure end"

gitFullPath=`git rev-parse --show-toplevel`

function cleanCode() {
  local hookFullPath=$1
  sed -i -Ee ":a;\$!{N;ba};s/(\s*\n|^)# =+ $templateBannerStart =+\n.*\n# =+ $templateBannerEnd =+\s*//g" "$hookFullPath"
}

function hasHashbang() {
  echo "$1" | head -n1 | grep -m1 -qe "^#!"
}
