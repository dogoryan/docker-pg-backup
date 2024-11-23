##############################################################################
# Production Stage                                                           #
##############################################################################
ARG POSTGRES_MAJOR_VERSION

FROM postgres:${POSTGRES_MAJOR_VERSION}

RUN apt-get -y update; apt-get -y --no-install-recommends install  cron vim  gettext \
    && apt-get -y --purge autoremove && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
RUN touch /var/log/cron.log

ENV \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ADD build_data /build_data
ADD scripts /backup-scripts
RUN echo ${POSTGRES_MAJOR_VERSION} > /tmp/pg_version.txt && chmod 0755 /backup-scripts/*.sh

WORKDIR /backup-scripts

ENTRYPOINT ["/bin/bash", "/backup-scripts/start.sh"]
CMD []