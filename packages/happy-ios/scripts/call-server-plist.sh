#!/usr/bin/env bash
# Points upstream's ElevenLabs call at our own ElevenLabs-compatible server:
# reads an Info.plist on stdin and writes it to stdout with HappyCallTokenURL
# and HappyCallLiveKitURL added (CallServer+Addons.swift hands them to the
# SDK) and HappyCallAgentID set to that server's agent. Used on copies only,
# by scripts/selfhost-project.sh and the device build's staged tree
# (scripts/prep-pro/remote.sh); App/Info-*.plist are never changed.
#
# Environment (each set empty leaves its keys as App/ has them; without both
# URLs the call keeps ElevenLabs, as upstream):
#   SELFHOST_CALL_TOKEN_URL    http(s) token route
#       (default https://happy.girthbass.duckdns.org/elevenlabs/v1/convai/conversation/token)
#   SELFHOST_CALL_LIVEKIT_URL  ws(s) LiveKit address
#       (default wss://happy.girthbass.duckdns.org/elevenlabs)
#   SELFHOST_CALL_AGENT_ID     agent_… ID the server knows (default agent_happy_voice_el)
#
# Options:
#   --check   Validate the environment only; read and write nothing.
set -euo pipefail

die() { printf 'call-server-plist: %s\n' "$*" >&2; exit 1; }

export CALL_TOKEN_URL="${SELFHOST_CALL_TOKEN_URL-https://happy.girthbass.duckdns.org/elevenlabs/v1/convai/conversation/token}"
export CALL_LIVEKIT_URL="${SELFHOST_CALL_LIVEKIT_URL-wss://happy.girthbass.duckdns.org/elevenlabs}"
export CALL_AGENT_ID="${SELFHOST_CALL_AGENT_ID-agent_happy_voice_el}"

# The same rules the app applies (CallServer.endpoints, CallAgent.id), so a
# bad value fails the build instead of quietly leaving the call on ElevenLabs.
[[ -z "$CALL_TOKEN_URL" || "$CALL_TOKEN_URL" =~ ^https?://[^/?#[:space:]]+([/?#][^[:space:]]*)?$ ]] \
    || die "SELFHOST_CALL_TOKEN_URL '$CALL_TOKEN_URL' must be an http(s) URL"
[[ -z "$CALL_LIVEKIT_URL" || "$CALL_LIVEKIT_URL" =~ ^wss?://[^/?#[:space:]]+([/?#][^[:space:]]*)?$ ]] \
    || die "SELFHOST_CALL_LIVEKIT_URL '$CALL_LIVEKIT_URL' must be a ws(s) URL"
if [[ -n "$CALL_TOKEN_URL" && -z "$CALL_LIVEKIT_URL" ]] || [[ -z "$CALL_TOKEN_URL" && -n "$CALL_LIVEKIT_URL" ]]; then
    die "set both SELFHOST_CALL_TOKEN_URL and SELFHOST_CALL_LIVEKIT_URL, or neither"
fi
[[ -z "$CALL_AGENT_ID" || "$CALL_AGENT_ID" =~ ^agent_[A-Za-z0-9_]+$ ]] \
    || die "SELFHOST_CALL_AGENT_ID '$CALL_AGENT_ID' must be an agent ID (agent_…)"

[[ "${1:-}" == --check ]] && exit 0
[[ $# -eq 0 ]] || die "unknown option: $1"

# Each edit must match, so a change to App/Info-*.plist fails here instead
# of shipping half-applied; a key upstream adds itself is refused, not doubled.
# shellcheck disable=SC2016
perl -e '
use strict;
use warnings;
undef $/;
my $plist = <STDIN>;
sub xml { my $s = shift; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; return $s; }
for my $key (qw(HappyCallTokenURL HappyCallLiveKitURL)) {
    $plist !~ m{<key>\Q$key\E</key>} or die "the plist already has $key\n";
}
if (length $ENV{CALL_AGENT_ID}) {
    my $id = xml($ENV{CALL_AGENT_ID});
    $plist =~ s{(<key>HappyCallAgentID</key>\s*<string>)[^<]*(</string>)}{$1$id$2} or die "no HappyCallAgentID\n";
}
if (length $ENV{CALL_TOKEN_URL}) {
    my $token = xml($ENV{CALL_TOKEN_URL});
    my $livekit = xml($ENV{CALL_LIVEKIT_URL});
    $plist =~ s{(</dict>\s*</plist>\s*)$}{\t<key>HappyCallTokenURL</key>\n\t<string>$token</string>\n\t<key>HappyCallLiveKitURL</key>\n\t<string>$livekit</string>\n$1}
        or die "no closing dict\n";
}
print $plist;
'
