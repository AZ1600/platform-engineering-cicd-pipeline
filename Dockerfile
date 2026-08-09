FROM nginxinc/nginx-unprivileged:1.30.4-alpine@sha256:44e36330f74d4f3a1d4e222acca9e23b401fb87811a7597024502bb759c4dd49

COPY --chown=101:101 src/ /usr/share/nginx/html/

USER 101:101

EXPOSE 8080