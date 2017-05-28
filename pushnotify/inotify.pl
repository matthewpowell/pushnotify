#!/usr/bin/perl -w -T

# Alternate notification method using inotify

use strict;
use IO::Socket::UNIX qw( SOCK_DGRAM SOMAXCONN );
use Sys::Syslog qw( openlog syslog LOG_INFO );
use Linux::Inotify2;

# Path to Dovecot's notification socket
my $sockpath = '/var/run/dovecot/push_notify';

my $min_uid = 1000;		# Minimum UID of a 'real' user
my $max_uid = 59999;		# Maximum UID of a 'real' user

openlog ('pushnotify', 'ndelay', 'mail');
syslog (LOG_INFO, 'Atomnet enhanced notification service running');

while (1) {
	syslog (LOG_INFO, 'Rescan user list');
	my $notifier = new Linux::Inotify2
		or die "unable to create new inotify object: $!";

	# A hash to map usernames and directories
	my %usermap;
	setpwent;

	while (my ($username, $uid, $home) = (getpwent)[0,2,7]) {
		next if ($uid < $min_uid);
		next if ($uid > $max_uid);
	
		$usermap{"$home/Maildir/new"} = $username;
		$notifier->watch ("$home/Maildir/new", IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE);
		$usermap{"$home/Maildir/cur"} = $username;
		$notifier->watch ("$home/Maildir/cur", IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE);
		$usermap{"$home/mdbox/mailboxes/INBOX/dbox-Mails"} = $username;
		$notifier->watch ("$home/mdbox/mailboxes/INBOX/dbox-Mails", IN_MODIFY);
	}

	my $last_userscan = time;

	while (time - $last_userscan < 3600) {
		my @events = $notifier->read;

		# If this is a new message delivery, notify immediately
		unless ($#events == 0 && $events[0]->fullname =~ /\/new\/[^\/]+$/) {
			# Otherwise avoid duplicate events; wait a short time for any additional events
			$notifier->blocking(0);
			while (1) {
				select (undef, undef, undef, 0.5);
				my @more = $notifier->read;
				last unless @more;
				push @events, @more;
			}
			$notifier->blocking(1);
		}

		# To track users we want to notify
		my %notifyusers;

		foreach my $event (@events) {
			my $dir = $event->fullname;
			$dir =~ s/\/[^\/]+$//;
			my $username = $usermap{"$dir"} 
				or die "Can't map object to user: $dir\n";
			if ($dir =~ /new$/ && $event->IN_MOVED_FROM) {
				# This is just a move from new to cur. We don't care about that.
				$notifyusers{$username}--;
			} else {
				$notifyusers{$username}++;
			}
		}

		my $socket = IO::Socket::UNIX->new(
   			Type => SOCK_DGRAM,
   			Peer => $sockpath,
		)
			or die "Can't connect to server: $!\n";

		foreach (keys %notifyusers) {
			next if $notifyusers{$_}<1;
			syslog (LOG_INFO, "Notify mailbox change for $_");
			print $socket "\0$_\0";
		}
	}
}
