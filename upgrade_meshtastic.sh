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

export rvmsudo_secure_path=1
rvmsudo /bin/bash --login -c "cd ${mesh_root} && ./build_meshtastic_gem.sh"
