Note these instructions are currently a mashup between ubuntu 24.04 and AlmaLinux 10.

sudo dnf install glibc-devel # FOR ALMALINUX 10

wget https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest_all.deb
sudo dpkg -i cvmfs-release-latest_all.deb
rm -f cvmfs-release-latest_all.deb

# 2. Update package index and install CVMFS
sudo apt-get update
sudo apt-get install -y cvmfs

sudo cvmfs_config setup


sudo nano /etc/cvmfs/default.local
CVMFS_REPOSITORIES=dunedaq.opensciencegrid.org,dunedaq-development.opensciencegrid.org
CVMFS_CLIENT_PROFILE=single


# 5. Test installation
cvmfs_config probe

# Try accessing DUNE DAQ repositories (this will mount them)
ls /cvmfs/dunedaq.opensciencegrid.org/

# Try the development repository too
ls /cvmfs/dunedaq-development.opensciencegrid.org/

# Now check what's mounted
ls /cvmfs/

source /cvmfs/dunedaq.opensciencegrid.org/setup_dunedaq.sh
setup_dbt latest 
dbt-create -n last_fddaq InitialDAQ                     
cd InitialDAQ
dbt-build (might need to be after . env.sh)
. env.sh

clone in drunc and drunc schema

pip install -e .[develop] for drunk

NOTE:
you can't build anything custom with dbt-build, you have to have no repos in your sourcecode.
you need to run dbt-build in order to run boot on unified shell


SETTING UP ON HEP CLUSTER
scp drunc_dev_latest_nightly.sh akarimi1@lx04.hep.ph.ic.ac.uk: