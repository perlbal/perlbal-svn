#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use Test::More 'no_plan';

# option setup
my $start_servers = 2; # web servers to start

# setup a few web servers that we can work with
my @web_ports = map { start_webserver() } 1..$start_servers;
@web_ports = grep { $_ > 0 } map { $_ += 0 } @web_ports;
ok(scalar(@web_ports) == $start_servers, 'web servers started');

# setup a simple perlbal that uses the above server
my $webport = new_port();
my $dir = tempdir();
my $deadport = new_port();

my $pb_port = new_port();

print "Web ports: [@web_ports], PB = $pb_port, http = $webport, dead = $deadport\n";

my $conf = qq{
CREATE POOL a

CREATE SERVICE test
SET test.role = reverse_proxy
SET test.listen = 127.0.0.1:$pb_port
SET test.persist_client = 1
SET test.persist_backend = 1
SET test.pool = a
SET test.connect_ahead = 0
ENABLE test

CREATE SERVICE ws
SET ws.role = web_server
SET ws.listen = 127.0.0.1:$webport
SET ws.docroot = $dir
SET ws.dirindexing = 0
SET ws.persist_client = 1
ENABLE ws

};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

add_all();

# make first web client
my $wc = Perlbal::Test::WebClient->new;
$wc->server("127.0.0.1:$pb_port");
$wc->keepalive(1);
$wc->http_version('1.0');

# see if a single request works
my $resp = $wc->request('status');
ok($resp, 'status response ok');

# make a file on disk, verifying we can get it via disk/URL
my $file_content = "foo bar yo this is my content.\n" x 1000;
open(F, ">$dir/foo.txt");
print F $file_content;
close(F);
ok(filecontent("$dir/foo.txt") eq $file_content, "file good via disk");
{
    my $wc2 = Perlbal::Test::WebClient->new;
    $wc2->server("127.0.0.1:$webport");
    $wc2->keepalive(1);
    $wc2->http_version('1.0');
    $resp = $wc2->request('foo.txt');
    ok($resp && $resp->content eq $file_content, 'file good via network');
}

# try to get that file, via internal file redirect
$resp = $wc->request("reproxy_file:$dir/foo.txt");
ok($resp && $resp->content eq $file_content, "reproxy file");
$resp = $wc->request("reproxy_file:$dir/foo.txt");
ok($resp && $resp->content eq $file_content, "reproxy file");
ok($wc->reqdone >= 2, "2 on same conn");

# reproxy URL support
$resp = $wc->request("reproxy_url:http://127.0.0.1:$webport/foo.txt");
ok($resp->content eq $file_content, "reproxy URL");
$resp = $wc->request("reproxy_url:http://127.0.0.1:$webport/foo.txt");
ok($resp->content eq $file_content, "reproxy URL");
ok($wc->reqdone >= 4, "4 on same conn");

#print "resp = $resp, ", $resp->status_line, "\n";
#print "content: ", $resp->content, "\n";


sub add_all {
    foreach (@web_ports) {
        manage("POOL a ADD 127.0.0.1:$_") or die;
    }
}

sub remove_all {
    foreach (@web_ports) {
        manage("POOL a REMOVE 127.0.0.1:$_") or die;
    }
}

sub flush_pools {
    remove_all();
    add_all();
}



1;
