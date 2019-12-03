#!/bin/bash
set -e

# Setup repository file in /etc/yum.repos.d
#
## Parameters:
# List of repos to enable
function add_repos() {
    local REPO=""
    for REPO in $@; do
        case "${REPO}" in
            EPEL)
                rpm --import https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7
                cat >/etc/yum.repos.d/epel.repo <<EOF
[epel]
name=Extra Packages for Enterprise Linux 7 - $basearch
#baseurl=http://download.fedoraproject.org/pub/epel/7/$basearch
mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=epel-7&arch=\$basearch
failovermethod=priorityenabled=1
# Django : 2014-08-14
# default: gpgcheck=0
gpgcheck=1
# default: unsetpriority = 10
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7
EOF
                ;;
            docker)
                rpm --import https://download.docker.com/linux/centos/gpg
                cat >/etc/yum.repos.d/docker.repo <<EOF
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/centos/7/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
EOF
                ;;
            nodejs)
                yum -y install https://rpm.nodesource.com/pub_8.x/el/7/x86_64/nodesource-release-el7-1.noarch.rpm
                ;;
        esac
    done
}

# Generic software installation routine
#
## Parameters:
#    List of packages to install

function install_software() {
    sed -e 's/enabled=.*/enabled=0/' -i /etc/yum/pluginconf.d/fastestmirror.conf
    yum -y clean all
    yum -y --disableplugin=fastestmirror update
    yum -y --disableplugin=fastestmirror install $@
}

function install_java8() {
    cd /tmp/
    curl -jkLsS -H "Cookie: oraclelicense=accept-securebackup-cookie" \
         "http://download.oracle.com/otn-pub/java/jdk/${JAVA_VERSION}-${JAVA_BUILD_NUMBER}/${JAVA_DL_PATH}jdk-${JAVA_VERSION}-linux-x64.rpm" \
         -o /tmp/jdk.rpm
    curl -jkLsS -H "Cookie: oraclelicense=accept-securebackup-cookie" \
         http://download.oracle.com/otn-pub/java/jce/8/jce_policy-8.zip \
         -o /tmp/jce_policy-8.zip
    if [ -n "${JAVA_CHECKSUM}" ]; then
        echo "${JAVA_CHECKSUM}  /tmp/jdk.rpm" >/tmp/jdk.rpm.sha256sum
        if [ -n "${JCE_CHECKSUM}" ]; then
            echo "${JCE_CHECKSUM}  /tmp/jce_policy-8.zip" >>/tmp/jdk.rpm.sha256sum
        fi
        sha256sum -c /tmp/jdk.rpm.sha256sum
    fi
    yum -y install /tmp/jdk.rpm
    cd ${JAVA_HOME}/jre/lib/security
    unzip /tmp/jce_policy-8.zip
}

function install_java10() {
    cd /tmp/
    curl -jkLsS -H "Cookie: oraclelicense=accept-securebackup-cookie" \
         "http://download.oracle.com/otn-pub/java/jdk/${JAVA_VERSION}+${JAVA_BUILD_NUMBER}/${JAVA_DL_PATH}/jdk-${JAVA_VERSION}_linux-x64_bin.rpm" \
         -o /tmp/jdk.rpm
    if [ -n "${JAVA_CHECKSUM}" ]; then
        echo "${JAVA_CHECKSUM}  /tmp/jdk.rpm" >/tmp/jdk.rpm.sha256sum
        sha256sum -c /tmp/jdk.rpm.sha256sum
    fi
    yum -y install /tmp/jdk.rpm
}
function get_gosu() {
    curl -sSL https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64 -o /usr/local/bin/gosu
    local GPG=$(type -p gpg)
    if [ -n "${GPG}" ]; then
        curl -sSL https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64.asc -o /tmp/gosu.asc
        ${GPG} --keyserver keys.gnupg.net --recv-keys '0x036a9c25bf357dd4'
        ${GPG} --verify /tmp/gosu.asc /usr/local/bin/gosu
    fi
    chmod a+x /usr/local/bin/gosu
}

function create_user_and_group() {
    set +e
    grep "${APP_GROUP}:x:${APP_GID}:" /etc/group &>/dev/null
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        groupadd -g ${APP_GID} ${APP_GROUP}
    fi
    grep "${APP_USER}:x:${APP_UID}:" /etc/passwd &>/dev/null
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        useradd -c "Application user" -d ${APP_HOME} -g ${APP_GROUP} -m -s /bin/bash -u ${APP_UID} ${APP_USER}
    fi
    set -e
    if [ ! -d ${APP_HOME} ]; then
        mkdir -p ${APP_HOME}
    fi
    chown -R ${APP_USER}:${APP_GROUP} ${APP_HOME}
}

function cleanup() {
    if [ $# -ne 0 ]; then
        yum -y erase $@
    fi
    yum -y autoremove
    yum clean all
    set +e
    /bin/rm -rf /var/cache/yum/*
    /bin/rm /tmp/*
    chmod 777 /tmp
}

function set_yum_proxy() {
    if [ -n "${https_proxy}" ]; then
        local PROXY="${https_proxy}"
    else
        if [ -n "${http_proxy}" ]; then
            local PROXY="${http_proxy}"
        fi
    fi
    set +e
    if [ -n "${proxy}" ]; then
        grep -e "^proxy=" /etc/yum.conf &>/dev/null
        if [ $? -eq 0 ]; then
            sed -e "s/^proxy=.*$/proxy=${proxy}" -i /etc/yum.conf
        else
            echo "proxy=${proxy}" >>/etc/yum.conf
        fi
    fi
    if [ -n "${proxy_user}" ]; then
        grep -e "^proxy_username=" /etc/yum.conf &>/dev/null
        if [ $? -eq 0 ]; then
            sed -e "s/^proxy_username=.*$/proxy_username=${proxy__username}" -i /etc/yum.conf
        else
            echo "proxy_username=${proxy_username}" >>/etc/yum.conf
        fi
    fi
    if [ -n "${proxy_password}" ]; then
        grep -e "^proxy_password=" /etc/yum.conf &>/dev/null
        if [ $? -eq 0 ]; then
            sed -e "s/^proxy_password=.*$/proxy_password=${proxy_password}" -i /etc/yum.conf
        else
            echo "proxy_password=${proxy_password}" >>/etc/yum.conf
        fi
    fi
    set -e
}


# Patch Dockerfile
function patch_dockerfile() {
    local DF=${1}
    if [ -z "${DF}" ]; then
        DF="Dockerfile"
    fi
    if [ -z "${PARENT_HISTORY}" ]; then
        local FROM=$(grep "FROM" ${DF}|sed -e 's/FROM\s*//')
        docker pull ${FROM}
        local PARENTENV=$(docker run --rm --entrypoint=/bin/bash ${FROM} -c export)
        PARENT_HISTORY=$(echo ${PARENTENV}|grep "IMAGE_HISTORY"|sed -e 's/.*IMAGE_HISTORY=//' -e 's/"//g')
    fi
   sed -e "s,GIT_COMMIT=.*\",GIT_COMMIT=\"${GIT_COMMIT}\"," \
        -e "s,IMAGE_HISTORY=.*\",IMAGE_HISTORY=\"${BUILD_TAG} « ${PARENT_HISTORY}\"," \
        -i ${DF}
}
