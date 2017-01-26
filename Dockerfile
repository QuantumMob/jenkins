FROM openjdk:8-jdk
RUN apt-get update

ENV BASE_APKS="sudo openssl openssh-client zip ttf-dejavu maven ruby" \
    BUILD_APKS=" make gcc clang g++ paxctl binutils-gold autoconf bison"

RUN apt-get install -y $BASE_APKS $BUILD_APKS \
      && rm -rf /var/lib/apt/lists/*

ENV NODE_PREFIX=/usr/local \
    NODE_VERSION=6.4.0 \
    NPM_VERSION=latest \
    NODE_SOURCE=/usr/src/node

RUN [ "${NODE_VERSION}" == "latest" ] && { \
        DOWNLOAD_PATH=https://nodejs.org/dist/node-latest.tar.gz; \
    } || { \
        DOWNLOAD_PATH=https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}.tar.gz; \
    }; \
    mkdir -p $NODE_SOURCE && \
    wget -O - $DOWNLOAD_PATH -nv | tar -xz --strip-components=1 -C $NODE_SOURCE && \
    cd $NODE_SOURCE && \
    export GYP_DEFINES="linux_use_gold_flags=0" && \
    ./configure --prefix=$NODE_PREFIX $NODE_CONFIG_FLAGS && \
    make -j$(grep -c ^processor /proc/cpuinfo 2>/dev/null || 1) && \
    make install;

RUN paxctl -cm ${NODE_PREFIX}/bin/node && \
    cd / && \
    if [ -x /usr/bin/npm ]; then \
      npm install -g npm@${NPM_VERSION} && \
      find /usr/lib/node_modules/npm -name test -o -name .bin -type d | xargs rm -rf; \
    fi && \
    rm -rf \
        ${NODE_SOURCE} \
        ${NODE_PREFIX}/include \
        ${NODE_PREFIX}/share/man \
        /tmp/* \
        /var/cache/apk/* \
        /root/.npm \
        /root/.node-gyp \
        /root/.gnupg \
        ${NODE_PREFIX}/lib/node_modules/npm/man \
        ${NODE_PREFIX}/lib/node_modules/npm/doc \
        ${NODE_PREFIX}/lib/node_modules/npm/html \
    && \
    mkdir -p /app && \
    exit 0 || exit 1;

RUN echo "jenkins ALL=NOPASSWD: ALL" >> /etc/sudoers

ENV JENKINS_HOME /var/jenkins_home
ENV JENKINS_SLAVE_AGENT_PORT 50000

ARG user=jenkins
ARG group=jenkins
ARG uid=1000
ARG gid=1000

# Jenkins is run with user `jenkins`, uid = 1000
# If you bind mount a volume from the host or a data container,
# ensure you use the same uid
RUN groupadd -g ${gid} ${group} \
    && useradd -d "$JENKINS_HOME" -u ${uid} -g ${gid} -m -s /bin/bash ${user}

# Jenkins home directory is a volume, so configuration and build history
# can be persisted and survive image upgrades
VOLUME /var/jenkins_home

# `/usr/share/jenkins/ref/` contains all reference configuration we want
# to set on a fresh new installation. Use it to bundle additional plugins
# or config file with your custom jenkins Docker image.
RUN mkdir -p /usr/share/jenkins/ref/init.groovy.d

ENV TINI_VERSION 0.9.0
ENV TINI_SHA fa23d1e20732501c3bb8eeeca423c89ac80ed452

# Use tini as subreaper in Docker container to adopt zombie processes
RUN curl -fsSL https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini-static -o /bin/tini && chmod +x /bin/tini \
  && echo "$TINI_SHA  /bin/tini" | sha1sum -c -

COPY init.groovy /usr/share/jenkins/ref/init.groovy.d/tcp-slave-agent-port.groovy

# jenkins version being bundled in this docker image
ARG JENKINS_VERSION
ENV JENKINS_VERSION ${JENKINS_VERSION:-2.28}

# jenkins.war checksum, download will be validated using it
ARG JENKINS_SHA=183125ee4e731a559f39d146a7ffbca08c3e011f

# Can be used to customize where jenkins.war get downloaded from
ARG JENKINS_URL=https://repo.jenkins-ci.org/public/org/jenkins-ci/main/jenkins-war/${JENKINS_VERSION}/jenkins-war-${JENKINS_VERSION}.war

# could use ADD but this one does not check Last-Modified header neither does it allow to control checksum
# see https://github.com/docker/docker/issues/8331
RUN curl -fsSL ${JENKINS_URL} -o /usr/share/jenkins/jenkins.war \
  && echo "${JENKINS_SHA}  /usr/share/jenkins/jenkins.war" | sha1sum -c -

ENV JENKINS_UC https://updates.jenkins.io
RUN chown -R ${user} "$JENKINS_HOME" /usr/share/jenkins/ref
RUN chown -R ${user} /usr/local

RUN sudo rm /usr/bin/java \
  &&  sudo ln -s /usr/lib/jvm/java-1.8.0-openjdk-amd64/bin/java /usr/bin/java

# Install docker-compose
RUN curl -L "https://github.com/docker/compose/releases/download/1.8.1/docker-compose-$(uname -s)-$(uname -m)" > /usr/local/bin/docker-compose \
  && chmod +x /usr/local/bin/docker-compose

# for main web interface:
EXPOSE 8080

# will be used by attached slave agents:
EXPOSE 50000

ENV COPY_REFERENCE_FILE_LOG $JENKINS_HOME/copy_reference_file.log

USER ${user}

RUN npm install -g yarn \
  && yarn global add gulp grunt node-sass bower

COPY jenkins-support /usr/local/bin/jenkins-support
COPY jenkins.sh /usr/local/bin/jenkins.sh

ENTRYPOINT ["/bin/tini", "--", "/usr/local/bin/jenkins.sh"]

# from a derived Dockerfile, can use `RUN plugins.sh active.txt` to setup /usr/share/jenkins/ref/plugins from a support bundle
COPY plugins.sh /usr/local/bin/plugins.sh
COPY install-plugins.sh /usr/local/bin/install-plugins.sh
