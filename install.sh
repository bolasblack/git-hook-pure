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

# check $0 is absolute path
if [ ${0::1} = "/" ]; then
  selfFullPath=$0
else
  selfFullPath=$PWD/$0
fi

templateFullPath=${selfFullPath%/*}/git-hook-template.sh

gitFullPath=`git rev-parse --show-toplevel`

for hn in $hookNames; do
  cp $templateFullPath $gitFullPath/.git/hooks/$hn
  chmod u+x $gitFullPath/.git/hooks/$hn
done

if [ ! -e $gitFullPath/.githooks ]; then
  mkdir $gitFullPath/.githooks
  touch $gitFullPath/.githooks/.gitkeep
else
  if [ ! -d $gitFullPath/.githooks ]; then
    echo "[git-hook-pure] WARNING: $gitFullPath/.githooks existed but not a directory!"
    exit
  fi
fi

echo "[git-hook-pure] installed"
