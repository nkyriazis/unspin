FROM alpine:3.20
RUN apk add --no-cache zsh bash mawk gawk busybox-extras coreutils jq python3 shellcheck tmux ncurses procps
RUN apk add --no-cache --virtual .b git gcc make musl-dev bison \
 && git clone -q https://github.com/onetrueawk/awk /tmp/ota \
 && cd /tmp/ota && git checkout -q 9804285 && make -s >/dev/null 2>&1 && cp a.out /usr/local/bin/bwk-awk-2020 \
 && git checkout -q master && make -s clean >/dev/null 2>&1; make -s >/dev/null 2>&1 && cp a.out /usr/local/bin/bwk-awk \
 && cd / && rm -rf /tmp/ota && apk del .b
