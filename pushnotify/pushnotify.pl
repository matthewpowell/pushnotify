#!/usr/bin/perl -w -T

use strict;
use lib '/usr/local/lib/pushnotify';

use Privileges::Drop;
use IO::Socket::UNIX qw( SOCK_DGRAM SOMAXCONN );
use Sys::Syslog qw( openlog syslog LOG_INFO );
use Net::APNS::Persistent;
use Net::APNS::Feedback;

sub save_devices;

# Dovecot's push notification socket
my $sockpath = '/var/run/dovecot/push_notify';
# A file containing registration information
my $devicepath = '/var/local/pushnotify/devices';
# APNS certificate
my $apns_cert = '/usr/local/lib/pushnotify/pushnotify.pem';
# APNS key (might be the same as $apns_cert)
my $apns_key = $apns_cert;

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

# When we last checked the feedback service (right now, never).
my $last_feedback = 0;
# When we last reconnected to APNS
my $last_connect = 0;

# We'll defer connecting to APNS until our first notification, but define $apns here
my $apns;

syslog (LOG_INFO, 'Atomnet push notify service running');

while(1)
{
my $data;
$socket->recv($data, 2048);

my ($junk, $username, $aps_acct_id, $aps_dev_token, $aps_sub_topic) = split /\0+/, $data;

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
		foreach (@{$devices{$username}}) {
			my ($aps_acct_id, $aps_dev_token, $aps_sub_topic, $time) = split /,/;
			syslog(LOG_INFO, "Send notification to $aps_dev_token for $username");
			eval {
				die if (time - $last_connect > 600);
				$apns->queue_notification (
					$aps_dev_token,
					{
						aps => {
							'account-id' => $aps_acct_id
						},
					});
				$apns->send_queue;
					1;
				} or do {
					# Failed; connect to APNS and try again
					syslog(LOG_INFO, 'Connect to APNS push gateway');
					$last_connect = time;
					eval { $apns->disconnect };

					$apns = Net::APNS::Persistent->new({
						sandbox => 0,
						cert => $apns_cert,
						key => $apns_key 
					});
					$apns->queue_notification (
						$aps_dev_token,
						{
							aps => {
								'account-id' => $aps_acct_id
							},
						});
					$apns->send_queue;
				}	
			}

			# Check for devices that don't want notifications any more
			if (time - $last_feedback > 3600) {
				syslog(LOG_INFO, 'Check APNS feedback service');
				$last_feedback = time;
				my $apns_feedback = Net::APNS::Feedback->new({
					sandbox => 0,
					cert => $apns_cert,
					key => $apns_key
				});
				my $feedback =  $apns_feedback->retrieve_feedback;
				$apns_feedback->disconnect;
	
				if (defined $feedback) {
					# Got at least one value
					foreach (@$feedback) {
						my $feedback_token = lc($$_{token});
						my $feedback_time = $$_{time_t};
						foreach my $username (keys %devices) {
							my @unregister;	
							foreach (@{$devices{$username}}) {
								my ($aps_acct_id, $aps_dev_token, $aps_sub_topic, $time) = split /,/;
								if ($aps_dev_token eq $feedback_token && $time < $feedback_time) {
									# Hasn't registered since the rejection; unregister
									push @unregister, $feedback_token
								}
							}
							foreach my $token (@unregister) {
								syslog(LOG_INFO, "Unregister device $token");
								@{$devices{$username}} = grep {!/$token/} @{$devices{$username}};
							}
						}
					}
					save_devices;
				}
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
