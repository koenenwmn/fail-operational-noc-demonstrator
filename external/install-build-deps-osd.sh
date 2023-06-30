#!/bin/bash
#
# Install development build dependencies for different Linux distributions
#

[ -f /etc/os-release ] || (echo "/etc/os-release doesn't exist."; exit 1)
. /etc/os-release

SUDO_CMD=""
if [ $(id -u) -ne 0 ]; then
  SUDO_CMD="sudo "
fi

case "$ID" in
  ubuntu)
    # Ubuntu seems to have a rather strange and inconsistent naming for the
    # ZeroMQ packages ...
    PKGLIST="check doxygen python3 python3-venv python3-pip tox \
      lcov valgrind libzmq5 libzmq3-dev libczmq-dev \
      xsltproc libelf1 libelf-dev zlib1g zlib1g-dev"
    $SUDO_CMD apt-get -y install $PKGLIST
    ;;

  *)
    echo Unknown distribution. Please extend this script!
    exit 1
    ;;
esac

