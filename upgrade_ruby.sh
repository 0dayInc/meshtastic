#!/bin/bash --login
# USE THIS SCRIPT WHEN UPGRADING RUBY
if [[ $MESHTASTIC_ROOT == '' ]]; then
  if [[ ! -d '/opt/meshtastic' ]]; then
    meshtastic_root=$(pwd)
  else
    meshtastic_root='/opt/meshtastic'
  fi
else
  meshtastic_root="${MESHTASTIC_ROOT}"
fi

function usage() {
  echo $"Usage: $0 <new ruby version e.g. 2.4.4> <optional bool running from build_gem.sh>"
  exit 1
}

if [[ -f '/etc/profile.d/rvm.sh' ]]; then
  source /etc/profile.d/rvm.sh
fi

new_ruby_version=$1
if [[ $2 != '' ]]; then
  old_ruby_version=$2
else
  old_ruby_version=`cat ${meshtastic_root}/.ruby-version`
fi

ruby_gemset=`cat ${meshtastic_root}/.ruby-gemset`

if [[ $# < 1 ]]; then
  usage
fi

# Upgrade RVM
export rvmsudo_secure_path=1
rvmsudo rvm get head
rvm reload

# Install New Version of RubyGems & Ruby
cd $meshtastic_root && ./upgrade_gem.sh
rvmsudo rvm install ruby-$new_ruby_version
echo $new_ruby_version > $meshtastic_root/.ruby-version

cd $meshtastic_root && rvm use $new_ruby_version@$ruby_gemset && ./build_gem.sh
