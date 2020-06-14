# pushnotify

Apple push notifications for Dovecot.

This repository contains the following components:

* Patches against Dovecot 2.1 through 2.3 that add Apple push support. These
are based on Apple's own open-source implementation. The patches add
`XAPPLEPUSHSERVICE` support to Dovecot, and a push-notification plugin 
`push_notify`.
* `pushnotify.pl`, a simple push-notification agent that receives messages
from Dovecot and pushes them to iOS devices.
* `inotify.pl`, an evil hack that watches mailboxes for changes. Use this or
the push_notify plugin, but not both. This agent is able to push all mailbox
changes, not just new message delivery, at the expense of being an evil hack
and not very portable.

You will require an Apple application integration certificate exported from
an Apple macOS server (High Sierra or earlier).

Dovecot configuration:

    protocol lda { 
      mail_plugins = $mail_plugins push_notify 
    }

(or use `inotify.pl`)

    aps_topic = com.apple.mail.XServer.xxxxxx

(should match UID field in push certificate)

# A note about certificates

A recent update to Debian's ca-certificates package removed trust for the root
"GeoTrust Global CA", which is currently required to establish trust with the
APNS API. This results in "certificate verify failed" messages in the log and
a failure to deliver push notifications.

To re-establish trust, you can obtain the root certificate from
[https://www.geotrust.com/resources/root-certificates/]. Save with a `.crt`
extension in `/usr/local/share/ca-certificates`, then run
`update-ca-certificates` as `root`. These instructions are specific to
Debian, but the same basic approach should work on other distributions.

# A note about Mojave and iOS 12

macOS 10.14 no longer includes the Mail server component and cannot be used
to generate a suitable push certificate. Although 10.14 uses push notifications
for device management, it appears that iOS mail will not accept notifications
that do not use the com.apple.mail topic.

Push notifications continue to work on iOS 12 and 13, using a certificate
generated on macOS 10.13 or earlier.

