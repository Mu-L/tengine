#!/usr/bin/perl

# Tests for round robin with an empty re-resolvable upstream.
#
# The tengine round robin optimization (T_NGX_HTTP_UPSTREAM_RANDOM,
# T_NGX_HTTP_ROUND_ROBIN_OPT_ALI) scans peers as a ring, computing positions
# modulo peers->number and caching the last selected peer.  With re-resolvable
# servers peers->number is zero before the first successful resolving and again
# after an empty or negative answer, which used to abort the worker process:
# either SIGFPE on "% peers->number", or SIGSEGV on the NULL peer list.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;
use IO::Socket::INET;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy upstream_zone/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;
worker_processes 1;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    # not weighted, selected by the O(1) ring scan that caches the last peer
    upstream u {
        zone z 1m;
        server example.net:%%PORT_8081%% resolve max_fails=0;
    }

    # weighted, selected by the smooth weight scan
    upstream uw {
        zone zw 1m;
        server example.net:%%PORT_8081%% resolve max_fails=0 weight=2;
    }

    # lower the retry timeout after empty reply
    resolver 127.0.0.1:%%PORT_8982_UDP%% valid=1s;
    # retry query shortly after DNS is started
    resolver_timeout 1s;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_connect_timeout 1s;

        location /u {
            proxy_pass http://u/t;
        }

        location /uw {
            proxy_pass http://uw/t;
        }
    }

    server {
        listen       127.0.0.1:%%PORT_8081%%;
        server_name  localhost;

        location /t {
            root %%TESTDIR%%;
        }
    }
}

EOF

port(8083);

$t->write_file('t', 'SEE-THIS');

$t->run_daemon(\&dns_daemon, $t)->waitforfile($t->testdir . '/' . port(8982));
$t->try_run('no resolve in upstream server')->plan(9);

###############################################################################

# nothing resolved yet: the peer list is empty from the very first request

like(http_get('/u'), qr/502/, 'not resolved');
like(http_get('/uw'), qr/502/, 'not resolved weighted');

# two peers, one of them is alive; both upstreams are usable now, and the
# selected peer gets cached in peers->last_peer

update_name({A => '127.0.0.1 127.0.0.201'});

like(http_get('/u'), qr/SEE-THIS/, 'resolved');
like(http_get('/u'), qr/SEE-THIS/, 'resolved again');
like(http_get('/uw'), qr/SEE-THIS/, 'resolved weighted');

# all records removed, peers->number drops back to zero while the cached
# position still points to a removed peer

update_name();

like(http_get('/u'), qr/502/, 'peers removed');
like(http_get('/uw'), qr/502/, 'peers removed weighted');

# and the upstreams recover once the name resolves again

update_name({A => '127.0.0.1'});

like(http_get('/u'), qr/SEE-THIS/, 'peers restored');

# note: a peer set that changes while a peer selected earlier stays alive is
# covered by nginx-tests/upstream_resolve.t ('A AAAA AAAA' steps), which also
# checks that each peer is tried exactly once. Reproducing it here would depend
# on which peer the ring scan happens to cache.

unlike($t->read_file('error.log'), qr/exited on signal|SEGV|Sanitizer/,
	'no worker process crash');

###############################################################################

sub update_name {
	my ($name, $plan) = @_;

	$plan = 2 if !defined $plan;

	sub sock {
		IO::Socket::INET->new(
			Proto => 'tcp',
			PeerAddr => '127.0.0.1:' . port(8083)
		)
			or die "Can't connect to nginx: $!\n";
	}

	$name->{A} = '' unless $name->{A};
	$name->{AAAA} = '' unless $name->{AAAA};
	$name->{ERROR} = '' unless $name->{ERROR};

	my $req =<<EOF;
GET / HTTP/1.0
Host: localhost
X-A: $name->{A}
X-AAAA: $name->{AAAA}
X-ERROR: $name->{ERROR}

EOF

	my ($gen) = http($req, socket => sock()) =~ /X-Gen: (\d+)/;
	for (1 .. 10) {
		my ($gen2) = http($req, socket => sock()) =~ /X-Gen: (\d+)/;

		# let resolver cache expire to finish upstream reconfiguration
		select undef, undef, undef, 0.5;
		last unless ($gen + $plan > $gen2);
	}
}

###############################################################################

sub reply_handler {
	my ($recv_data, $h) = @_;

	my (@name, @rdata);

	use constant NOERROR	=> 0;
	use constant SERVFAIL	=> 2;

	use constant A		=> 1;
	use constant AAAA	=> 28;
	use constant IN		=> 1;

	# default values

	my ($hdr, $rcode, $ttl) = (0x8180, NOERROR, 1);

	# no records until the test asks for them

	$h = {} unless defined $h;

	# decode name

	my ($len, $offset) = (undef, 12);
	while (1) {
		$len = unpack("\@$offset C", $recv_data);
		last if $len == 0;
		$offset++;
		push @name, unpack("\@$offset A$len", $recv_data);
		$offset += $len;
	}

	$offset -= 1;
	my ($id, $type, $class) = unpack("n x$offset n2", $recv_data);
	my $name = join('.', @name);

	if ($h->{ERROR}) {
		$rcode = SERVFAIL;
		goto bad;
	}

	if ($name eq 'example.net') {
		if ($type == A && $h->{A}) {
			map { push @rdata, rd_addr($ttl, $_) } @{$h->{A}};
		}
		if ($type == AAAA && $h->{AAAA}) {
			map { push @rdata, rd_addr6($ttl, $_) } @{$h->{AAAA}};
		}
	}

bad:

	Test::Nginx::log_core('||', "DNS: $name $type $rcode");

	$len = @name;
	pack("n6 (C/a*)$len x n2", $id, $hdr | $rcode, 1, scalar @rdata,
		0, 0, @name, $type, $class) . join('', @rdata);
}

sub rd_addr {
	my ($ttl, $addr) = @_;

	my $code = 'split(/\./, $addr)';

	pack 'n3N nC4', 0xc00c, A, IN, $ttl, eval "scalar $code", eval($code);
}

sub expand_ip6 {
	my ($addr) = @_;

	substr ($addr, index($addr, "::"), 2) =
		join "0", map { ":" } (0 .. 8 - (split /:/, $addr) + 1);
	map { hex "0" x (4 - length $_) . "$_" } split /:/, $addr;
}

sub rd_addr6 {
	my ($ttl, $addr) = @_;

	pack 'n3N nn8', 0xc00c, AAAA, IN, $ttl, 16, expand_ip6($addr);
}

sub dns_daemon {
	my ($t) = @_;
	my ($data, $recv_data, $h);

	my $socket = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1',
		LocalPort => port(8982),
		Proto => 'udp',
	)
		or die "Can't create listening socket: $!\n";

	my $control = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => "127.0.0.1:" . port(8083),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	my $sel = IO::Select->new($socket, $control);

	local $SIG{PIPE} = 'IGNORE';

	# signal we are ready

	open my $fh, '>', $t->testdir() . '/' . port(8982);
	close $fh;
	my $cnt = 0;

	while (my @ready = $sel->can_read) {
		foreach my $fh (@ready) {
			if ($control == $fh) {
				my $new = $fh->accept;
				$new->autoflush(1);
				$sel->add($new);

			} elsif ($socket == $fh) {
				$fh->recv($recv_data, 65536);
				$data = reply_handler($recv_data, $h);
				$fh->send($data);
				$cnt++;

			} else {
				$h = process_name($fh, $cnt);
				$sel->remove($fh);
				$fh->close;
			}
		}
	}
}

# parse dns update

sub process_name {
	my ($client, $cnt) = @_;
	my $port = $client->sockport();

	my $headers = '';
	my $uri = '';
	my %h;

	while (<$client>) {
		$headers .= $_;
		last if (/^\x0d?\x0a?$/);
	}
	return 1 if $headers eq '';

	$uri = $1 if $headers =~ /^\S+\s+([^ ]+)\s+HTTP/i;
	return 1 if $uri eq '';

	$headers =~ /X-A: (.*)$/m;
	map { push @{$h{A}}, $_ } split(/ /, $1);
	$headers =~ /X-AAAA: (.*)$/m;
	map { push @{$h{AAAA}}, $_ } split(/ /, $1);
	$headers =~ /X-ERROR: (.*)$/m;
	$h{ERROR} = $1;

	Test::Nginx::log_core('||', "$port: response, 200");
	print $client <<EOF;
HTTP/1.1 200 OK
Connection: close
X-Gen: $cnt

OK
EOF

	return \%h;
}

###############################################################################
