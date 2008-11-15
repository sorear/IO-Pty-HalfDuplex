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

my %used_sns;
sub queryA {
    my ($sn, $str) = @_;

    die "Serial number reused\n" if (++$used_sns{$sn} > 1);

    print $comm_write "$sn $str\n";
}

sub queryB {
    my ($sn, $expect, $name) = @_;
    my $out = <$val_read>;

    if ($out !~ /([0-9]+) (.*)\n/) {
        ok(0, "malformed response from mock");
        diag("got \"$out\"");
        return;
    }

    $name ||= 'sync';

    if ($1 != $sn) {
        is($1, $sn, $name);
        diag("(serial number)");
    } else {
        if (ref $expect eq 'Regexp') {
            like($2, $expect, $name);
        } else {
            is($2, $expect, $name);
        }
    }
}

sub ready {
    my $vin = '';
    vec($vin, fileno($val_read), 1) = 1;
    select $vin, undef, undef, 0;
}

sub mock {
    open LOG, ">>/tmp/k";
    LOG->autoflush(1);
    while (1) {
        my $line = <$comm_read>;
        print LOG "got $line";
        my ($sn, $code) = ($line =~ /([0-9]*) (.*)\n/);
        my $out = eval $code || $@;
        chomp $out;
        print LOG "replying $sn $out\n";
        print $val_write "$sn $out\n";
    }
}

# Now we can start

my $pty = new_ok('IO::Pty::HalfDuplex');

ok(!$pty->is_active, "pty starts inactive");

$pty->spawn (\&mock);

# I means that the slave is now waiting on stdin.
# C means ... the command pipe.

queryA(0, '2 + 2');
queryB(0, 4,                           "mock slave is functional for success");
queryA(1, 'die "moo\n"');
queryB(1, "moo",                       "mock slave is functional for failure");

queryA(2, '$$ . " " . getpgrp');
queryB(2, qr/^(.*) \1$/,               "slave is a process group leader");

queryA(3, 'POSIX::tcgetpgrp(0) . " " . getpgrp(getppid)');
queryB(3, qr/^(.*) \1$/,               "and is running in the background");

queryA(4, 'print 2; $_ = <STDIN>; chomp; $_'); #I

is($pty->read(), "2",                  "First read got output");
is($pty->read(), "",                   "Back-to-back reads get nothing");

$pty->write('3\n');

ok(!ready(),                           "No data readable until read");

queryA(5, '<STDIN>; print 4; sleep 1; print 5; <STDIN>; my $a = "\1"; ' .
          'my $r = select $a, undef, undef, 0.1; <STDIN>; $r');

is($pty->read(), "",                   "Successful read of nothing"); #C

ok(ready(),                            "Read allowed process to continue");

queryB(4, '3',                         "Written data received by slave");

# Still going?  Up the ante.

$pty->write("\n");

is($pty->read, "45",                   "Laggy reception does not break read");

$pty->write("\n");
select undef, undef, undef, 0.3;
$pty->write("\n");

queryA(6, 'print 6; my $a = "\1"; select $a, undef, undef, 0; print 7; ' . 
          '<STDIN>');

is($pty->read, "6", "Select with empty input misinterpreted as read");

queryB(5, "1",                         "Laggy transmittion appears instant");

# I'm impressed.  Up the ante again.

$pty->write("\n");
queryA(7, 'print 8; <STDIN>');

is($pty->read, "78",                   "but another read uncorks");

queryB(6, "",                          "sync received");

queryA(8, 'exit');

$pty->write("9\n");

ok($pty->is_active,                    "exit not noticed before read");
is($pty->read, "",                     "exiting slave noticed");
ok(!$pty->is_acive,                    "now noticed, after read");
is($pty->read, undef,                  "reading exited -> undef");

# Wow.

$pty->spawn(\&mock);

queryA(10, '<STDIN> + <STDIN>; <STDIN>; <STDIN>');

$pty->write("2\n2\n");

is($pty->read, "4",                    "objects are reusable");

$pty->kill;
$pty->read;

ok(!$pty->is_active,                   "kill worked");

# A final test.

$pty->spawn (\&mock);

queryA(11, '<STDIN>; POSIX::tcflush(0, POSIX::TCOFLUSH); <STDIN>; ' .
           'print "10"; exit');

$pty->write("\n\n");

is($pty->read, "10", "output ioctli with non-empty input buffers are ignored");

$pty->close;

ok(1, "close did not error");

