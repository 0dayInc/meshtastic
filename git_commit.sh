#!/bin/bash --login
if [[ $1 != "" && $2 != "" && $3 != "" ]]; then
  # Default Strategy is to merge codebase
  git config pull.rebase false
  git config commit.gpgsign true
  git pull origin master
  git add . --all
  echo 'Updating Gems to Latest Versions in Gemfile...'
  ./upgrade_Gemfile_gems.sh
  ./AUTOGEN_meshtastic_protobufs.sh
  meshtastic_autoinc_version
  if [[ $tag_this_version_bool == 'true' ]]; then
    last_tag=$(git tag | tail -n 1)
    git log $last_tag.. --oneline > CHANGELOG_BETWEEN_TAGS.txt
  fi

  git commit -a -S --author="${1} <${2}>" -m "${3}"
  ./upgrade_meshtastic.sh
  # Tag for every 100 commits (i.e. 0.1.100, 0.1.200, etc)
  tag_this_version_bool=`ruby -r 'meshtastic' -e 'if Meshtastic::VERSION.split(".")[-1].to_i % 100 == 0; then print true; else print false; end'`
  if [[ $tag_this_version_bool == 'true' ]]; then
    this_version=`ruby -r 'meshtastic' -e 'print Meshtastic::VERSION'`
    echo "Tagging: ${this_version}"
    git tag $this_version
    git push origin $this_version
  fi
else
  echo "USAGE: ${0} '<full name>' <email address> '<git commit comments>'"
fi
