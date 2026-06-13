FROM debian:bookworm

RUN set -eux; \
    sed -i -- 's/Types: deb/Types: deb deb-src/g' /etc/apt/sources.list.d/debian.sources; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        binutils \
        build-essential \
        ca-certificates \
        cdbs \
        curl \
        devscripts \
        dpkg-dev \
        equivs \
        fakeroot \
        git \
        gnupg \
        kmod \
        squashfs-tools \
        wget; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
