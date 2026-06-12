FROM alpine:3.24
RUN apk add --no-cache tinyproxy
EXPOSE 8888
# -d: foreground (don't daemonize, so the container stays alive and logs go to stderr)
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
