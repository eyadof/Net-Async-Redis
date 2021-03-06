#!/usr/bin/env perl
use strict;
use warnings;

use feature qw(say);

=head1 NAME

pub.pl - simple Redis publish example

=head1 SYNOPSIS

 pub.pl channel_name message_content
 pub.pl -h localhost channel_name message_content
 pub.pl -a some_password channel_name message_content

=cut

use Net::Async::Redis;
use IO::Async::Loop;

use Getopt::Long;
use Pod::Usage;

use Log::Any::Adapter qw(Stderr), log_level => 'trace';

GetOptions(
    'p|port' => \my $port,
    'h|host' => \my $host,
    'a|auth' => \my $auth,
    'h|help' => \my $help,
    't|timeout=i' => \my $timeout,
) or pod2usage(1);
pod2usage(2) if $help;

# Defaults
$timeout //= 30;
$host //= 'localhost';
$port //= 6379;

$SIG{PIPE} = 'IGNORE';
my $loop = IO::Async::Loop->new;

$loop->add(
    my $redis = Net::Async::Redis->new
);

my ($channel, $msg) = @ARGV or die 'need a channel';
Future->wait_any(
    $redis->connect
        ->then(sub {
            $redis->publish($channel => $msg)
        })->on_done(sub {
            say $_ // '<undef>' for @_;
        }),
    $loop->timeout_future(after => $timeout),
)->get;

