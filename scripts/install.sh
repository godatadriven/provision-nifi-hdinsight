#!/bin/bash
INIT_FOLDER=`pwd`
NIFI_VERSION=nifi-1.1.2
NGINX_CONF="https://raw.githubusercontent.com/godatadriven/provision-nifi-hdinsight/master/scripts/nifi_nginx.conf"
NIFI_HOME="/opt/nifi"
HADOOP_CORE_CONF="/etc/hadoop/conf/core-site.xml"

SHARE=$1
MOUNT=$SHARE
ENDPOINT=$2

getPassword() {
    KEY=`grep -A1 "fs\.azure\.account\.key\." $HADOOP_CORE_CONF | grep "<value>" | sed 's/ *//;s/<[^>]*>//g'`
    export PASSWORD=`/usr/lib/hdinsight-common/scripts/decrypt.sh $KEY`
}

getStorage() {
    PROVIDER="fs\.azure\.account\.keyprovider"
    export STORAGE=`grep $PROVIDER $HADOOP_CORE_CONF | sed "s/.*$PROVIDER\.\([a-z0-9]*\).*/\1/"`
}

mountExternalStorage() {
    usage() {
        echo "Invoke with mountExternalStorage account sharename password mountpoint"

    }
    if [ -z "$1" ]; then
            echo "Need storage account name to run"
            exit 136
            usage
    fi
    if [ -z "$2" ]; then
            echo "Need storage sharename to run"
            exit 137
            usage
    fi
    if [ -z "$3" ]; then
            echo "Need storage password to run"
            exit 138
            usage
    fi
    ACCOUNT=$1
    SHARE=$2
    PASSWORD=$3
    MOUNT=$SHARE
    sudo mount -t cifs //$ACCOUNT.file.core.windows.net/$SHARE /mnt/$MOUNT -o vers=3.0,username=$ACCOUNT,password=$PASSWORD,dir_mode=0777,file_mode=0777,serverino
}


rewriteNginxConfig() {
    curl $NGINX_CONF | sed "s/ENDPOINT/$1" | sudo tee /etc/nginx/nginx.conf > /dev/null
    sudo service nginx reload || sudo service nginx start
}

installJava() {
    sudo add-apt-repository -y ppa:openjdk-r/ppa
    sudo apt-get update
    sudo apt-get install -y --allow-unauthenticated openjdk-8-jdk
}

createUser() {
    sudo adduser --disabled-password --home $1 --gecos "" $2
}

createWasbConf() {
    TARGET=/mnt/$MOUNT/wasb-site.xml
    if [ ! -f $TARGET ]; then
    sudo echo "
<configuration>
  <property>
    <name>fs.wasb.impl</name>
    <value>org.apache.hadoop.fs.azure.NativeAzureFileSystem</value>
  </property>
</configuration>
    " > $TARGET
    fi
}

createFolder() {
    if [ ! -d $1 ]; then
        sudo mkdir -p $1
    fi
}

createNiFiFolders() {
    NIFI_MOUNT=/mnt/$1
    CONFIGURATION=$NIFI_MOUNT/configuration
    createFolder $CONFIGURATION
    createFolder $CONFIGURATION/custom_lib
    REPOSITORIES=$NIFI_MOUNT/repositories
    createFolder $REPOSITORIES
    createFolder $REPOSITORIES/database_repository
    createFolder $REPOSITORIES/flowfile_repository
    createFolder $REPOSITORIES/content_repository
    createFolder $REPOSITORIES/provenance_repository
}

installNiFi() {
    MOUNT=$1
    createNiFiFolders $MOUNT
    sudo -n -u nifi bash <<-EOS
    if [ ! -d ~/$NIFI_VERSION ]; then
        cd $NIFI_HOME
        wget https://github.com/gglanzani/nifi/releases/download/rel%2F1.1.2-hadoop-2.8/$NIFI_VERSION-bin.zip
        unzip $NIFI_VERSION-bin.zip &> /dev/null
        rm $NIFI_VERSION-bin.zip
        export NIFI_PROPERTIES="$NIFI_HOME/$NIFI_VERSION/conf/nifi.properties"
        echo -e "\nexport JAVA_HOME=\"/usr/lib/jvm/java-8-openjdk-amd64/\"" >> $NIFI_HOME/$NIFI_VERSION/bin/nifi-env.sh
        echo -e "\nnifi.nar.library.directory.custom=/mnt/$MOUNT/configuration/custom_lib" >> $NIFI_HOME/$NIFI_VERSION/conf/nifi.properties
        sed -i "s/\(nifi\.flow\.configuration\.file=\).*/\1\/mnt\/$MOUNT\/configuration\/flow\.xml\.gz/" $NIFI_PROPERTIES
        sed -i "s/\(nifi\.flow\.configuration\.archive\.dir=\).*/\1\/mnt\/$MOUNT\/configuration\/archive/" $NIFI_PROPERTIES
        sed -i "s/\(nifi\.database\.directory=\).*/\1\/mnt\/$MOUNT\/repositories\/database_repository/" $NIFI_PROPERTIES
        sed -i "s/\(nifi\.flowfile\.repository\.directory=\).*/\1\/mnt\/$MOUNT\/repositories\/flowfile_repository/" $NIFI_PROPERTIES
        sed -i "s/\(nifi\.content\.repository\.directory.default=\).*/\1\/mnt\/$MOUNT\/repositories\/content_repository/" $NIFI_PROPERTIES
        sed -i "s/\(nifi\.provenance\.repository\.directory.default=\).*/\1\/mnt\/$MOUNT\/repositories\/provenance_repository/" $NIFI_PROPERTIES
    fi
    $NIFI_HOME/$NIFI_VERSION/bin/nifi.sh start
EOS
}


getStorage
getPassword
createFolder /mnt/$MOUNT
mountExternalStorage $STORAGE $SHARE $PASSWORD
rewriteNginxConfig $ENDPOINT
installJava
createUser $NIFI_HOME "nifi"
createWasbConf
installNiFi $SHARE
