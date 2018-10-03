#!/bin/bash

# check $0 is absolute path
if [ ${0::1} = "/" ]; then
  selfFullPath="$0"
else
  selfFullPath="$PWD/$0"
fi

source $(dirname $selfFullPath)/helpers.sh

for hn in $hookNames; do
  cleanCode "$gitFullPath"/.git/hooks/$hn
done

echo "[git-hook-pure] uninstalled"
