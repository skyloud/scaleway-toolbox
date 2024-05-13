FROM --platform=amd64 ubuntu:22.04

RUN \
    apt-get update -yqq >/dev/null 2>&1 && \
    apt-get install -yqq jq curl >/dev/null 2>&1 && \
    curl -sS https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc && \
    chmod +x /usr/local/bin/mc && \
    arch="amd64" && \
    os="linux" && \
    latest_release_json=$(curl -s https://api.github.com/repos/scaleway/scaleway-cli/releases/latest) && \
    latest=$(echo "$latest_release_json" | grep "browser_download_url.*${os}_${arch}" | cut -d : -f 2,3 | tr -d \" | tr -d " ") && \
    curl -s -L "$latest" -o /usr/local/bin/scw && \
    chmod +x /usr/local/bin/scw

COPY --chmod=0755 ./entrypoint.sh /entrypoint.sh

CMD ["/entrypoint.sh"]
