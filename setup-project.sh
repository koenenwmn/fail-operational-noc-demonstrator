#!/bin/bash
#
# Setup the Fail-Operational NoC for Mixed-Critical MPSoC Demonstrator Project
#
# This script initially sets up the project directory. If called again with -f,
# it resets the project directory to its default state. It deletes the
# directories 'build' and 'external' and afterwards sets up the project as if
# for the first time.
# Calling the script with -u will skip dependencies that require sudo rights.
#

usage()
{
    echo "usage: setup-project.sh [[[-f] [-u]] | [-h]]"
}

PROJ_DIR="`pwd`"

force=0

# Read parameters
while [ "$1" != "" ]; do
    case $1 in
        -f | --force )			force=1
                                ;;
        -h | --help )           usage
                                exit
                                ;;
        * )                     usage
                                exit 1
    esac
    shift
done

# Stop here if 'load_deps.sh' exists and rebuild is not forced
if [ -f "load_deps.sh" ] && [ $force -ne 1 ]; then
	echo "Project has already been set up. Use '-f' to force a rebuild (will delete external/ and venv/ dirs)."
	exit
fi

# Install git
sudo apt-get install -y git

# Remove 'external', and 'venv'
rm -rf external/optimsoc*
rm -rf venv/

# Install old python version
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get update
sudo apt-get install -y python3.7 python3.7-venv python3.7-dev
python3.7 -m ensurepip --upgrade
sudo apt-get install -y python3.7-tk
echo '#python3.7 installed'

# Just in case, unset $OPTIMSOC variable
unset OPTIMSOC
echo '#OPTIMSOC unset'

# Prepare OpTiMSoC (latest version)
mkdir -p external/optimsoc
git clone https://github.com/optimsoc/optimsoc.git external/optimsoc-src
echo '#OPTIMSOC cloned'

# Build dependencies
INSTALL_DOC_DEPS=no external/install-build-deps-optimsoc.sh
echo '#build deps installed'
pip3 install --upgrade --user pip && pip3 install --upgrade --user pytest fusesoc==1.9.3
python3 -m pip install --user pipenv
echo '#build deps and fusesoc installed'

# OpTiMSoC Prebuilts (Verilator and or1k toolchain)
curl -sL https://raw.githubusercontent.com/optimsoc/prebuilts/master/optimsoc-prebuilt-deploy.py | python3 - -d $PROJ_DIR/external/optimsoc all
source external/optimsoc/setup_prebuilt.sh
echo '#prebuilts installed'

# Build and install OpTiMSoC to external/optimsoc/
external/optimsoc-src/tools/build.py --without-examples-fpga --without-examples-sim --without-docs --link-hw
make -C external/optimsoc-src install INSTALL_TARGET=$PROJ_DIR/external/optimsoc/framework
source $PROJ_DIR/external/optimsoc/framework/optimsoc-environment.sh
echo '#OPTIMSOC installed'

# Prepare virtual environment for Python osd API
python3.7 -m venv venv
echo '#venv created'
venv/bin/python3 -m ensurepip --upgrade
echo '#ensurepip returned'
venv/bin/pip3 install wheel
echo '#wheel installed'
venv/bin/pip3 install external/optimsoc-src/objdir/dist/host/share/python3-pkgs/opensocdebug-0.tar.gz
echo '#osd installed'
venv/bin/pip3 install -r requirements.txt
echo '#other stuff installed'

# Create script to load the OpTiMSoC environment
echo '#!/bin/bash' > load_deps.sh
echo '# Simple script to load the OpTiMSoC environment' >> load_deps.sh
echo 'source '$PROJ_DIR'/external/optimsoc/setup_prebuilt.sh' >> load_deps.sh
echo 'source '$PROJ_DIR'/external/optimsoc/framework/optimsoc-environment.sh' >> load_deps.sh
echo 'export DEMONSTRATOR_DIR='$PROJ_DIR >> load_deps.sh

echo 'export PATH=~/.local/bin:$PATH' >> load_deps.sh

echo '#finished'

