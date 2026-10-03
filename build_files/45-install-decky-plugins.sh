#!/bin/bash
set -euxo pipefail

# Copy dist from the image build stage, not the source tree.
install_plugin() {
    local name=$1 dist=$2 src=/ctx/decky/$1 dest=/usr/share/decky-plugins/$1
    install -d -m 0755 "${dest}"
    cp -a "${src}/plugin.json" "${src}/package.json" "${src}/main.py" "${dest}/"
    cp -a "${src}/py_modules" "${dest}/"
    [[ ! -f "${src}/catalog.json" ]] || cp -a "${src}/catalog.json" "${dest}/"
    [[ ! -d "${src}/templates" ]] || cp -a "${src}/templates" "${dest}/"
    cp -a "${dist}" "${dest}/dist"
    rm -f "${dest}/dist/"*.map
    find "${dest}" -name __pycache__ -type d -prune -exec rm -rf {} +
}
install_plugin armada-control /packages/decky-dist
install_plugin armada-store /packages/decky-store-dist
chmod 0755 /usr/lib/decky-loader/armada-decky-sync

decky_latest_url=https://github.com/SteamDeckHomebrew/decky-loader/releases/latest/download/PluginLoader
decky_service_url=https://raw.githubusercontent.com/SteamDeckHomebrew/decky-loader/main/dist/plugin_loader-prerelease.service
decky_headers="$(mktemp)"
decky_loader_tmp="$(mktemp)"
decky_service_tmp="$(mktemp)"
trap 'rm -f "${decky_headers}" "${decky_loader_tmp}" "${decky_service_tmp}"' EXIT

# Download the latest release asset directly to avoid GitHub API rate limits.
curl --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 2 -fsSL \
    -D "${decky_headers}" -o "${decky_loader_tmp}" "${decky_latest_url}"
decky_release_location="$(awk 'tolower($1) == "location:" && $2 ~ /\/releases\/download\// {print $2; exit}' "${decky_headers}")"
decky_version="${decky_release_location#*/releases/download/}"
decky_version="${decky_version%%/*}"
[[ -n "${decky_version}" && "${decky_version}" != "${decky_release_location}" ]]
[[ -s "${decky_loader_tmp}" ]]

install -d -m 0755 /usr/share/decky-loader
install -m 0755 "${decky_loader_tmp}" /usr/share/decky-loader/PluginLoader
printf '%s\n' "${decky_version}" > /usr/share/decky-loader/.loader.version
curl --retry 12 --retry-delay 10 -fsSL "${decky_service_url}" |
    sed 's#${HOMEBREW_FOLDER}#/var/home/armada/homebrew#g' \
        >"${decky_service_tmp}"
install -D -m 0644 "${decky_service_tmp}" /etc/systemd/system/plugin_loader.service

systemctl enable armada-decky-sync.service
systemctl enable plugin_loader.service
