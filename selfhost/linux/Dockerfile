# PEK Server for Linux / Docker. Build context = the repository root:
#   docker build -f selfhost/linux/Dockerfile -t pek-server .                                   the Docker image
#   docker build -f selfhost/linux/Dockerfile --target binary --output build/selfhost-linux .   just the program (one static file)
# The program is built on Alpine (musl) and linked statically, so the same file runs on any Linux distribution.
FROM alpine:3.20 AS build
RUN apk add --no-cache build-base cmake ninja linux-headers \
    openssl-dev openssl-libs-static sqlite-dev sqlite-static zlib-dev zlib-static
WORKDIR /src
COPY backend backend
COPY selfhost/linux selfhost/linux
ARG VERSION=dev
RUN cmake -S selfhost/linux -B /build -G Ninja -DCMAKE_BUILD_TYPE=Release -DPEK_STATIC=ON -DPEK_SERVER_VERSION=${VERSION} \
 && cmake --build /build

# --target binary: only the program
FROM scratch AS binary
COPY --from=build /build/pek-server /pek-server

# default target: the image
FROM alpine:3.20 AS image
RUN apk add --no-cache ffmpeg ca-certificates tzdata \
 && adduser -D -u 1000 pek \
 && mkdir -p /data /media && chown pek:pek /data
COPY --from=build /build/pek-server /usr/local/bin/pek-server
USER pek
ENV PEK_DATA=/data PEK_MEDIA=/media
VOLUME /data
EXPOSE 8080 8768/udp
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD nc -z 127.0.0.1 8080 || exit 1
ENTRYPOINT ["pek-server"]
