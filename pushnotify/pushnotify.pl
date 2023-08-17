#!/usr/bin/perl -w -T

use strict;
use lib '/usr/local/lib/pushnotify';

use Privileges::Drop;
use IO::Socket::UNIX qw( SOCK_DGRAM SOMAXCONN );
use Sys::Syslog qw( openlog syslog LOG_INFO LOG_WARNING );
use Net::APNS::SimpleCert;

sub save_devices;

# Dovecot's push notification socket
my $sockpath = '/var/run/dovecot/push_notify';
# A file containing registration information
my $devicepath = '/var/local/pushnotify/devices';
# APNS certificate
my $apns_cert = '/usr/local/lib/pushnotify/pushnotify.pem';
# APNS key (might be the same as $apns_cert)
my $apns_key = $apns_cert;
# How long before device registrations expire
my $expire_time = 86400*3;

# Read in the list of registered devices.
my %devices;
if (open DEVICES, $devicepath) {
	while (<DEVICES>) {
		chomp;
		my ($username, $devicedata) = split /:/;
		push @{$devices{$username}}, $devicedata;
	}
	close DEVICES;
}

# Open the socket to Dovecot
unlink $sockpath;
umask (0111);
my $socket = IO::Socket::UNIX->new(
   Type   => SOCK_DGRAM,
   Local  => $sockpath,
   Listen => SOMAXCONN,
)
   or die("Can't create server socket: $!\n");

drop_privileges('dovecot');

openlog ('pushnotify', 'ndelay', 'mail');

# We'll defer connecting to APNS until our first notification, but define $apns here
my $apns;

syslog (LOG_INFO, 'Atomnet push notify service running');

while(1)
{
	my $data;
	$socket->recv($data, 2048);

	my ($junk, $username, $aps_acct_id, $aps_dev_token, $aps_sub_topic) = split /\0+/, $data;

	# Validate input
	unless ($username =~ /^[a-z][-a-z0-9_]*$/) {
		syslog (LOG_WARNING, "Reject invalid username $username");
		next;
	}
	unless ($aps_acct_id =~ /^[-a-f0-9]*$/i) {
		syslog (LOG_WARNING, "Reject invalid aps_acct_id $aps_acct_id");
		next;
	}
	unless ($aps_dev_token =~ /^[a-f0-9]*$/i) {
		syslog (LOG_WARNING, "Reject invalid aps_dev_token $aps_dev_token");
		next;
	}
	unless ($aps_sub_topic =~ /^[.a-z]*$/) {
		syslog (LOG_WARNING, "Reject invalid aps_sub_topic $aps_sub_topic");
		next;
	}

	if ($aps_acct_id) {
		$aps_dev_token = lc($aps_dev_token);

		my $devicedata = join ',', $aps_acct_id, $aps_dev_token, $aps_sub_topic, time;

		syslog (LOG_INFO, "Register device $aps_dev_token for $username");
		# Cancel any duplicate registration
		@{$devices{$username}} = grep {!/$aps_dev_token/} @{$devices{$username}};
		# Register new device
		push @{$devices{$username}}, $devicedata;
		save_devices;
	} else {
		if (defined $devices{$username}) {
			# User has at least one device registered

			# Do the push notification
			my @unregister;
			foreach (@{$devices{$username}}) {
				my ($aps_acct_id, $aps_dev_token, $aps_sub_topic, $time) = split /,/;
				# Expire the registration if it is stale
				if ((time - $time) > $expire_time) {
					syslog(LOG_INFO, "Expire device $aps_dev_token for $username");
					push @unregister, $aps_dev_token;
					next;
				}
				syslog(LOG_INFO, "Send notification to $aps_dev_token for $username");
				eval {
					$apns->prepare (
						$aps_dev_token,
						{
							aps => {
								'account-id' => $aps_acct_id
							},
						});
					$apns->notify;
					1;
				} or do {
					# Failed; connect to APNS and try again
					syslog(LOG_INFO, 'Connect to APNS push gateway');
					eval { $apns->disconnect };

					$apns = Net::APNS::SimpleCert->new({
						development => 0,
						cert => $apns_cert,
						key => $apns_key 
					});
					$apns->prepare (
						$aps_dev_token,
						{
							aps => {
								'account-id' => $aps_acct_id
							},
						});
					$apns->notify;
				}	
			}
			# Remove registrations that have expired
			if (@unregister > 0) {
				foreach my $aps_dev_token (@unregister) {
					syslog(LOG_INFO, "Unregister device $aps_dev_token");
					@{$devices{$username}} = grep {!/$aps_dev_token/} @{$devices{$username}};
				}
				save_devices;
			}

		}
	}
}

sub save_devices {
	# Save our registration data
	umask (0077);
	open DEVICES, ">$devicepath";
	foreach my $username (keys %devices) {
		foreach my $devicedata (@{$devices{$username}}) {
			print DEVICES "$username:$devicedata\n";
		}
	}
	close DEVICES;
}
