#!/bin/bash

# check $0 is absolute path
if [ ${0::1} = "/" ]; then
  selfFullPath="$0"
else
  selfFullPath="$PWD/$0"
fi

source $(dirname $selfFullPath)/helpers.sh

defualtTemplateContent=`cat ${selfFullPath%/*}/git-hook-template.sh`
if [ $# -lt 1 ]; then
  templateContent=`echo "$defualtTemplateContent" | tail -n+3`
  hashbangMatcher='\(bash\|zsh\|sh\)$'
  templateContentHashbang=`echo "$defualtTemplateContent" | head -n1`
else
  templateContent=`cat $1`
  if hasHashbang $templateContent; then
    hashbangMatcher=`echo "$templateContent" | head -n1`
    templateContentHashbang=$hashbangMatcher
    templateContent=`echo "$templateContent" | tail -n+2`
  fi
fi

function installCode() {
  local hookFullPath=$1
  local insertContent=`cat <<EOF

# ================== $templateBannerStart ==================
$templateContent
# ================== $templateBannerEnd ==================
EOF`

  if [ ! -e "$hookFullPath" ]; then
    mkdir -p `dirname $hookFullPath`
    echo -e "$templateContentHashbang\n$insertContent" > "$hookFullPath"
    chmod u+x "$hookFullPath"
    return
  fi

  if [ -z "`cat $hookFullPath | tr -d '[[:space:]]'`" ]; then
    echo -e "$templateContentHashbang\n$insertContent" > "$hookFullPath"
    return
  fi

  if ! cat "$hookFullPath" | head -n1 | grep -m1 -qe "$hashbangMatcher"; then
    echo "[git-hook-pure] WARNING: $hookFullPath install failed: hash bang not match $hashbangMatcher."
    return
  fi

  cleanCode $hookFullPath
  echo -e "$insertContent" >> "$hookFullPath"
}

for hn in $hookNames; do
  installCode "$gitFullPath"/.git/hooks/$hn
done
if [ ! -e "$gitFullPath"/.githooks ]; then
  mkdir "$gitFullPath"/.githooks
  touch "$gitFullPath"/.githooks/.gitkeep
else
  if [ ! -d "$gitFullPath"/.githooks ]; then
    echo "[git-hook-pure] WARNING: $gitFullPath/.githooks existed but not a directory!"
    exit
  fi
fi

echo "[git-hook-pure] installed"
