#!/bin/bash --login
cat Gemfile | awk '{print $2}' | grep -E "^'.+$" | grep -v -e rubygems.org | while read gem; do 
  this_gem=`echo $gem | sed "s/'//g" | sed 's/\,//g'`
  latest_version=`gem search -r $this_gem | grep -E "^${this_gem}\s.+$" | awk '{print $2}' | sed 's/(//g' | sed 's/)//g' | sed 's/,//g'`
  echo "${this_gem} => $latest_version"
  os=`uname -s`
  if [[ $os == 'Linux' ]]; then
    case $this_gem in
      'bundler'|'rubocop'|'rubocop-rake'|'rubocop-rspec')
	sed -i "s/^gem '${this_gem}'.*$/gem '${this_gem}', '>=${latest_version}'/g" Gemfile;;
      'google-protobuf')
        same_version=`protoc --version | awk '{ print $NF}'`
	sed -i "s/^gem '${this_gem}'.*$/gem '${this_gem}', '${same_version}'/g" Gemfile;;
      *)
	sed -i "s/^gem '${this_gem}'.*$/gem '${this_gem}', '${latest_version}'/g" Gemfile;;
    esac
  elif [[ $os == 'Darwin' ]]; then
    if [[ $this_gem == 'bundler' ]]; then
      sed -i '' "s/^gem '${this_gem}'.*$/gem '${this_gem}', '>=${latest_version}'/g" Gemfile
    else
      sed -i '' "s/^gem '${this_gem}'.*$/gem '${this_gem}', '${latest_version}'/g" Gemfile
    fi
  fi
done
