# pushnotify

Apple push notifications for Dovecot.

This repository contains the following components:

* A patch against Dovecot 2.2.29.1 that adds Apple push support. This is based
on Apple's own open-source implementation. The patch adds XAPPLEPUSHSERVICE
support to Dovecot, and a push-notification plugin "push_notify".
* pushnotify.pl, a simple push-notification agent that receives messages from
Dovecot and pushes them to iOS devices.
* inotify.pl, an evil hack that watches mailboxes for changes. Use this or
the push_notify plugin, but not both. This agent is able to push all mailbox
changes, not just new message delivery. At the expense of being an evil hack
and not very portable.

You will require an Apple application integration certificate exported from
an Apple macOS server.

Dovecot configuration:

mail_plugins = $mail_plugins push_notify 
(or use inotify.pl)

aps_topic = aps_topic = com.apple.mail.XServer.xxxxxx
(should match UID field in push certificate)
