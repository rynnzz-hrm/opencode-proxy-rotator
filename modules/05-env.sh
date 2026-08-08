#!/usr/bin/env bash
# 05-env.sh — opencode env (global ALL_PROXY + OPENCODE_BASE_URL).
# Root: /etc/profile.d/opencode-proxy.sh. Non-root: ~/.profile (a file, not dir).

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

write_env_to() {
    local tgt="$1"
    local want="OPENCODE_BASE_URL=http://127.0.0.1:${PROXY_PORT}/v1"
    if [ -f "$tgt" ] && grep -qF "$want" "$tgt"; then
        log "opencode proxy env already correct ($tgt)"
        return 0
    fi
    {
        echo "# opencode -> oc-free-proxy -> WARP (opencode-proxy-rotator)"
        echo "export ALL_PROXY=socks5://127.0.0.1:${SOCKS_PORT}"
        echo "export OPENCODE_BASE_URL=http://127.0.0.1:${PROXY_PORT}/v1"
    } >> "$tgt"
    log "wrote opencode proxy env to $tgt"
}

write_opencode_env() {
    if is_root; then
        mkdir -p /etc/profile.d
        write_env_to "/etc/profile.d/opencode-proxy.sh"
    else
        write_env_to "${HOME}/.profile"
        log "opencode proxy env in ~/.profile (source it or relogin)"
    fi
}

module_main() {
    write_opencode_env
}

if [ "$(basename "$0")" = "05-env.sh" ]; then
    module_main
fi