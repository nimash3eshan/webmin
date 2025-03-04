#!/usr/local/bin/perl
# Start a websocket server connected to a shell

use lib ("$ENV{'PERLLIB'}/xterm/lib");
use Net::WebSocket::Server;
use utf8;

require './xterm-lib.pl';

my ($port, $user, $dir) = @ARGV;

# Switch to the user we're running as
my @uinfo = getpwnam($user);
my ($uid, $gid);
if ($user ne "root" && !$<) {
	if (!@uinfo) {
		&cleanup_miniserv();
		die "User $user does not exist!";
		}
	$uid = $uinfo[2];
	$gid = $uinfo[3];
	}
else {
	$uid = $gid = 0;
	}

# Run the user's shell in a sub-process
&foreign_require("proc");
&clean_environment();

# Terminal inbuilt flavors (envs)
if ($config{'flavors'} == 1 ||
    $config{'flavors'} == 2 && $uinfo[8] =~ /\/bash$/) {

	# Set shell history controls
	$ENV{'HISTCONTROL'} = 'ignoredups:ignorespace';
	
	# Set PS1, if flavors are forced or
	# skip in auto mode, if already set
	if ($config{'flavors'} == 1 ||
	    $config{'flavors'} == 2 && !$ENV{'PS1'}) {
		my $ps1;

		# Optionally add colors to the prompt depending on the user type
		if ($user eq "root") {
			# magenta@blue ~# (for root)
			$ps1 = '\[\033[1;35m\]\u\[\033[1;37m\]@'.
			       '\[\033[1;34m\]\h:\[\033[1;37m\]'.
			       '\w\[\033[1;37m\]$\[\033[0m\] ';
			}
		else {
			# green@blue ~$ (for regular users)
			$ps1 = '\[\033[1;32m\]\u\[\033[1;37m\]@'.
			       '\[\033[1;34m\]\h:\[\033[1;37m\]'.
			       '\w\[\033[1;37m\]$\[\033[0m\] ';
			}
		$ENV{'PS1'} = $ps1;
		}
	}

# Set terminal
$ENV{'TERM'} = 'xterm-256color';
$ENV{'HOME'} = $uinfo[7];
chdir($dir || $uinfo[7] || "/");
my $shell = $uinfo[8];
$shell =~ s/^.*\///;
$shell = "-".$shell;
my ($shellfh, $pid) = &proc::pty_process_exec($uinfo[8], $uid, $gid, $shell);
&reset_environment();
if (!$pid) {
	&cleanup_miniserv();
	die "Failed to run shell $uinfo[8]";
	}
print STDERR "shell process is $pid\n";

# Detach from controlling terminal
if (fork()) {
	exit(0);
	}
untie(*STDIN);
close(STDIN);

$SIG{'ALRM'} = sub {
	&cleanup_miniserv();
	die "timeout waiting for connection";
	};
alarm(60);
print STDERR "listening on port $port\n";
my ($wsconn, $shellbuf);
Net::WebSocket::Server->new(
	listen     => $port,
	on_connect => sub {
		my ($serv, $conn) = @_;
		print STDERR "got websockets connection\n";
		if ($wsconn) {
			print STDERR "Unexpected second connection to the same port\n";
			$conn->disconnect();
			return;
			}
		$wsconn = $conn;
		alarm(0);
		$conn->on(
			handshake => sub {
				# Is the key valid for this Webmin session?
				my ($conn, $handshake) = @_;
				my $key   = $handshake->req->fields->{'sec-websocket-key'};
				my $dsess = &encode_base64($main::session_id);
				$key   =~ s/\s//g;
				$dsess =~ s/\s//g;
				if ($key ne $dsess) {
					print STDERR "Key $key does not match session ID $dsess\n";
					$conn->disconnect();
					}
				},
			ready => sub {
				my ($conn) = @_;
				$conn->send_binary($shellbuf) if ($shellbuf);
				},
			utf8 => sub {
				my ($conn, $msg) = @_;
				utf8::encode($msg) if (utf8::is_utf8($msg));
				# Check for resize escape sequence explicitly
				if ($msg =~ /^\\033\[8;\((\d+)\);\((\d+)\)t$/) {
					my ($rows, $cols) = ($1, $2);
					print STDERR "got resize to $rows $cols\n";
					eval {
						$shellfh->set_winsize($rows, $cols);
						};
					kill('WINCH', $pid);
					return;
					}
				if (!syswrite($shellfh, $msg, length($msg))) {
					print STDERR "write to shell failed : $!\n";
					&cleanup_miniserv();
					exit(1);
					}
				},
			disconnect => sub {
				print STDERR "websocket connection closed\n";
				&cleanup_miniserv();
				kill('KILL', $pid) if ($pid);
				exit(0);
				}
			);
	},
	watch_readable => [
		$shellfh => sub {
			# Got something from the shell
			my $buf;
			my $ok = sysread($shellfh, $buf, 1024);
			if ($ok <= 0) {
				&cleanup_miniserv();
				exit(0);
				}
			if ($wsconn) {
				$wsconn->send_binary($buf);
				}
			else {
				$shellbuf .= $buf;
				}
		},
	],
)->start;
&cleanup_miniserv();

sub cleanup_miniserv
{
my %miniserv;
if ($port) {
	&lock_file(&get_miniserv_config_file());
	&get_miniserv_config(\%miniserv);
	my $wspath = "/$module_name/ws-".$port;
	if ($miniserv{'websockets_'.$wspath}) {
		delete($miniserv{'websockets_'.$wspath});
		&put_miniserv_config(\%miniserv);
		&reload_miniserv();
		}
	&unlock_file(&get_miniserv_config_file());
	}
}
