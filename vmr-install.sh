#!/bin/bash

URL=""
USERNAME=admin
PASSWORD=admin
LOG_FILE=install.log
SWAP_FILE=swap
SOLACE_HOME=`pwd`

while [[ $# -gt 1 ]]
do
  key="$1"
  case $key in
      -i|--url)
        URL="$2"
        shift # past argument
      ;;
      -l|--logfile)
        LOG_FILE="$2"
        shift # past argument
      ;;
      -p|--password)
        PASSWORD="$2"
        shift # past argument
      ;;
      -u|--username)
        USERNAME="$2"
        shift # past argument
      ;;
      *)
            # unknown option
      ;;
  esac
  shift # past argument or value
done

echo "`date` INFO: Validate we have been passed a VMR url" &>> ${LOG_FILE}
# -----------------------------------------------------
if [ -z "$URL" ]
then
      echo "USAGE: vmr-install.sh --url <Solace Docker URL>" &>> ${LOG_FILE}
      exit 1
else
      echo "`date` INFO: VMR URL is ${URL}" &>> ${LOG_FILE}
fi


echo "`date` INFO:Get repositories up to date" &>> ${LOG_FILE}
# ---------------------------------------

yum -y update &>> ${LOG_FILE}
yum -y install lvm2 &>> ${LOG_FILE}

echo "`date` INFO:Set up Docker Repository" &>> ${LOG_FILE}
# -----------------------------------
tee /etc/yum.repos.d/docker.repo <<-EOF
[dockerrepo]
name=Docker Repository
baseurl=https://yum.dockerproject.org/repo/main/centos/7/
enabled=1
gpgcheck=1
gpgkey=https://yum.dockerproject.org/gpg
EOF
echo "`date` INFO:/etc/yum.repos.d/docker.repo =\n `cat /etc/yum.repos.d/docker.repo`"  &>> ${LOG_FILE}

echo "`date` INFO:Intall Docker" &>> ${LOG_FILE}
# -------------------------
yum -y install docker-engine &>> ${LOG_FILE}

echo "`date` INFO:Configure Docker as a service" &>> ${LOG_FILE}
# ----------------------------------------
mkdir /etc/systemd/system/docker.service.d &>> install.log
tee /etc/systemd/system/docker.service.d/docker.conf <<-EOF 
[Service] 
  ExecStart= 
  ExecStart=/usr/bin/dockerd --iptables=false --storage-driver=devicemapper 
EOF
echo "`date` INFO:/etc/systemd/system/docker.service.d =\n `cat /etc/systemd/system/docker.service.d`" &>> ${LOG_FILE}

systemctl enable docker &>> ${LOG_FILE}
systemctl start docker &>> ${LOG_FILE}

echo "`date` INFO:Set up swap for < 6GB machines" &>> ${LOG_FILE}
# -----------------------------------------
MEM_SIZE=`cat /proc/meminfo | grep MemTotal | tr -dc '0-9'` &>> ${LOG_FILE}
if [ ${MEM_SIZE} -lt 6087960 ]; then
  echo "`date` WARN: Not enough memory: ${MEM_SIZE} Creating 2GB Swap space" &>> ${LOG_FILE}
  mkdir /var/lib/solace &>> ${LOG_FILE}
  dd if=/dev/zero of=/var/lib/solace/swap count=2048 bs=1MiB &>> ${LOG_FILE}
  mkswap -f /var/lib/solace/swap &>> ${LOG_FILE}
  chmod 0600 /var/lib/solace/swap &>> ${LOG_FILE}
  swapon -f /var/lib/solace/swap &>> ${LOG_FILE}
  grep -q 'solace\/swap' /etc/fstab || sudo sh -c 'echo "/var/lib/solace/swap none swap sw 0 0" >> /etc/fstab' &>> ${LOG_FILE}
else
   echo "`date` INFO: Memory size is ${MEM_SIZE}" &>> ${LOG_FILE}
fi


echo "`date` INFO:Get and load the Solace Docker url" &>> ${LOG_FILE}
# ------------------------------------------------
wget -O /tmp/redirect.html -nv -a ${LOG_FILE} ${URL}
REAL_HTML=`egrep -o "https://[a-zA-Z0-9\.\/\_\?\=]*" /tmp/redirect.html`

LOOP_COUNT=0
while [ $LOOP_COUNT -lt 3 ]; do
  wget -O /tmp/soltr-docker.tar.gz -nv -a ${LOG_FILE} ${REAL_HTML}
  if [ 0 != `echo $?` ]; then 
    ((LOOP_COUNT++))
  else
    break
  fi
done
if [ ${LOOP_COUNT} == 3 ]; then
  echo "`date` ERROR: Failed to download VMR Docker image exiting"
  exit 1
fi

docker load -i /tmp/soltr-docker.tar.gz &>> ${LOG_FILE}
docker images &>> ${LOG_FILE}


echo "`date` INFO:Create a Docker instance from Solace Docker image" &>> ${LOG_FILE}
# -------------------------------------------------------------
VMR_VERSION=`docker images | grep solace | awk '{print $2}'`

docker create \
   --uts=host \
   --shm-size 2g \
   --ulimit core=-1 \
   --ulimit memlock=-1 \
   --ulimit nofile=2448:38048 \
   --cap-add=IPC_LOCK \
   --cap-add=SYS_NICE \
   --net=host \
   --restart=always \
   --env "username_admin_globalaccesslevel=${USERNAME}" \
   --env "username_admin_password=${PASSWORD}" \
   --env "SERVICE_SSH_PORT=2222" \
   --name=solace solace-app:${VMR_VERSION} &>> ${LOG_FILE}

docker ps -a &>> ${LOG_FILE}

echo "`date` INFO:Construct systemd for VMR" &>> ${LOG_FILE}
# --------------------------------------
tee /etc/systemd/system/solace-docker-vmr.service <<-EOF
[Unit]
  Description=solace-docker-vmr
  Requires=docker.service
  After=docker.service
[Service]
  Restart=always
  ExecStart=/usr/bin/docker start -a solace
  ExecStop=/usr/bin/docker stop solace
[Install]
  WantedBy=default.target
EOF
echo "`date` INFO:/etc/systemd/system/solace-docker-vmr.service =/n `cat /etc/systemd/system/solace-docker-vmr.service`" &>> ${LOG_FILE} 

echo "`date` INFO: Start the VMR"
# --------------------------
systemctl daemon-reload &>> ${LOG_FILE}
systemctl enable solace-docker-vmr &>> ${LOG_FILE}
systemctl start solace-docker-vmr &>> ${LOG_FILE}
