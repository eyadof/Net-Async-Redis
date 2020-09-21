package Net::Async::Redis;
# ABSTRACT: Redis support for IO::Async

use strict;
use warnings;

use parent qw(
    Net::Async::Redis::Commands
    IO::Async::Notifier
);

our $VERSION = '3.000';

=head1 NAME

Net::Async::Redis - talk to Redis servers via L<IO::Async>

=head1 SYNOPSIS

    use Net::Async::Redis;
    use Future::AsyncAwait;
    use IO::Async::Loop;
    my $loop = IO::Async::Loop->new;
    $loop->add(my $redis = Net::Async::Redis->new);
    (async sub {
     await $redis->connect;
     my $value = await $redis->get('some_key');
     $value ||= await $redis->set(some_key => 'some_value');
     print "Value: $value";
    })->()->get;

    # You can also use ->then chaining, see L<Future> for more details
    $redis->connect->then(sub {
        $redis->get('some_key')
    })->then(sub {
        my $value = shift;
        return Future->done($value) if $value;
        $redis->set(some_key => 'some_value')
    })->on_done(sub {
        print "Value: " . shift;
    })->get;

    # ... or with Future::AsyncAwait (recommended)
    await $redis->connect;
    my $value = await $redis->get('some_key');
    $value ||= await $redis->set(some_key => 'some_value');
    print "Value: $value";

=head1 DESCRIPTION

Provides client access for dealing with Redis servers.

See L<Net::Async::Redis::Commands> for the full list of commands, this list
is autogenerated from the official documentation here:

L<https://redis.io/commands>

This is intended to be a near-complete low-level client module for asynchronous Redis
support. See L<Net::Async::Redis::Server> for a (limited) Perl server implementation.

This is an unofficial Perl port, and not endorsed by the Redis server maintainers in any
way.

=head2 Supported features

Current features include:

=over 4

=item * L<all commands|https://redis.io/commands> as of 6.0.7 (September 2020), see L<https://redis.io/commands> for the methods and parameters

=item * L<pub/sub support|https://redis.io/topics/pubsub>, see L</METHODS - Subscriptions>

=item * L<pipelining|https://redis.io/topics/pipelining>, see L</pipeline_depth>

=item * L<transactions|https://redis.io/topics/transactions>, see L</METHODS - Transactions>

=item * L<streams|https://redis.io/topics/streams-intro> and consumer groups, via L<Net::Async::Redis::Commands/XADD> and related methods

=item * L<client-side caching|https://redis.io/topics/client-side-caching>, see L</METHODS - Clientside caching>

=item * L<RESP3/https://github.com/antirez/RESP3/blob/master/spec.md> protocol for Redis 6 and above, allowing pubsub on the same connection as regular commands

=back

=head2 Connecting

As with any other L<IO::Async::Notifier>-based module, you'll need to
add this to an L<IO::Async::Loop>:

    my $loop = IO::Async::Loop->new;
    $loop->add(
        my $redis = Net::Async::Redis->new
    );

then connect to the server:

    $redis->connect
        ->then(sub {
            # You could achieve a similar result by passing client_name in
            # constructor or ->connect parameters
            $redis->client_setname("example client")
        })->get;

=head2 Key-value handling

One of the most common Redis scenarios is as a key/value store. The L</get> and L</set>
methods are typically used here:

 $redis->set(some_key => 'some value')
  ->then(sub {
   $redis->get('some_key')
  })->on_done(sub {
   my ($value) = @_;
   print "Read back value [$value]\n";
  })->retain;

See the next section for more information on what these methods are actually returning.

=head2 Requests and responses

Requests are implemented as methods on the L<Net::Async::Redis> object.
These typically return a L<Future> which will resolve once ready:

    my $future = $redis->incr("xyz")
        ->on_done(sub {
            print "result of increment was " . shift . "\n"
        });

For synchronous code, call C<< ->get >> on that L<Future>:

    print "Database has " . $redis->dbsize->get . " total keys\n";

This means you can end up with C<< ->get >> being called on the result of C<< ->get >>,
note that these are two very different methods:

 $redis
  ->get('some key') # this is being called on $redis, and is issuing a GET request
  ->get # this is called on the returned Future, and blocks until the value is ready

Typical async code would not be expected to use the L<Future/get> method extensively;
often only calling it in one place at the top level in the code.

=head2 Error handling

Since L<Future> is used for deferred results, failure is indicated
by a failing Future with L<failure category|Future/FAILURE-CATEGORIES>
of C<redis>.

The L<Future/catch> feature may be useful for handling these:

 $redis->lpush(key => $value)
     ->catch(
         redis => sub { warn "probably an incorrect type, cannot push value"; Future->done }
     )->get;

Note that this module uses L<Future::AsyncAwait> internally.

=cut

use mro;
use Class::Method::Modifiers;
use Syntax::Keyword::Try;
use curry::weak;
use Future::AsyncAwait;
use IO::Async::Stream;
use Ryu::Async;
use URI;
use URI::redis;
use Cache::LRU;

use Log::Any qw($log);
use Metrics::Any qw($metrics), strict => 0;
use OpenTracing::Any qw($tracer);

use List::Util qw(pairmap);
use Scalar::Util qw(reftype blessed);

use Net::Async::Redis::Multi;
use Net::Async::Redis::Subscription;
use Net::Async::Redis::Subscription::Message;

=head1 CONSTANTS

=head2 OPENTRACING_ENABLED

Defaults to false, this can be controlled by the C<USE_OPENTRACING>
environment variable. This provides a way to set the default opentracing
mode for all L<Net::Async::Redis> instances - you can enable/disable
for a specific instance via L</configure>:

 $redis->configure(opentracing => 1);

When enabled, this will create a span for every Redis request. See
L<OpenTracing::Any> for details.

=cut

use constant OPENTRACING_ENABLED => $ENV{USE_OPENTRACING} // 0;

# These only apply to the legacy RESP2 protocol. Since RESP3, connections
# are no longer restricted once pubsub activity has started.
our %ALLOWED_SUBSCRIPTION_COMMANDS = (
    SUBSCRIBE    => 1,
    PSUBSCRIBE   => 1,
    UNSUBSCRIBE  => 1,
    PUNSUBSCRIBE => 1,
    PING         => 1,
    QUIT         => 1,
);

# Any of these commands would necessitate switching a RESP2 connection into
# a limited pubsub-only mode.
our %SUBSCRIPTION_COMMANDS = (
    SUBSCRIBE    => 1,
    PSUBSCRIBE   => 1,
    UNSUBSCRIBE  => 1,
    PUNSUBSCRIBE => 1,
    MESSAGE      => 1,
    PMESSAGE     => 1,
);


=head1 METHODS

B<NOTE>: For a full list of the Redis methods supported by this module,
please see L<Net::Async::Redis::Commands>.

=cut

=head2 configure

Applies configuration parameters - currently supports:

=over 4

=item * C<host>

=item * C<port>

=item * C<auth>

=item * C<database>

=item * C<pipeline_depth>

=item * C<stream_read_len>

=item * C<stream_write_len>

=item * C<on_disconnect>

=item * C<client_name>

=item * C<opentracing>

=back

=cut

sub configure {
    my ($self, %args) = @_;
    for (qw(
        host
        port
        auth
        database
        pipeline_depth
        stream_read_len
        stream_write_len
        on_disconnect
        client_name
        opentracing
    )) {
        $self->{$_} = delete $args{$_} if exists $args{$_};
    }

    # Be more lenient with the URI parameter, since it's tedious to
    # need the redis:// prefix every time... after all, what else
    # would we expect it to be?
    if(exists $args{uri}) {
        my $uri = delete $args{uri};
        $uri = "redis://$uri" unless ref($uri) or $uri =~ /^redis:/;
        $self->{uri} = $uri;
    }

    if(exists $args{client_side_cache_size}) {
        $self->{client_side_cache_size} = delete $args{client_side_cache_size};
        delete $self->{client_side_cache};
        if($self->loop) {
            $self->remove_child(delete $self->{client_side_connection}) if $self->{client_side_connection};
        }
    }
    my $uri = $self->{uri} = URI->new($self->{uri}) unless ref $self->uri;
    if($uri) {
        $self->{host} //= $uri->host;
        $self->{port} //= $uri->port;
    }
    $self->next::method(%args)
}

=head2 host

Returns the host or IP address for the Redis server.

=cut

sub host { shift->{host} }

=head2 port

Returns the port used for connecting to the Redis server.

=cut

sub port { shift->{port} }

=head2 database

Returns the database index used when connecting to the Redis server.

See the L<Net::Async::Redis::Commands/select> method for details.

=cut

sub database { shift->{database} }

=head2 uri

Returns the Redis endpoint L<URI> instance.

=cut

sub uri { shift->{uri} //= URI->new('redis://localhost') }

=head2 stream_read_len

Returns the buffer size when reading from a Redis connection.

Defaults to 1MB, reduce this if you're dealing with a lot of connections and
want to minimise memory usage. Alternatively, if you're reading large amounts
of data and spend too much time in needless C<epoll_wait> calls, try a larger
value.

=cut

sub stream_read_len { shift->{stream_read_len} //= 1048576 }

=head2 stream_write_len

Returns the buffer size when writing to Redis connections, in bytes. Defaults to 1MB.

See L</stream_read_len>.

=cut

sub stream_write_len { shift->{stream_read_len} //= 1048576 }

=head2 client_name

Returns the name used for this client when connecting.

=cut

sub client_name { shift->{client_name} }

=head1 METHODS - Connection

=head2 connect

Connects to the Redis server.

Will use the L</configure>d parameters if available, but as a convenience
can be passed additional parameters which will then be applied as if you
had called L</configure> with those beforehand. This also means that they
will be preserved for subsequent L</connect> calls.

=cut

sub connect : method {
    my ($self, %args) = @_;
    $self->configure(%args) if %args;
    my $uri = $self->uri->clone;
    for (qw(host port)) {
        $uri->$_($self->$_) if defined $self->$_;
    }

    # 0 is the default anyway, no need to apply in that case
    $uri->path('/' . $self->database) if $self->database;

    my $auth = $self->{auth};
    $auth //= ($uri->userinfo =~ s{^[^:]*:}{}r) if defined $uri->userinfo;
    $self->{connection} //= $self->loop->connect(
        service => $uri->port // 6379,
        host    => $uri->host,
        socktype => 'stream',
    )->then(async sub {
        my ($sock) = @_;
        $self->{endpoint} = join ':', $sock->peerhost, $sock->peerport;
        $self->{local_endpoint} = join ':', $sock->sockhost, $sock->sockport;
        my $proto = $self->protocol;
        my $stream = IO::Async::Stream->new(
            handle              => $sock,
            read_len            => $self->stream_read_len,
            write_len           => $self->stream_write_len,
            # Arbitrary multipliers for our stream values,
            # in a memory-constrained environment it's expected
            # that ->stream_read_len would be configured with
            # low enough values for this not to be a concern.
            read_high_watermark => 16 * $self->stream_read_len,
            read_low_watermark  => 2 * $self->stream_read_len,
            on_closed           => $self->curry::weak::notify_close,
            on_read             => sub {
                $proto->parse($_[1]);
                0
            }
        );
        $self->add_child($stream);
        Scalar::Util::weaken(
            $self->{stream} = $stream
        );

        try {
            # Try issuing a HELLO to detect RESP3 or above
            await $self->hello(
                3, defined($auth) ? (
                    qw(AUTH default), $auth
                ) : (), defined($self->client_name) ? (
                    qw(SETNAME), $self->client_name
                ) : ()
            );
            $self->{protocol_level} = 'resp3';
        } catch {
            # If we had an auth failure or invalid client name, all bets are off:
            # immediately raise those back to the caller
            die $@ unless $@ =~ /ERR unknown command/;

            $log->tracef('Older Redis version detected, dropping back to RESP2 protocol');
            $self->{protocol_level} = 'resp2';

            await $self->auth($auth) if defined $auth;
            await $self->client_setname($self->client_name) if defined $self->client_name;
        }

        await $self->select($uri->database) if $uri->database;
        return Future->done;
    })->on_fail(sub { delete $self->{connection} })
      ->on_cancel(sub { delete $self->{connection} });
}

=head2 connected

Establishes a connection if needed, otherwise returns an immediately-available
L<Future> instance.

=cut

sub connected {
    my ($self) = @_;
    return $self->{connection} if $self->{connection};
    $self->connect;
}

=head2 endpoint

The string describing the remote endpoint.

=cut

sub endpoint { shift->{endpoint} }

=head2 local_endpoint

A string describing the local endpoint, usually C<host:port>.

=cut

sub local_endpoint { shift->{local_endpoint} }

=head1 METHODS - Subscriptions

See L<https://redis.io/topics/pubsub> for more details on this topic.
There's also more details on the internal implementation in Redis here:
L<https://making.pusher.com/redis-pubsub-under-the-hood/>.

B<NOTE>: On Redis versions prior to 6.0, you will need a I<separate> connection
for subscriptions; you cannot share a connection for regular requests once
any of the L</subscribe> or L</psubscribe> methods have been called on an
existing connection.

With Redis 6.0, a newer protocol version (RESP3) is used by default, and
this is quite happy to support pubsub activity on the same connection
as other traffic.

=cut

=head2 psubscribe

Subscribes to a pattern.

Example:

 # Subscribe to 'info::*' channels, i.e. any message
 # that starts with the C<info::> prefix, and prints them
 # with a timestamp.
 $redis_connection->psubscribe('info::*')
    ->then(sub {
        my $sub = shift;
        $sub->map('payload')
            ->each(sub {
             print localtime . ' ' . $_ . "\n";
            })->retain
    })->get;
 # this will block until the subscribe is confirmed. Note that you can't publish on
 # a connection that's handling subscriptions due to Redis protocol restrictions.
 $other_redis_connection->publish('info::example', 'a message here')->get;

Returns a L<Future> which resolves to a L<Net::Async::Redis::Subscription> instance.

=cut

async sub psubscribe {
    my ($self, $pattern) = @_;
    $self->{pending_subscription_pattern_channel}{$pattern} //= $self->future('pattern_subscription[' . $pattern . ']');
    await $self->next::method($pattern);
    $self->{pubsub} //= 0;
    return $self->{subscription_pattern_channel}{$pattern} //= Net::Async::Redis::Subscription->new(
        redis   => $self,
        channel => $pattern
    )
}

=head2 subscribe

Subscribes to one or more channels.

Returns a L<Future> which resolves to a L<Net::Async::Redis::Subscription> instance.

Example:

 # Subscribe to 'notifications' channel,
 # print the first 5 messages, then unsubscribe
 $redis->subscribe('notifications')
    ->then(sub {
        my $sub = shift;
        $sub->events
            ->map('payload')
            ->take(5)
            ->say
            ->completed
    })->then(sub {
        $redis->unsubscribe('notifications')
    })->get

=cut

async sub subscribe {
    my ($self, @channels) = @_;
    my @pending = map {
        $self->{pending_subscription_channel}{$_} //= $self->future('subscription[' . $_ . ']')
    } @channels;
    await $self->next::method(@channels);
    $self->{pubsub} //= 0;
    await Future->wait_all(@pending);
    $log->tracef('Susbcriptions established, we are go');
    return @{$self->{subscription_channel}}{@channels};
}

=head1 METHODS - Transactions

=head2 multi

Executes the given code in a Redis C<MULTI> transaction.

This will cause each of the requests to be queued on the server, then applied in a single
atomic transaction.

Note that the commands will resolve only after the transaction is committed: for example,
when the L</set> command is issued, Redis will return C<QUEUED>. This information
is B<not> used as the result - we only pass through the immediate
response if there was an error. The L<Future> representing
the response will be marked as done once the C<EXEC> command is applied and we have the
results back.

Example:

 $redis->multi(sub {
  my $tx = shift;
  $tx->incr('some::key')->on_done(sub { print "Final value for incremented key was " . shift . "\n"; });
  $tx->set('other::key => 'test data')
 })->then(sub {
  my ($success, $failure) = @_;
  return Future->fail("Had $failure failures, expecting everything to succeed") if $failure;
  print "$success succeeded\m";
  return Future->done;
 })->retain;

=cut

async sub multi {
    my ($self, $code) = @_;
    die 'Need a coderef' unless $code and reftype($code) eq 'CODE';

    my $multi = Net::Async::Redis::Multi->new(
        redis => $self,
    );
    my @pending = @{$self->{pending_multi}};

    $log->tracef('Have %d pending MULTI transactions',
        0 + @pending
    );
    push @{$self->{pending_multi}}, $self->loop->new_future->set_label($self->command_label('multi'));

    await Future->wait_all(
        @pending
    ) if @pending;
    await do {
        local $self->{_is_multi} = 1;
        Net::Async::Redis::Commands::multi($self);
    };
    return await $multi->exec($code)
}

around [qw(discard exec)] => sub {
    my ($code, $self, @args) = @_;
    local $self->{_is_multi} = 1;
    my $f = $self->$code(@args);
    (shift @{$self->{pending_multi}})->done;
    $f->retain
};

=head1 METHODS - Clientside caching

Enable clientside caching by passing a true value for C<client_side_caching_enabled> in
L</configure> or L</new>. This is currently B<experimental>, and only operates on
L<Net::Async::Redis::Commands/get> requests.

See L<https://redis.io/topics/client-side-caching> for more details on this feature.

=cut

async sub client_side_connection {
    my ($self) = @_;
    return if $self->{client_side_connection};

    if($self->{protocol_level} eq 'resp3') {
        $self->{client_side_cache_ready} = Future->done;
        Scalar::Util::weaken($self->{client_side_connection} = $self);
        return;
    }

    my $f = $self->{client_side_cache_ready} = $self->loop->new_future;
    $self->{client_side_connection} = my $redis = ref($self)->new(
        host => $self->host,
        port => $self->port,
        auth => $self->{auth},
    );
    $self->add_child($redis);
    my $id = await $redis->client_id;
    my $sub = await $redis->subscribe('__redis__:invalidate');
    $sub->events->each(sub {
        $log->tracef('Invalidating key %s', $_->payload);
        $self->client_side_cache->remove($_->payload);
    });
    $f->done;
    return;
}

=head2 client_side_cache_ready

Returns a L<Future> representing the client-side cache connection status,
if there is one.

=cut

sub client_side_cache_ready {
    my ($self) = @_;
    my $f = $self->{client_side_cache_ready} or return Future->fail('client-side cache is not enabled');
    return $f->without_cancel;
}

=head2 client_side_cache

Returns the L<Cache::LRU> instance used for the client-side cache.

=cut

sub client_side_cache {
    my ($self) = @_;
    $self->{client_side_cache} //= Cache::LRU->new(
        size => $self->client_side_cache_size,
    );
}

=head2 is_client_side_cache_enabled

Returns true if the client-side cache is enabled.

=cut

sub is_client_side_cache_enabled { defined shift->{client_side_cache_size} }

=head2 client_side_cache_size

Returns the current client-side cache size, as a number of entries.

=cut

sub client_side_cache_size { shift->{client_side_cache_size} }

around get => async sub {
    my ($code, $self, $k) = @_;
    return await $self->$code($k) unless $self->is_client_side_cache_enabled;

    $log->tracef('Check cache for [%s]', $k);
    my $v = $self->client_side_cache->get($k);
    return $v if defined $v;
    $log->tracef('Key [%s] was not cached', $k);
    return await $self->$code($k)->on_done(sub {
        $self->client_side_cache->set($k => shift)
    });
};


=head1 METHODS - Generic

=head2 keys

=cut

sub keys : method {
    my ($self, $match) = @_;
    $match //= '*';
    return $self->next::method($match);
}

=head2 watch_keyspace

A convenience wrapper around the keyspace notifications API.

Provides the necessary setup to establish a C<PSUBSCRIBE> subscription
on the C<__keyspace@*__> namespace, setting the configuration required
for this to start emitting events, and then calls C<$code> with each
event.

Note that this will switch the connection into pubsub mode on versions
of Redis older than 6.0, so it will no longer be available for any
other activity. This limitation does not apply on Redis 6 or above.

Use C<*> to listen for all keyspace changes.

Resolves to a L<Ryu::Source> instance.

=cut

async sub watch_keyspace {
    my ($self, $pattern, $code) = @_;
    $pattern //= '*';
    my $sub_name = '__keyspace@*__:' . $pattern;
    $self->{have_notify} ||= await $self->config_set(
        'notify-keyspace-events', 'Kg$xe'
    );
    my $sub = await $self->psubscribe($sub_name);
    my $ev = $sub->events;
    $ev->each(sub {
        my $message = $_;
        $log->tracef('Keyspace notification for channel %s, type %s, payload %s', map $message->$_, qw(channel type payload));
        my $k = $message->channel;
        $k =~ s/^[^:]+://;
        my $f = $code->($message->payload, $k);
        $f->retain if blessed($f) and $f->isa('Future');
    }) if $code;
    return $ev;
}

=head2 pipeline_depth

Number of requests awaiting responses before we start queuing.
This defaults to an arbitrary value of 100 requests.

Note that this does not apply when in L<transaction|METHODS - Transactions> (C<MULTI>) mode.

See L<https://redis.io/topics/pipelining> for more details on this concept.

=cut

sub pipeline_depth { shift->{pipeline_depth} //= 100 }

=head2 opentracing

Indicates whether L<OpenTracing::Any> support is enabled.

=cut

sub opentracing { shift->{opentracing} }

=head1 METHODS - Deprecated

This are still supported, but no longer recommended.

=cut

sub bus {
    shift->{bus} //= do {
        require Mixin::Event::Dispatch::Bus;
        Mixin::Event::Dispatch::Bus->VERSION(2.000);
        Mixin::Event::Dispatch::Bus->new
    }
}

=head1 METHODS - Internal

=cut

=head2 on_message

Called for each incoming message.

Passes off the work to L</handle_pubsub_message> or the next queue
item, depending on whether we're dealing with subscriptions at the moment.

=cut

sub on_message {
    my ($self, $data) = @_;
    local @{$log->{context}}{qw(redis_remote redis_local)} = ($self->endpoint, $self->local_endpoint);

    $log->tracef('Incoming message: %s, pending = %s', $data, join ',', map { $_->[0] } $self->{pending}->@*) if $log->is_trace;

    if($self->{protocol_level} eq 'resp2' and exists $self->{pubsub} and exists $SUBSCRIPTION_COMMANDS{uc $data->[0]}) {
        return $self->handle_pubsub_message(@$data);
    }

    return $self->complete_message($data);
}

sub complete_message {
    my ($self, $data) = @_;
    my $next = shift @{$self->{pending}} or die "No pending handler";
    $self->next_in_pipeline if @{$self->{awaiting_pipeline}};
    return if $next->[1]->is_cancelled;

    # This shouldn't happen, preferably
    $log->errorf("our [%s] entry is ready, original was [%s]??", $data, $next->[0]) if $next->[1]->is_ready;
    $next->[1]->done($data);
    return;
}

=head2 next_in_pipeline

Attempt to process next pending request when in pipeline mode.

=cut

sub next_in_pipeline {
    my ($self) = @_;
    my $depth = $self->pipeline_depth;
    until($depth and $self->{pending}->@* >= $depth) {
        return unless my $next = shift @{$self->{awaiting_pipeline}};
        my $cmd = join ' ', @{$next->[0]};
        $log->tracef("Have free space in pipeline, sending %s", $cmd);
        push @{$self->{pending}}, [ $cmd, $next->[1] ];
        my $data = $self->protocol->encode_from_client(@{$next->[0]});
        $self->stream->write($data);
    }
    # Ensure last ->write is in void context
    return;
}

=head2 on_error_message

Called when there's an error response.

=cut

sub on_error_message {
    my ($self, $data) = @_;
    local @{$log->{context}}{qw(redis_remote redis_local)} = ($self->endpoint, $self->local_endpoint);
    $log->tracef('Incoming error message: %s', $data);

    my $next = shift @{$self->{pending}} or die "No pending handler";
    $next->[1]->fail($data);
    $self->next_in_pipeline if @{$self->{awaiting_pipeline}};
    return;
}

=head2 handle_pubsub_message

Deal with an incoming pubsub-related message.

=cut

sub handle_pubsub_message {
    my ($self, $type, @details) = @_;
    $type = lc $type;
    if($type eq 'message') {
        my ($channel, $payload) = @details;
        if(my $sub = $self->{subscription_channel}{$channel}) {
            my $msg = Net::Async::Redis::Subscription::Message->new(
                type         => $type,
                channel      => $channel,
                payload      => $payload,
                redis        => $self,
                subscription => $sub
            );
            $sub->events->emit($msg);
        } else {
            $log->warnf('Have message for unknown channel [%s]', $channel);
        }
        $self->bus->invoke_event(message => [ $type, $channel, $payload ]) if exists $self->{bus};
        return;
    }
    if($type eq 'pmessage') {
        my ($pattern, $channel, $payload) = @details;
        if(my $sub = $self->{subscription_pattern_channel}{$pattern}) {
            my $msg = Net::Async::Redis::Subscription::Message->new(
                type         => $type,
                pattern      => $pattern,
                channel      => $channel,
                payload      => $payload,
                redis        => $self,
                subscription => $sub
            );
            $sub->events->emit($msg);
        } else {
            $log->warnf('Have message for unknown channel [%s]', $channel);
        }
        $self->bus->invoke_event(message => [ $type, $channel, $payload ]) if exists $self->{bus};
        return;
    }

    # Looks like this isn't a message, it's a response to (un)subscribe
    return $self->handle_pubsub_response($type, @details);
}

sub handle_pubsub_response {
    my ($self, $type, @details) = @_;
    my ($channel, $payload) = @details;
    $type = lc $type;
    my $k = (substr $type, 0, 1) eq 'p' ? 'subscription_pattern_channel' : 'subscription_channel';
    if($type =~ /unsubscribe$/) {
        --$self->{pubsub};
        if(my $sub = delete $self->{$k}{$channel}) {
            $log->tracef('Removed subscription for [%s]', $channel);
        } else {
            $log->warnf('Have unsubscription for unknown channel [%s]', $channel);
        }
    } elsif($type =~ /subscribe$/) {
        $log->tracef('Have %s subscription for [%s]', (exists $self->{$k}{$channel} ? 'existing' : 'new'), $channel);
        ++$self->{pubsub};
        $self->{$k}{$channel} //= Net::Async::Redis::Subscription->new(
            redis => $self,
            channel => $channel
        );
        $self->{'pending_' . $k}{$channel}->done($payload) unless $self->{'pending_' . $k}{$channel}->is_done;
    } else {
        $log->warnf('have unknown pubsub message type %s with channel %s payload %s', $type, $channel, $payload);
    }

    return $self->complete_message([ $type, @details ]) unless $self->{protocol_level} eq 'resp2';
}

=head2 stream

Represents the L<IO::Async::Stream> instance for the active Redis connection.

=cut

sub stream { shift->{stream} }

=head2 notify_close

Called when the socket is closed.

=cut

sub notify_close {
    my ($self) = @_;
    # If we think we have an existing connection, it needs removing:
    # there's no guarantee that it's in a usable state.
    if(my $stream = delete $self->{stream}) {
        $stream->close_now;
    }

    # Also clear our connection future so that the next request is triggered appropriately
    delete $self->{connection};

    # Clear out anything in the pending queue - we normally wouldn't expect anything to
    # have ready status here, but no sense failing on a failure. Note that we aren't
    # filtering out the list via grep because some of these Futures may be interdependent.
    $_->[1]->fail(
        'Server connection is no longer active',
        redis => 'disconnected'
    ) for grep { !$_->[1]->is_ready } splice @{$self->{pending}};

    # Subscriptions also need clearing up
    $_->cancel for values %{$self->{subscription_channel}};
    $self->{subscription_channel} = {};
    $_->cancel for values %{$self->{subscription_pattern_channel}};
    $self->{subscription_pattern_channel} = {};

    $self->maybe_invoke_event(disconnect => );
}

=head2 command_label

Generate a label for the given command list.

=cut

sub command_label {
    my ($self, @cmd) = @_;
    return join ' ', @cmd if $cmd[0] eq 'KEYS';
    return $cmd[0];
}

=head2 execute_command

Queues or executes the given command.

=cut

sub execute_command {
    my ($self, @cmd) = @_;

    # First, the rules: pubsub or plain
    my $is_sub_command = (
        $self->{protocol_level} eq 'resp2' and exists $SUBSCRIPTION_COMMANDS{$cmd[0]}
    );

    return Future->fail(
        'Currently in pubsub mode, cannot send regular commands until unsubscribed',
        redis =>
            0 + (keys %{$self->{subscription_channel}}),
            0 + (keys %{$self->{subscription_pattern_channel}})
    ) if $self->{protocol_level} ne 'resp3' and exists $self->{pubsub} and not exists $ALLOWED_SUBSCRIPTION_COMMANDS{$cmd[0]};

    my $f = $self->loop->new_future->set_label(
        $self->command_label(@cmd)
    );
    $tracer->span_for_future($f) if $self->opentracing;
    $log->tracef("Will have to wait for %d MULTI tx", 0 + @{$self->{pending_multi}}) unless $self->{_is_multi};
    my $code = sub {
        local @{$log->{context}}{qw(redis_remote redis_local)} = ($self->endpoint, $self->local_endpoint);
        my $cmd = join ' ', @cmd;
        $log->tracef('Outgoing [%s]', $cmd);
        my $depth = $self->pipeline_depth;
        $log->tracef("Pipeline depth now %d/%d", 0 + @{$self->{pending}}, $depth);
        if($depth && $self->{pending}->@* >= $depth) {
            $log->tracef("Pipeline full, deferring %s (%d others in that queue)", $cmd, 0 + @{$self->{awaiting_pipeline}});
            push @{$self->{awaiting_pipeline}}, [ \@cmd, $f ];
            return $f;
        }
        my $data = $self->protocol->encode_from_client(@cmd);
        return $self->stream->write($data)->on_ready($f) if $is_sub_command;

        # Void-context write allows IaStream to combine multiple writes on the same connection.
        push @{$self->{pending}}, [ $cmd, $f ];
        $self->stream->write($data);
        return $f
    };
    return $code->()->retain if $self->{stream} and ($self->{is_multi} or 0 == @{$self->{pending_multi}});
    return (
        $self->{_is_multi}
        ? $self->connected
        : Future->wait_all(
            $self->connected,
            @{$self->{pending_multi}}
        )
    )->then($code)
     ->retain;
}

=head2 ryu

A L<Ryu::Async> instance for source/sink creation.

=cut

sub ryu {
    my ($self) = @_;
    $self->{ryu} ||= do {
        $self->add_child(
            my $ryu = Ryu::Async->new
        );
        $ryu
    }
}

=head2 future

Factory method for creating new L<Future> instances.

=cut

sub future {
    my ($self) = @_;
    return $self->loop->new_future(@_);
}

=head2 protocol

Returns the L<Net::Async::Redis::Protocol> instance used for
encoding and decoding messages.

=cut

sub protocol {
    my ($self) = @_;
    $self->{protocol} ||= do {
        require Net::Async::Redis::Protocol;
        Net::Async::Redis::Protocol->new(
            handler => $self->curry::weak::on_message,
            pubsub  => $self->curry::weak::handle_pubsub_message,
            error   => $self->curry::weak::on_error_message,
        )
    };
}

=head2 _init



=cut

sub _init {
    my ($self, @args) = @_;
    $self->{protocol_level} //= 'resp2';
    $self->{pending_multi} //= [];
    $self->{pending} //= [];
    $self->{awaiting_pipeline} //= [];
    $self->{opentracing} = OPENTRACING_ENABLED;
    $self->next::method(@args);
}

=head2 _add_to_loop



=cut

sub _add_to_loop {
    my ($self, $loop) = @_;
    delete $self->{client_side_connection};
    # $self->client_side_connection->retain if $self->client_side_cache_size;
}

1;

__END__

=head1 SEE ALSO

Some other Redis implementations on CPAN:

=over 4

=item * L<Mojo::Redis2> - nonblocking, using the L<Mojolicious> framework, actively maintained

=item * L<MojoX::Redis> - changelog mentions that this was obsoleted by L<Mojo::Redis>, although there
have been new versions released since then

=item * L<RedisDB> - another synchronous (blocking) implementation, handles pub/sub and autoreconnect

=item * L<Cache::Redis> - wrapper around L<RedisDB>

=item * L<Redis::Fast> - wraps C<hiredis>, faster than L<Redis>

=item * L<Redis::Jet> - also XS-based, docs mention C<very early development stage> but appears to support
pipelining and can handle newer commands via C<< ->command >>.

=item * L<Redis> - synchronous (blocking) implementation, handles pub/sub and autoreconnect

=item * L<HiRedis::Raw> - another C<hiredis> wrapper

=back

=head1 AUTHOR

Tom Molesworth <TEAM@cpan.org>

=head1 CONTRIBUTORS

With thanks to the following for contributing patches, bug reports,
tests and feedback:

=over 4

=item * C<< BINARY@cpan.org >>

=item * C<< PEVANS@cpan.org >>

=item * C<< @eyadof >>

=item * Nael Alolwani

=back

=head1 LICENSE

Copyright Tom Molesworth and others 2015-2020.
Licensed under the same terms as Perl itself.

