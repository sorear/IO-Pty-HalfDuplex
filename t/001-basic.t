#!/usr/bin/env perl
# vim: sw=4 et
use strict;
use warnings;
use Test::More tests => 32;

use IO::Handle;

use_ok 'IO::Pty::HalfDuplex';

# Support for mock subprocess

pipe (my $comm_read, my $comm_write);
pipe (my $val_read, my $val_write);

$val_write->autoflush(1);
$comm_write->autoflush(1);

sub queryA {
    my $str = shift;
    print $comm_write "$str\n";
}

sub queryB {
    my $out = <$val_read>;
    chomp $out;
    return $out;
}

sub ready {
    my $vin = '';
    vec($vin, fileno($val_read), 1) = 1;
    select $vin, undef, undef, 0;
}

sub query { queryA @_; queryB; }


# Now we can start

my $pty = new_ok('IO::Pty::HalfDuplex');

ok(!$pty->is_active, "pty starts inactive");

$pty->spawn (sub { print ((eval(<$comm_read>) || $@), "\n") while 1; });

is(query('2 + 2'), 4,                  "mock slave is functional for success");
is(query('die "moo"'), "moo",          "mock slave is functional for failure");

is(query('$$'), query('getppid'),      "slave is a process group leader");

is(query('POSIX::tcgetpgrp(0)'), query('getpgid getppid'),
                                       "and is running in the background");

query('print 2');
queryA('$_ = <STDIN>; chomp; $_');

is($pty->read(), "2\n",                "First read got output");

$pty->write('3\n');

ok(!ready(),                           "No data readable until read");

queryA('<STDIN>, 0');

is($pty->read(), "",                   "Successful read of nothing");

ok(ready(),                            "Read allowed process to continue");

is(queryB(), "3",                      "Written data received by slave");

# Still going?  Up the ante.

$pty->write("\n");

queryA('print 4; sleep 1; print 5');
queryA('<STDIN>; my $a = "\1"; my $r = select $a, undef, undef, 0.1; ' .
       '<STDIN>; $r');

is($pty->read, "45",                   "Laggy reception does not break read");

is(queryB(), "0",                      "sync received");

$pty->write('\n');
select undef, undef, undef, 0.3;
$pty->write('\n');

queryA('<STDIN>');

is($pty->read, "",                     "Null read");
is($pty->read, "",                     "back-to-back reads give null");

is(queryB(), "",                       "sync received");
is(queryB(), "1",                      "Laggy transmittion appears instant");

# I'm impressed.  Up the ante again.

$pty->write("\n");
queryA('print 6; my $a = "\1"; select $a, undef, undef, 0; print 7; <STDIN>');

is($pty->read, "",                     "sync received");
is(queryB(),   "",                     "sync received");
is($pty->read, "6","select with empty input expectedly misinterpreted as read");

queryA('print 8; <STDIN>');

$pty->write("9\n");

queryA('exit');

is($pty->read, "78",                   "but another read uncorks");

is(queryB(), "9",                      "sync received");
is(queryB(), "",                       "sync received");

ok($pty->is_active,                    "exit not noticed before read");
is($pty->read, "",                     "exiting slave noticed");
ok(!$pty->is_acive,                    "now noticed, after read");
is($pty->read, undef,                  "reading exited -> undef");

# Wow.

$pty->spawn (sub { print ((eval(<$comm_read>) || $@), "\n") while 1; });

queryA('<STDIN> + <STDIN>; <STDIN>; <STDIN>');

$pty->write("2\n2\n");

is($pty->read, "4",                    "objects are reusable");

$pty->kill;
$pty->read;

ok(!$pty->is_active,                   "kill worked");

# A final test.

$pty->spawn (sub { print ((eval(<$comm_read>) || $@), "\n") while 1; });

queryA('<STDIN>; POSIX::tcflush(0, POSIX::TCOFLUSH); <STDIN>; ' .
       'print "10"; exit');

$pty->write("\n\n");

is($pty->read, "10", "output ioctli with non-empty input buffers are ignored");

$pty->close;

ok(1, "close did not error");


# Not tested: close, non-mock usage, automissing TTOU
