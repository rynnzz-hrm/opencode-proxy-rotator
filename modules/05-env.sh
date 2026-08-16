#!/usr/bin/env bash
# 05-env.sh — opencode env (global ALL_PROXY + OPENCODE_BASE_URL).
# Root: /etc/profile.d/opencode-proxy.sh. Non-root: ~/.profile (a file, not dir).

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

write_env_to() {
    local tgt="$1"
    local socks_port="${SOCKS_PORT:-40000}"
    local proxy_port="${PROXY_PORT:-6446}"
    # the whole block is managed between markers; a rerun with a different port
    # REPLACES the block instead of appending a duplicate ALL_PROXY line
    local start_marker="# >>> opencode-proxy-rotator env block >>>"
    local end_marker="# <<< opencode-proxy-rotator env block <<<"

    # if the block already exists in the target, drop it (both old 2-line form
    # and marker form) so re-runs converge instead of stacking
    if [ -f "$tgt" ]; then
        sed -i "/^$start_marker$/,/^$end_marker$/d" "$tgt"
        sed -i "/^export ALL_PROXY=/d" "$tgt"
        sed -i "/^export OPENCODE_BASE_URL=/d" "$tgt"
    fi

    {
        echo "$start_marker"
        echo "# opencode -> oc-free-proxy -> WARP (opencode-proxy-rotator)"
        # ALL_PROXY only when the WARP SOCKS is actually listening (round 3).
        # A dead ALL_PROXY makes every new shell's curl/git/npm silently hang on
        # devices where WARP/proxy is down. Conditional export: proxy up =>
        # routed (Option 2 preserved); proxy down => no ALL_PROXY, shells work.
        echo "if ss -tln 2>/dev/null | grep -q \":${socks_port} \"; then"
        echo "    export ALL_PROXY=socks5://127.0.0.1:${socks_port}"
        echo "fi"
        echo "export OPENCODE_BASE_URL=http://127.0.0.1:${proxy_port}/v1"
        echo "$end_marker"
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