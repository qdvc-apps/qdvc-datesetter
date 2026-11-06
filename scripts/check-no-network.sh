#!/usr/bin/env bash
# QDVC Datesetter must never touch the network. This script checks it at
# three levels; scripts/build-app.sh runs all three and stops on a failure.
#
#   scripts/check-no-network.sh sources              # Package.swift, Sources/, Tests/
#   scripts/check-no-network.sh binary <executable>  # what the app links and calls
#   scripts/check-no-network.sh app <QDVC Datesetter.app>  # sandboxed, no network entitlement
#
# The sources check also runs on Linux (no Xcode needed).
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    echo "error: $*" >&2
    echo "       QDVC Datesetter must never access the network (docs/MAINTENANCE.md, \"No network\")." >&2
    exit 1
}

case "${1:-}" in
sources)
    # No package dependencies, so SwiftPM never fetches anything.
    if grep -nE '\.package[[:space:]]*\(' Package.swift; then
        fail "Package.swift declares a package dependency (above)"
    fi
    # Networking APIs, web views, links that open a browser, and URLs.
    pattern='URLSession|NSURLConnection|NSURLDownload|URLRequest|URLCache|NSURLProtocol'
    pattern+='|import[[:space:]]+(Network|CFNetwork|WebKit|NetworkExtension|MultipeerConnectivity|CloudKit|SafariServices)'
    pattern+='|NWConnection|NWListener|NWBrowser|NWPathMonitor|nw_connection|WKWebView|SFSafariViewController'
    pattern+='|CFSocket|CFStreamCreatePairWith|CFHost|NSNetService|getaddrinfo|gethostbyname|SCNetworkReachability'
    pattern+='|AsyncImage|openURL|NSWorkspace\.shared\.open[[:space:]]*\(|[^A-Za-z]Link[[:space:]]*\('
    pattern+='|https?://|ftp://|wss?://'
    if grep -rnE "$pattern" Sources Tests Package.swift; then
        fail "network-related code in the sources (above)"
    fi
    echo "==> Sources: no network code, no package dependencies"
    ;;

binary)
    exe="${2:?usage: $0 binary <executable>}"
    # Frameworks whose only purpose is networking or web content.
    if xcrun otool -L "$exe" | grep -E '/(Network|WebKit|NetworkExtension|MultipeerConnectivity|CloudKit|SafariServices)\.framework/'; then
        fail "the app links a networking framework (above)"
    fi
    # Networking functions and classes the app would call.
    if xcrun nm -u "$exe" | grep -E 'URLSession|NSURLConnection|NSURLDownload|URLRequest|WKWebView|NSNetService|CFSocket|CFHost|CFStreamCreatePairWithSocket|SCNetworkReachability|^_nw_|^_socket$|^_connect$|^_getaddrinfo$|^_gethostbyname'; then
        fail "the app refers to networking functions (above)"
    fi
    echo "==> Binary: no networking frameworks or functions"
    ;;

app)
    app="${2:?usage: $0 app <app bundle>}"
    entitlements="$(codesign -d --entitlements - "$app" 2>/dev/null || true)"
    if ! grep -q 'com.apple.security.app-sandbox' <<<"$entitlements"; then
        fail "the app is not sandboxed"
    fi
    if grep -E 'com\.apple\.security\.network\.' <<<"$entitlements"; then
        fail "the app has a network entitlement (above)"
    fi
    echo "==> App: sandboxed, with no network entitlement (macOS blocks any connection)"
    ;;

*)
    sed -n '2,9p' "$0"
    exit 2
    ;;
esac
