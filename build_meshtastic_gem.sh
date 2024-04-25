#!/bin/bash --login
if [[ $MESHTASTIC_ROOT == '' ]]; then
  if [[ ! -d '/opt/meshtastic' ]]; then
    mesh_root=$(pwd)
  else
    mesh_root='/opt/meshtastic'
  fi
else
  mesh_root="${MESHTASTIC_ROOT}"
fi

ls pkg/*.gem 2> /dev/null | while read previous_gems; do 
  rvmsudo rm $previous_gems
done
old_ruby_version=`cat ${mesh_root}/.ruby-version`
# Default Strategy is to merge codebase
# rvmsudo git config pull.rebase false 
# rvmsudo git pull origin master
git config pull.rebase false 
git pull origin master
new_ruby_version=`cat ${mesh_root}/.ruby-version`

rvm list gemsets | grep `cat ${mesh_root}/.ruby-gemset`
if [[ $? != 0 ]]; then
  echo "Ruby v${new_ruby_version} is not installed.  Installing..."
  cd $mesh_root && ./upgrade_ruby.sh $new_ruby_version
  # Rely on RVM to creeate gemset
  cd / && cd $mesh_root
fi

if [[ $old_ruby_version == $new_ruby_version ]]; then
  export rvmsudo_secure_path=1
  rvmsudo /bin/bash --login -c "cd ${mesh_root} && ./reinstall_meshtastic_gemset.sh"
  rvmsudo rake
  rvmsudo rake install
  rvmsudo rake rerdoc
  rvmsudo gem update --system
  rvmsudo gem rdoc --rdoc --ri --overwrite -V meshtastic
  echo "Invoking bundle-audit Gemfile Scanner..."
  rvmsudo bundle-audit

  latest_gem=$(ls pkg/*.gem)
  if [[ $latest_gem != "" ]]; then
    echo "Pushing ${latest_gem} to RubyGems.org..."
    rvmsudo gem push $latest_gem --debug
  fi
else
  cd $mesh_root && ./upgrade_ruby.sh $new_ruby_version $old_ruby_version
fi

unpriv_user=`echo $USER`
if [[ $unpriv_user != 'root' ]]; then
  if [[ $(uname -s) == 'Darwin' ]]; then
    rvmsudo chown -R $unpriv_user $mesh_root
  else
    rvmsudo chown -R $unpriv_user:$unpriv_user $mesh_root
  fi
fi
