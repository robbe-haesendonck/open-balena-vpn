FROM balena/open-balena-base:v13.0.4 as base


FROM base as builder
COPY package.json package-lock.json /usr/src/app/
RUN npm ci && npm cache clean --force 2>/dev/null
COPY tsconfig.json tsconfig.dev.json /usr/src/app/
COPY typings /usr/src/app/typings
COPY test /usr/src/app/test
COPY src /usr/src/app/src
RUN npm run build


FROM base as main

EXPOSE 80 443 3128

RUN curl -s https://haproxy.debian.net/bernat.debian.org.gpg | apt-key add - >/dev/null \
    && echo deb http://haproxy.debian.net bullseye-backports-2.4 main > /etc/apt/sources.list.d/haproxy.list \
    && apt-get update -qq \
    && apt-get install -qy haproxy=2.4.* iptables --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/*.list /etc/haproxy/* /etc/rsyslog.d/49-haproxy.conf /etc/openvpn/* /etc/defaults/openvpn \
    && ln -sf /usr/src/app/openvpn/scripts /etc/openvpn/scripts \
    && systemctl mask openvpn@.service openvpn.service

ENV LIBNSS_OPENVPN_VERSION 22feb11322182f6fd79f85cd014b65b6c40b7b47
RUN tmp="$(mktemp -d)" set -x \
    && git clone -q https://github.com/balena-io-modules/libnss-openvpn.git "${tmp}" \
    && cd "${tmp}" \
    && git -C "${tmp}" checkout -q ${LIBNSS_OPENVPN_VERSION} \
    && make -C "${tmp}" -j "$(nproc)" \
    && make -C "${tmp}" install \
    && sed --in-place --regexp-extended 's|(hosts:\W+)(.*)|\1openvpn \2|' /etc/nsswitch.conf \
    && rm -rf "${tmp}"

ENV NODE_EXPORTER_VERSION 1.2.2
ENV NODE_EXPORTER_SHA256SUM 344bd4c0bbd66ff78f14486ec48b89c248139cdd485e992583ea30e89e0e5390
RUN NODE_EXPORTER_TGZ="/tmp/node_exporter.tar.gz" set -x \
    && curl -Lo "${NODE_EXPORTER_TGZ}" https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz \
    && echo "${NODE_EXPORTER_SHA256SUM}  ${NODE_EXPORTER_TGZ}" | sha256sum -c \
    && tar -xzC /usr/local/bin -f "${NODE_EXPORTER_TGZ}" --strip-components=1 --wildcards '*/node_exporter' \
    && rm "${NODE_EXPORTER_TGZ}"

ENV PROCESS_EXPORTER_VERSION 0.7.5
ENV PROCESS_EXPORTER_SHA256SUM 27f133596205654a67b4a3e3af11db640f7d4609a457f48c155901835bd349c6
RUN PROCESS_EXPORTER_TGZ="/tmp/process_exporter.tar.gz" set -x \
    && curl -Lo "${PROCESS_EXPORTER_TGZ}" https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/process-exporter-${PROCESS_EXPORTER_VERSION}.linux-amd64.tar.gz \
    && echo "${PROCESS_EXPORTER_SHA256SUM}  ${PROCESS_EXPORTER_TGZ}" | sha256sum -c \
    && tar -xzC /usr/local/bin -f "${PROCESS_EXPORTER_TGZ}" --strip-components=1 --wildcards '*/process-exporter' \
    && rm "${PROCESS_EXPORTER_TGZ}"

COPY package.json package-lock.json /usr/src/app/
RUN npm ci --unsafe-perm --production && npm cache clean --force 2>/dev/null

COPY --from=builder /usr/src/app/build /usr/src/app/build
COPY bin /usr/src/app/bin
COPY config /usr/src/app/config
COPY openvpn /usr/src/app/openvpn

COPY docker-hc /usr/src/app/

COPY config/services /etc/systemd/system
RUN systemctl enable \
    open-balena-vpn.service \
    node-exporter.service \
    process-exporter.service
