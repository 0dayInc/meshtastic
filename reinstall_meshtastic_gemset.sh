#!/bin/bash --login
# USE THIS SCRIPT WHEN UPGRADING VERSIONS IN Gemfile
if [[ $MESHTASTIC_ROOT == '' ]]; then
  if [[ ! -d '/opt/meshtastic' ]]; then
    mesh_root=$(pwd)
  else
    mesh_root='/opt/meshtastic'
  fi
else
  mesh_root="${MESHTASTIC_ROOT}"
fi

if [[ -f '/etc/profile.d/rvm.sh' ]]; then
  source /etc/profile.d/rvm.sh
fi

ruby_version=`cat ${mesh_root}/.ruby-version`
ruby_gemset=`cat ${mesh_root}/.ruby-gemset`
rvm use ruby-$ruby_version@global
rvm gemset --force delete $ruby_gemset
if [[ -f "${mesh_root}/Gemfile.lock" ]]; then
  rvmsudo rm $mesh_root/Gemfile.lock
fi

rvm use ruby-$ruby_version@$ruby_gemset --create
export rvmsudo_secure_path=1
rvmsudo gem install bundler
rvmsudo bundle install
rvm --default ruby-$ruby_version@$ruby_gemset
