ARG TARGET=server

# Can be used in case a proxy is necessary
ARG GOPROXY

# Build Temporal binaries
FROM golang:1.16-alpine AS builder

RUN apk add --update --no-cache \
    make \
    git

# Making sure that dependency is not touched
ENV GOFLAGS="-mod=readonly"

WORKDIR /temporal

# Copy go mod dependencies first and build docker cache
COPY go.mod ./
COPY go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 make bins

# Download dockerize
FROM alpine:3.12 AS dockerize

ENV DOCKERIZE_VERSION v0.6.1
RUN wget https://github.com/jwilder/dockerize/releases/download/$DOCKERIZE_VERSION/dockerize-alpine-linux-amd64-$DOCKERIZE_VERSION.tar.gz \
    && tar -C /usr/local/bin -xzvf dockerize-alpine-linux-amd64-$DOCKERIZE_VERSION.tar.gz \
    && rm dockerize-alpine-linux-amd64-$DOCKERIZE_VERSION.tar.gz \
    && echo "**** fix for host id mapping error ****" \
    && chown root:root /usr/local/bin/dockerize

# Alpine base image
FROM alpine:3.12 AS alpine

RUN apk add --update --no-cache \
    ca-certificates \
    tzdata \
    bash \
    curl \
    vim

# set up nsswitch.conf for Go's "netgo" implementation
# https://github.com/gliderlabs/docker-alpine/issues/367#issuecomment-424546457
RUN test ! -e /etc/nsswitch.conf && echo 'hosts: files dns' > /etc/nsswitch.conf

SHELL ["/bin/bash", "-c"]

# Temporal server
FROM alpine AS temporal-server

ENV TEMPORAL_HOME /etc/temporal
RUN mkdir -p /etc/temporal

COPY --from=dockerize /usr/local/bin/dockerize /usr/local/bin
COPY --from=builder /temporal/temporal-cassandra-tool /usr/local/bin
COPY --from=builder /temporal/temporal-sql-tool /usr/local/bin
COPY --from=builder /temporal/tctl /usr/local/bin
COPY --from=builder /temporal/temporal-server /usr/local/bin
COPY --from=builder /temporal/schema /etc/temporal/schema

COPY docker/entrypoint.sh /entrypoint.sh
COPY config/dynamicconfig /etc/temporal/config/dynamicconfig
COPY docker/config_template.yaml /etc/temporal/config/config_template.yaml
COPY docker/start-temporal.sh /start-temporal.sh
COPY docker/start.sh /start.sh

WORKDIR /etc/temporal

ENV SERVICES="history:matching:frontend:worker"

EXPOSE 6933 6934 6935 6939 7233 7234 7235 7239
ENTRYPOINT ["/entrypoint.sh"]
CMD /start.sh

# All-in-one Temporal server
FROM temporal-server AS temporal-auto-setup
CMD /start.sh autosetup

# Temporal CLI
FROM alpine AS temporal-tctl

COPY --from=builder /temporal/tctl /usr/local/bin

ENTRYPOINT ["tctl"]

# All temporal tool binaries
FROM alpine AS temporal-admin-tools

RUN apk add --update --no-cache \
    jq \
    mysql-client \
    postgresql-client \
    python2 \
    && curl https://bootstrap.pypa.io/2.7/get-pip.py | python \
    && pip install cqlsh

ENV TEMPORAL_HOME /etc/temporal
RUN mkdir -p /etc/temporal

COPY --from=builder /temporal/temporal-cassandra-tool /usr/local/bin
COPY --from=builder /temporal/temporal-sql-tool /usr/local/bin
COPY --from=builder /temporal/tctl /usr/local/bin
COPY --from=builder /temporal/schema /etc/temporal/schema

WORKDIR /etc/temporal

# keep the container running
ENTRYPOINT ["tail", "-f", "/dev/null"]

# Final image
FROM temporal-${TARGET}
