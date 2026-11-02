#!/usr/bin/env bash
# Generates the self-host Xcode project for a personal Apple team: your bundle
# id, name and server, no push, no associated domains. Opt-in; project.yml and
# App/ are read, never changed.
#
#   APPLE_TEAM_ID=ABCDE12345 \
#   APP_BUNDLE_ID_PREFIX=com.example.happy \
#   SELFHOST_SERVER_URL=https://happy.example.com \
#   scripts/selfhost-project.sh
#
# Writes .selfhost/Info-{Development,Preview,Production}.plist from App/ so
# they can't drift, then HappySelfHost.xcodeproj with xcodegen. Both git-ignored.
#
# Environment:
#   APPLE_TEAM_ID (or DEVELOPMENT_TEAM)  10-character Apple team id
#   APP_BUNDLE_ID_PREFIX                 reverse-DNS, letters and digits only
#   SELFHOST_SERVER_URL                  http(s) URL of your server
#   APP_DISPLAY_NAME                     home-screen name (default "Happy")
#   APP_ENV                              development | preview | production
#                                        (default preview). Only decides whether
#                                        the production transport rule applies.
#
# Options:
#   --plists-only   Validate and write the plists; don't run xcodegen.
#   --output DIR    Write the plists to DIR instead of .selfhost.
set -euo pipefail

die() { printf 'selfhost-project: %s\n' "$*" >&2; exit 1; }

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$PACKAGE_DIR/.selfhost"
PLISTS_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plists-only) PLISTS_ONLY=1 ;;
        --output)      [[ $# -ge 2 ]] || die "--output needs a value"; OUTPUT_DIR="$2"; shift ;;
        -h|--help)     sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "unknown option: $1" ;;
    esac
    shift
done

APPLE_TEAM_ID="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
APP_BUNDLE_ID_PREFIX="${APP_BUNDLE_ID_PREFIX:-}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Happy}"
APP_ENV="${APP_ENV:-preview}"
SERVER_URL="${SELFHOST_SERVER_URL:-}"
while [[ "$SERVER_URL" == */ ]]; do SERVER_URL="${SERVER_URL%/}"; done

[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
    || die "APPLE_TEAM_ID missing or invalid ('$APPLE_TEAM_ID'), expected 10 capitals and digits"

# Same rule as packages/happy-app/plugins/selfHost.js (no hyphens).
[[ "$APP_BUNDLE_ID_PREFIX" =~ ^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$ ]] \
    || die "APP_BUNDLE_ID_PREFIX '$APP_BUNDLE_ID_PREFIX' must be reverse-DNS, letters and digits only"
case "$APP_BUNDLE_ID_PREFIX" in
    com.slopus|com.slopus.*|com.ex3ndr|com.ex3ndr.*)
        die "APP_BUNDLE_ID_PREFIX must be your own, '$APP_BUNDLE_ID_PREFIX' belongs to the upstream app" ;;
esac

case "$APP_ENV" in
    development|preview|production) ;;
    *) die "APP_ENV must be development, preview or production (got '$APP_ENV')" ;;
esac

url_pattern='^(https?)://([^/?#[:space:]]+)([/?#][^[:space:]]*)?$'
[[ "$SERVER_URL" =~ $url_pattern ]] \
    || die "SELFHOST_SERVER_URL missing or invalid ('$SERVER_URL'), expected an http(s) URL"
scheme="${BASH_REMATCH[1]}"
authority="${BASH_REMATCH[2]}"

# App Transport Security in App/Info-Production.plist allows only local
# networking: plain http works to an IP address, an unqualified host or a .local
# name, and is blocked to anything else. Refuse here, not silently on the phone.
if [[ "$APP_ENV" == production && "$scheme" == http ]]; then
    host="${authority##*@}"
    if [[ "$host" == \[* ]]; then
        host="${host%%]*}]"
    else
        host="${host%%:*}"
    fi
    host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
    ipv4_pattern='^[0-9]+(\.[0-9]+){3}$'
    if [[ "$host" != \[* && "$host" == *.* && "$host" != *.local && ! "$host" =~ $ipv4_pattern ]]; then
        die "a production build can't reach http://$host: its App Transport Security allows https only for a remote server. Use https, or APP_ENV=preview."
    fi
fi

# Reads a canonical plist and writes its self-host twin. Each edit must match,
# so a change to App/Info-*.plist fails here instead of shipping half-applied.
# shellcheck disable=SC2016
derive='
use strict;
use warnings;
undef $/;
my $plist = <STDIN>;
sub xml { my $s = shift; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; return $s; }
my $name = xml($ENV{SELFHOST_NAME});
my $url = xml($ENV{SELFHOST_URL});

$plist =~ m{<key>CFBundleDisplayName</key>\s*<string>([^<]*)</string>} or die "no CFBundleDisplayName\n";
my $canonical = $1;
$plist =~ s{(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)}{$1$name$2} or die "no display name\n";
for my $key (qw(NSCameraUsageDescription NSLocalNetworkUsageDescription)) {
    $plist =~ s{(<key>\Q$key\E</key>\s*<string>[^<]*?)\Q$canonical\E([^<]*</string>)}{$1$name$2}
        or die "$key does not name the app\n";
}
$plist =~ s{[ \t]*<string>remote-notification</string>\n}{} or die "no remote-notification mode\n";
$plist =~ s{[ \t]*<key>UIBackgroundModes</key>\s*<array>\s*</array>\n}{};
$plist =~ s{(</dict>\s*</plist>\s*)$}{\t<key>HappyPushDisabled</key>\n\t<true/>\n\t<key>HappyServerURL</key>\n\t<string>$url</string>\n$1}
    or die "no closing dict\n";
print $plist;
'

mkdir -p "$OUTPUT_DIR"
for variant in Development Preview Production; do
    SELFHOST_NAME="$APP_DISPLAY_NAME" SELFHOST_URL="$SERVER_URL" \
        perl -e "$derive" < "$PACKAGE_DIR/App/Info-$variant.plist" > "$OUTPUT_DIR/Info-$variant.plist" \
        || die "could not derive Info-$variant.plist from App/"
done

[[ $PLISTS_ONLY -eq 0 ]] || exit 0

command -v xcodegen >/dev/null || die "xcodegen not found. Run: brew install xcodegen"
export APPLE_TEAM_ID APP_BUNDLE_ID_PREFIX
cd "$PACKAGE_DIR"
xcodegen generate --spec project.selfhost.yml
