#!/bin/sh
projectRoot=`git rev-parse --show-toplevel`
hookName=`basename "$0"`
gitParams="$*"

function executeAllFiles() {
  local hookFolderPath=$1
  for f in `ls -1 $hookFolderPath`; do
    if  [ ! -d $hookFolderPath/$f ]; then
      if [ -x $hookFolderPath/$f ]; then
        $hookFolderPath/$f "${@:2}" || exit 1
      else
        echo "==============================================="
        echo "WARNING: File $hookFolderPath/$f not executable"
        echo "==============================================="
      fi
    fi
  done
}

hookFolderPath=$projectRoot/.githooks
if [ -d $hookFolderPath ]; then
  executeAllFiles $hookFolderPath $hookName "$@"
fi
if [ -d $hookFolderPath/$hookName ]; then
  executeAllFiles $hookFolderPath/$hookName "$@"
fi
