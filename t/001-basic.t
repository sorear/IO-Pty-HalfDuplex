#!/usr/bin/env perl
# vim: sw=4 et
use strict;
use warnings;
use Test::More tests => 24;

use IO::Handle;
use Time::HiRes 'gettimeofday';

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
        is($2, $expect, $name);
    }
}

sub ready {
    my $vin = '';
    vec($vin, fileno($val_read), 1) = 1;
    select $vin, undef, undef, 0;
}

sub mock {
    my $stderr = shift;
    open STDERR, ">&", $stderr  if  defined $stderr;
    open STDERR, ">/dev/null"   if !defined $stderr;

    while (1) {
        my $line = <$comm_read>;
        warn "got $line\n";
        my ($sn, $code) = ($line =~ /([0-9]*) (.*)\n/);
        my $out = eval $code;
        $out = $@ if $@;
        chomp $out;
        warn "replying $sn $out\n";
        print $val_write "$sn $out\n";
    }
}

# Now we can start

my $pty = IO::Pty::HalfDuplex->new(debug => (@ARGV == 1 && $ARGV[0] == "-v"));

isa_ok($pty, 'IO::Pty::HalfDuplex');

#ok($pty->{debug}, "pty successfully created in debug mode");

ok(!$pty->is_active, "pty starts inactive");

$pty->spawn (\&mock);

# I means that the slave is now waiting on stdin.
# C means ... the command pipe.

queryA(99, 'getppid . " " . $$');
my ($sup, $slv) = (<$val_read> =~ /[0-9]+ ([0-9]+) ([0-9]+)\n/);

warn "$sup $slv" if $pty->{debug};

queryA(0, '2 + 2');
queryB(0, 4,                           "mock slave is functional for success");
queryA(1, 'die "moo\n"');
queryB(1, "moo",                       "mock slave is functional for failure");

queryA(2, '$$ - getpgrp');
queryB(2, '0',                         "slave is a process group leader");

queryA(3, 'POSIX::tcgetpgrp(0) - getpgrp(getppid)');
queryB(3, '0',                         "and is running in the background");

queryA(4, 'print 2; warn "4/before read"; $_ = <STDIN>; if (!defined $_) { ' .
          'warn $!; }; warn "4/after read"; chomp; $_'); #I

is($pty->read(), "2",                  "First read got output");
is($pty->read(), "",                   "Back-to-back reads get nothing");

$pty->write("3\n");

ok(!ready(),                           "No data readable until read");

queryA(5, '<STDIN>; print 4; sleep 1; print 5; <STDIN>; $a = gettimeofday; ' .
          '<STDIN>; (gettimeofday - $a) < 0.1');

is($pty->read(), "",                   "Successful read of nothing");

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

is($pty->read, "67", "Non-blocking reads via select are ignored");

queryB(5, "1",                         "Laggy transmittion appears instant");

# I'm impressed.

$pty->write("\n");
queryA(7, 'exit; <STDIN>');

$pty->write("8\n");

ok($pty->is_active,                    "exit not noticed before read");
is($pty->read, "",                     "read last bit of data");
ok(!$pty->is_active,                   "now noticed, after read");
is($pty->read, undef,                  "reading exited -> undef");

# Wow.

$pty->spawn(\&mock);

queryA(10, 'print(<STDIN> + <STDIN>)');
queryA(11, '<STDIN>');

$pty->write("2\n2\n");

is($pty->read, "4",                    "objects are reusable");

$pty->kill;
$pty->read;

ok(!$pty->is_active,                   "kill worked");

# A final test.

$pty->spawn (\&mock);

queryA(20, '<STDIN>; POSIX::tcflush(0, POSIX::TCOFLUSH()); <STDIN>; ' .
           'print "10"; exit');

$pty->write("\n\n");

is($pty->read, "10", "output ioctli with non-empty input buffers are ignored");

$pty->close;

ok(1, "close did not error");

