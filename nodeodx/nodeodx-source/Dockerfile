ARG FROM_REPO=webodm/odx
FROM ${FROM_REPO}
MAINTAINER Piero Toffanin <pt@masseranolabs.com>

EXPOSE 3000

USER root

RUN mkdir /var/www

WORKDIR "/var/www"
COPY . /var/www

ENV NVM_DIR /usr/local/nvm
ENV NODE_VERSION 14

RUN bash install_deps.sh && \
    bash -lc '. "$NVM_DIR/nvm.sh" && nvm use "$NODE_VERSION" && test -x "$(command -v node)" && node -p process.execPath' && \
    ln -s /code/SuperBuild/install/bin/untwine /usr/bin/untwine && \
    ln -s /code/SuperBuild/install/bin/entwine /usr/bin/entwine && \
    ln -s /code/SuperBuild/install/bin/pdal /usr/bin/pdal && \
    ln -s /var/www/node.sh /usr/bin/node && \
    mkdir -p data logs tmp && node index.js --powercycle

ENTRYPOINT ["/usr/bin/node", "/var/www/index.js"]
