FROM nginxinc/nginx-unprivileged:1.30.5-alpine3.24@sha256:15c994d10d6d78658721c3bcafff14cb281fba2a4bdf9d5ba92c416a472516e3

COPY --chown=101:101 src/ /usr/share/nginx/html/

USER 101:101

EXPOSE 8080