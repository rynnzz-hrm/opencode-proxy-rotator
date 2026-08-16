#!/usr/bin/env bash
# 05-env.sh — opencode env (global ALL_PROXY + OPENCODE_BASE_URL).
# Root: /etc/profile.d/opencode-proxy.sh. Non-root: ~/.profile (a file, not dir).

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

write_env_to() {
    local tgt="$1"
    local want="OPENCODE_BASE_URL=http://127.0.0.1:${PROXY_PORT}/v1"
    local all_proxy="ALL_PROXY=socks5://127.0.0.1:${SOCKS_PORT}"
    if [ -f "$tgt" ] && grep -qF "export $want" "$tgt" && grep -qF "export $all_proxy" "$tgt"; then
        log "opencode proxy env already correct ($tgt)"
        return 0
    fi
    # AUDIT FIX 2026-08-16: old dedup only checked OPENCODE_BASE_URL, so a rerun
    # with a different SOCKS_PORT appended a SECOND ALL_PROXY line (stale port
    # wins — the exact cross-device inconsistency). Replace in place, never dup.
    if [ -f "$tgt" ] && grep -qE '^[[:space:]]*export ALL_PROXY=' "$tgt"; then
        sed -i "s|^[[:space:]]*export ALL_PROXY=.*|export $all_proxy|" "$tgt"
    else
        {
            echo "# opencode -> oc-free-proxy -> WARP (opencode-proxy-rotator)"
            echo "export $all_proxy"
        } >> "$tgt"
    fi
    grep -qF "export $want" "$tgt" 2>/dev/null || echo "export $want" >> "$tgt"
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